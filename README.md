# Evaluations Framework CLI

> [!IMPORTANT]
> `xceval` is a community-defined name and an unofficial tool. It is not an
> Apple command or product, Apple does not use it as the public name of the
> framework, and it is not affiliated with or endorsed by Apple.

`xceval` is an unofficial command-line toolkit for Apple Evaluations workflows:
scaffold a typed starter, run evaluation stages, drive Xcode tests, export
attachments, reproduce the data behind Xcode's evaluation report, compare runs,
validate collections, and enforce explicit CI gates.

## Why This Exists

Xcode 27 exposes one public command-line operation:

```bash
xcrun xcresulttool export evaluations \
  --path Tests.xcresult \
  --output-path ExportedEvaluations
```

That command extracts attachments, but it does not scaffold producers, run a
multi-stage workflow, inspect, normalize, validate, query, compare, convert, or
gate their contents for scripts and CI. `xceval` fills that tooling gap.

The CLI deliberately does **not** link `Evaluations.framework`. Artifact
inspection uses the documented JSON files directly, so it remains useful when
Xcode 27 is not installed and avoids binding automation to beta framework
round-trip behavior. Typed framework code still runs in your app, package, or
tests; `xceval run` and `xceval test` orchestrate those producers.

## Scope

`xceval init` creates compilable typed boilerplate, but `xceval` cannot author
the meaningful part of an evaluation for you. Representative datasets,
feature-specific subjects, criteria, model judges, tool expectations, and model
execution remain Swift code owned by the app, package, or benchmark harness.

The CLI can begin at one of three boundaries:

1. A generated starter package from `xceval init`.
2. An executable that can save `.xcevalresult` files.
3. An Xcode test that attaches evaluation results with Swift Testing.

| Workflow | Owner |
| --- | --- |
| Generate a working package, test, producer, dataset, and pipeline manifest | `xceval init` |
| Define datasets, subjects, evaluators, judges, tools, and aggregation | App or package using `Evaluations.framework` |
| Invoke the model and record deployment-specific benchmark measurements | App-specific producer or benchmark harness |
| Launch an existing producer and collect changed results | `xceval run` |
| Run Xcode tests and export attached results | `xceval test` |
| Execute named stages and write one complete analysis directory | `xceval pipeline` |
| Inspect, filter, normalize, validate, compare, convert, and gate persisted results | `xceval` |

This makes `xceval` useful both when adopting Apple Evaluations and after a
project has built a mature evaluation suite.

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

Homebrew is the primary install path:

```bash
brew tap rudrankriyam/tap
brew install xceval
```

## First Commands

```bash
# Create a compilable macOS 27 package and ready-to-run pipeline.
xceval init SearchQuality
cd SearchQualityEvaluations
xceval pipeline

# Print supported operations and producer-owned boundaries.
xceval capabilities --output json

# Discover Xcode 27 even when it lives in ~/Downloads.
xceval doctor

# List every result in a file, JSONL collection, or recursive directory.
xceval list ./evaluation-results --output json

# Validate structure while remaining forward-compatible with unknown fields.
xceval validate Results.xcevalresults.jsonl --strict

# Read metadata and aggregate metrics.
xceval inspect Result.xcevalresult --summary-only

# Emit the complete normalized artifact as JSON.
xceval inspect Result.xcevalresult --output json --pretty

# Preserve Apple's exact JSON document.
xceval inspect Result.xcevalresult --output raw-json

# Stream one normalized sample per line.
xceval samples Result.xcevalresult --output jsonl

# Focus on rows containing a failing metric.
xceval samples Result.xcevalresult --only-failures --output json

# Filter evaluator rows without loading the result into another program.
xceval samples Result.xcevalresult \
  --metric "Tool Call Accuracy" --kind fail --output jsonl

# Profile pass, fail, score, ignore, numeric, and rationale counts.
xceval metrics Result.xcevalresult --output json

# Emit the machine-readable data behind Xcode's evaluation report.
xceval report Result.xcevalresult --output json --pretty

# Superset Apple's sample DatasetExtractor output.
xceval dataset Result.xcevalresult --output apple-json --pretty

# Compare aggregate values without assuming metric direction.
xceval compare Baseline.xcevalresult Candidate.xcevalresult --output json

# Enforce only the metric direction you explicitly declare.
xceval gate Result.xcevalresult \
  --rule "Mean of Accuracy>=0.9" \
  --rule "Maximum of Latency<2"

# Pack or split EvaluationResult JSON Lines collections.
xceval convert ./runs --to jsonl \
  --output-path Results.xcevalresults.jsonl

# Run an app-specific executable that saves .xcevalresult files.
xceval run --results-path ./results -- \
  swift run MyEvaluationRunner

# Run all producer and analysis stages declared in a versioned manifest.
xceval pipeline xceval.pipeline.json

# Run Swift Testing or XCTest through Xcode, then export attachments.
xceval test --xcode ~/Downloads/Xcode-beta.app \
  --working-directory ./MyPackage -- \
  -scheme MyPackage-Package -destination 'platform=macOS' test

# Export evaluation attachments from Swift Testing or Xcode tests.
xceval export Tests.xcresult --output-path ./evaluations --output json

# Print Apple's manifest schema for the selected Xcode.
xceval schema
```

Text is the default in an interactive terminal. JSON is the default when output
is piped. Use `-` as an input path to read a result or collection from stdin.
Use `--output text|json|jsonl|raw-json|apple-json` where supported.

## Framework Boundaries

A universal binary cannot construct every `Evaluation` itself. Framework types
such as the sample, subject, expected value, tools, model judge, dimensions,
credentials, and synthetic-data validator are generic Swift code compiled into
the owning app or package. Claiming otherwise would require `xceval` to guess
application behavior.

`xceval` instead interoperates with framework capabilities at explicit
boundaries. Rows marked as producer-owned still require app-specific Swift code;
the CLI only launches that code and consumes its persisted output.

| Evaluations capability | `xceval` handling |
| --- | --- |
| Starter package with JSON data, deterministic evaluators, `.evaluates`, direct persistence, and gates | Generate with `xceval init` |
| `Evaluation`, custom `Evaluator`, and `Metric` | Run the typed producer with `xceval run` |
| Swift Testing `.evaluates` | Run tests and export attachments with `xceval test` |
| `ArrayLoader`, `JSONLoader`, and `StreamLoader` | Execute in producer code; inspect every stored row |
| Mean, median, mode, min, max, variance, standard deviation, groups, and custom aggregation | Query persisted aggregates with `metrics`, `inspect`, `compare`, and `gate` |
| `ModelJudgeEvaluator`, pairwise mode, score dimensions, and rationales | Execute with the producer; inspect scores and rationales generically |
| `ToolCallEvaluator`, trajectories, transcripts, and all argument matchers | Execute with the producer; filter failures and rationales with `samples` |
| `SampleGenerator`, random or sliding-window strategies, and validators | Run the typed generator executable with `run --allow-empty` |
| `saveJSON`, `loadJSON`, `saveJSONLines`, and `loadJSONLines` workflows | Read, validate, pack, split, and stream with `list`, `validate`, and `convert` |
| Summary and detailed data frames | Normalize with `inspect`, `samples`, `metrics`, and `report` |
| Xcode evaluation reports | Export with Apple’s `xcresulttool` through `export` or `test` |
| End-to-end producer, analysis, comparison, and policy workflow | Declare stages in `xceval.pipeline.json` and run `pipeline` |

Run `xceval capabilities --output json` for the same matrix in a stable,
machine-readable form so scripts can inspect command boundaries without parsing
this README.

## Stable Machine-Readable Output

Normalized JSON uses the envelope version `xceval/v1`. `inspect` exposes:

- Evaluation and result identifiers.
- Start, end, and duration fields.
- Evaluation info and report metadata.
- Flattened aggregate metrics with group and operation details.
- Decoded sample inputs when the `Input` column contains nested JSON.
- Response, expected value, evaluator kind, metric kind, value, and rationale.
- Unknown nonmetric columns without discarding them.

`report` combines those rows with:

- Exact numeric values for recreating distributions and histograms.
- Pass, fail, score, ignore, and rationale counts per metric.
- Median, sample variance, and sample standard deviation computed from persisted
  numeric values.
- Structural Subject-versus-Expected issues with JSON paths.
- Optional baseline aggregate comparisons.

This is the machine-readable substance of Xcode 27's evaluation report. The CLI
does not attempt to reproduce Xcode's visual chart rendering.

`--output raw-json` returns Apple's document unchanged. This gives automation a
stable default while preserving an escape hatch as Apple's beta schema evolves.

Collections can be a single `.xcevalresult`, a JSONL file produced by
`EvaluationResult.saveJSONLines`, a recursive directory, or stdin. Select one
result with `--evaluation-id` or `--result-id`.

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

The application or package owns typed evaluation behavior. The standalone CLI
owns orchestration and generic result behavior:

1. `xceval run` launches any direct producer and discovers new or changed
   `.xcevalresult` files.
2. `xceval test` launches `xcodebuild`, preserves its `.xcresult`, and exports
   evaluation attachments even when tests fail.
3. `xceval` then validates, lists, inspects, filters, profiles, extracts,
   compares, converts, and gates those artifacts without opening Xcode.
4. `xceval pipeline` composes those boundaries into a repeatable manifest and
   writes logs plus every derived artifact into one directory.

This keeps the CLI reusable across Foundation Models, server models,
tool-calling systems, deterministic systems, and custom stochastic systems.

## Evaluation Pipeline

A pipeline manifest makes Apple's evaluation lifecycle explicit:

```json
{
  "schemaVersion": "xceval.pipeline/v1",
  "name": "Search quality",
  "workingDirectory": ".",
  "artifactsDirectory": ".xceval/pipeline",
  "resultsPath": ".xceval/results",
  "requiresEvaluationsXcode": true,
  "steps": [
    {
      "name": "evaluate",
      "command": [
        "/usr/bin/xcrun",
        "swift",
        "run",
        "search-evaluate",
        "--output",
        ".xceval/results"
      ]
    }
  ],
  "baseline": "Baselines/search.xcevalresult",
  "gates": [
    "Mean of Accuracy>=0.9",
    "Maximum of Latency<2"
  ]
}
```

Run it with:

```bash
xceval pipeline --set DATASET=Fixtures/holdout.json
```

The output directory contains the selected native result, stage logs,
`inspect.json`, `report.json`, `metrics.json`, `failures.jsonl`, `dataset.json`,
Apple-compatible prompt-response data, validation, optional comparison, gate
results, and `pipeline-report.json`.

## Lessons From Apple's Sample

Apple's Book Tracker sample demonstrates a complete loop rather than a single
test:

1. Start with curated golden examples.
2. Generate and validate broader synthetic samples.
3. Run deterministic evaluators for computable behavior.
4. Use model judges only for subjective dimensions.
5. Extract prompt-response pairs from persisted results.
6. Calibrate judges against human labels with agreement statistics.
7. Compare a baseline and one experimental change.
8. Gate the aggregate result and keep failures as regression samples.

`xceval init` covers the compilable starting structure. `xceval pipeline`
covers production, extraction, analysis, comparison, and gates. Human labeling,
domain-specific synthetic-data validation, and judge calibration remain
project-owned because a generic CLI cannot decide what "good" means for a
feature.

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
