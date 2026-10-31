// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckFeatures
import TopdeckSurface

/// The Sessions tab: requests to answer first, then every session the connected tools reported, the
/// ones waiting for approval first in line to be noticed, with a way back to each one's terminal.
struct AgentsView: View {
    let agents: AgentsFeature

    var body: some View {
        if agents.connected.isEmpty {
            setup
        } else if agents.sessions.isEmpty, agents.requests.isEmpty {
            DeckEmptyLine("No agents at work")
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(agents.requests) { AgentRequestCard(agents: agents, request: $0) }
                    VStack(spacing: 0) {
                        ForEach(agents.sessions) { row($0) }
                    }
                    .padding(.horizontal, 2)
                }
            }
            // Fades only at the bottom, so a card at the top isn't dimmed when there's nothing above it.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                }
            }
        }
    }

    private var setup: some View {
        VStack(spacing: Deck.Metric.gap) {
            Text(agents.available.isEmpty ? "No coding agents found" : "Connect a coding agent")
                .deckText(.body, color: Deck.tertiary)
            HStack(spacing: Deck.Metric.gap) {
                ForEach(agents.available) { tool in
                    Button("Connect \(tool.name)") { agents.connect(tool) }.buttonStyle(.deck())
                }
            }
            if let failure = agents.failure {
                Text(failure).deckText(.detail, color: Deck.stop).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A session: its state as a dot, the project, what it is doing, and how long ago. With a
    /// terminal to go back to, the whole row is the way there.
    private func row(_ session: AgentSession) -> some View {
        let tone: DeckTone = session.state == .waiting ? .signal : session.state == .working ? .go : .quiet
        return DeckRow(action: session.app == nil ? nil : { agents.open(session) }) {
            DeckDot(tone)
            Text(session.project).deckText(.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            status(session).deckText(.caption).lineLimit(1)
            Text(Self.age(of: session.updated))
                .deckText(.caption)
                .frame(width: 44, alignment: .trailing)
        }
        .help(session.app == nil ? "" : "Go to its terminal")
        .contextMenu {
            Button("Go to Terminal") { agents.open(session) }.disabled(session.app == nil)
            Button("Clear") { agents.clear(session) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.project), \(session.tool.name)")
        .accessibilityAction(named: "Clear") { agents.clear(session) }
    }

    private func status(_ session: AgentSession) -> Text {
        switch session.state {
        case .waiting: Text(session.detail ?? "Waiting for approval")
        case .working: Text("Working")
        case .done: Text("Done")
        }
    }

    /// "12m", "1h": the biggest unit only. Fixed when drawn, not a ticking clock: it's redrawn
    /// whenever the tab is.
    private static func age(of date: Date) -> String {
        let minutes = max(1, Int(Date.now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes)m" }
        return minutes < 24 * 60 ? "\(minutes / 60)h" : "\(minutes / (24 * 60))d"
    }
}

/// A permission request or an `AskUserQuestion` prompt, answered here or handed back to the terminal.
private struct AgentRequestCard: View {
    let agents: AgentsFeature
    let request: AgentRequest
    /// For a question: the labels picked so far, one list per question.
    @State private var picked: [[String]] = []

    var body: some View {
        DeckCard(request.isQuestion ? .standard : .signal) {
            VStack(alignment: .leading, spacing: Deck.Metric.gap) {
                header
                if request.isQuestion {
                    questions
                } else {
                    permission
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.tool.name) in \(request.project) asks to use \(request.toolName)")
        .onAppear {
            if picked.count != request.questions.count { picked = request.questions.map { _ in [] } }
        }
    }

    /// Who is asking, and from which tool.
    private var header: some View {
        HStack(spacing: Deck.Metric.gap) {
            HStack(spacing: 7) {
                DeckIconView(.hand).foregroundStyle(Deck.signal)
                Text(request.project)
                    .deckText(.body, color: request.isQuestion ? Deck.text : Deck.signal)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(request.isQuestion ? request.tool.name : "\(request.tool.name) · \(request.toolName)")
                .deckText(.caption)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var permission: some View {
        if !request.summary.isEmpty {
            Text(request.summary)
                .deckText(.command)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous).fill(Deck.deck))
        }
        HStack(spacing: Deck.Metric.gap) {
            Button("Allow") { agents.answer(request, .allow) }.buttonStyle(.deck(.primary)).fixedSize()
            Button("Deny") { agents.answer(request, .deny) }.buttonStyle(.deck()).fixedSize()
            if let rule = request.alwaysAllowRule {
                Button {
                    agents.answer(request, .allowAlways)
                } label: {
                    Text("Always Allow \(rule)").lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.deck(.outline))
                .accessibilityLabel("Always Allow \(rule)")
            }
            Spacer(minLength: 0)
            terminal
        }
    }

    @ViewBuilder private var questions: some View {
        let single = request.questions.count == 1
        ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
            Text(question.question).deckText(.body).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            if single {
                HStack(alignment: .top, spacing: Deck.Metric.gap) {
                    options(of: question, at: index).frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
            } else {
                options(of: question, at: index)
            }
        }
        if !single {
            HStack(spacing: Deck.Metric.gap) {
                if needsSend { send }
                Spacer(minLength: 0)
                terminal
            }
        }
    }

    private func options(of question: AgentQuestion, at index: Int) -> some View {
        DeckFlow(spacing: Deck.Metric.gap) {
            ForEach(question.options, id: \.self) { option in
                let chosen = picked.indices.contains(index) && picked[index].contains(option)
                Button(option) { pick(option, for: index) }
                    .buttonStyle(.deck(chosen ? .primary : .standard))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    /// Send, when the answer waits for it, and Terminal.
    private var actions: some View {
        HStack(spacing: Deck.Metric.gap) {
            if needsSend { send }
            terminal
        }
    }

    private var send: some View {
        Button("Send") { agents.answer(request, .answer(picked)) }
            .buttonStyle(.deck(.primary))
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
            .buttonStyle(.deck(.outline))
            .fixedSize()
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
