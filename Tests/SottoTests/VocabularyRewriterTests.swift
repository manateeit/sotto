import Foundation
import Testing
@testable import Sotto

/// Golden input→output pairs for the deterministic replacement table.
@Suite struct VocabularyRewriterTests {
    @Test func emptyTableLeavesTextUnchanged() {
        // The ⇧-raw path relies on this: an empty table is byte-for-byte identity.
        let rewriter = VocabularyRewriter.empty
        #expect(rewriter.rewrite("meet me at the cafe") == "meet me at the cafe")
    }

    @Test func literalReplacement() {
        let rewriter = VocabularyRewriter(rules: [.init("github", "GitHub")])
        #expect(rewriter.rewrite("push to github now") == "push to GitHub now")
    }

    @Test func regexReplacementRemovesFiller() {
        // Demonstrates deterministic filler removal via a regex rule.
        let rewriter = VocabularyRewriter(rules: [
            .init("\\b(um|uh|er)\\b[,]?\\s*", "", isRegex: true)
        ])
        #expect(rewriter.rewrite("so um the plan is uh ready") == "so the plan is ready")
    }

    @Test func rulesApplyInOrder() {
        let rewriter = VocabularyRewriter(rules: [
            .init("foo", "bar"),
            .init("bar", "baz")
        ])
        // foo→bar then bar→baz, so both land on baz.
        #expect(rewriter.rewrite("foo bar") == "baz baz")
    }

    @Test func decodesRulesFromJSON() {
        let json = Data("""
        { "_comment": "x", "rules": [
            {"pattern": "github", "replacement": "GitHub"},
            {"pattern": "\\\\bum\\\\b\\\\s*", "replacement": "", "regex": true}
        ] }
        """.utf8)
        let rewriter = VocabularyRewriter.decode(json)
        #expect(rewriter.rules.count == 2)
        #expect(rewriter.rewrite("push to github um now") == "push to GitHub now")
    }

    @Test func malformedJSONYieldsEmptyTable() {
        let rewriter = VocabularyRewriter.decode(Data("not json".utf8))
        #expect(rewriter.rules.isEmpty)
        #expect(rewriter.rewrite("unchanged") == "unchanged")
    }

    @Test func hintTermsAreLiteralReplacementsOnly() {
        let rewriter = VocabularyRewriter(rules: [
            .init("github", "GitHub"),
            .init("\\bum\\b", "", isRegex: true), // regex + empty → excluded
            .init("k8s", "Kubernetes")
        ])
        #expect(rewriter.hintTerms == ["GitHub", "Kubernetes"])
    }

    @Test func invalidRegexRuleIsSkippedNotCrashed() {
        // A syntactically-invalid regex must be skipped (not crash); later valid
        // rules still apply.
        let rewriter = VocabularyRewriter(rules: [
            .init("[", "X", isRegex: true), // invalid pattern
            .init("cat", "dog")
        ])
        #expect(rewriter.rewrite("a cat [") == "a dog [")
    }

    @Test func exampleFileParsesToEmptyRules() {
        // Round-trip: the example file we write on first run must decode cleanly.
        let rewriter = VocabularyRewriter.decode(Data(VocabularyStore.exampleFileContents.utf8))
        #expect(rewriter.rules.isEmpty)
        #expect(rewriter.rewrite("unchanged text") == "unchanged text")
    }
}
