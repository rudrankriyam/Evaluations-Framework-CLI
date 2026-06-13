#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${1:-$ROOT/.build/debug/xceval}"
if [[ "$BIN" != /* ]]; then
    BIN="$ROOT/$BIN"
fi
if [[ ! -x "$BIN" ]]; then
    echo "xceval binary is not executable: $BIN" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xceval-integration.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CHECKS=0
LAST_STDOUT="$WORK/last.stdout"
LAST_STDERR="$WORK/last.stderr"

mark() {
    CHECKS=$((CHECKS + 1))
    printf '[ok] %s\n' "$1"
}

assert_json() {
    local file="$1"
    local expression="$2"
    local name="$3"
    python3 - "$file" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
scope = {
    "d": data,
    "len": len,
    "abs": abs,
    "all": all,
    "any": any,
    "next": next,
    "set": set,
    "sorted": sorted,
}
if not eval(expression, {"__builtins__": {}}, scope):
    raise SystemExit(f"JSON assertion failed: {expression}\n{data!r}")
PY
    mark "$name"
}

assert_jsonl() {
    local file="$1"
    local expression="$2"
    local name="$3"
    python3 - "$file" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    rows = [json.loads(line) for line in handle if line.strip()]
scope = {
    "rows": rows,
    "len": len,
    "abs": abs,
    "all": all,
    "any": any,
    "next": next,
    "set": set,
    "sorted": sorted,
}
if not eval(expression, {"__builtins__": {}}, scope):
    raise SystemExit(f"JSONL assertion failed: {expression}\n{rows!r}")
PY
    mark "$name"
}

assert_contains() {
    local file="$1"
    local value="$2"
    local name="$3"
    if ! grep -Fq "$value" "$file"; then
        echo "Expected '$value' in $file" >&2
        exit 1
    fi
    mark "$name"
}

expect_failure() {
    local name="$1"
    shift
    set +e
    "$@" >"$LAST_STDOUT" 2>"$LAST_STDERR"
    local status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        echo "Expected failure: $name" >&2
        exit 1
    fi
    mark "$name"
}

expect_status() {
    local expected="$1"
    local name="$2"
    shift 2
    set +e
    "$@" >"$LAST_STDOUT" 2>"$LAST_STDERR"
    local status=$?
    set -e
    if [[ $status -ne $expected ]]; then
        echo "Expected status $expected, got $status: $name" >&2
        exit 1
    fi
    mark "$name"
}

python3 - "$WORK" <<'PY'
import copy
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

base = {
    "evaluationID": "ExampleEvaluation",
    "resultID": "BASELINE",
    "startTime": "2026-06-13T20:00:00Z",
    "endTime": "2026-06-13T20:00:01Z",
    "durationInMilliseconds": 12,
    "evaluationInfo": {"Model": "Example"},
    "reportMetadata": {
        "ColumnOrdering": ["Input", "Response", "Expected", "Accuracy", "Score"]
    },
    "futureField": {"preserved": True},
    "summary": [
        {
            "Mean of Accuracy": {
                "group": "Quality",
                "operation": {"metric": "Accuracy", "type": "mean"},
                "value": 0.5,
            },
            "Maximum of Latency": {
                "group": "Performance",
                "operation": {"metric": "Latency", "type": "maximum"},
                "value": 2,
            },
        }
    ],
    "results": [
        {
            "Input": json.dumps({"input": {"prompt": "Alpha prompt"}}),
            "Response": {"typeName": "String", "value": "alpha"},
            "Expected": "alpha",
            "Accuracy": {
                "evaluatorKind": "custom",
                "kind": "pass",
                "value": True,
            },
            "Score": {
                "evaluatorKind": "modelJudge",
                "kind": "score",
                "value": 0.8,
            },
        },
        {
            "Input": json.dumps({"input": {"prompt": "Beta prompt"}}),
            "Response": {"typeName": "String", "value": "wrong"},
            "Expected": "beta",
            "Accuracy": {
                "evaluatorKind": "custom",
                "kind": "fail",
                "value": False,
                "rationale": "Expected beta.",
            },
            "Score": {
                "evaluatorKind": "modelJudge",
                "kind": "score",
                "value": 0.2,
            },
        },
        {
            "Input": json.dumps({"input": {"prompt": "Gamma prompt"}}),
            "Response": {"typeName": "String", "value": "gamma"},
            "Expected": "gamma",
            "Accuracy": {
                "evaluatorKind": "custom",
                "kind": "ignore",
                "value": None,
            },
        },
    ],
}

candidate = copy.deepcopy(base)
candidate["resultID"] = "CANDIDATE"
candidate["summary"][0]["Mean of Accuracy"]["value"] = 0.75
candidate["summary"][0]["Maximum of Latency"]["value"] = 1.5

duplicate_baseline = {
    "evaluationID": "DuplicateSummary",
    "resultID": "DUP-BASE",
    "summary": [
        {
            "Mean Score": {
                "group": "Quality",
                "operation": {"metric": "Score", "type": "mean"},
                "value": 0.5,
            }
        },
        {
            "Mean Score": {
                "group": "Safety",
                "operation": {"metric": "Score", "type": "mean"},
                "value": 0.7,
            }
        },
        {
            "Mean Score": {
                "group": "Quality",
                "operation": {"metric": "Score", "type": "mean"},
                "value": 0.6,
            }
        },
    ],
    "results": [],
}
duplicate_candidate = copy.deepcopy(duplicate_baseline)
duplicate_candidate["resultID"] = "DUP-CAND"
duplicate_candidate["summary"][0]["Mean Score"]["value"] = 0.8
duplicate_candidate["summary"][1]["Mean Score"]["value"] = 0.9
duplicate_candidate["summary"][2]["Mean Score"]["value"] = 0.65

warning = {"future": "field", "summary": [], "results": []}
same_a = {"evaluationID": "Same", "resultID": "SAME-001", "summary": [], "results": []}
same_b = {"evaluationID": "Same", "resultID": "SAME-002", "summary": [], "results": []}

def write_json(name, value):
    with (root / name).open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")

write_json("baseline.xcevalresult", base)
write_json("candidate.xcevalresult", candidate)
write_json("duplicate-baseline.xcevalresult", duplicate_baseline)
write_json("duplicate-candidate.xcevalresult", duplicate_candidate)
write_json("warning.xcevalresult", warning)
write_json("same-a.xcevalresult", same_a)
write_json("same-b.xcevalresult", same_b)
write_json("array.json", [base, candidate])
(root / "empty-array.json").write_text("[]\n", encoding="utf-8")
(root / "whitespace.jsonl").write_text(" \n\t\n", encoding="utf-8")
(root / "scalar.json").write_text("42\n", encoding="utf-8")

compact_base = json.dumps(base, ensure_ascii=False, separators=(",", ":"))
compact_candidate = json.dumps(candidate, ensure_ascii=False, separators=(",", ":"))
(root / "collection.jsonl").write_text(
    compact_base + "\n\n" + compact_candidate + "\n",
    encoding="utf-8",
)
(root / "collection-crlf.jsonl").write_bytes(
    (compact_base + "\r\n" + compact_candidate + "\r\n").encode("utf-8")
)
(root / "malformed.jsonl").write_text(
    compact_base + "\n{\"broken\":\n",
    encoding="utf-8",
)

directory = root / "recursive input"
(directory / "nested").mkdir(parents=True)
write_json("recursive input/one.xcevalresult", base)
write_json("recursive input/nested/two.xcevalresult", candidate)
(directory / "ignored.json").write_text(compact_base, encoding="utf-8")
(directory / ".hidden.xcevalresult").write_text(compact_base, encoding="utf-8")
PY

BASE="$WORK/baseline.xcevalresult"
CANDIDATE="$WORK/candidate.xcevalresult"
COLLECTION="$WORK/collection.jsonl"
DUP_BASE="$WORK/duplicate-baseline.xcevalresult"
DUP_CANDIDATE="$WORK/duplicate-candidate.xcevalresult"

VERSION="$("$BIN" --version)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid semantic version: $VERSION" >&2
    exit 1
fi
if [[ -n "${XCEVAL_EXPECTED_VERSION:-}" && "$VERSION" != "$XCEVAL_EXPECTED_VERSION" ]]; then
    echo "Expected version $XCEVAL_EXPECTED_VERSION, got $VERSION" >&2
    exit 1
fi
mark "semantic version"

"$BIN" >"$WORK/root.txt"
assert_contains "$WORK/root.txt" "unofficial CLI" "root guidance"

for command in init capabilities doctor list validate inspect samples metrics report dataset compare gate convert pipeline run test export schema; do
    "$BIN" "$command" --help >"$WORK/help-$command.txt"
    assert_contains "$WORK/help-$command.txt" "USAGE:" "help: $command"
done

"$BIN" capabilities --xcode "$WORK/missing.app" --output json >"$WORK/capabilities.json"
assert_json "$WORK/capabilities.json" \
    'len(d["capabilities"]) == 15 and sorted(set(x["support"] for x in d["capabilities"])) == ["native", "orchestrated", "producer-owned"]' \
    "capability boundary matrix"

"$BIN" doctor --xcode "$WORK/missing.app" --output json >"$WORK/doctor.json"
assert_json "$WORK/doctor.json" \
    'd["artifactInspectionAvailable"] is True and d["evaluationExportAvailable"] is False and d["discoveredXcodes"] == []' \
    "doctor without evaluation-capable Xcode"
expect_failure "doctor --require-export failure" \
    "$BIN" doctor --xcode "$WORK/missing.app" --require-export --output json

"$BIN" list "$BASE" --output json >"$WORK/list-single.json"
assert_json "$WORK/list-single.json" \
    'd["count"] == 1 and d["artifacts"][0]["resultID"] == "BASELINE" and d["artifacts"][0]["sampleCount"] == 3' \
    "list single artifact"

"$BIN" list "$COLLECTION" --output json >"$WORK/list-collection.json"
assert_json "$WORK/list-collection.json" \
    'd["count"] == 2 and [x["resultID"] for x in d["artifacts"]] == ["BASELINE", "CANDIDATE"]' \
    "list JSONL collection"

"$BIN" list "$COLLECTION" --result-id CANDIDATE --output json >"$WORK/list-selected.json"
assert_json "$WORK/list-selected.json" \
    'd["count"] == 1 and d["artifacts"][0]["resultID"] == "CANDIDATE"' \
    "collection selection"

"$BIN" list "$WORK/array.json" --output json >"$WORK/list-array.json"
assert_json "$WORK/list-array.json" 'd["count"] == 2' "top-level JSON array"

"$BIN" list "$WORK/collection-crlf.jsonl" --output json >"$WORK/list-crlf.json"
assert_json "$WORK/list-crlf.json" 'd["count"] == 2' "CRLF JSONL collection"

"$BIN" list "$WORK/recursive input" --output json >"$WORK/list-directory.json"
assert_json "$WORK/list-directory.json" \
    'd["count"] == 2 and sorted(x["resultID"] for x in d["artifacts"]) == ["BASELINE", "CANDIDATE"]' \
    "recursive directory and ignored files"

"$BIN" list - --output json <"$BASE" >"$WORK/list-stdin.json"
assert_json "$WORK/list-stdin.json" \
    'd["count"] == 1 and d["artifacts"][0]["resultID"] == "BASELINE"' \
    "stdin artifact"

expect_failure "missing input path" \
    "$BIN" list "$WORK/does-not-exist" --output json
expect_failure "selection with no match" \
    "$BIN" list "$COLLECTION" --result-id UNKNOWN --output json
expect_failure "empty JSON array rejected" \
    "$BIN" list "$WORK/empty-array.json" --output json
expect_failure "whitespace collection rejected" \
    "$BIN" list "$WORK/whitespace.jsonl" --output json
expect_failure "scalar JSON rejected" \
    "$BIN" list "$WORK/scalar.json" --output json

"$BIN" validate "$BASE" --output json >"$WORK/validate.json"
assert_json "$WORK/validate.json" \
    'd["valid"] is True and d["errorCount"] == 0 and d["warningCount"] == 0' \
    "validate clean artifact"

"$BIN" validate "$WORK/warning.xcevalresult" --output json >"$WORK/validate-warning.json"
assert_json "$WORK/validate-warning.json" \
    'd["valid"] is True and d["warningCount"] == 4' \
    "validation warnings"

expect_failure "strict validation warnings fail" \
    "$BIN" validate "$WORK/warning.xcevalresult" --strict --output json
assert_json "$LAST_STDOUT" \
    'd["valid"] is True and d["warningCount"] == 4' \
    "strict validation still emits JSON"

expect_failure "malformed JSONL fails validation" \
    "$BIN" validate "$WORK/malformed.jsonl" --output json
assert_json "$LAST_STDOUT" \
    'd["valid"] is False and d["errorCount"] == 1 and ":2:" in d["loadError"]' \
    "malformed JSONL line diagnostics"

expect_failure "empty array fails validation" \
    "$BIN" validate "$WORK/empty-array.json" --output json
assert_json "$LAST_STDOUT" \
    'd["valid"] is False and "No evaluation artifacts" in d["loadError"]' \
    "empty array validation diagnostics"

"$BIN" inspect "$BASE" --output json --pretty >"$WORK/inspect.json"
assert_json "$WORK/inspect.json" \
    'd["artifact"]["sampleCount"] == 3 and d["artifact"]["otherFields"]["futureField"]["preserved"] is True and len(d["artifact"]["samples"]) == 3' \
    "inspect normalized artifact"

"$BIN" inspect "$BASE" --summary-only --output json >"$WORK/inspect-summary.json"
assert_json "$WORK/inspect-summary.json" \
    'd["artifact"]["sampleCount"] == 3 and "samples" not in d["artifact"]' \
    "inspect summary-only"

"$BIN" inspect "$BASE" --output raw-json >"$WORK/raw.json"
cmp -s "$BASE" "$WORK/raw.json"
mark "raw JSON byte preservation"

expect_failure "inspect collection requires selection" \
    "$BIN" inspect "$COLLECTION" --output json
expect_failure "raw JSON rejects pretty printing" \
    "$BIN" inspect "$BASE" --output raw-json --pretty

"$BIN" samples "$BASE" --output json >"$WORK/samples.json"
assert_json "$WORK/samples.json" \
    'd["sampleCount"] == 3 and [x["index"] for x in d["samples"]] == [0, 1, 2]' \
    "all samples"

"$BIN" samples "$BASE" --only-failures --output json >"$WORK/samples-failures.json"
assert_json "$WORK/samples-failures.json" \
    'd["sampleCount"] == 1 and d["samples"][0]["index"] == 1' \
    "failing samples"

"$BIN" samples "$BASE" \
    --metric Accuracy \
    --kind fail \
    --evaluator-kind custom \
    --prompt-contains beta \
    --rationale-contains expected \
    --output json >"$WORK/samples-filtered.json"
assert_json "$WORK/samples-filtered.json" \
    'd["sampleCount"] == 1 and d["samples"][0]["index"] == 1' \
    "combined sample filters"

"$BIN" samples "$BASE" --offset 1 --limit 1 --output json >"$WORK/samples-page.json"
assert_json "$WORK/samples-page.json" \
    'd["sampleCount"] == 1 and d["samples"][0]["index"] == 1' \
    "sample pagination"

"$BIN" samples "$BASE" --output jsonl >"$WORK/samples.jsonl"
assert_jsonl "$WORK/samples.jsonl" \
    'len(rows) == 3 and all(x["schemaVersion"] == "xceval/v1" for x in rows)' \
    "sample JSON Lines"

expect_failure "negative sample offset" \
    "$BIN" samples "$BASE" --offset -1 --output json
expect_failure "negative sample limit" \
    "$BIN" samples "$BASE" --limit -1 --output json
expect_failure "JSONL rejects pretty printing" \
    "$BIN" samples "$BASE" --output jsonl --pretty

"$BIN" metrics "$BASE" --output json >"$WORK/metrics.json"
assert_json "$WORK/metrics.json" \
    'len(d["profiles"]) == 2 and next(x for x in d["profiles"] if x["name"] == "Accuracy")["failCount"] == 1 and next(x for x in d["profiles"] if x["name"] == "Score")["numericValues"] == [0.8, 0.2] and len(d["summary"]) == 2' \
    "metric profiles and summaries"

"$BIN" report "$BASE" --baseline "$CANDIDATE" --output json >"$WORK/report.json"
assert_json "$WORK/report.json" \
    'len(d["samples"]) == 3 and d["samples"][1]["failedMetrics"] == ["Accuracy"] and d["samples"][1]["issues"][0]["kind"] == "value-mismatch" and len(d["aggregateComparison"]) == 2' \
    "Xcode-style machine-readable report"

"$BIN" dataset "$BASE" --output json >"$WORK/dataset.json"
assert_json "$WORK/dataset.json" \
    'd["rowCount"] == 3 and d["pairCount"] == 3 and d["records"][1]["prompt"] == "Beta prompt"' \
    "rich dataset extraction"

"$BIN" dataset "$BASE" --output jsonl >"$WORK/dataset.jsonl"
assert_jsonl "$WORK/dataset.jsonl" \
    'len(rows) == 3 and rows[0]["record"]["prompt"] == "Alpha prompt"' \
    "dataset JSON Lines"

"$BIN" dataset "$BASE" --output apple-json --pretty >"$WORK/dataset-apple.json"
assert_json "$WORK/dataset-apple.json" \
    'len(d) == 3 and d[2] == {"input": "Gamma prompt", "response": "gamma"}' \
    "Apple prompt-response dataset"

expect_failure "dataset JSONL rejects pretty printing" \
    "$BIN" dataset "$BASE" --output jsonl --pretty

"$BIN" compare "$BASE" "$CANDIDATE" --output json >"$WORK/compare.json"
assert_json "$WORK/compare.json" \
    'len(d["metrics"]) == 2 and abs(next(x for x in d["metrics"] if x["name"] == "Mean of Accuracy")["delta"] - 0.25) < 1e-9' \
    "aggregate comparison"

"$BIN" compare "$DUP_BASE" "$DUP_CANDIDATE" --output json >"$WORK/compare-duplicates.json"
assert_json "$WORK/compare-duplicates.json" \
    'len(d["metrics"]) == 3 and [x["group"] for x in d["metrics"]] == ["Quality", "Safety", "Quality"] and [x["occurrence"] for x in d["metrics"]] == [1, 1, 2]' \
    "duplicate summary comparisons"

"$BIN" compare "$DUP_BASE" "$DUP_CANDIDATE" --output text >"$WORK/compare-duplicates.txt"
assert_contains "$WORK/compare-duplicates.txt" \
    "Mean Score [Quality] #2" \
    "duplicate summary text labels"

"$BIN" gate "$BASE" \
    --rule "Mean of Accuracy>=0.5" \
    --rule "Maximum of Latency<3" \
    --output json >"$WORK/gate-pass.json"
assert_json "$WORK/gate-pass.json" \
    'd["passed"] is True and len(d["rules"]) == 2' \
    "passing gates"

expect_failure "failing gate status" \
    "$BIN" gate "$BASE" --rule "Mean of Accuracy>0.5" --output json
assert_json "$LAST_STDOUT" \
    'd["passed"] is False and d["rules"][0]["actual"] == 0.5' \
    "failing gate JSON"

expect_failure "missing gate metric" \
    "$BIN" gate "$BASE" --rule "Unknown>=1" --output json
expect_failure "ambiguous gate metric" \
    "$BIN" gate "$DUP_BASE" --rule "Mean Score>=0.5" --output json
expect_failure "invalid gate expression" \
    "$BIN" gate "$BASE" --rule "Accuracy is good" --output json
expect_failure "gate requires rules" \
    "$BIN" gate "$BASE" --output json

SPLIT="$WORK/split"
"$BIN" convert "$COLLECTION" --to directory --output-path "$SPLIT" --output json >"$WORK/convert-directory.json"
assert_json "$WORK/convert-directory.json" \
    'd["artifactCount"] == 2 and len(d["writtenFiles"]) == 2' \
    "split collection into artifacts"

"$BIN" list "$SPLIT" --output json >"$WORK/list-split.json"
assert_json "$WORK/list-split.json" 'd["count"] == 2' "load converted directory"

PACKED="$WORK/packed.jsonl"
"$BIN" convert "$SPLIT" --to jsonl --output-path "$PACKED" --output json >"$WORK/convert-jsonl.json"
assert_json "$WORK/convert-jsonl.json" \
    'd["artifactCount"] == 2 and d["writtenFiles"] == [d["outputPath"]]' \
    "pack directory into JSONL"

expect_failure "convert protects existing output" \
    "$BIN" convert "$SPLIT" --to jsonl --output-path "$PACKED" --output json
"$BIN" convert "$SPLIT" --to jsonl --output-path "$PACKED" --force --output json >"$WORK/convert-force.json"
assert_json "$WORK/convert-force.json" 'd["artifactCount"] == 2' "force conversion overwrite"

DUPLICATE_COLLECTION="$WORK/duplicate-ids.jsonl"
cat "$BASE" "$BASE" >"$DUPLICATE_COLLECTION"
DUPLICATE_DIRECTORY="$WORK/duplicate-output"
"$BIN" convert "$DUPLICATE_COLLECTION" \
    --to directory \
    --output-path "$DUPLICATE_DIRECTORY" \
    --output json >"$WORK/convert-duplicates.json"
assert_json "$WORK/convert-duplicates.json" \
    'len(d["writtenFiles"]) == 2 and len(set(d["writtenFiles"])) == 2 and any("-2.xcevalresult" in x for x in d["writtenFiles"])' \
    "duplicate output file names"

"$BIN" convert - --to jsonl --output-path "$WORK/stdin.jsonl" --output json \
    <"$BASE" >"$WORK/convert-stdin.json"
assert_json "$WORK/convert-stdin.json" 'd["artifactCount"] == 1' "convert stdin"

RUN_DIRECTORY="$WORK/run-results"
mkdir -p "$RUN_DIRECTORY"
"$BIN" run \
    --results-path "$RUN_DIRECTORY" \
    --output json \
    -- /bin/sh -c 'printf "producer stdout\n"; printf "producer stderr\n" >&2; cp "$1" "$2"' \
    _ "$BASE" "$RUN_DIRECTORY/produced.xcevalresult" >"$WORK/run.json"
assert_json "$WORK/run.json" \
    'd["process"]["status"] == 0 and "producer stdout" in d["process"]["standardOutput"] and "producer stderr" in d["process"]["standardError"] and len(d["artifacts"]) == 1' \
    "producer execution and capture"

expect_failure "producer with no new artifacts" \
    "$BIN" run --results-path "$RUN_DIRECTORY" --output json -- /usr/bin/true
assert_json "$LAST_STDOUT" \
    'd["process"]["status"] == 0 and d["artifacts"] == []' \
    "empty producer still emits JSON"

"$BIN" run \
    --results-path "$RUN_DIRECTORY" \
    --allow-empty \
    --output json \
    -- /usr/bin/true >"$WORK/run-empty.json"
assert_json "$WORK/run-empty.json" \
    'd["process"]["status"] == 0 and d["artifacts"] == []' \
    "allow-empty producer"

"$BIN" run \
    --results-path "$RUN_DIRECTORY" \
    --include-existing \
    --output json \
    -- /usr/bin/true >"$WORK/run-existing.json"
assert_json "$WORK/run-existing.json" \
    'd["process"]["status"] == 0 and len(d["artifacts"]) == 1' \
    "include existing artifacts"

expect_status 7 "producer exit status propagation" \
    "$BIN" run \
    --results-path "$RUN_DIRECTORY" \
    --allow-empty \
    --output json \
    -- /bin/sh -c 'printf "failed\n" >&2; exit 7'
assert_json "$LAST_STDOUT" \
    'd["process"]["status"] == 7 and "failed" in d["process"]["standardError"]' \
    "failed producer JSON"

WORKING_DIRECTORY="$WORK/producer working directory"
mkdir -p "$WORKING_DIRECTORY"
"$BIN" run \
    --results-path "$WORKING_DIRECTORY/result.xcevalresult" \
    --working-directory "$WORKING_DIRECTORY" \
    --output json \
    -- /bin/sh -c 'pwd; cp "$1" "$2"' \
    _ "$BASE" "$WORKING_DIRECTORY/result.xcevalresult" >"$WORK/run-working-directory.json"
assert_json "$WORK/run-working-directory.json" \
    'd["workingDirectory"].endswith("producer working directory") and d["workingDirectory"] in d["process"]["standardOutput"] and len(d["artifacts"]) == 1' \
    "producer working directory and single-file result path"

RELATIVE_WORKING_DIRECTORY="$WORK/relative producer directory"
mkdir -p "$RELATIVE_WORKING_DIRECTORY"
"$BIN" run \
    --results-path relative-results \
    --working-directory "$RELATIVE_WORKING_DIRECTORY" \
    --output json \
    -- /bin/sh -c 'mkdir -p relative-results; cp "$1" relative-results/result.xcevalresult' \
    _ "$BASE" >"$WORK/run-relative-results.json"
assert_json "$WORK/run-relative-results.json" \
    'd["resultsPath"].endswith("relative producer directory/relative-results") and len(d["artifacts"]) == 1' \
    "relative results path uses producer working directory"

RUN_JSONL="$WORK/run-results.jsonl"
cp "$BASE" "$RUN_JSONL"
"$BIN" run \
    --results-path "$RUN_JSONL" \
    --output json \
    -- /bin/sh -c 'cat "$1" >> "$2"' \
    _ "$CANDIDATE" "$RUN_JSONL" >"$WORK/run-jsonl.json"
assert_json "$WORK/run-jsonl.json" \
    'len(d["artifacts"]) == 1 and d["artifacts"][0]["resultID"] == "CANDIDATE"' \
    "JSONL run returns only appended artifacts"

RUN_DUPLICATE_JSONL="$WORK/run-duplicate-results.jsonl"
cp "$BASE" "$RUN_DUPLICATE_JSONL"
"$BIN" run \
    --results-path "$RUN_DUPLICATE_JSONL" \
    --output json \
    -- /bin/sh -c 'cat "$1" >> "$2"' \
    _ "$BASE" "$RUN_DUPLICATE_JSONL" >"$WORK/run-duplicate-jsonl.json"
assert_json "$WORK/run-duplicate-jsonl.json" \
    'len(d["artifacts"]) == 1 and d["artifacts"][0]["resultID"] == "BASELINE"' \
    "JSONL run preserves an appended duplicate artifact"

SAME_TARGET="$WORK/same-metadata.xcevalresult"
touch -t 202401010101 "$WORK/same-a.xcevalresult" "$WORK/same-b.xcevalresult"
cp -p "$WORK/same-a.xcevalresult" "$SAME_TARGET"
"$BIN" run \
    --results-path "$SAME_TARGET" \
    --output json \
    -- /bin/cp -p "$WORK/same-b.xcevalresult" "$SAME_TARGET" >"$WORK/run-same-metadata.json"
assert_json "$WORK/run-same-metadata.json" \
    'len(d["artifacts"]) == 1 and d["artifacts"][0]["resultID"] == "SAME-002"' \
    "content change with stable size and timestamp"

expect_failure "malformed produced artifact" \
    "$BIN" run \
    --results-path "$WORK/malformed-produced.xcevalresult" \
    --output json \
    -- /bin/cp "$WORK/scalar.json" "$WORK/malformed-produced.xcevalresult"

INIT_DIRECTORY="$WORK/GeneratedFeatureEvaluations"
"$BIN" init "Generated Feature" \
    --path "$INIT_DIRECTORY" \
    --output json >"$WORK/init.json"
assert_json "$WORK/init.json" \
    'd["packageName"] == "GeneratedFeatureEvaluations" and d["executableName"] == "generated-feature-evaluate" and len(d["files"]) == 8' \
    "evaluation starter generation"
test -f "$INIT_DIRECTORY/xceval.pipeline.json"
test -f "$INIT_DIRECTORY/Sources/GeneratedFeatureEvaluations/GeneratedFeatureEvaluation.swift"
mark "generated starter files"
expect_failure "init protects existing destination" \
    "$BIN" init "Generated Feature" --path "$INIT_DIRECTORY" --output json
RESERVED_INIT_DIRECTORY="$WORK/ReservedEvaluation"
"$BIN" init "Evaluation" \
    --path "$RESERVED_INIT_DIRECTORY" \
    --output json >"$WORK/init-reserved.json"
test -f \
    "$RESERVED_INIT_DIRECTORY/Sources/EvaluationEvaluations/GeneratedEvaluation.swift"
mark "generated starter avoids Evaluation protocol collision"

PIPELINE_ROOT="$WORK/pipelines"
mkdir -p "$PIPELINE_ROOT"
python3 - "$PIPELINE_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def write(name, value):
    directory = root / name
    directory.mkdir(parents=True)
    with (directory / "xceval.pipeline.json").open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")

base = {
    "schemaVersion": "xceval.pipeline/v1",
    "name": "Fixture pipeline",
    "workingDirectory": ".",
    "artifactsDirectory": "artifacts",
    "resultsPath": "results",
    "steps": [{
        "name": "produce",
        "command": [
            "/bin/sh",
            "-c",
            'mkdir -p results; /bin/cp "${SOURCE}" results/result.xcevalresult',
        ],
    }],
    "selection": {"resultID": "BASELINE"},
    "baseline": "${BASELINE}",
    "gates": ["Mean of Accuracy>=0.5"],
}
write("success", base)

gate = dict(base)
gate["name"] = "Failing gate pipeline"
gate["artifactsDirectory"] = "gate-artifacts"
gate["resultsPath"] = "gate-results"
gate["steps"] = [{
    "name": "produce",
    "command": [
        "/bin/sh",
        "-c",
        'mkdir -p gate-results; /bin/cp "${SOURCE}" gate-results/result.xcevalresult',
    ],
}]
gate["gates"] = ["Mean of Accuracy>0.5"]
write("gate-failure", gate)

write("step-failure", {
    "schemaVersion": "xceval.pipeline/v1",
    "name": "Step failure pipeline",
    "artifactsDirectory": "artifacts",
    "resultsPath": "results",
    "steps": [{
        "name": "explode",
        "command": ["/bin/sh", "-c", "printf failure >&2; exit 7"],
    }],
})

write("existing", {
    "schemaVersion": "xceval.pipeline/v1",
    "name": "Existing artifact pipeline",
    "artifactsDirectory": "artifacts",
    "resultsPath": "${SOURCE}",
    "selection": {"resultID": "BASELINE"},
})
PY

SUCCESS_MANIFEST="$PIPELINE_ROOT/success/xceval.pipeline.json"
"$BIN" pipeline "$SUCCESS_MANIFEST" \
    --set "SOURCE=$BASE" \
    --set "BASELINE=$BASE" \
    --output json >"$WORK/pipeline-success.json"
assert_json "$WORK/pipeline-success.json" \
    'd["passed"] is True and len(d["steps"]) == 1 and len(d["aggregateComparison"]) == 2 and d["gates"][0]["passed"] is True and set(d["outputs"]) >= {"result", "report", "metrics", "failures", "dataset", "promptResponse", "validation", "comparison", "gates"}' \
    "complete evaluation pipeline"
PIPELINE_ARTIFACTS="$PIPELINE_ROOT/success/artifacts"
test -f "$PIPELINE_ARTIFACTS/pipeline-report.json"
test -f "$PIPELINE_ARTIFACTS/report.json"
test -f "$PIPELINE_ARTIFACTS/failures.jsonl"
assert_json "$PIPELINE_ARTIFACTS/report.json" \
    'd["samples"][1]["issues"][0]["kind"] == "value-mismatch" and next(x for x in d["profiles"] if x["name"] == "Score")["numericValues"] == [0.8, 0.2]' \
    "pipeline report contents"
expect_failure "pipeline protects existing artifact directory" \
    "$BIN" pipeline "$SUCCESS_MANIFEST" \
        --set "SOURCE=$BASE" \
        --set "BASELINE=$BASE" \
        --output json
"$BIN" pipeline "$SUCCESS_MANIFEST" \
    --set "SOURCE=$BASE" \
    --set "BASELINE=$BASE" \
    --force \
    --include-existing \
    --output json >"$WORK/pipeline-force.json"
assert_json "$WORK/pipeline-force.json" 'd["passed"] is True' "pipeline force rerun"

expect_failure "pipeline failed gate" \
    "$BIN" pipeline "$PIPELINE_ROOT/gate-failure/xceval.pipeline.json" \
        --set "SOURCE=$BASE" \
        --set "BASELINE=$BASE" \
        --output json
assert_json "$LAST_STDOUT" \
    'd["passed"] is False and d["gates"][0]["passed"] is False and "One or more evaluation gates failed." in d["errors"]' \
    "failed gate pipeline report"

expect_status 7 "pipeline stage status propagation" \
    "$BIN" pipeline "$PIPELINE_ROOT/step-failure/xceval.pipeline.json" \
        --output json
assert_json "$LAST_STDOUT" \
    'd["passed"] is False and d["steps"][0]["status"] == 7 and "exited with status 7" in d["errors"][0]' \
    "failed stage pipeline report"
test -f "$PIPELINE_ROOT/step-failure/artifacts/logs/01-explode.stderr.log"
mark "failed stage logs"

expect_failure "pipeline unresolved variable" \
    "$BIN" pipeline "$PIPELINE_ROOT/existing/xceval.pipeline.json" \
        --include-existing \
        --output json
expect_failure "pipeline rejects malformed variable names" \
    "$BIN" pipeline "$PIPELINE_ROOT/existing/xceval.pipeline.json" \
        --set "1SOURCE=$BASE" \
        --include-existing \
        --output json
assert_contains "$LAST_STDERR" "Invalid --set name" \
    "pipeline variable name diagnostic"
expect_failure "pipeline validates explicit Xcode override" \
    "$BIN" pipeline "$PIPELINE_ROOT/existing/xceval.pipeline.json" \
        --set "SOURCE=$BASE" \
        --include-existing \
        --xcode "$WORK/missing.app" \
        --output json
assert_contains "$LAST_STDERR" "not an Xcode.app" \
    "pipeline invalid Xcode path diagnostic"
"$BIN" pipeline "$PIPELINE_ROOT/existing/xceval.pipeline.json" \
    --set "SOURCE=$BASE" \
    --include-existing \
    --output json >"$WORK/pipeline-existing.json"
assert_json "$WORK/pipeline-existing.json" \
    'd["passed"] is True and d["steps"] == [] and d["artifact"]["resultID"] == "BASELINE"' \
    "pipeline analyzes existing artifact"

expect_failure "run requires passthrough command" \
    "$BIN" run --results-path "$RUN_DIRECTORY" --output json
expect_failure "test requires xcodebuild arguments" \
    "$BIN" test --output json
expect_failure "test reserves result bundle path" \
    "$BIN" test --output json -- -resultBundlePath "$WORK/result.xcresult" test
expect_failure "test reserves combined result bundle path" \
    "$BIN" test --output json -- "-resultBundlePath=$WORK/result.xcresult" test
expect_failure "export rejects missing xcresult" \
    "$BIN" export "$WORK/missing.xcresult" --output json
expect_failure "schema distinguishes invalid Xcode path" \
    "$BIN" schema --xcode "$WORK/missing.app"
assert_contains "$LAST_STDERR" "not an Xcode.app" "invalid Xcode path diagnostic"

expect_failure "text output rejects pretty printing" \
    "$BIN" list "$BASE" --output text --pretty

printf 'CLI integration matrix passed: %d checks\n' "$CHECKS"
