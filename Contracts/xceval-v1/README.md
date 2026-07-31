# `xceval/v1` contract fixtures

These files are golden examples of the normalized interchange formats emitted
by `xceval`:

- `inspect.json`: `xceval inspect --output json`
- `samples.json`: `xceval samples --output json`
- `samples.jsonl`: `xceval samples --output jsonl`

`XCEvalFormat` decodes these formats without reading Apple's persisted
evaluation schema. Consumers should ignore unknown object fields. Additive
fields remain compatible with `xceval/v1`; removing a field, changing a field's
meaning, or changing its JSON type requires a new schema version.

The `inspect` document is the safest calibration input because it contains the
complete normalized result. The `samples` command supports filters, offsets,
and limits, so consumers must not assume that a samples document or JSONL
stream represents the complete evaluation population.

Stable sample identity must come from a documented value inside `sample.input`.
The normalized `sample.index` is positional and must not be used to join model
ratings to human labels.
