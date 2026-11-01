// SPDX-License-Identifier: MIT
import XCTest

@testable import TopdeckUsage

/// The `agy -p "/usage" --output-format json` report: both pools, and nothing unless it proves no model ran.
final class AntigravityCLIUsageTests: XCTestCase {
    /// The shape `agy` 1.4.12 prints, with made-up numbers.
    private func report(
        status: String = "SUCCESS", turns: String = "0", conversation: String = "\"\"", totalTokens: Int = 0,
        command: String = "usage"
    ) -> String {
        """
        {"status":"\(status)","num_turns":\(turns),"conversation_id":\(conversation),
         "usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":\(totalTokens)},
         "command":{"name":"\(command)","data":{"groups":[
           {"name":"Gemini Models","buckets":[
             {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.4,"reset_time":"2026-11-04T00:46:02Z"},
             {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-11-02T01:59:40Z"}]},
           {"name":"Claude and GPT models","buckets":[
             {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.5,"reset_time":"2026-11-08T13:34:48Z"},
             {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-11-02T01:59:40Z"}]}
         ]}}}
        """
    }

    private func used(_ line: MetricLine) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _) = line else { return nil }
        return used
    }

    func testBothPoolsComeOutInSummaryOrder() throws {
        let lines = try XCTUnwrap(AntigravityUsageMapper.parseCLIUsage(report()))
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(lines.map(used), [0, 60, 0, 50], "remaining_fraction is what's left, so used is its inverse")
    }

    func testAnythingThatMightHaveRunAModelIsRejected() {
        XCTAssertNil(AntigravityUsageMapper.parseCLIUsage(report(status: "ERROR")))
        XCTAssertNil(AntigravityUsageMapper.parseCLIUsage(report(turns: "1")))
        XCTAssertNil(AntigravityUsageMapper.parseCLIUsage(report(turns: "null")), "a missing turn count isn't safe")
        XCTAssertNil(AntigravityUsageMapper.parseCLIUsage(report(conversation: "\"abc\"")))
        XCTAssertNil(AntigravityUsageMapper.parseCLIUsage(report(totalTokens: 12)))
        XCTAssertNil(AntigravityUsageMapper.parseCLIUsage(report(command: "chat")))
        XCTAssertNil(AntigravityUsageMapper.parseCLIUsage("Error: not signed in"))
    }

    func testTextAroundTheJSONIsIgnored() {
        XCTAssertEqual(AntigravityUsageMapper.parseCLIUsage("warning: update available\n" + report())?.count, 4)
    }
}
