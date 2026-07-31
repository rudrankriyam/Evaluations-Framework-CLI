# Contributing

Thanks for helping improve `xceval`.

## Development

Requirements:

- macOS 14 or newer
- Swift 6.2 or newer
- Xcode 27 only for live `.xcresult` export verification

Build and test:

```bash
swift build
swift test
Tests/Integration/cli-integration.sh .build/debug/xceval
swift run xceval --help
```

The core artifact parser must remain independent of `Evaluations.framework`.
That keeps inspection usable on machines where Xcode 27 is absent and avoids
binding the CLI to a beta framework ABI.

`XCEvalFormat` is the public normalized interchange boundary. Keep the CLI's
inspect, samples, and JSONL output backed by its shared document types. Update
the golden files under `Contracts/xceval-v1` when adding compatible fields, and
introduce a new schema version for breaking field or semantic changes.

## Pull Requests

- Keep command and JSON schema changes intentional and documented.
- Add fixtures or focused tests for new artifact shapes.
- Preserve unknown Apple JSON fields rather than rejecting future additions.
- Keep text output readable and JSON output deterministic for scripts and CI.
