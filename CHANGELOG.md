# Changelog

## 0.4.0 — 2026-07-31

This release turns `xceval` into a deterministic control plane for external
coding agents while keeping evaluation meaning in project-owned Swift.

### Agent workflow

- Declare runnable producers in `.xceval/targets.json`, discover them with
  `targets`, inspect one with `target`, and execute one with `run TARGET`.
- Resume or audit idempotent runs through durable operation receipts and
  bounded stdout/stderr logs.
- Address results by canonical artifact ID while retaining a byte digest for
  exact-source identity.
- Select failures into a stable manifest, pass that manifest back to a
  producer, and compare samples by JSON Pointer or canonical input identity.
- Apply explicit absolute or baseline-delta gates without guessing whether a
  metric should increase or decrease.
- Emit compact deterministic evidence for an external agent; `xceval` does not
  embed an agent or edit application code.

### Evaluation and dataset authoring

- Discover the installed Xcode Evaluations API with source-line evidence.
- Generate and typecheck explicit deterministic, model-judge, tool-call,
  synthetic-data, and session-backed authoring recipes.
- Discover, validate, select, quarantine, draft, and promote evaluation
  datasets without synthesizing expected labels from model responses.
- Expose normalized command contracts through `XCEvalFormat`, including
  structured `xceval.error/v1` failures.

### Reliability and verification

- Add safe process timeouts, cancellation, TERM-to-KILL escalation, and
  crash-durable operation state.
- Reject broad or protected destructive paths before producer execution.
- Preserve structural sample failures alongside metric failures.
- Add a disposable Tuist project that compiles directly against Xcode 27 Beta
  4 and exercises Evaluations framework persistence, loaders, evaluators,
  metrics, tool trajectories, model-judge construction, synthetic generation,
  Swift Testing attachments, and `xcresulttool` export.
- Add a second black-box integration matrix for the complete agent loop while
  retaining the original CLI compatibility matrix.

### Compatibility

- Existing `xceval/v1` command envelopes remain additive.
- Existing artifact, pipeline, and legacy `run --results-path -- COMMAND`
  workflows remain supported.
- The package remains pre-1.0; `XCEvalCore` is experimental.
