# Evaluations Framework CLI

`xceval` is an agent-friendly command-line interface for Apple Evaluations
artifacts and Xcode result bundles.

It reads `.xcevalresult` files, normalizes their metadata, aggregate metrics,
sample rows, responses, rationales, and evaluator outputs, compares two runs,
and exports evaluation attachments from `.xcresult` bundles.

## Why This Exists

Xcode 27 exposes one public command-line operation:

```bash
xcrun xcresulttool export evaluations \
  --path Tests.xcresult \
  --output-path ExportedEvaluations
```

That command extracts attachments, but it does not inspect, normalize, compare,
or stream their contents for agents. `xceval` fills that tooling gap.

The CLI deliberately does **not** link `Evaluations.framework`. Artifact
inspection uses the documented JSON files directly, so it remains useful when
Xcode 27 is not installed and avoids binding automation to beta framework
round-trip behavior.

## Build

```bash
git clone https://github.com/rudrankriyam/Evaluations-Framework-CLI.git
cd Evaluations-Framework-CLI
swift build -c release
.build/release/xceval --help
```

The binary runs on macOS 14 or newer. Exporting from `.xcresult` requires an
Xcode installation that provides `xcresulttool export evaluations`, currently
Xcode 27.

After the first tagged release, Homebrew is the primary install path:

```bash
brew tap rudrankriyam/tap
brew install xceval
```

## First Commands

```bash
# Discover Xcode 27 even when it lives in ~/Downloads.
xceval doctor

# Read metadata and aggregate metrics.
xceval inspect Result.xcevalresult --summary-only

# Emit the complete normalized artifact as JSON.
xceval inspect Result.xcevalresult --output json --pretty

# Preserve Apple's exact JSON document.
xceval inspect Result.xcevalresult --output raw-json

# Stream one normalized sample per line to an agent.
xceval samples Result.xcevalresult --output jsonl

# Focus on rows containing a failing metric.
xceval samples Result.xcevalresult --only-failures --output json

# Compare aggregate values without assuming metric direction.
xceval compare Baseline.xcevalresult Candidate.xcevalresult --output json

# Export evaluation attachments from Swift Testing or Xcode tests.
xceval export Tests.xcresult --output-path ./evaluations --output json

# Print Apple's manifest schema for the selected Xcode.
xceval schema
```

Text is the default in an interactive terminal. JSON is the default when output
is piped. Use `--output text|json|jsonl|raw-json` where supported.

## Stable Agent Output

Normalized JSON uses the envelope version `xceval/v1`. `inspect` exposes:

- Evaluation and result identifiers.
- Start, end, and duration fields.
- Evaluation info and report metadata.
- Flattened aggregate metrics with group and operation details.
- Decoded sample inputs when the `Input` column contains nested JSON.
- Response, expected value, evaluator kind, metric kind, value, and rationale.
- Unknown nonmetric columns without discarding them.

`--output raw-json` returns Apple's document unchanged. This gives agents a
stable default while preserving an escape hatch as Apple's beta schema evolves.

## What Apple Stores

A direct `EvaluationResult.saveJSON` call creates a plain JSON document with the
`.xcevalresult` extension. In Xcode 27, its top-level fields include:

- `evaluationID`
- `resultID`
- `startTime`
- `endTime`
- `durationInMilliseconds`
- `evaluationInfo`
- `reportMetadata`
- `results`
- `summary`

Swift Testing's `.evaluates` trait attaches that file to a test. Xcode stores
the attachment inside `.xcresult`; `xceval export` invokes Apple's public
`xcresulttool` command and returns both the exported files and `manifest.json`.

## Xcode Framework Folders

The public developer framework lives here:

```text
Xcode.app/Contents/Developer/Platforms/<Platform>.platform/
Developer/Library/Frameworks/Evaluations.framework
```

Do not confuse it with:

| Location | Meaning |
| --- | --- |
| `Xcode.app/Contents/Frameworks/IDEEvaluationKit.framework` | Private Xcode IDE implementation |
| `Xcode.app/Contents/SharedFrameworks/MLEvaluation*.framework` | Other private ML evaluation support |
| `<Platform>.sdk/System/Library/Frameworks` | Runtime OS SDK frameworks |
| A project's `Frameworks` group | Xcode project metadata |
| An app bundle's `Frameworks` directory | Embedded shipping dependencies |

`xceval doctor --output json` reports every Evaluations developer-framework
copy found for macOS, iOS, watchOS, and visionOS platforms.

## Producer Boundary

`xceval` is an artifact CLI, not a universal evaluation runner. Evaluations are
Swift types containing app-specific datasets, subjects, and evaluator code, so
the application or package that owns them should produce `.xcevalresult`.

That keeps responsibilities clear:

1. App-specific code runs the evaluation and saves or attaches the result.
2. `xceval` exports, inspects, streams, and compares the generic artifact.
3. Xcode remains optional for humans who want the native report UI.

## Xcode Discovery

For export and schema commands, `xceval` checks:

1. `--xcode`
2. `DEVELOPER_DIR`
3. `xcode-select --print-path`
4. Xcode apps under `/Applications`, `~/Applications`, and `~/Downloads`

This supports side-by-side beta installations without changing the system-wide
selected Xcode.

## Beta Compatibility

The Xcode 27 beta convenience APIs are not yet a reliable automation boundary.
During development, a valid result produced by `EvaluationResult.saveJSON` was
rejected by `EvaluationResult.loadJSON`, and `groupedSummary` crashed on another
valid exported result because of a TabularData column type mismatch.

The underlying JSON remained valid and complete. `xceval` therefore uses a
tolerant JSON parser and preserves unknown fields.

## Apple Resources

- [Evaluations documentation](https://developer.apple.com/documentation/evaluations)
- [Meet the Evaluations framework](https://developer.apple.com/videos/play/wwdc2026/298/)
- [Create robust evaluations for agentic apps](https://developer.apple.com/videos/play/wwdc2026/299/)
- [Improve prompts by hill-climbing evaluations](https://developer.apple.com/videos/play/wwdc2026/335/)
- [Designing effective evaluations](https://developer.apple.com/documentation/evaluations/designing-effective-evaluations)
- [Designing evaluation datasets](https://developer.apple.com/documentation/evaluations/designing-evaluation-datasets)
- [Evaluating language model responses](https://developer.apple.com/documentation/evaluations/evaluating-language-model-responses)
- [Designing evaluation criteria](https://developer.apple.com/documentation/evaluations/designing-evaluation-criteria)
- [Designing effective model judges](https://developer.apple.com/documentation/evaluations/designing-effective-model-judges)
- [Scoring with model-as-judge evaluators](https://developer.apple.com/documentation/evaluations/scoring-with-model-as-judge-evaluators)
- [Generating synthetic evaluation datasets](https://developer.apple.com/documentation/evaluations/generating-synthetic-evaluation-datasets)
- [Evaluating tool-calling behavior](https://developer.apple.com/documentation/evaluations/evaluating-tool-calling-behavior)
- [Book Tracker Evaluations sample](https://developer.apple.com/documentation/evaluations/book-tracker-using-evaluations-to-evaluate-an-intelligent-feature)

## License

MIT
