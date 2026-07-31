# EvaluationsLab

Disposable Xcode 27 Beta 4 integration harness for Apple's
`Evaluations.framework`.

The fixture contains:

- `EvaluationsLabSupport`: reusable deterministic samples, evaluators,
  aggregation, transcripts, and persistence helpers.
- `EvaluationsLabCLI`: direct `Evaluation.run`, JSON save/load, and JSON Lines
  save/load without invoking a language model.
- `EvaluationsLabTests`: Swift Testing coverage for direct runs,
  `.evaluates`, loaders, custom metrics and aggregation, model samples,
  tool trajectories and argument matchers, structured transcripts, and
  result persistence.
- Four compile-smoke targets cover the Beta 4 Evaluations SDK surface on
  macOS, iOS Simulator, visionOS Simulator, and watchOS Simulator.

## Generate

The checked local Tuist binary is version `4.202.2`.

```sh
cd Tests/Fixtures/EvaluationsLab
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer \
XDG_STATE_HOME="$PWD/.tuist-state" \
tuist generate --no-open
```

## Deterministic offline lanes

```sh
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer \
xcodebuild \
  -project EvaluationsLab.xcodeproj \
  -scheme EvaluationsLabTests \
  -destination 'platform=macOS' \
  -derivedDataPath .derived-data \
  CODE_SIGNING_ALLOWED=NO \
  test

DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer \
xcodebuild \
  -project EvaluationsLab.xcodeproj \
  -scheme EvaluationsLabCLI \
  -destination 'platform=macOS' \
  -derivedDataPath .derived-data \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The default test run does not invoke a model.

## Beta 4 behavior captured by the fixture

`FrameworkEdgeCaseTests` keeps current framework behavior explicit:

- Default and metadata-inclusive JSON, JSON Lines, and `jsonData` results
  round-trip successfully in the current Beta 4 runtime.
- `JSONLoader` throws `NSCocoaErrorDomain` / `NSFileNoSuchFileError` when its
  file does not exist.
- A malformed top-level JSON document silently yields no samples.
- One malformed element in an otherwise valid JSON array causes the loader to
  yield no samples, including the valid siblings.
- `StreamLoader` propagates an error from its source sequence.
- `EvaluationResult.loadJSON` throws for missing, empty, and malformed files,
  but those errors do not materialize as the public `EvaluationResultsError`
  cases in this Beta 4 runtime.
- Variance and standard deviation over a single numeric sample produce
  non-finite aggregate values, so `saveJSON` fails with `EncodingError`.
  Generated starters therefore use mean, minimum, and maximum by default so a
  one-sample agent rerun remains persistable.
- `EvaluatorsBuilder.buildOptional` works when invoked directly. Writing `if`
  inside the result-builder body does not compile because `buildOptional`
  returns an evaluator array that `buildBlock` does not accept.

The tool tests also execute negative missing, wrong-name, wrong-argument,
out-of-order, forbidden, duplicate, unordered, any-order, and
additional-call-policy trajectories without invoking a model.

The opt-in runtime suite also treats multi-dimension model-judge output as
generative: Beta 4 can return a nonempty subset of the requested dimensions.
It validates unique numeric metrics and rationales while printing the returned
names. Single-dimension pointwise and pairwise lanes still require exactly one
metric.

## Cross-platform compile matrix

Xcode 27 Beta 4 ships `Evaluations.framework` for macOS, iOS, visionOS, and
watchOS, but not tvOS. Generate the project, then compile each supported
simulator/host SDK with a distinct DerivedData directory:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer \
./Scripts/build-platform-matrix.sh
```

The shared smoke source compiles common model samples, trajectory expectations,
and metrics everywhere. Beta 4 marks the deterministic
`ToolCallEvaluator(allPass:percentagePass:)` initializer unavailable on
watchOS, so that constructor is guarded with `#if !os(watchOS)`.

Run the CLI without a `DYLD_FRAMEWORK_PATH` override:

```sh
EVALUATIONS_LAB_OUTPUT_DIR="$PWD/.cli-output" \
.derived-data/Build/Products/Debug/EvaluationsLabCLI
```

## Single verification entry point

The verification script generates the Tuist project, builds the four-platform
matrix, runs a focused deterministic macOS verification target, and executes
the CLI. The focused target keeps release verification independent from
exploratory edge-case and model-dependent suites:

```sh
./Scripts/verify-harness.sh
```

If Xcode 27 or exactly Tuist 4.202.2 is unavailable, it prints `SKIP` and exits
successfully for CI portability. Set `EVALUATIONS_LAB_REQUIRE_TOOLCHAIN=1` to
turn a missing or mismatched toolchain into a release-verification failure.

## Explicit model opt-in

Model judge, natural-language argument matching, and sample generation are
disabled in the default scheme. The explicit `EvaluationsLabModelTests` scheme
sets `EVALUATIONS_LAB_RUN_MODEL_TESTS=1` inside the Xcode test process. These
tests also require `SystemLanguageModel().isAvailable`. Pointwise and pairwise
judge loops, both `makeSamples` overloads, and the invalid-sample generator
probe use the same explicit opt-in; their constructors remain covered offline.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer \
xcodebuild \
  -project EvaluationsLab.xcodeproj \
  -scheme EvaluationsLabModelTests \
  -destination 'platform=macOS' \
  -derivedDataPath .derived-data-model \
  CODE_SIGNING_ALLOWED=NO \
  test
```
