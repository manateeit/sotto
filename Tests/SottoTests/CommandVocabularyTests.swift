import Testing
@testable import Sotto

/// The curated map only recognizes UNIVERSAL phrases and keeps the argument literal
/// (verbatim, original case). "run <words>" types the words as spoken — it never
/// maps to a project-specific command. A curated hit is what lets the pipeline skip
/// the model entirely (see CommandPipelineTests.curatedMatchSkipsModel).
@Suite struct CommandVocabularyTests {
    @Test func openMatchesTarget() {
        #expect(CommandVocabulary.match("open Safari")
            == ParsedCommand(kind: .openTarget, argument: "Safari", confidence: .high))
    }

    @Test func openPreservesArgumentCase() {
        #expect(CommandVocabulary.match("open Visual Studio Code")?.argument == "Visual Studio Code")
    }

    @Test func typeMatchesLiteralWords() {
        #expect(CommandVocabulary.match("type Hello World")
            == ParsedCommand(kind: .typeIntoTerminal, argument: "Hello World", confidence: .high))
    }

    @Test func runMatchesLiteralWordsVerbatim() {
        // The words are literal — "run the tests" types "the tests", it is NOT mapped
        // to any project-specific command.
        #expect(CommandVocabulary.match("run npm test")
            == ParsedCommand(kind: .typeIntoTerminal, argument: "npm test", confidence: .high))
        #expect(CommandVocabulary.match("run the tests")?.argument == "the tests")
    }

    @Test func volumePhrasesMatchSystemControl() {
        #expect(CommandVocabulary.match("volume up")
            == ParsedCommand(kind: .systemControl, argument: "volume up", confidence: .high))
        #expect(CommandVocabulary.match("louder")?.argument == "volume up")
        #expect(CommandVocabulary.match("mute")
            == ParsedCommand(kind: .systemControl, argument: "mute", confidence: .high))
    }

    @Test func verbMatchIsCaseInsensitive() {
        #expect(CommandVocabulary.match("OPEN Safari")?.kind == .openTarget)
    }

    @Test func bareVerbWithoutArgumentDoesNotMatch() {
        #expect(CommandVocabulary.match("open") == nil)
        #expect(CommandVocabulary.match("type ") == nil)
    }

    @Test func unrelatedPhraseDoesNotMatch() {
        #expect(CommandVocabulary.match("what is the weather") == nil)
        #expect(CommandVocabulary.match("the quick brown fox") == nil)
    }
}
