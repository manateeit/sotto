import Foundation
import Testing
@testable import Sotto

/// Golden coverage of the smart/raw composition via fake processors injected at the
/// seam — no real model. Proves the raw route goes through Passthrough (no model
/// call), a transform-attempt failure yields `.transformFailed` (caller must not
/// paste), and dictate results/fallbacks arrive as `.paste` carrying their mode.
@Suite struct ProcessingPipelineTests {
    private struct FakeProcessor: PostProcessor {
        var output: String = "SMART"
        var mode: String = "dictate"
        var fail: Bool = false
        struct Boom: Error {}

        func process(_ text: String, context: ContextSnapshot) async throws -> PostProcessorResult {
            if fail { throw Boom() } // models a transform-attempt failure
            return PostProcessorResult(text: output, mode: mode)
        }
    }

    private let ctx = ContextSnapshot()

    @Test func smartRouteUsesProcessorOutput() async {
        let out = await ProcessingPipeline().run(
            text: "hi", context: ctx, shiftHeld: false, smartAvailable: true,
            smart: FakeProcessor(output: "CLEANED", mode: "dictate"), raw: Passthrough())
        #expect(out == .paste(text: "CLEANED", mode: "dictate"))
    }

    @Test func shiftRoutesThroughRawPassthrough() async {
        let out = await ProcessingPipeline().run(
            text: "hi", context: ctx, shiftHeld: true, smartAvailable: true,
            smart: FakeProcessor(output: "CLEANED"), raw: Passthrough())
        #expect(out == .paste(text: "hi", mode: "raw")) // Passthrough, no model call
    }

    @Test func unavailableModelRoutesThroughRaw() async {
        let out = await ProcessingPipeline().run(
            text: "hi", context: ctx, shiftHeld: false, smartAvailable: false,
            smart: FakeProcessor(output: "CLEANED"), raw: Passthrough())
        #expect(out == .paste(text: "hi", mode: "raw"))
    }

    @Test func overLengthCapRoutesThroughRaw() async {
        let long = String(repeating: "a", count: 5000)
        let out = await ProcessingPipeline().run(
            text: long, context: ctx, shiftHeld: false, smartAvailable: true,
            smart: FakeProcessor(output: "CLEANED"), raw: Passthrough())
        #expect(out == .paste(text: long, mode: "raw"))
    }

    @Test func transformAttemptFailureYieldsTransformFailed() async {
        let withSelection = ContextSnapshot(selectedText: "original selection")
        let out = await ProcessingPipeline().run(
            text: "make this a bullet list", context: withSelection,
            shiftHeld: false, smartAvailable: true,
            smart: FakeProcessor(fail: true), raw: Passthrough())
        #expect(out == .transformFailed)
    }

    @Test func transformModeIsCarriedThrough() async {
        let out = await ProcessingPipeline().run(
            text: "make it a list", context: ContextSnapshot(selectedText: "a\nb"),
            shiftHeld: false, smartAvailable: true,
            smart: FakeProcessor(output: "• a\n• b", mode: "transform"), raw: Passthrough())
        #expect(out == .paste(text: "• a\n• b", mode: "transform"))
    }
}
