import XCEvalCore

enum CapabilitySupport: String, Encodable, Equatable {
    case native
    case orchestrated
    case producerOwned = "producer-owned"
}

struct CapabilityPayload: Encodable {
    let name: String
    let frameworkAPIs: [String]
    let support: CapabilitySupport
    let command: String
    let boundary: String
    let automationUse: String
}

struct CapabilitiesPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "capabilities"
    let productName = "xceval"
    let naming = "Community-defined name; not an Apple command or product."
    let affiliation = "Unofficial. Not affiliated with or endorsed by Apple."
    let selectedXcode: XcodeInstallation?
    let capabilities: [CapabilityPayload]

    init(selectedXcode: XcodeInstallation?) {
        self.selectedXcode = selectedXcode
        capabilities =
            runtimeCapabilityPayloads
            + analysisCapabilityPayloads
            + automationCapabilityPayloads
    }
}

private let runtimeCapabilityPayloads = [
    CapabilityPayload(
        name: "Scaffold a typed evaluation package",
        frameworkAPIs: [
            "Evaluation",
            "JSONLoader",
            "Evaluator",
            "Test.evaluates",
            "EvaluationResult.saveJSON"
        ],
        support: .native,
        command: "xceval init NAME",
        boundary: """
            Generates compilable boilerplate and a sample dataset. The \
            feature subject, representative data, and meaningful criteria \
            remain application-specific.
            """,
        automationUse: """
            Start from a working producer, Swift Testing attachment, explicit \
            gates, and pipeline manifest instead of wiring framework search \
            paths and result persistence by hand.
            """
    ),
    CapabilityPayload(
        name: "Define typed evaluations and custom evaluators",
        frameworkAPIs: [
            "Evaluation",
            "Evaluator",
            "Metric",
            "EvaluationContext"
        ],
        support: .producerOwned,
        command: "xceval run --results-path DIR -- COMMAND",
        boundary: """
            Subjects, sample types, and evaluator code are compiled Swift \
            owned by the producer.
            """,
        automationUse: """
            Run any package or executable that saves .xcevalresult, then \
            ingest the new artifacts.
            """
    ),
    CapabilityPayload(
        name: "Run evaluations in Swift Testing and Xcode",
        frameworkAPIs: ["Test.evaluates", "Evaluation.run(info:)"],
        support: .orchestrated,
        command: "xceval test -- XCODEBUILD_ARGUMENTS",
        boundary: """
            The framework executes inside the app or test process; xceval \
            drives xcodebuild and exports attachments.
            """,
        automationUse: """
            Execute tests, retain the xcresult path, and immediately \
            receive evaluation artifact paths.
            """
    ),
    CapabilityPayload(
        name: "Load datasets",
        frameworkAPIs: [
            "Loader",
            "ArrayLoader",
            "JSONLoader",
            "StreamLoader"
        ],
        support: .producerOwned,
        command: "xceval run --results-path DIR -- COMMAND",
        boundary: "Dataset element types and decoding live in producer code.",
        automationUse: """
            Invoke the typed runner and inspect the resulting dataset \
            behavior through sample rows.
            """
    ),
    CapabilityPayload(
        name: "Model-as-judge and pairwise scoring",
        frameworkAPIs: [
            "ModelJudgeEvaluator",
            "ModelJudgePrompt",
            "ScoringMode",
            "ScoringScale",
            "ScoreDimension",
            "ScoreLevel"
        ],
        support: .producerOwned,
        command: "xceval run --results-path DIR -- COMMAND",
        boundary: """
            Model choice, credentials, prompts, dimensions, and pairwise \
            candidates are application-specific.
            """,
        automationUse: """
            Run the configured judge and analyze every persisted score and \
            rationale with samples and metrics.
            """
    ),
    CapabilityPayload(
        name: "Tool-call and trajectory evaluation",
        frameworkAPIs: [
            "ToolCallEvaluator",
            "ToolExpectation",
            "TrajectoryExpectation",
            "StructuredTranscript"
        ],
        support: .producerOwned,
        command: "xceval run --results-path DIR -- COMMAND",
        boundary: """
            Tool schemas and transcript types are compiled into the \
            producer.
            """,
        automationUse: """
            Execute tool-calling tests and inspect pass, fail, score, ignore, \
            and rationale columns.
            """
    ),
    CapabilityPayload(
        name: "Argument matching",
        frameworkAPIs: [
            "ArgumentMatcher.exact",
            "keyOnly",
            "oneOf",
            "range",
            "pattern",
            "contains",
            "hasPrefix",
            "hasSuffix",
            "naturalLanguage"
        ],
        support: .producerOwned,
        command: "xceval run --results-path DIR -- COMMAND",
        boundary: """
            Matchers evaluate typed tool arguments while the producer runs.
            """,
        automationUse: """
            Use stored ToolCallEvaluator metrics and rationales to identify \
            exact mismatch rows.
            """
    ),
    CapabilityPayload(
        name: "Synthetic sample generation",
        frameworkAPIs: [
            "SampleGenerator",
            "ModelSample",
            "random",
            "slidingWindow",
            "validator",
            "samples",
            "invalidSamples"
        ],
        support: .producerOwned,
        command: "xceval run --allow-empty --results-path DIR -- COMMAND",
        boundary: """
            Generable expected types, sessions, prompts, and validators \
            must be compiled in producer code.
            """,
        automationUse: """
            Run the generator executable, then consume its JSON dataset or \
            subsequent evaluation results.
            """
    )
]

private let analysisCapabilityPayloads = [
    CapabilityPayload(
        name: "Aggregate metrics",
        frameworkAPIs: [
            "Aggregation",
            "mean",
            "median",
            "mode",
            "minimum",
            "maximum",
            "standardDeviation",
            "variance",
            "groups"
        ],
        support: .native,
        command: "xceval metrics RESULT",
        boundary: """
            Custom aggregation executes in producer code; all stored \
            aggregate values are queryable generically.
            """,
        automationUse: """
            Enumerate summary values, groups, source metrics, and per-sample \
            distributions.
            """
    ),
    CapabilityPayload(
        name: "Persist and collect results",
        frameworkAPIs: [
            "EvaluationResult.jsonData",
            "saveJSON",
            "loadJSON",
            "saveJSONLines",
            "loadJSONLines"
        ],
        support: .native,
        command: "xceval convert INPUT --to jsonl|directory",
        boundary: """
            xceval preserves unknown fields and does not depend on beta \
            framework round-tripping.
            """,
        automationUse: """
            Pack many runs into JSONL, split collections, validate them, or \
            stream them through stdin.
            """
    ),
    CapabilityPayload(
        name: "Inspect summary and detailed data frames",
        frameworkAPIs: [
            "EvaluationResult.summary",
            "detailed",
            "groupedSummary",
            "jsonRepresentableDataFrame"
        ],
        support: .native,
        command: "xceval inspect|samples|metrics",
        boundary: """
            The CLI reads the persisted JSON representation rather than \
            importing TabularData.
            """,
        automationUse: """
            Query metadata, normalized samples, rationales, evaluator \
            kinds, and aggregate values.
            """
    ),
    CapabilityPayload(
        name: "Build downstream prompt-response datasets",
        frameworkAPIs: ["EvaluationResult detailed rows"],
        support: .native,
        command: "xceval dataset RESULT --output apple-json|json|jsonl",
        boundary: """
            Supports Apple's sample DatasetExtractor shape and a richer \
            normalized record.
            """,
        automationUse: """
            Extract prompts, responses, expected values, and decoded input \
            in one command.
            """
    )
]

private let automationCapabilityPayloads = [
    CapabilityPayload(
        name: "Run a reproducible evaluation pipeline",
        frameworkAPIs: [
            "EvaluationResult persisted output",
            "xcresulttool export evaluations"
        ],
        support: .orchestrated,
        command: "xceval pipeline [MANIFEST]",
        boundary: """
            Typed evaluation stages remain normal commands. The manifest \
            defines orchestration, artifact selection, analysis, comparison, \
            and policy.
            """,
        automationUse: """
            Produce one directory containing logs, the selected result, a \
            normalized Xcode-style report, failures, datasets, comparisons, \
            validation, and gate results.
            """
    ),
    CapabilityPayload(
        name: "Extract evaluation attachments",
        frameworkAPIs: ["xcresulttool export evaluations"],
        support: .native,
        command: "xceval export TESTS.xcresult",
        boundary: """
            Uses Apple's public xcresulttool command from an \
            Evaluations-capable Xcode.
            """,
        automationUse: """
            Recover all .xcevalresult attachments and manifest metadata \
            without opening Xcode.
            """
    ),
    CapabilityPayload(
        name: "Validate, compare, and enforce CI policy",
        frameworkAPIs: ["EvaluationResult persisted output"],
        support: .native,
        command: "xceval validate|compare|gate",
        boundary: """
            Metric direction is never guessed; gates require explicit \
            comparison operators.
            """,
        automationUse: """
            Detect malformed rows, calculate deltas, and fail automation \
            on precise aggregate thresholds.
            """
    )
]
