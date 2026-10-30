// SPDX-License-Identifier: MIT
import Foundation
import Testing
import TopdeckCore

@testable import TopdeckUsage

/// A Claude Code permission request for Bash, with the suggestions it offers.
private let bash = #"""
    {"session_id":"abc-123","hook_event_name":"PermissionRequest","cwd":"/Users/me/Code/nook",
     "tool_name":"Bash","tool_input":{"command":"rm -rf build\nls","description":"Clean"},
     "permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"},
      {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],"behavior":"allow",
       "destination":"localSettings"}]}
    """#

/// Claude Code's `AskUserQuestion`: one question with one answer, one with several.
private let question = #"""
    {"session_id":"q-1","hook_event_name":"PermissionRequest","cwd":"/work/app","tool_name":"AskUserQuestion",
     "tool_input":{"questions":[
      {"question":"Which database?","header":"DB","multiSelect":false,
       "options":[{"label":"Postgres","description":"Server"},{"label":"SQLite","description":"File"}]},
      {"question":"Which extras?","header":"Extras","multiSelect":true,
       "options":[{"label":"Auth"},{"label":"Billing"},{"label":"Search"}]}]}}
    """#

/// Codex's request, with its command as an argument list.
private let codex = #"""
    {"session_id":"019a-77","hook_event_name":"PermissionRequest","cwd":"/work/api","tool_name":"exec_command",
     "tool_input":{"command":["git","push"]},
     "permission_suggestions":[{"type":"addRules","rules":[],"behavior":"allow"}]}
    """#

private func parse(_ json: String, tool: AgentTool = .claude) throws -> AgentRequest {
    try AgentRequest.parse(Data(json.utf8), tool: tool)
}

/// `json` with one top-level field changed, or removed with nil.
private func changing(_ json: String, _ key: String, to value: Any?) throws -> String {
    var object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    object[key] = value
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func object(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Whether the hook exited cleanly having printed nothing: the agent asks in its own prompt.
private func printedNothing(_ result: (status: Int32, output: String)) -> Bool {
    result.status == 0 && result.output.isEmpty
}

/// The decision inside a hook's output.
private func decision(_ data: Data?) throws -> [String: Any] {
    let output = try #require(try object(data)["hookSpecificOutput"] as? [String: Any])
    #expect(output["hookEventName"] as? String == "PermissionRequest")
    return try #require(output["decision"] as? [String: Any])
}

struct AgentRequestTests {
    @Test func aPermissionRequestIsReadWithWhatItWants() throws {
        let request = try parse(bash)
        #expect(request.tool == .claude && request.session == "abc-123" && request.project == "nook")
        #expect(request.toolName == "Bash" && !request.isQuestion && request.canAlwaysAllow)
        #expect(request.summary == "rm -rf build ls", "one line, whatever the command")
    }

    @Test func aQuestionIsReadWithItsOptions() throws {
        let request = try parse(question)
        #expect(request.isQuestion && request.project == "app")
        #expect(request.questions.map(\.question) == ["Which database?", "Which extras?"])
        #expect(request.questions[0].options == ["Postgres", "SQLite"] && !request.questions[0].multiSelect)
        #expect(request.questions[1].options == ["Auth", "Billing", "Search"] && request.questions[1].multiSelect)
        #expect(request.questions[0].header == "DB")
    }

    @Test func codexRequestsCanBeAllowedOrDeniedOnly() throws {
        let request = try parse(codex, tool: .codex)
        #expect(request.summary == "git push" && request.project == "api")
        #expect(!request.canAlwaysAllow, "only Claude Code takes a remembered rule")
        let asked = try parse(try changing(codex, "tool_name", to: "AskUserQuestion"), tool: .codex)
        #expect(!asked.isQuestion, "Codex has no AskUserQuestion")
    }

    @Test func anythingMalformedIsTurnedAway() throws {
        func rejection(_ json: String) -> AgentRequest.Rejection? {
            do {
                _ = try AgentRequest.parse(Data(json.utf8), tool: .claude)
                return nil
            } catch {
                return error
            }
        }
        #expect(rejection("not json") == .notJSON)
        #expect(rejection("[1, 2]") == .notJSON)
        #expect(rejection(try changing(bash, "hook_event_name", to: "PreToolUse")) == .wrongEvent)
        #expect(rejection(try changing(bash, "hook_event_name", to: nil)) == .wrongEvent)
        let sessions: [Any] = ["", "../../etc", "a b", String(repeating: "a", count: 129), "é", 42]
        for session in sessions {
            #expect(rejection(try changing(bash, "session_id", to: session)) == .badSession)
        }
        let names: [Any] = ["", "Bash; rm -rf /", "Bash\n", String(repeating: "x", count: 129), ["Bash"]]
        for name in names {
            #expect(rejection(try changing(bash, "tool_name", to: name)) == .badToolName)
        }
        #expect(rejection(try changing(bash, "tool_input", to: "rm -rf /")) == .badInput)
        #expect(rejection(try changing(bash, "tool_input", to: ["rm"])) == .badInput)
        #expect(throws: AgentRequest.Rejection.notJSON) {
            try AgentRequest.parse(Data(repeating: 0x20, count: AgentRequest.maxSize + 1), tool: .claude)
        }
        #expect(try parse(changing(bash, "tool_input", to: nil)).summary.isEmpty, "no input is an empty one")
    }

    @Test func aQuestionWithoutUsableOptionsIsTurnedAway() throws {
        let twice: [String: Any] = ["question": "Which?", "options": ["A", "B"]]
        let lists: [[Any]] = [
            [], [["question": "Which?"]], [["question": "Which?", "options": [Any]()]],
            [["question": "Which?", "options": [["label": "A"], ["label": "A"]]]],
            [["question": "Which?", "options": [["description": "no label"]]]],
            [["question": "", "options": ["A"]]], [twice, twice],
        ]
        for list in lists {
            let input: [String: Any] = ["questions": list]
            let json = try changing(question, "tool_input", to: input)
            #expect(throws: AgentRequest.Rejection.badQuestion) { try parse(json) }
        }
    }

    @Test func onlyAnAllowRuleCanBeRemembered() throws {
        let mode: [[String: Any]] = [["type": "setMode", "mode": "plan"]]
        let deny: [[String: Any]] = [["type": "addRules", "behavior": "deny", "rules": [Any]()]]
        let noRules: [[String: Any]] = [["type": "addRules", "behavior": "allow"]]
        let cases: [Any] = [mode, deny, noRules, "allow everything"]
        for suggestions in cases {
            let request = try parse(changing(bash, "permission_suggestions", to: suggestions))
            #expect(!request.canAlwaysAllow)
        }
    }

    @Test func theRuleAlwaysAllowAddsIsSpelledOut() throws {
        #expect(try parse(bash).alwaysAllowRule == "Bash(rm -rf build)")
        func rule(_ rules: Any) throws -> String? {
            let suggestion: [[String: Any]] = [["type": "addRules", "behavior": "allow", "rules": rules]]
            return try parse(changing(bash, "permission_suggestions", to: suggestion)).alwaysAllowRule
        }
        #expect(try rule([["toolName": "Read"]]) == "Read")
        #expect(try rule([["toolName": "Bash", "ruleContent": ""]]) == "Bash")
        let two: [[String: Any]] = [
            ["toolName": "Bash", "ruleContent": "npm test"], ["toolName": "mcp__git__log"],
        ]
        #expect(try rule(two) == "Bash(npm test), mcp__git__log")
        #expect(try rule([["toolName": "Bash", "ruleContent": "a\nb"]]) == "Bash(a b)", "one line")
    }

    @Test func aRuleThatCantBeSpelledOutIsNotOffered() throws {
        let unparsable: [Any] = [
            [Any](), [["ruleContent": "npm test"]], [["toolName": 7]], [["toolName": "Bash"], "Read"],
            [["toolName": "Bash", "ruleContent": String(repeating: "x", count: 300)]], "Bash",
        ]
        for rules in unparsable {
            let suggestion: [[String: Any]] = [["type": "addRules", "behavior": "allow", "rules": rules]]
            let request = try parse(changing(bash, "permission_suggestions", to: suggestion))
            #expect(request.alwaysAllowRule == nil && !request.canAlwaysAllow && request.rule == nil)
            #expect(AgentDecision.allowAlways.payload(for: request) == nil)
        }
        #expect(try parse(codex, tool: .codex).alwaysAllowRule == nil)
    }

    @Test func aToolWithUnknownFieldsShowsItsInputAsJSON() throws {
        let input: [String: Any] = ["zone": "eu", "args": ["id": 7, "path": "/a/b"]]
        let mcp = try parse(changing(changing(bash, "tool_name", to: "mcp__db__run"), "tool_input", to: input))
        #expect(mcp.summary == #"{"args":{"id":7,"path":"/a/b"},"zone":"eu"}"#)
        let long = try parse(changing(bash, "tool_input", to: ["blob": String(repeating: "x", count: 500)]))
        #expect(long.summary.count == 300 && long.summary.hasSuffix("…"))
        #expect(try parse(changing(bash, "tool_input", to: [String: Any]())).summary.isEmpty)
    }

    @Test func theSocketHeaderIsStrict() {
        let claude = AgentWire.header("topdeck-agent 1 claude 42")
        #expect(claude?.tool == .claude && claude?.length == 42)
        let codex = AgentWire.header("topdeck-agent 1 codex 1048576")
        #expect(codex?.tool == .codex && codex?.length == 1_048_576)
        for line in [
            "topdeck-agent 1 claude 0", "topdeck-agent 1 claude 1048577", "topdeck-agent 1 claude +4",
            "topdeck-agent 1 claude -4", "topdeck-agent 2 claude 4", "topdeck-agent 1 cursor 4",
            "other 1 claude 4", "topdeck-agent 1 claude 4 extra", "topdeck-agent  1 claude 4", "",
        ] {
            #expect(AgentWire.header(line) == nil, "\(line)")
        }
    }

    @Test func aRequestIsTakenFromTheStreamOnlyWhenItIsExact() throws {
        let body = Data(bash.utf8)
        let message = Data("topdeck-agent 1 claude \(body.count)\n".utf8) + body
        var buffer = Data()
        var header: (tool: AgentTool, length: Int)?
        for byte in message.dropLast() {
            buffer.append(byte)
            #expect(AgentSocket.request(from: &buffer, header: &header) == .incomplete)
        }
        buffer.append(message.last!)
        let id = UUID()
        guard case .complete(let request) = AgentSocket.request(from: &buffer, header: &header, id: id) else {
            Issue.record("the whole message is a request")
            return
        }
        #expect(request.id == id && request.toolName == "Bash")

        func read(_ data: Data) -> AgentSocket.ReadResult {
            var buffer = data
            var header: (tool: AgentTool, length: Int)?
            return AgentSocket.request(from: &buffer, header: &header)
        }
        #expect(read(message + Data("x".utf8)) == .invalid, "more than it announced")
        #expect(read(Data(repeating: 0x61, count: 65)) == .invalid, "a header line that never ends")
        #expect(read(Data("topdeck-agent 9 claude 3\n{}\n".utf8)) == .invalid)
        let wrong = Data(try changing(bash, "hook_event_name", to: "Stop").utf8)
        #expect(read(Data("topdeck-agent 1 claude \(wrong.count)\n".utf8) + wrong) == .invalid)
    }
}

struct AgentDecisionTests {
    @Test func allowAndDenyAreTheHookOutputClaudeCodeAndCodexRead() throws {
        let request = try parse(bash)
        let allow = try #require(AgentDecision.allow.payload(for: request))
        #expect(
            String(decoding: allow, as: UTF8.self)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        let deny = try decision(AgentDecision.deny.payload(for: request))
        #expect(deny["behavior"] as? String == "deny" && deny["message"] as? String == AgentDecision.denial)
        #expect(deny["updatedInput"] == nil && deny["updatedPermissions"] == nil)
        let codexRequest = try parse(codex, tool: .codex)
        #expect(try decision(AgentDecision.allow.payload(for: codexRequest)).keys.sorted() == ["behavior"])
    }

    @Test func alwaysAllowPassesClaudesOwnRuleBack() throws {
        let always = try decision(AgentDecision.allowAlways.payload(for: try parse(bash)))
        #expect(always["behavior"] as? String == "allow")
        let rules = try #require(always["updatedPermissions"] as? [[String: Any]])
        #expect(rules.count == 1 && rules[0]["type"] as? String == "addRules")
        #expect(rules[0]["destination"] as? String == "localSettings")
        #expect(AgentDecision.allowAlways.payload(for: try parse(codex, tool: .codex)) == nil)
        let noRule = try parse(changing(bash, "permission_suggestions", to: nil))
        #expect(AgentDecision.allowAlways.payload(for: noRule) == nil)
    }

    @Test func answersGoInTheQuestionsInputKeyedByQuestion() throws {
        let request = try parse(question)
        let answered = try decision(AgentDecision.answer([["SQLite"], ["Auth", "Search"]]).payload(for: request))
        #expect(answered["behavior"] as? String == "allow")
        let input = try #require(answered["updatedInput"] as? [String: Any])
        let answers = input["answers"] as? [String: String]
        #expect(answers == ["Which database?": "SQLite", "Which extras?": "Auth, Search"])
        #expect((input["questions"] as? [Any])?.count == 2, "the questions stay as asked")
    }

    @Test func aDecisionThatDoesntFitSendsNothing() throws {
        let asked = try parse(question)
        let plain = try parse(bash)
        let unfit: [(AgentDecision, AgentRequest)] = [
            (.allow, asked), (.allowAlways, asked), (.answer([["SQLite"], ["Auth"]]), plain),
            (.answer([["SQLite"]]), asked), (.answer([["SQLite"], ["Auth"], ["Auth"]]), asked),
            (.answer([["MySQL"], ["Auth"]]), asked), (.answer([["Postgres", "SQLite"], ["Auth"]]), asked),
            (.answer([[], ["Auth"]]), asked), (.answer([["SQLite"], ["Auth", "Auth"]]), asked),
        ]
        for (choice, request) in unfit {
            #expect(choice.payload(for: request) == nil, "\(choice)")
        }
        #expect(try decision(AgentDecision.deny.payload(for: asked))["behavior"] as? String == "deny")
    }
}

/// The approval hook, run as an agent runs it: given its input and left to wait for an answer.
private final class WaitingHook: @unchecked Sendable {
    let process = Process()
    private let output = Pipe()

    init(_ sandbox: Sandbox, tool: String = "claude", input: String) throws {
        process.executableURL = sandbox.hooks.script
        process.arguments = [tool, AgentHooks.approve]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
    }

    /// Its exit status and what it printed for the agent, once it's done.
    func result() async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = self.output.fileHandleForReading.readDataToEndOfFile()
                self.process.waitUntilExit()
                let printed = String(decoding: data, as: UTF8.self)
                continuation.resume(returning: (self.process.terminationStatus, printed))
            }
        }
    }
}

/// What a bare socket reported.
@MainActor
private final class Heard {
    var requests: [AgentRequest] = []
    var gone: [UUID] = []

    func socket(_ sandbox: Sandbox, holdLimit: TimeInterval = 30) -> AgentSocket {
        AgentSocket(
            path: sandbox.hooks.socket, holdLimit: holdLimit,
            onRequest: { [weak self] in self?.requests.append($0) },
            onGone: { [weak self] in self?.gone.append($0) })
    }
}

@MainActor
struct AgentApprovalTests {
    private let defaults = UserDefaults(suiteName: "Agents.\(UUID().uuidString)")!

    private func connected(_ tool: AgentTool = .claude) throws -> (Sandbox, AgentsFeature) {
        let sandbox = try Sandbox()
        try sandbox.hooks.install(tool)
        let agents = AgentsFeature(hooks: sandbox.hooks, defaults: defaults)
        agents.phase = .background
        return (sandbox, agents)
    }

    @Test func connectingAddsAWaitingHookBesideTheirsAndDisconnectingTakesOnlyOurs() throws {
        let sandbox = try Sandbox()
        let guardHook: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "guard.sh"]]]
        let others: [String: Any] = ["hooks": ["PermissionRequest": [guardHook]]]
        try sandbox.write(others, for: .claude)
        try sandbox.hooks.install(.claude)
        let events = try #require(try sandbox.settings(for: .claude)["hooks"] as? [String: [[String: Any]]])
        let groups = try #require(events["PermissionRequest"])
        #expect(groups.count == 2, "theirs first, then ours")
        let handler = try #require((groups[1]["hooks"] as? [[String: Any]])?.first)
        #expect((handler["command"] as? String)?.hasSuffix("topdeck-agent-hook' claude approve") == true)
        #expect(handler["async"] == nil && handler["timeout"] as? Int == AgentHooks.approveTimeout)
        #expect(AgentHooks.approveTimeout > Int(AgentsFeature.holdLimit) + 10, "Topdeck lets go first")
        try sandbox.hooks.uninstall(.claude)
        #expect(NSDictionary(dictionary: try sandbox.settings(for: .claude)).isEqual(to: others))
    }

    @Test func theSocketIsTheOwnersAloneBeforeAnyoneCanConnect() throws {
        let (sandbox, agents) = try connected()
        #expect(agents.isServing)
        let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.hooks.socket.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSocket)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(attributes[.ownerAccountID] as? Int == Int(getuid()))
        agents.phase = .stopped
        #expect(!agents.isServing && !FileManager.default.fileExists(atPath: sandbox.hooks.socket.path))
    }

    @Test func aSocketPathIsNeverTakenFromSomethingElse() throws {
        let sandbox = try Sandbox()
        try sandbox.hooks.install(.claude)
        let heard = Heard()
        try Data("mine".utf8).write(to: sandbox.hooks.socket)
        #expect(throws: AgentSocket.StartError.occupied) { try heard.socket(sandbox).start() }
        #expect(try String(contentsOf: sandbox.hooks.socket, encoding: .utf8) == "mine")
        try FileManager.default.removeItem(at: sandbox.hooks.socket)

        let first = heard.socket(sandbox)
        try first.start()
        #expect(throws: AgentSocket.StartError.inUse) { try heard.socket(sandbox).start() }
        first.stop()

        let long = AgentSocket(
            path: URL(filePath: "/tmp/" + String(repeating: "x", count: 120)), holdLimit: 1, onRequest: { _ in },
            onGone: { _ in })
        #expect(throws: AgentSocket.StartError.pathTooLong) { try long.start() }
    }

    @Test func aLeftoverSocketFromATopdeckThatQuitIsReplaced() throws {
        let sandbox = try Sandbox()
        try sandbox.hooks.install(.claude)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        #expect(AgentSocket.withAddress(sandbox.hooks.socket.path) { bind(fd, $0, $1) } == 0)
        let heard = Heard()
        let replacement = heard.socket(sandbox)
        try replacement.start()
        #expect(replacement.isListening)
        replacement.stop()
    }

    @Test func anAnswerFromTheNotchIsWhatTheHookPrints() async throws {
        let (sandbox, agents) = try connected()
        let hook = try WaitingHook(sandbox, input: bash)
        #expect(await eventually { agents.requests.count == 1 })
        let request = try #require(agents.requests.first)
        #expect(request.toolName == "Bash" && request.project == "nook")
        agents.answer(request, .allow)
        #expect(agents.requests.isEmpty)
        let result = await hook.result()
        #expect(result.status == 0)
        let allowed = try decision(Data(result.output.utf8))
        #expect(allowed["behavior"] as? String == "allow")
        agents.phase = .stopped
    }

    @Test func aQuestionAnsweredInTheNotchReachesClaude() async throws {
        let (sandbox, agents) = try connected()
        let hook = try WaitingHook(sandbox, input: question)
        #expect(await eventually { agents.requests.first?.isQuestion == true })
        let request = try #require(agents.requests.first)
        agents.answer(request, .answer([["Postgres"], ["Billing"]]))
        let result = await hook.result()
        let answered = try decision(Data(result.output.utf8))
        let input = try #require(answered["updatedInput"] as? [String: Any])
        #expect(input["answers"] as? [String: String] == ["Which database?": "Postgres", "Which extras?": "Billing"])
        agents.phase = .stopped
    }

    @Test func deniedInTheNotchTheAgentIsToldSo() async throws {
        let (sandbox, agents) = try connected(.codex)
        let hook = try WaitingHook(sandbox, tool: "codex", input: codex)
        #expect(await eventually { agents.requests.first?.tool == .codex })
        agents.answer(try #require(agents.requests.first), .deny)
        let result = await hook.result()
        let denied = try decision(Data(result.output.utf8))
        #expect(denied["behavior"] as? String == "deny")
        agents.phase = .stopped
    }

    /// Every way a request can go unanswered prints nothing, so the agent shows its own prompt.
    @Test func withoutTopdeckTheHookPrintsNothingAtOnce() async throws {
        let sandbox = try Sandbox()
        try sandbox.hooks.install(.claude)
        let started = ContinuousClock.now
        let hook = try WaitingHook(sandbox, input: bash)
        let result = await hook.result()
        #expect(printedNothing(result) && ContinuousClock.now - started < .seconds(10))
    }

    @Test func turnedOffTheNotchAnswersNothing() async throws {
        let (sandbox, agents) = try connected()
        agents.answersRequests = false
        #expect(!agents.isServing && !FileManager.default.fileExists(atPath: sandbox.hooks.socket.path))
        let hook = try WaitingHook(sandbox, input: bash)
        #expect(printedNothing(await hook.result()))
        agents.answersRequests = true
        #expect(agents.isServing)
        agents.phase = .stopped
    }

    @Test func aRequestTopdeckCantReadPrintsNothing() async throws {
        let (sandbox, agents) = try connected()
        let inputs = [
            "not json", try changing(bash, "session_id", to: "../x"), try changing(bash, "hook_event_name", to: "Stop"),
        ]
        for input in inputs {
            let hook = try WaitingHook(sandbox, input: input)
            #expect(printedNothing(await hook.result()))
        }
        let unknown = try WaitingHook(sandbox, tool: "cursor", input: bash)
        #expect(printedNothing(await unknown.result()))
        #expect(agents.requests.isEmpty)
        agents.phase = .stopped
    }

    @Test func anAnswerThatDoesntFitPrintsNothing() async throws {
        let (sandbox, agents) = try connected()
        let hook = try WaitingHook(sandbox, input: question)
        #expect(await eventually { agents.requests.count == 1 })
        agents.answer(try #require(agents.requests.first), .allow)
        #expect(printedNothing(await hook.result()))
        agents.phase = .stopped
    }

    @Test func handedToTheTerminalTheHookPrintsNothing() async throws {
        let (sandbox, agents) = try connected()
        let hook = try WaitingHook(sandbox, input: bash)
        #expect(await eventually { agents.requests.count == 1 })
        agents.answerInTerminal(try #require(agents.requests.first))
        #expect(agents.requests.isEmpty)
        #expect(printedNothing(await hook.result()))
        agents.phase = .stopped
    }

    @Test func aRequestNobodyAnswersTimesOutToTheAgentsPrompt() async throws {
        let sandbox = try Sandbox()
        try sandbox.hooks.install(.claude)
        let heard = Heard()
        let socket = heard.socket(sandbox, holdLimit: 0.5)
        try socket.start()
        let hook = try WaitingHook(sandbox, input: bash)
        #expect(printedNothing(await hook.result()))
        #expect(await eventually { heard.gone.count == 1 })
        #expect(heard.gone == heard.requests.map(\.id))
        socket.reply(to: heard.gone[0], with: Data("{}".utf8))  // too late: nothing to answer
        socket.stop()
    }

    @Test func stoppingTheNotchLetsEveryWaitingHookGo() async throws {
        let (sandbox, agents) = try connected()
        let hook = try WaitingHook(sandbox, input: bash)
        #expect(await eventually { agents.requests.count == 1 })
        agents.phase = .stopped
        #expect(agents.requests.isEmpty)
        #expect(printedNothing(await hook.result()))
    }

    @Test func anAgentThatStopsWaitingTakesItsRequestOffTheNotch() async throws {
        let (sandbox, agents) = try connected()
        let hook = try WaitingHook(sandbox, input: bash)
        #expect(await eventually { agents.requests.count == 1 })
        hook.process.terminate()
        #expect(await eventually { agents.requests.isEmpty })
        agents.phase = .stopped
    }

    @Test func aSecondApprovalRightAfterTheFirstLeavesItPending() throws {
        let agents = AgentsFeature(hooks: try Sandbox().hooks, defaults: defaults)
        let start = Date.now
        agents.clock = { start }
        let first = try AgentRequest.parse(Data(bash.utf8), tool: .claude)
        let second = try AgentRequest.parse(Data(bash.utf8), tool: .claude)
        let third = try AgentRequest.parse(Data(bash.utf8), tool: .claude)
        [first, second, third].forEach(agents.received)
        agents.answer(first, .allow)
        agents.answer(second, .allow)
        agents.answer(second, .allowAlways)
        agents.answer(second, .answer([["x"]]))
        #expect(agents.requests.map(\.id) == [second.id, third.id], "a click that comes too soon is ignored")
        agents.clock = { start.addingTimeInterval(AgentsFeature.answerPause / 2) }
        agents.answer(second, .deny)
        #expect(agents.requests.map(\.id) == [third.id], "denying is always accepted")
        agents.clock = { start.addingTimeInterval(AgentsFeature.answerPause * 2) }
        agents.answer(third, .allow)
        #expect(agents.requests.isEmpty, "once the pause has passed")
    }

    @Test func aHeldRequestCountsAsWaitingInTheClosedNotch() throws {
        let request = try parse(bash)
        let session = AgentSession(id: "claude-abc-123", tool: .claude, state: .waiting, project: "nook", updated: .now)
        let other = AgentSession(id: "codex-9", tool: .codex, state: .waiting, project: "api", updated: .now)
        #expect(AgentsFeature.waiting(in: [], requests: [request])?.title == "nook")
        #expect(AgentsFeature.waiting(in: [session], requests: [request])?.title == "nook", "the same session")
        #expect(AgentsFeature.waiting(in: [session, other], requests: [request])?.title == "2 waiting")
        #expect(AgentsFeature.waiting(in: [], requests: []) == nil)
    }
}
