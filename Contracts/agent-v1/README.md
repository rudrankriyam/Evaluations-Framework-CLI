# Agent protocol contract fixtures

These fixtures are stable examples of the lower-level contracts an external
agent can compose around `xceval`:

- `error.json`: explicit `--output json` failure.
- `targets.json`: declared producer discovery.
- `selection.json`: persisted selected-sample identity.
- `operation-receipt.json`: durable idempotent execution state.
- `evidence.json`: compact failure and baseline-comparison evidence.

The schemas are independently versioned. Consumers should tolerate additive
fields within a version and decode them through `XCEvalFormat`.

An agent is deliberately not named in any document. The caller owns diagnosis
and source edits; these contracts expose deterministic capabilities and facts.
