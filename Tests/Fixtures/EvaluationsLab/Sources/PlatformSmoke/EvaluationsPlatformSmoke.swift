import Evaluations

/// Compile-only coverage shared by every Apple platform where Xcode 27 Beta 4
/// ships Evaluations.framework.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public enum EvaluationsPlatformSmoke {
    public static func modelSample() -> ModelSample<String> {
        ModelSample(
            prompt: "Use the weather tool.",
            expected: "It is 24 degrees.",
            expectations: trajectoryExpectation()
        )
    }

    public static func trajectoryExpectation() -> TrajectoryExpectation {
        TrajectoryExpectation(
            expected: "weather",
            arguments: [
                .exact(argumentName: "city", value: "Paris")
            ]
        )
    }

    public static func customMetric() -> Metric {
        Metric("platform_smoke")
    }

    #if !os(watchOS)
        /// The deterministic initializer is explicitly unavailable on watchOS in
        /// Xcode 27 Beta 4, even though ToolCallEvaluator itself is present.
        public static func deterministicToolCallEvaluator()
            -> ToolCallEvaluator<ModelSample<String>>
        {
            ToolCallEvaluator(
                allPass: Metric("platform_tool_all_pass"),
                percentagePass: Metric("platform_tool_percentage")
            )
        }
    #endif
}
