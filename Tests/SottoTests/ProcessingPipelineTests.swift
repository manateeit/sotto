import Foundation
import Testing
@testable import Sotto

/// Golden coverage of the smart/raw composition via fake processors injected at the
/// seam — no real model. Proves the raw route goes through Passthrough (no model
/// call), a transform-attempt failure yields `.transformFailed` (caller must not
/// paste), and dictate results/fallbacks arrive as `.paste`.
@Suite struct ProcessingPipelineTests {
    private struct FakeProcessor: PostProcessor {
        var output: String = "SMART"
        var fail: Bool = false
        struct Boom: Error {}

        func process(_ text: String, context: ContextSnapshot) async throws -> String {
            if fail { throw Boom() } // models a transform-attempt failure (SmartProcessor throws only then)
            return output
        }
    }

    private let ctx = ContextSnapshot()

    @Test func smartRouteUsesProcessorOutput() async {
        let out = await ProcessingPipeline().run(
            text: "hi", context: ctx, shiftHeld: false, smartAvailable: true,
            smart: FakeProcessor(output: "CLEANED"), raw: Passthrough())
        #expect(out == .paste("CLEANED"))
    }

    @Test func shiftRoutesThroughRawPassthrough() async {
        let out = await ProcessingPipeline().run(
            text: "hi", context: ctx, shiftHeld: true, smartAvailable: true,
            smart: FakeProcessor(output: "CLEANED"), raw: Passthrough())
        #expect(out == .paste("hi")) // Passthrough returns the text, no model call
    }

    @Test func unavailableModelRoutesThroughRaw() async {
        let out = await ProcessingPipeline().run(
            text: "hi", context: ctx, shiftHeld: false, smartAvailable: false,
            smart: FakeProcessor(output: "CLEANED"), raw: Passthrough())
        #expect(out == .paste("hi"))
    }

    @Test func overLengthCapRoutesThroughRaw() async {
        let long = String(repeating: "a", count: 5000)
        let out = await ProcessingPipeline().run(
            text: long, context: ctx, shiftHeld: false, smartAvailable: true,
            smart: FakeProcessor(output: "CLEANED"), raw: Passthrough())
        #expect(out == .paste(long))
    }

    @Test func transformAttemptFailureYieldsTransformFailed() async {
        let withSelection = ContextSnapshot(selectedText: "original selection")
        let out = await ProcessingPipeline().run(
            text: "make this a bullet list", context: withSelection,
            shiftHeld: false, smartAvailable: true,
            smart: FakeProcessor(fail: true), raw: Passthrough())
        #expect(out == .transformFailed) // caller leaves the selection untouched
    }

    @Test func dictateFallbackArrivesAsPaste() async {
        // On a dictate failure SmartProcessor returns the raw text (no throw); modeled
        // by a fake that returns the input.
        let out = await ProcessingPipeline().run(
            text: "hello world", context: ctx, shiftHeld: false, smartAvailable: true,
            smart: FakeProcessor(output: "hello world"), raw: Passthrough())
        #expect(out == .paste("hello world"))
    }
}
