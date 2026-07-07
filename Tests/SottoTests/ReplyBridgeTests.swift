import Foundation
import Testing
@testable import Sotto

/// Parsing of `sotto://reply` deep links from coding-agent hooks. This is a trust
/// boundary — the URL comes from outside the app — so malformed input must yield
/// nil rather than a half-built request.
@Suite struct ReplyBridgeTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func parsesFullRequest() {
        let r = ReplyBridge.parse(url("sotto://reply?response=/tmp/out.txt&ctx=/tmp/ctx.txt&agent=Claude%20Code"))
        #expect(r == ReplyBridge.Request(responsePath: "/tmp/out.txt",
                                         contextPath: "/tmp/ctx.txt",
                                         agent: "Claude Code"))
    }

    @Test func responseOnlyDefaultsAgentAndCtx() {
        let r = ReplyBridge.parse(url("sotto://reply?response=/tmp/out.txt"))
        #expect(r?.responsePath == "/tmp/out.txt")
        #expect(r?.contextPath == nil)
        #expect(r?.agent == "your agent")
    }

    @Test func rejectsWrongScheme() {
        #expect(ReplyBridge.parse(url("https://reply?response=/tmp/out.txt")) == nil)
    }

    @Test func rejectsWrongHost() {
        #expect(ReplyBridge.parse(url("sotto://settings?response=/tmp/out.txt")) == nil)
    }

    @Test func rejectsMissingResponsePath() {
        #expect(ReplyBridge.parse(url("sotto://reply?ctx=/tmp/ctx.txt&agent=X")) == nil)
    }

    @Test func rejectsEmptyResponsePath() {
        #expect(ReplyBridge.parse(url("sotto://reply?response=")) == nil)
    }
}
