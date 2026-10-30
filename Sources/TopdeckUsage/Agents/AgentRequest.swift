// SPDX-License-Identifier: MIT
// Adapted from Atoll (https://github.com/rutmehta/Atoll) at 537ad7d: Features/Agents/AgentModels.swift.
// Copyright (c) 2026 Rut Mehta. MIT License; see THIRD_PARTY_NOTICES.md.
import Foundation

/// A permission request an agent's hook holds open on Topdeck's socket until the user answers it in
/// the notch. Built only from input that passed every check below; anything else is turned away,
/// and the agent asks in its own prompt.
public struct AgentRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let tool: AgentTool
    /// The agent's session ID.
    public let session: String
    /// The folder it works in, by name.
    public let project: String
    /// The tool it wants to use: Bash, Edit, AskUserQuestion, exec_command, and so on.
    public let toolName: String
    /// One line on what it wants to do: the command, the file, the address.
    public let summary: String
    /// For `AskUserQuestion`, what it asks. Empty for any other tool.
    public let questions: [AgentQuestion]
    /// `tool_input`, as JSON.
    let input: Data
    /// The rule Claude Code offers to remember with "always allow", as JSON.
    let rule: Data?

    public var isQuestion: Bool { !questions.isEmpty }
    public var canAlwaysAllow: Bool { alwaysAllowRule != nil }

    /// What "always allow" would add, as Claude Code writes a rule: `Bash(npm test)`, or `Bash` for
    /// a whole tool, several joined with ", ". Nil when it can't be told, and then it isn't offered.
    public var alwaysAllowRule: String? {
        guard let rule, let suggestion = try? JSONSerialization.jsonObject(with: rule) as? [String: Any]
        else { return nil }
        return Self.describe(suggestion["rules"])
    }

    /// The hook event that asks for approval, in Claude Code and in Codex.
    static let event = "PermissionRequest"
    /// The most a hook may send. Large enough for a Write of a big file.
    static let maxSize = 1 << 20

    /// What was wrong with a hook's message. The hook is answered with nothing.
    enum Rejection: Error, Equatable {
        case notJSON, wrongEvent, badSession, badToolName, badInput, badQuestion
    }

    /// Reads a hook's JSON input as `tool`'s hook sent it.
    static func parse(_ data: Data, tool: AgentTool, id: UUID = UUID()) throws(Rejection) -> AgentRequest {
        guard data.count <= maxSize,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw .notJSON }
        guard object["hook_event_name"] as? String == event else { throw .wrongEvent }
        guard let session = object["session_id"] as? String, isSessionID(session) else { throw .badSession }
        guard let toolName = object["tool_name"] as? String, isToolName(toolName) else { throw .badToolName }
        let input = object["tool_input"] ?? [String: Any]()
        guard let fields = input as? [String: Any],
            let inputData = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        else { throw .badInput }
        var questions: [AgentQuestion] = []
        if tool == .claude, toolName == "AskUserQuestion" {
            questions = try AgentQuestion.parse(fields)
        }
        let cwd = (object["cwd"] as? String).map { URL(filePath: $0).lastPathComponent } ?? ""
        return AgentRequest(
            id: id, tool: tool, session: session, project: clip(cwd.isEmpty ? tool.name : cwd, 80),
            toolName: toolName, summary: summarize(toolName, fields), questions: questions, input: inputData,
            rule: tool == .claude ? alwaysRule(object["permission_suggestions"]) : nil)
    }

    /// Session IDs name files elsewhere, so only a plain one gets through.
    static func isSessionID(_ text: String) -> Bool {
        (1...128).contains(text.utf8.count)
            && text.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
            }
    }

    /// Tool names are identifiers, MCP ones included (`mcp__server__tool`).
    static func isToolName(_ text: String) -> Bool {
        (1...128).contains(text.utf8.count)
            && text.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-.:".unicodeScalars.contains($0))
            }
    }

    /// The first of Claude Code's suggestions that adds an allow rule; others change the mode, which
    /// the notch doesn't offer.
    static func alwaysRule(_ suggestions: Any?) -> Data? {
        guard let suggestions = suggestions as? [Any] else { return nil }
        for case let suggestion as [String: Any] in suggestions
        where suggestion["type"] as? String == "addRules" && suggestion["behavior"] as? String == "allow" {
            guard describe(suggestion["rules"]) != nil else { continue }
            return try? JSONSerialization.data(withJSONObject: suggestion, options: .sortedKeys)
        }
        return nil
    }

    /// `Bash(npm test)` for each of `[{"toolName": "Bash", "ruleContent": "npm test"}]`. Nil for no
    /// rules, a malformed one, or text too long to show whole: the user must see the whole rule.
    static func describe(_ rules: Any?) -> String? {
        guard let rules = rules as? [Any], !rules.isEmpty else { return nil }
        var parts: [String] = []
        for case let rule as [String: Any] in rules {
            guard let name = rule["toolName"] as? String, isToolName(name) else { return nil }
            let content = rule["ruleContent"] as? String
            parts.append(content.map { $0.isEmpty ? name : "\(name)(\($0))" } ?? name)
        }
        guard parts.count == rules.count else { return nil }
        let text = parts.joined(separator: ", ")
        return text.count <= 300 ? clip(text, 300) : nil
    }

    /// The input field that says most about the call, on one line.
    static func summarize(_ toolName: String, _ input: [String: Any]) -> String {
        let keys =
            switch toolName {
            case "Bash", "exec_command", "shell": ["command", "cmd", "description"]
            case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit": ["file_path", "notebook_path", "path"]
            case "WebFetch", "WebSearch": ["url", "query"]
            case "Glob", "Grep": ["pattern", "path"]
            default: ["command", "cmd", "file_path", "path", "url", "query", "pattern", "description", "prompt"]
            }
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty { return clip(value, 300) }
            // Codex passes its command as an argument list.
            if let value = input[key] as? [String], !value.isEmpty { return clip(value.joined(separator: " "), 300) }
        }
        // A tool with none of those, an MCP tool say, still shows what it was given.
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: options)
        else { return "" }
        return clip(String(decoding: data, as: UTF8.self), 300)
    }

    /// One line, no control characters, at most `limit` characters.
    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

/// One question of an `AskUserQuestion` call, with the answers it offers.
public struct AgentQuestion: Sendable, Equatable {
    public let question: String
    /// Its short label, when it has one.
    public let header: String?
    public let options: [String]
    public let multiSelect: Bool

    /// Reads `{"questions": [{question, header, options: [{label, description}], multiSelect}]}`.
    static func parse(_ input: [String: Any]) throws(AgentRequest.Rejection) -> [AgentQuestion] {
        guard let items = input["questions"] as? [Any], (1...8).contains(items.count) else { throw .badQuestion }
        var questions: [AgentQuestion] = []
        for item in items {
            guard let fields = item as? [String: Any], let question = fields["question"] as? String,
                (1...2000).contains(question.count), let rawOptions = fields["options"] as? [Any],
                (1...16).contains(rawOptions.count)
            else { throw .badQuestion }
            let options = rawOptions.compactMap { option in
                (option as? [String: Any])?["label"] as? String ?? option as? String
            }
            guard options.count == rawOptions.count, options.allSatisfy({ (1...200).contains($0.count) }),
                Set(options).count == options.count, !questions.contains(where: { $0.question == question })
            else { throw .badQuestion }
            questions.append(
                AgentQuestion(
                    question: question, header: (fields["header"] as? String).map { AgentRequest.clip($0, 40) },
                    options: options, multiSelect: fields["multiSelect"] as? Bool ?? false))
        }
        return questions
    }
}

/// What the user chose for a request in the notch.
public enum AgentDecision: Sendable, Equatable {
    case allow
    /// Allow, and remember Claude Code's suggested rule so it doesn't ask again.
    case allowAlways
    case deny
    /// For `AskUserQuestion`: the chosen labels, one list per question, in order.
    case answer([[String]])

    static let denial = "The user denied this in Topdeck."

    /// The JSON the hook prints for the agent, or nil when the decision doesn't fit the request; then
    /// nothing is sent and the agent asks in its own prompt.
    func payload(for request: AgentRequest) -> Data? {
        let decision: [String: Any]
        switch self {
        case .deny:
            decision = ["behavior": "deny", "message": Self.denial]
        case .allow:
            guard !request.isQuestion else { return nil }
            decision = ["behavior": "allow"]
        case .allowAlways:
            guard !request.isQuestion, request.canAlwaysAllow, let data = request.rule,
                let rule = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            decision = ["behavior": "allow", "updatedPermissions": [rule]]
        case .answer(let answers):
            guard request.isQuestion, answers.count == request.questions.count,
                var input = try? JSONSerialization.jsonObject(with: request.input) as? [String: Any]
            else { return nil }
            var chosen: [String: String] = [:]
            for (question, labels) in zip(request.questions, answers) {
                guard !labels.isEmpty, question.multiSelect || labels.count == 1,
                    Set(labels).count == labels.count, labels.allSatisfy({ question.options.contains($0) })
                else { return nil }
                chosen[question.question] = labels.joined(separator: ", ")
            }
            // Claude Code takes the answers in the tool's input, keyed by question.
            input["answers"] = chosen
            decision = ["behavior": "allow", "updatedInput": input]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": AgentRequest.event, "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// The socket's message: one header line, `topdeck-agent 1 <tool> <length>`, then that many bytes of
/// the hook's own JSON input.
enum AgentWire {
    static let magic = "topdeck-agent"
    static let maxHeader = 64

    /// The tool and the length of the JSON that follows, or nil for any other line.
    static func header(_ line: String) -> (tool: AgentTool, length: Int)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == magic, parts[1] == "1", let tool = AgentTool(rawValue: String(parts[2])),
            parts[3].allSatisfy({ ("0"..."9").contains($0) }), let length = Int(parts[3]),
            (1...AgentRequest.maxSize).contains(length)
        else { return nil }
        return (tool, length)
    }
}
