// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore
import TopdeckSurface

/// An agent waiting for an answer, as the bar in Now's second row: the project, the command it wants to
/// run in mono, and Deny and Allow. It shows the oldest request, else the session that has waited
/// longest; a question is answered in the Agents space, where its choices are. Allow and Deny answer
/// exactly as the Agents space does.
public struct AgentRequestBar: View {
    enum Waiting {
        case request(AgentRequest)
        case session(AgentSession)
    }

    let agents: AgentsFeature
    let waiting: Waiting
    let open: (SpaceID) -> Void

    /// The bar for what is waiting now, or nil when nothing is.
    public init?(agents: AgentsFeature, open: @escaping (SpaceID) -> Void) {
        guard let waiting = Self.waiting(in: agents) else { return nil }
        self.agents = agents
        self.waiting = waiting
        self.open = open
    }

    private static func waiting(in agents: AgentsFeature) -> Waiting? {
        if let request = agents.requests.first { return .request(request) }
        return agents.sessions.filter { $0.state == .waiting }.min { $0.updated < $1.updated }.map(Waiting.session)
    }

    public var body: some View {
        DeckSlot(needsYou: true) {
            HStack(spacing: 6) {
                DeckIconView(.hand)
                Text(project).deckText(.body, color: Deck.signal).fontWeight(.semibold).lineLimit(1)
            }
            .foregroundStyle(Deck.signal)
            Text(summary).deckText(.command).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .accessibilityElement(children: .contain)
    }

    private var project: String {
        switch waiting {
        case .request(let request): request.project
        case .session(let session): session.project
        }
    }

    private var summary: String {
        switch waiting {
        case .request(let request): request.isQuestion ? (request.questions.first?.question ?? "") : request.summary
        case .session(let session): session.detail ?? "Waiting"
        }
    }

    /// Deny and Allow for a request; a question is answered in the Agents space, where its choices are.
    @ViewBuilder private var buttons: some View {
        switch waiting {
        case .request(let request) where !request.isQuestion:
            Button("Deny") { agents.answer(request, .deny) }.buttonStyle(.deck(slot: true))
            Button("Allow") { agents.answer(request, .allow) }.buttonStyle(.deck(.primary, slot: true))
        case .request:
            Button("Answer") { open(.agents) }.buttonStyle(.deck(.accent, slot: true))
        case .session(let session):
            Button("Open") { agents.open(session) }.buttonStyle(.deck(.outline, slot: true))
        }
    }
}
