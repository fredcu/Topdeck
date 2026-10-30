import SwiftUI
// SPDX-License-Identifier: MIT
import TopdeckFeatures

/// The Agents tab: requests to answer first, then every session the connected tools reported, the
/// ones waiting for approval first in line to be noticed, with a way back to each one's terminal.
struct AgentsView: View {
    let agents: AgentsFeature

    var body: some View {
        if agents.connected.isEmpty {
            setup
        } else if agents.sessions.isEmpty, agents.requests.isEmpty {
            FeatureUnavailableView(
                symbol: "terminal", title: "No agents at work",
                message: "Sessions show up here when \(names(agents.connected)) starts working.")
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(agents.requests) { AgentRequestCard(agents: agents, request: $0) }
                    ForEach(agents.sessions) { row($0) }
                }
                .padding(.vertical, 6)
            }
            .fadingEdges()
        }
    }

    private var setup: some View {
        VStack(spacing: 8) {
            FeatureUnavailableView(
                symbol: "terminal", title: "Your coding agents, in the notch",
                message: agents.available.isEmpty
                    ? "Install Claude Code or Codex, then connect it here."
                    : "The notch shows when an agent needs your approval or finishes, and takes you back to its "
                        + "terminal. Connecting adds a hook to the tool's own settings.")
            HStack(spacing: 8) {
                ForEach(agents.available) { tool in
                    Button("Connect \(tool.name)") { agents.connect(tool) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            if let failure = agents.failure {
                Text(failure).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ session: AgentSession) -> some View {
        let waiting = session.state == .waiting
        return HStack(spacing: 10) {
            ProviderLogo(providerID: session.tool.rawValue, name: session.tool.name, size: 18)
                .foregroundStyle(ProviderStyle.of(session.tool.rawValue).gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project).font(.callout.weight(.medium)).lineLimit(1)
                status(session)
                    .font(.caption)
                    .foregroundStyle(waiting ? .orange : .white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if session.app != nil {
                Button("Go") { agents.open(session) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(waiting ? Color.orange.opacity(0.85) : .white.opacity(0.14), in: Capsule())
                    .help("Go to its terminal")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(waiting ? Color.orange.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Go to Terminal") { agents.open(session) }.disabled(session.app == nil)
            Button("Clear") { agents.clear(session) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Clear") { agents.clear(session) }
    }

    @ViewBuilder private func status(_ session: AgentSession) -> some View {
        switch session.state {
        case .waiting: Text("\(session.tool.shortName) needs you: \(session.detail ?? "waiting for approval")")
        case .working: Text("\(session.tool.shortName) is working")
        // Fixed when drawn, not a ticking clock: it's redrawn whenever the tab is.
        case .done:
            Text("\(session.tool.shortName) finished \(session.updated.formatted(.relative(presentation: .named)))")
        }
    }
}

/// A permission request or an `AskUserQuestion` prompt, answered here or handed back to the terminal.
private struct AgentRequestCard: View {
    let agents: AgentsFeature
    let request: AgentRequest
    /// For a question: the labels picked so far, one list per question.
    @State private var picked: [[String]] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProviderLogo(providerID: request.tool.rawValue, name: request.tool.name, size: 16)
                    .foregroundStyle(ProviderStyle.of(request.tool.rawValue).gradient)
                Text(request.project).font(.callout.weight(.medium)).lineLimit(1)
                if !request.isQuestion {
                    Text(request.toolName).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if request.isQuestion {
                questions
            } else {
                if !request.summary.isEmpty {
                    Text(request.summary).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    pill("Deny", tint: .white.opacity(0.14)) { agents.answer(request, .deny) }
                    pill("Allow", tint: .green.opacity(0.7)) { agents.answer(request, .allow) }
                    if request.canAlwaysAllow {
                        pill("Always Allow", tint: .white.opacity(0.14)) { agents.answer(request, .allowAlways) }
                    }
                    Spacer(minLength: 0)
                    terminal
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.tool.name) in \(request.project) asks to use \(request.toolName)")
        .onAppear {
            if picked.count != request.questions.count { picked = request.questions.map { _ in [] } }
        }
    }

    @ViewBuilder private var questions: some View {
        ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
            Text(question.question).font(.caption).lineLimit(3)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(question.options, id: \.self) { option in
                    let chosen = picked.indices.contains(index) && picked[index].contains(option)
                    pill(option, tint: chosen ? .green.opacity(0.7) : .white.opacity(0.14)) {
                        pick(option, for: index)
                    }
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
        HStack(spacing: 6) {
            if needsSend {
                pill("Send", tint: .green.opacity(0.7)) { agents.answer(request, .answer(picked)) }
                    .disabled(picked.count != request.questions.count || picked.contains(where: \.isEmpty))
            }
            Spacer(minLength: 0)
            terminal
        }
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
        pill("Terminal", tint: .white.opacity(0.14)) { agents.answerInTerminal(request) }
            .accessibilityLabel("Answer in the terminal")
    }

    private func pill(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1)
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint, in: Capsule())
    }
}

/// "Claude Code and Codex".
private func names(_ tools: Set<AgentTool>) -> String {
    AgentTool.allCases.filter(tools.contains).map(\.name).formatted(.list(type: .and))
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
