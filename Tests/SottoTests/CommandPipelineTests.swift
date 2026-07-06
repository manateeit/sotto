import Testing
@testable import Sotto

/// Golden coverage of the command-recognition composition via a FAKE parser at the
/// CommandParsing seam — no real model. Proves the curated pre-pass skips the FM
/// entirely, and that unknown / low-confidence / parser-failure / empty all resolve
/// to `.notACommand` (nothing executes; never guess).
@Suite struct CommandPipelineTests {
    /// Records whether the model was consulted, so "curated skips FM" is an assertion,
    /// not an inference.
    private actor CallCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    private struct FakeParser: CommandParsing {
        var result: ParsedCommand
        var shouldThrow = false
        let counter: CallCounter
        struct Boom: Error {}

        func parse(_ utterance: String) async throws -> ParsedCommand {
            await counter.bump()
            if shouldThrow { throw Boom() }
            return result
        }
    }

    @Test func curatedMatchSkipsModel() async {
        let counter = CallCounter()
        // If the model were consulted it would return this distinct sentinel.
        let parser = FakeParser(
            result: ParsedCommand(kind: .typeIntoTerminal, argument: "SENTINEL", confidence: .high),
            counter: counter)
        let plan = await CommandPipeline().plan(utterance: "open Safari", parser: parser)
        #expect(plan == .execute(ParsedCommand(kind: .openTarget, argument: "Safari", confidence: .high)))
        #expect(await counter.count == 0) // FM never consulted
    }

    @Test func unknownFromModelIsNotACommand() async {
        let parser = FakeParser(
            result: ParsedCommand(kind: .unknown, argument: "", confidence: .low),
            counter: CallCounter())
        let plan = await CommandPipeline().plan(utterance: "what time is it", parser: parser)
        #expect(plan == .notACommand)
    }

    @Test func lowConfidenceFromModelIsNotACommand() async {
        let parser = FakeParser(
            result: ParsedCommand(kind: .openTarget, argument: "something", confidence: .low),
            counter: CallCounter())
        let plan = await CommandPipeline().plan(utterance: "maybe show me something", parser: parser)
        #expect(plan == .notACommand)
    }

    @Test func parserFailureIsNotACommand() async {
        let parser = FakeParser(
            result: ParsedCommand(kind: .openTarget, argument: "x", confidence: .high),
            shouldThrow: true, counter: CallCounter())
        let plan = await CommandPipeline().plan(utterance: "please do the thing", parser: parser)
        #expect(plan == .notACommand)
    }

    @Test func highConfidenceModelParseExecutes() async {
        let expected = ParsedCommand(kind: .openTarget, argument: "Xcode", confidence: .high)
        let parser = FakeParser(result: expected, counter: CallCounter())
        let plan = await CommandPipeline().plan(utterance: "launch Xcode please", parser: parser)
        #expect(plan == .execute(expected))
    }

    @Test func emptyUtteranceIsNotACommandAndSkipsModel() async {
        let counter = CallCounter()
        let parser = FakeParser(
            result: ParsedCommand(kind: .openTarget, argument: "x", confidence: .high),
            counter: counter)
        let plan = await CommandPipeline().plan(utterance: "   ", parser: parser)
        #expect(plan == .notACommand)
        #expect(await counter.count == 0)
    }
}
