// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckFeatures
import TopdeckSurface

/// The Agents space's left column: the requests to answer first, then the sessions waiting on a terminal, then
/// the ones at work, a card each. A session that has finished or gone quiet is not listed. Clicking a session
/// goes to its terminal.
struct AgentsColumn: View {
    let agents: AgentsFeature

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                ForEach(agents.requests) { AgentRequestCard(agents: agents, request: $0) }
                ForEach(agents.waitingSessions) { SessionCard(agents: agents, session: $0) }
                ForEach(agents.runningSessions) { SessionCard(agents: agents, session: $0) }
            }
            .padding(.bottom, 6)
        }
        .fadingEdges(length: 6, atStart: false)
    }
}

/// A session: its project and a dot for its state, the tool and what it is doing, and what it is waiting for.
private struct SessionCard: View {
    let agents: AgentsFeature
    let session: AgentSession

    var body: some View {
        let waiting = session.state == .waiting
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Button {
            agents.open(session)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    DeckDot(waiting ? .signal : .go)
                }
                Text("\(session.tool.name), \(waiting ? "waiting" : "working")").deckText(.caption).lineLimit(1)
                if let detail = session.detail {
                    Text(detail).deckText(.command).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Deck.secondary).lineLimit(1)
                }
            }
            .foregroundStyle(Deck.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(waiting ? Deck.signalFill : Deck.card))
            .overlay(shape.strokeBorder(waiting ? Deck.signal.opacity(0.5) : Deck.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(session.app == nil)
        .help(session.app == nil ? "" : "Go to its terminal")
        .contextMenu {
            Button("Go to Terminal") { agents.open(session) }.disabled(session.app == nil)
            Button("Clear") { agents.clear(session) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.project), \(session.tool.name), \(waiting ? "waiting" : "working")")
        .accessibilityAction(named: "Clear") { agents.clear(session) }
    }
}

/// A permission request or an `AskUserQuestion` prompt, answered here or handed back to the terminal. The
/// answers, the safety around them and Always Allow are as they always were; only the card is narrower.
private struct AgentRequestCard: View {
    let agents: AgentsFeature
    let request: AgentRequest
    /// For a question: the labels picked so far, one list per question.
    @State private var picked: [[String]] = []

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            header
            if request.isQuestion { questions } else { permission }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(request.isQuestion ? Deck.card : Deck.signalFill))
        .overlay(shape.strokeBorder(request.isQuestion ? Deck.hairline : Deck.signal.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.tool.name) in \(request.project) asks to use \(request.toolName)")
        .onAppear {
            if picked.count != request.questions.count { picked = request.questions.map { _ in [] } }
        }
    }

    /// Who is asking, and with what.
    private var header: some View {
        HStack(spacing: 6) {
            Text(request.project)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(request.isQuestion ? Deck.text : Deck.signal)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(request.isQuestion ? request.tool.name : request.toolName).deckText(.caption).lineLimit(1)
        }
    }

    @ViewBuilder private var permission: some View {
        if !request.summary.isEmpty {
            Text(request.summary)
                .deckText(.command)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 6) {
            Button("Deny") { agents.answer(request, .deny) }.buttonStyle(.deck(fill: true, slot: true))
            Button("Allow") { agents.answer(request, .allow) }.buttonStyle(.deck(.primary, fill: true, slot: true))
        }
        if let rule = request.alwaysAllowRule {
            Button {
                agents.answer(request, .allowAlways)
            } label: {
                Text("Always Allow \(rule)").lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.deck(.outline, compact: true, fill: true))
            .accessibilityLabel("Always Allow \(rule)")
        }
        terminal
    }

    @ViewBuilder private var questions: some View {
        ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
            Text(question.question).deckText(.body).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            options(of: question, at: index)
        }
        HStack(spacing: 6) {
            if needsSend { send }
            terminal
        }
    }

    private func options(of question: AgentQuestion, at index: Int) -> some View {
        DeckFlow(spacing: 6) {
            ForEach(question.options, id: \.self) { option in
                let chosen = picked.indices.contains(index) && picked[index].contains(option)
                Button(option) { pick(option, for: index) }
                    .buttonStyle(.deck(chosen ? .primary : .standard, compact: true))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    private var send: some View {
        Button("Send") { agents.answer(request, .answer(picked)) }
            .buttonStyle(.deck(.primary, compact: true, fill: true))
            .disabled(picked.count != request.questions.count || picked.contains(where: \.isEmpty))
    }

    /// One question with one answer goes as soon as it's picked; anything more waits for Send.
    private var needsSend: Bool {
        request.questions.count > 1 || request.questions.contains(where: \.multiSelect)
    }

    private func pick(_ option: String, for index: Int) {
        guard picked.indices.contains(index) else { return }
        if request.questions[index].multiSelect {
            if let at = picked[index].firstIndex(of: option) {
                picked[index].remove(at: at)
            } else {
                picked[index].append(option)
            }
        } else {
            picked[index] = [option]
        }
        if !needsSend { agents.answer(request, .answer(picked)) }
    }

    private var terminal: some View {
        Button("Terminal") { agents.answerInTerminal(request) }
            .buttonStyle(.deck(.outline, compact: true, fill: true))
            .accessibilityLabel("Answer in the terminal")
    }
}

extension AgentsFeature {
    /// Settings › Agents: which tools report to the notch.
    public var settingsView: some View { AgentsSettings(agents: self) }
}

private struct AgentsSettings: View {
    @Bindable var agents: AgentsFeature

    var body: some View {
        Group {
            ForEach(AgentTool.allCases) { tool in
                // A closure, not a method reference: see the app's GeneralSettings.
                Toggle(
                    isOn: Binding(
                        get: { agents.connected.contains(tool) },
                        set: { $0 ? agents.connect(tool) : agents.disconnect(tool) })
                ) {
                    HStack(spacing: 6) {
                        ProviderLogo(providerID: tool.rawValue, name: tool.name, size: 14)
                        Text(tool.name)
                    }
                    Text(explanation(tool))
                }
                .disabled(!agents.available.contains(tool))
            }
            Toggle("Answer permission requests in the notch", isOn: $agents.answersRequests)
            Toggle("Show when an agent finishes in the background", isOn: $agents.announcesDone)
            if let failure = agents.failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: agents.refreshConnected)
    }

    private func explanation(_ tool: AgentTool) -> String {
        guard agents.available.contains(tool) else { return "Not on this Mac." }
        let adds = "Adds hooks to ~/\(tool.configPath); turning this off removes them."
        return tool == .codex ? adds + " Codex asks you to trust them the next time it starts." : adds
    }
}
