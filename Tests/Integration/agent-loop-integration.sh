#!/bin/bash

# Black-box contract tests for the external-agent evaluation loop.
#
# The groups in this file intentionally describe the required public CLI
# interfaces. During implementation, run one group with:
#
#   XCEVAL_AGENT_TEST_GROUP=targets Tests/Integration/agent-loop-integration.sh
#
# The default runs every group and reports all missing contracts together.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${1:-$ROOT/.build/debug/xceval}"
if [[ "$BIN" != /* ]]; then
    BIN="$ROOT/$BIN"
fi
if [[ ! -x "$BIN" ]]; then
    echo "xceval binary is not executable: $BIN" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xceval-agent-integration.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
LAST_STDOUT="$WORK/last.stdout"
LAST_STDERR="$WORK/last.stderr"
LAST_STATUS=0
CHECKS=0
GROUP_FAILURES=0

mark() {
    CHECKS=$((CHECKS + 1))
    printf '[ok] %s\n' "$1"
}

capture() {
    set +e
    "$@" >"$LAST_STDOUT" 2>"$LAST_STDERR"
    LAST_STATUS=$?
    set -e
}

require_success() {
    local name="$1"
    if [[ $LAST_STATUS -ne 0 ]]; then
        echo "Expected success, got status $LAST_STATUS: $name" >&2
        sed -n '1,20p' "$LAST_STDERR" >&2
        return 1
    fi
}

require_failure() {
    local name="$1"
    if [[ $LAST_STATUS -eq 0 ]]; then
        echo "Expected failure: $name" >&2
        return 1
    fi
}

assert_json() {
    local file="$1"
    local expression="$2"
    local name="$3"
    python3 - "$file" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"Expected JSON in {path}: {error}") from error
scope = {
    "d": data,
    "len": len,
    "abs": abs,
    "all": all,
    "any": any,
    "next": next,
    "set": set,
    "sorted": sorted,
    "isinstance": isinstance,
    "dict": dict,
    "list": list,
    "str": str,
    "bool": bool,
}
globals_scope = {"__builtins__": {}}
globals_scope.update(scope)
if not eval(expression, globals_scope, {}):
    raise SystemExit(f"JSON assertion failed: {expression}\n{data!r}")
PY
    mark "$name"
}

assert_same_json_value() {
    local first="$1"
    local second="$2"
    local expression="$3"
    local name="$4"
    python3 - "$first" "$second" "$expression" <<'PY'
import json
import sys

first_path, second_path, expression = sys.argv[1:]
try:
    with open(first_path, encoding="utf-8") as handle:
        first = json.load(handle)
    with open(second_path, encoding="utf-8") as handle:
        second = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"Expected comparable JSON documents: {error}") from error
scope = {"a": first, "b": second}
globals_scope = {"__builtins__": {}}
globals_scope.update(scope)
if not eval(expression, globals_scope, {}):
    raise SystemExit(
        f"JSON values differ for: {expression}\nfirst={first!r}\nsecond={second!r}"
    )
PY
    mark "$name"
}

assert_file_exists() {
    local path="$1"
    local name="$2"
    if [[ ! -f "$path" ]]; then
        echo "Expected file to exist: $path" >&2
        return 1
    fi
    mark "$name"
}

python3 - "$WORK" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def sample(key, prompt, response, expected, kind, value):
    return {
        "Input": json.dumps(
            {"input": {"id": key, "prompt": prompt}},
            separators=(",", ":"),
            sort_keys=True,
        ),
        "Response": {"typeName": "String", "value": response},
        "Expected": expected,
        "Accuracy": {
            "evaluatorKind": "custom",
            "kind": kind,
            "value": value,
        },
    }

baseline = {
    "evaluationID": "AgentLoop",
    "resultID": "BASELINE",
    "evaluationInfo": {"datasetID": "golden-v1"},
    "summary": [{
        "Mean of Accuracy": {
            "group": "Quality",
            "operation": {"metric": "Accuracy", "type": "mean"},
            "value": 0.5,
        }
    }],
    "results": [
        sample("case-alpha", "Alpha prompt", "alpha", "alpha", "pass", True),
        sample("case-beta", "Beta prompt", "wrong", "beta", "fail", False),
        sample("case-gamma", "Gamma prompt", "gamma", "gamma", "ignore", None),
    ],
}

candidate = copy.deepcopy(baseline)
candidate["resultID"] = "CANDIDATE"
candidate["summary"][0]["Mean of Accuracy"]["value"] = 0.75
candidate["results"] = [
    sample("case-alpha", "Alpha prompt", "wrong", "alpha", "fail", False),
    sample("case-beta", "Beta prompt", "beta", "beta", "pass", True),
    sample("case-delta", "Delta prompt", "delta", "delta", "pass", True),
]

def write_json(name, value, *, pretty=True):
    with (root / name).open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2 if pretty else None, sort_keys=pretty)
        handle.write("\n")

write_json("baseline.xcevalresult", baseline)
write_json("baseline-reformatted.xcevalresult", baseline, pretty=False)
write_json("candidate.xcevalresult", candidate)
duplicate_keys = copy.deepcopy(baseline)
duplicate_keys["resultID"] = "DUPLICATE-KEYS"
duplicate_keys["results"] = [
    sample("shared", "First prompt", "first", "first", "pass", True),
    sample("shared", "Second prompt", "second", "second", "pass", True),
]
write_json("duplicate-keys.xcevalresult", duplicate_keys)
baseline_canonical = json.dumps(
    baseline,
    separators=(",", ":"),
    sort_keys=True,
).encode()
write_json(
    "seed.selection.json",
    {
        "schemaVersion": "xceval.selection/v1",
        "source": {
            "path": str(root / "baseline.xcevalresult"),
            "artifactID": "sha256:" + hashlib.sha256(baseline_canonical).hexdigest(),
            "evaluationID": "AgentLoop",
            "resultID": "BASELINE",
        },
        "sampleKey": "/input/id",
        "count": 1,
        "samples": [{"key": "case-beta", "index": 1}],
    },
)
write_json(
    "dataset.selection.json",
    {
        "schemaVersion": "xceval.selection/v1",
        "sampleKey": "/id",
        "count": 2,
        "samples": [
            {"key": "case-alpha", "index": 0},
            {"key": "case-missing", "index": 99},
        ],
    },
)
write_json(
    "dataset-duplicate.selection.json",
    {
        "schemaVersion": "xceval.selection/v1",
        "sampleKey": "/id",
        "count": 2,
        "samples": [
            {"key": "case-alpha", "index": 0},
            {"key": "case-alpha", "index": 0},
        ],
    },
)

golden = [
    {
        "id": "case-alpha",
        "input": {"prompt": "Alpha prompt"},
        "expected": "alpha",
    },
    {
        "id": "case-gamma",
        "input": {"prompt": "Gamma prompt"},
        "expected": "gamma",
    },
]
invalid = [
    {"id": "duplicate", "input": {"prompt": "One"}, "expected": "one"},
    {"id": "duplicate", "input": {"prompt": "Two"}},
]
write_json("golden.dataset.json", golden)
write_json("invalid.dataset.json", invalid)

results = root / "target-results"
state = root / "operation-state"
marker = root / "target-marker"
targets = {
    "schemaVersion": "xceval.targets/v1",
    "targets": [
        {
            "id": "fixture.evaluate",
            "kind": "command",
            "workingDirectory": str(root),
            "argv": [
                "/bin/sh",
                "-c",
                'mkdir -p "$1"; printf "run\n" >>"$2"; cp "$3" "$1/result.xcevalresult"',
                "_",
                str(results),
                str(marker),
                str(root / "candidate.xcevalresult"),
            ],
            "environment": {"inherit": [], "set": {}},
            "outputs": [
                {
                    "role": "evaluation-results",
                    "path": str(results),
                    "format": "xcevalresult",
                    "minimumCount": 1,
                }
            ],
            "requirements": [],
        },
        {
            "id": "fixture.empty",
            "kind": "command",
            "workingDirectory": str(root),
            "argv": ["/usr/bin/true"],
            "environment": {"inherit": [], "set": {}},
            "outputs": [
                {
                    "role": "evaluation-results",
                    "path": str(root / "empty-target-results"),
                    "format": "xcevalresult",
                    "minimumCount": 1,
                }
            ],
            "requirements": [],
        },
        {
            "id": "fixture.timeout",
            "kind": "command",
            "workingDirectory": str(root),
            "argv": ["/bin/sh", "-c", "sleep 5"],
            "environment": {"inherit": [], "set": {}},
            "outputs": [
                {
                    "role": "evaluation-results",
                    "path": str(root / "timeout-results"),
                    "format": "xcevalresult",
                    "minimumCount": 0,
                }
            ],
            "requirements": [],
        },
        {
            "id": "fixture.unsafe",
            "kind": "command",
            "workingDirectory": str(root),
            "argv": ["/usr/bin/true"],
            "environment": {"inherit": [], "set": {}},
            "outputs": [
                {
                    "role": "evaluation-results",
                    "path": "/",
                    "format": "xcevalresult",
                    "minimumCount": 1,
                }
            ],
            "requirements": [],
        },
    ],
}
write_json("xceval.targets.json", targets)

safe = root / "safe-project"
safe.mkdir()
(safe / "keep.txt").write_text("must survive\n", encoding="utf-8")
write_json(
    "safe-project/xceval.pipeline.json",
    {
        "schemaVersion": "xceval.pipeline/v1",
        "name": "Unsafe path fixture",
        "workingDirectory": ".",
        "artifactsDirectory": ".",
        "resultsPath": "results",
        "steps": [],
    },
)
PY

BASE="$WORK/baseline.xcevalresult"
REFORMATTED="$WORK/baseline-reformatted.xcevalresult"
CANDIDATE="$WORK/candidate.xcevalresult"
DUPLICATE_KEYS="$WORK/duplicate-keys.xcevalresult"
TARGETS="$WORK/xceval.targets.json"
STATE="$WORK/operation-state"
SELECTION="$WORK/failures.selection.json"
SEED_SELECTION="$WORK/seed.selection.json"
DATASET_SELECTION="$WORK/dataset.selection.json"
DUPLICATE_DATASET_SELECTION="$WORK/dataset-duplicate.selection.json"
GOLDEN="$WORK/golden.dataset.json"
INVALID_DATASET="$WORK/invalid.dataset.json"

test_stable_errors_and_contracts() {
    capture "$BIN" list "$BASE" --output json
    require_success "legacy list JSON contract"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "list" and d["count"] == 1' \
        "legacy JSON contract remains compatible"

    capture "$BIN" list "$WORK/missing.xcevalresult" --output json
    require_failure "missing artifact machine error"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["command"] == "list" and d["error"]["code"] == "input_not_found" and isinstance(d["error"]["retryable"], bool) and isinstance(d["error"]["details"], dict)' \
        "machine errors have stable code, retryability, and details"

    capture "$BIN" list "$WORK/missing-implicit.xcevalresult"
    require_failure "piped default machine error"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["command"] == "list" and d["error"]["code"] == "input_not_found" and d["error"]["retryable"] is False' \
        "piped failures default to the same JSON contract as successes"

    capture "$BIN" targets "$WORK/missing-targets.json" --output json
    require_failure "missing targets manifest machine error"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["command"] == "targets" and d["error"]["code"] == "manifest_not_found" and d["error"]["retryable"] is False and "path" in d["error"]["details"]' \
        "new commands share the stable machine error envelope"
}

test_artifact_content_ids() {
    local first="$WORK/list-first.json"
    local reformatted="$WORK/list-reformatted.json"
    local candidate="$WORK/list-candidate.json"
    local inspect="$WORK/inspect-content-id.json"

    "$BIN" list "$BASE" --output json >"$first"
    "$BIN" list "$REFORMATTED" --output json >"$reformatted"
    "$BIN" list "$CANDIDATE" --output json >"$candidate"
    "$BIN" inspect "$BASE" --output json >"$inspect"

    assert_json "$first" \
        'd["artifacts"][0]["artifactID"].startswith("sha256:") and len(d["artifacts"][0]["artifactID"]) == 71 and all(x in "0123456789abcdef" for x in d["artifacts"][0]["artifactID"][7:]) and d["artifacts"][0]["byteDigest"].startswith("sha256:")' \
        "artifact content ID is an explicit SHA-256 identifier"
    assert_same_json_value "$first" "$reformatted" \
        'a["artifacts"][0]["artifactID"] == b["artifacts"][0]["artifactID"]' \
        "artifact content ID is invariant to JSON formatting"
    assert_same_json_value "$first" "$reformatted" \
        'a["artifacts"][0]["byteDigest"] != b["artifacts"][0]["byteDigest"]' \
        "artifact byte digest preserves exact source identity"
    assert_same_json_value "$first" "$candidate" \
        'a["artifacts"][0]["artifactID"] != b["artifacts"][0]["artifactID"]' \
        "artifact content ID changes with semantic content"
    assert_same_json_value "$first" "$inspect" \
        'a["artifacts"][0]["artifactID"] == b["artifact"]["artifactID"]' \
        "artifact content ID is consistent across commands"
}

test_targets() {
    capture "$BIN" targets "$TARGETS" --output json
    require_success "list declared targets"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.targets/v1" and d["command"] == "targets" and d["count"] == 4 and [x["id"] for x in d["targets"]] == ["fixture.evaluate", "fixture.empty", "fixture.timeout", "fixture.unsafe"]' \
        "targets lists ordered declared targets"
    assert_json "$LAST_STDOUT" \
        'd["targets"][0]["kind"] == "command" and d["targets"][0]["revision"].startswith("sha256:") and d["targets"][0]["argv"][0] == "/bin/sh" and d["targets"][0]["outputs"][0]["role"] == "evaluation-results"' \
        "target contract exposes execution and output declarations"

    capture "$BIN" target fixture.evaluate --manifest "$TARGETS" --output json
    require_success "resolve one declared target"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.targets/v1" and d["command"] == "target" and d["target"]["id"] == "fixture.evaluate" and isinstance(d["target"]["environment"]["set"], dict)' \
        "target resolves one complete declaration"

    capture "$BIN" target missing.target --manifest "$TARGETS" --output json
    require_failure "unknown target"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["error"]["code"] == "target_not_found" and d["error"]["details"]["targetID"] == "missing.target"' \
        "unknown target is a structured error"
}

test_selection_manifests() {
    capture "$BIN" select "$BASE" \
        --only-failures \
        --sample-key /input/id \
        --output-path "$SELECTION" \
        --output json
    require_success "write failure selection manifest"
    assert_file_exists "$SELECTION" "selection manifest is persisted"
    assert_json "$SELECTION" \
        'd["schemaVersion"] == "xceval.selection/v1" and d["sampleKey"] == "/input/id" and d["count"] == 1 and d["samples"][0]["key"] == "case-beta" and d["source"]["artifactID"].startswith("sha256:")' \
        "selection manifest contains stable sample and artifact identities"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.selection/v1" and d["command"] == "select" and d["outputPath"].endswith("failures.selection.json")' \
        "select reports the persisted manifest"

    local duplicate_selection="$WORK/duplicate.selection.json"
    capture "$BIN" select "$DUPLICATE_KEYS" \
        --sample-key /input/id \
        --output-path "$duplicate_selection" \
        --output json
    require_failure "reject duplicate selection keys"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["command"] == "select" and d["error"]["code"] == "invalid_arguments" and d["error"]["retryable"] is False' \
        "duplicate selection keys produce a structured failure"
    if [[ -e "$duplicate_selection" ]]; then
        echo "Duplicate selection keys wrote a manifest." >&2
        return 1
    fi
    mark "duplicate selection keys fail before writing"
}

test_sample_compare() {
    capture "$BIN" compare "$BASE" "$CANDIDATE" \
        --sample-key /input/id \
        --include-samples \
        --output json
    require_success "sample comparison"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "compare" and d["sampleKeyStrategy"]["jsonPointer"]["_0"] == "/input/id"' \
        "compare retains the existing envelope and adds sample comparison"
    assert_json "$LAST_STDOUT" \
        'sorted(x["classification"] for x in d["samples"]) == ["added", "fixed", "regressed", "removed"]' \
        "sample comparison summarizes lifecycle classifications"
    assert_json "$LAST_STDOUT" \
        'all(any(x["classification"] == classification and key in x["key"]["value"] for x in d["samples"]) for key, classification in [("case-alpha", "regressed"), ("case-beta", "fixed"), ("case-delta", "added"), ("case-gamma", "removed")])' \
        "sample comparison is keyed by durable dataset identity"

    capture "$BIN" compare "$BASE" "$CANDIDATE" \
        --sample-key /input/missing \
        --include-samples \
        --output json
    require_success "missing sample key remains inspectable"
    assert_json "$LAST_STDOUT" \
        'len(d["samples"]) == 6 and all(x["classification"] == "unjoinable" and "key" not in x for x in d["samples"])' \
        "samples missing the selected identity are explicitly unjoinable"
}

test_delta_gates() {
    capture "$BIN" gate "$CANDIDATE" \
        --baseline "$BASE" \
        --delta-rule "Mean of Accuracy>=0.2" \
        --output json
    require_success "passing delta gate"
    assert_json "$LAST_STDOUT" \
        'd["passed"] is True and d["baseline"]["resultID"] == "BASELINE" and d["artifact"]["resultID"] == "CANDIDATE" and d["deltaRules"][0]["expression"] == "Mean of Accuracy>=0.2" and abs(d["deltaRules"][0]["delta"] - 0.25) < 1e-9 and d["deltaRules"][0]["passed"] is True' \
        "delta gate evaluates candidate minus baseline"

    capture "$BIN" gate "$CANDIDATE" \
        --baseline "$BASE" \
        --delta-rule "Mean of Accuracy>=0.3" \
        --output json
    require_failure "failing delta gate"
    assert_json "$LAST_STDOUT" \
        'd["passed"] is False and abs(d["deltaRules"][0]["baseline"] - 0.5) < 1e-9 and abs(d["deltaRules"][0]["candidate"] - 0.75) < 1e-9 and abs(d["deltaRules"][0]["delta"] - 0.25) < 1e-9' \
        "failing delta gate still emits complete evidence"
}

test_operation_receipts_and_timeouts() {
    local first="$WORK/operation-first.json"
    local replay="$WORK/operation-replay.json"
    local fetched="$WORK/operation-fetched.json"

    capture "$BIN" run fixture.evaluate \
        --targets "$TARGETS" \
        --operation-id operation-success \
        --state-directory "$STATE" \
        --timeout 10 \
        --selection "$SEED_SELECTION" \
        --output json
    require_success "run declared target"
    cp "$LAST_STDOUT" "$first"
    assert_json "$first" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "run" and d["replayed"] is False and d["process"]["status"] == 0 and d["operationReceipt"]["schemaVersion"] == "xceval.operation-receipt/v1" and d["operationReceipt"]["idempotencyKey"] == "operation-success" and d["operationReceipt"]["operation"] == "run" and d["operationReceipt"]["state"] == "succeeded"' \
        "run emits a durable operation receipt"
    assert_json "$first" \
        'd["operationReceipt"]["inputDigest"].startswith("sha256:") and d["operationReceipt"]["outputs"][0]["path"].endswith("result.xcevalresult") and d["operationReceipt"]["outputs"][0]["contentDigest"].startswith("sha256:")' \
        "receipt binds the request and produced artifact bytes"

    capture "$BIN" operation operation-success \
        --state-directory "$STATE" \
        --output json
    require_success "read operation receipt"
    cp "$LAST_STDOUT" "$fetched"
    assert_same_json_value "$first" "$fetched" \
        'a["operationReceipt"]["operationID"] == b["operationID"] and a["operationReceipt"]["inputDigest"] == b["inputDigest"] and a["operationReceipt"]["outputs"] == b["outputs"]' \
        "operation retrieves the durable receipt"

    rm -f "$WORK/target-results/result.xcevalresult"
    capture "$BIN" run fixture.evaluate \
        --targets "$TARGETS" \
        --operation-id operation-success \
        --state-directory "$STATE" \
        --timeout 10 \
        --selection "$SEED_SELECTION" \
        --output json
    require_success "idempotent operation replay"
    cp "$LAST_STDOUT" "$replay"
    assert_same_json_value "$first" "$replay" \
        'b["schemaVersion"] == "xceval/v1" and b["command"] == "run" and b["replayed"] is True and a["operationReceipt"]["operationID"] == b["operationReceipt"]["operationID"] and a["operationReceipt"]["inputDigest"] == b["operationReceipt"]["inputDigest"] and a["operationReceipt"]["outputs"] == b["operationReceipt"]["outputs"] and a["artifacts"] == b["artifacts"]' \
        "replay restores the run envelope from its receipt"
    if [[ $(wc -l <"$WORK/target-marker") -ne 1 ]]; then
        echo "Idempotent operation executed its target more than once." >&2
        return 1
    fi
    mark "idempotent replay does not re-execute target"

    capture "$BIN" run fixture.evaluate \
        --targets "$TARGETS" \
        --operation-id operation-success \
        --state-directory "$STATE" \
        --timeout 9 \
        --selection "$SEED_SELECTION" \
        --output json
    require_failure "conflicting operation request"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["command"] == "run" and d["error"]["code"] == "operation_conflict" and d["error"]["retryable"] is False and d["error"]["details"]["operationID"] == "operation-success"' \
        "operation conflict emits its documented machine contract"

    python3 - "$STATE" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

state = pathlib.Path(sys.argv[1])
digest = hashlib.sha256(b"operation-success").hexdigest()
receipt = state / f"{digest}.json"
temporary = state / f".{digest}.ambiguous.tmp"
document = json.loads(receipt.read_text(encoding="utf-8"))
document["state"] = "running"
document["outputs"] = []
for key in ("endedAt", "process", "errorMessage"):
    document.pop(key, None)
temporary.write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
os.replace(temporary, receipt)
PY
    capture "$BIN" run fixture.evaluate \
        --targets "$TARGETS" \
        --operation-id operation-success \
        --state-directory "$STATE" \
        --timeout 10 \
        --selection "$SEED_SELECTION" \
        --output json
    require_failure "refuse ambiguous completed operation"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["command"] == "run" and d["error"]["code"] == "operation_outcome_ambiguous" and d["error"]["retryable"] is False and d["error"]["details"]["operationID"] == "operation-success"' \
        "uncommitted completed outcome is a non-retryable ambiguity"
    if [[ $(wc -l <"$WORK/target-marker") -ne 1 ]]; then
        echo "Ambiguous completed operation re-executed its target." >&2
        return 1
    fi
    mark "ambiguous completed operation never re-executes target"

    capture "$BIN" operation operation-missing \
        --state-directory "$STATE" \
        --output json
    require_failure "read missing operation"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["command"] == "operation" and d["error"]["code"] == "operation_not_found" and d["error"]["retryable"] is False and d["error"]["details"]["operationID"] == "operation-missing"' \
        "missing operation is distinct from an identity conflict"

    local pending_id="operation-pending"
    local claim_digest
    claim_digest="$(
        python3 - "$pending_id" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode()).hexdigest())
PY
    )"
    local claim_path="$STATE/$claim_digest.claim"
    local lock_ready="$WORK/pending-lock-ready"
    python3 - "$claim_path" "$lock_ready" <<'PY' &
import fcntl
import pathlib
import sys
import time

claim = pathlib.Path(sys.argv[1])
claim.parent.mkdir(parents=True, exist_ok=True)
with claim.open("a+b") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).write_text("ready\n", encoding="utf-8")
    time.sleep(3)
PY
    local lock_pid=$!
    local lock_observed=0
    for _ in {1..100}; do
        if [[ -f "$lock_ready" ]]; then
            lock_observed=1
            break
        fi
        sleep 0.02
    done
    if [[ $lock_observed -ne 1 ]]; then
        echo "Pending-operation lock was not acquired in time." >&2
        kill -KILL "$lock_pid" 2>/dev/null || true
        wait "$lock_pid" 2>/dev/null
        return 1
    fi
    capture "$BIN" run \
        --results-path "$WORK/pending-results" \
        --allow-empty \
        --operation-id "$pending_id" \
        --state-directory "$STATE" \
        --output json \
        -- /usr/bin/true
    require_failure "observe pending operation claim"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["command"] == "run" and d["error"]["code"] == "operation_in_progress" and d["error"]["retryable"] is True and d["error"]["details"]["operationID"] == "operation-pending"' \
        "pending operation claim is explicitly retryable"
    wait "$lock_pid"

    capture "$BIN" run fixture.empty \
        --targets "$TARGETS" \
        --allow-empty \
        --output json
    require_success "allow empty declared target"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "run" and d["process"]["status"] == 0 and d["artifacts"] == []' \
        "allow-empty overrides a declared minimum for a zero-artifact run"

    capture "$BIN" run fixture.timeout \
        --targets "$TARGETS" \
        --operation-id operation-timeout \
        --state-directory "$STATE" \
        --timeout 0.2 \
        --output json
    require_failure "timed out target"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "run" and d["operationReceipt"]["schemaVersion"] == "xceval.operation-receipt/v1" and d["operationReceipt"]["idempotencyKey"] == "operation-timeout" and d["operationReceipt"]["state"] == "timedOut" and d["operationReceipt"]["process"]["terminationReason"] == "timedOut" and d["operationReceipt"]["process"]["duration"] < 5' \
        "timeout writes a terminal machine-readable receipt"

    capture "$BIN" operation operation-timeout \
        --state-directory "$STATE" \
        --output json
    require_success "read timed-out operation"
    assert_json "$LAST_STDOUT" \
        'd["idempotencyKey"] == "operation-timeout" and d["state"] == "timedOut"' \
        "timed-out receipt remains inspectable"

    "$BIN" run \
        --results-path "$WORK/interrupted-results" \
        --operation-id operation-interrupted \
        --state-directory "$STATE" \
        --output json \
        -- /bin/sleep 30 \
        >"$WORK/interrupted.stdout" \
        2>"$WORK/interrupted.stderr" &
    local interrupted_pid=$!
    local interrupted_claimed=0
    for _ in {1..100}; do
        if "$BIN" operation operation-interrupted \
            --state-directory "$STATE" \
            --output json \
            >/dev/null 2>&1
        then
            interrupted_claimed=1
            break
        fi
        sleep 0.02
    done
    if [[ $interrupted_claimed -ne 1 ]]; then
        echo "Interrupted operation was not claimed in time." >&2
        kill -KILL "$interrupted_pid" 2>/dev/null || true
        wait "$interrupted_pid" 2>/dev/null
        return 1
    fi
    capture "$BIN" run \
        --results-path "$WORK/interrupted-results" \
        --operation-id operation-interrupted \
        --state-directory "$STATE" \
        --output json \
        -- /bin/sleep 30
    require_failure "observe live idempotent operation"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "run" and d["replayed"] is True and d.get("process") is None and d["artifacts"] == [] and d["operationReceipt"]["state"] == "running"' \
        "concurrent observer receives an in-progress run envelope"
    kill -INT "$interrupted_pid"
    set +e
    wait "$interrupted_pid"
    local interrupted_status=$?
    set -e
    if [[ $interrupted_status -eq 0 ]]; then
        echo "Interrupted operation unexpectedly succeeded." >&2
        return 1
    fi
    capture "$BIN" operation operation-interrupted \
        --state-directory "$STATE" \
        --output json
    require_success "read interrupted operation"
    assert_json "$LAST_STDOUT" \
        'd["state"] == "cancelled" and d["process"]["terminationReason"] == "cancelled" and d["endedAt"] is not None' \
        "interrupt writes a terminal cancelled receipt"
}

test_safe_paths() {
    local safe_project="$WORK/safe-project"
    capture "$BIN" pipeline "$safe_project/xceval.pipeline.json" \
        --force \
        --output json
    require_failure "pipeline working-directory deletion guard"
    assert_file_exists "$safe_project/keep.txt" \
        "unsafe pipeline rejection preserves the working directory"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["error"]["code"] == "unsafe_output_path" and d["error"]["retryable"] is False and d["error"]["details"]["path"]' \
        "pipeline rejects an artifact path equal to its working directory"

    capture "$BIN" run fixture.unsafe \
        --targets "$TARGETS" \
        --operation-id operation-unsafe \
        --state-directory "$STATE" \
        --timeout 1 \
        --output json
    require_failure "unsafe declared output"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["error"]["code"] == "unsafe_output_path" and d["error"]["details"]["path"] == "/"' \
        "target preflight rejects filesystem root outputs"
}

test_datasets() {
    local discovered="$WORK/datasets-discovered.json"
    local selected="$WORK/dataset-selected.json"
    local draft="$WORK/dataset-draft.json"
    local promoted="$WORK/dataset-promoted.json"

    capture "$BIN" datasets discover "$WORK" --output json
    require_success "discover datasets"
    cp "$LAST_STDOUT" "$discovered"
    assert_json "$discovered" \
        'd["schemaVersion"] == "xceval.datasets/v1" and d["command"] == "datasets.discover" and any(x["path"].endswith("golden.dataset.json") and x["recordCount"] == 2 for x in d["datasets"])' \
        "dataset discovery returns machine-readable candidates"

    capture "$BIN" datasets validate "$GOLDEN" \
        --sample-key /id \
        --output json
    require_success "validate dataset"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.dataset-validation/v1" and d["command"] == "datasets.validate" and d["valid"] is True and d["recordCount"] == 2 and d["datasetID"].startswith("sha256:")' \
        "valid dataset has a durable content identity"

    capture "$BIN" datasets validate "$INVALID_DATASET" \
        --sample-key /id \
        --output json
    require_failure "invalid dataset"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.dataset-validation/v1" and d["valid"] is False and set(x["code"] for x in d["issues"]) >= {"duplicate_sample_key", "missing_expected"}' \
        "dataset validation reports stable issue codes"

    capture "$BIN" datasets select "$GOLDEN" \
        --selection "$DATASET_SELECTION" \
        --sample-key /id \
        --allow-missing \
        --output-path "$selected" \
        --output json
    require_success "select dataset records"
    assert_file_exists "$selected" "dataset selection writes records"
    assert_json "$selected" \
        'len(d) == 1 and d[0]["id"] == "case-alpha"' \
        "dataset selection materializes requested records"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.datasets/v1" and d["command"] == "datasets.select" and d["selectedCount"] == 1 and d["missingKeys"] == ["case-missing"]' \
        "dataset selection reports absent requested keys"

    local duplicate_selected="$WORK/dataset-duplicate-selected.json"
    capture "$BIN" datasets select "$GOLDEN" \
        --selection "$DUPLICATE_DATASET_SELECTION" \
        --sample-key /id \
        --output-path "$duplicate_selected" \
        --output json
    require_failure "reject duplicate legacy dataset selection keys"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.error/v1" and d["command"] == "datasets" and d["error"]["code"] == "invalid_arguments" and d["error"]["retryable"] is False' \
        "duplicate legacy dataset selection keys are structured failures"
    if [[ -e "$duplicate_selected" ]]; then
        echo "Duplicate dataset selection keys wrote output." >&2
        return 1
    fi
    mark "duplicate legacy dataset selection keys fail before writing"

    capture "$BIN" datasets draft "$BASE" \
        --only-failures \
        --sample-key /input/id \
        --output-path "$draft" \
        --output json
    require_success "draft regression dataset"
    assert_file_exists "$draft" "dataset draft is persisted"
    assert_json "$draft" \
        'len(d) == 1 and d[0]["id"] == "case-beta"' \
        "draft extracts the failing sample with stable identity"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.datasets/v1" and d["command"] == "datasets.draft" and d["recordCount"] == 1 and d["source"]["artifactID"].startswith("sha256:")' \
        "draft receipt binds the source artifact"

    capture "$BIN" datasets promote "$draft" \
        --into "$GOLDEN" \
        --sample-key /id \
        --output-path "$promoted" \
        --output json
    require_success "promote regression dataset"
    assert_file_exists "$promoted" "promoted dataset is persisted"
    assert_json "$promoted" \
        'len(d) == 3 and sorted(x["id"] for x in d) == ["case-alpha", "case-beta", "case-gamma"]' \
        "promotion merges draft records without losing existing data"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval.datasets/v1" and d["command"] == "datasets.promote" and d["addedCount"] == 1 and d["duplicateCount"] == 0 and d["datasetID"].startswith("sha256:")' \
        "promotion emits a reproducible dataset receipt"
}

test_existing_compatibility() {
    capture "$BIN" run \
        --results-path "$WORK/legacy-results" \
        --allow-empty \
        --output json \
        -- /usr/bin/true
    require_success "legacy run syntax"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "run" and d["process"]["status"] == 0 and d["artifacts"] == []' \
        "legacy run remains source compatible"

    local current_results="$WORK/legacy-current-results"
    mkdir -p "$current_results"
    capture "$BIN" run \
        --working-directory "$current_results" \
        --results-path . \
        --allow-empty \
        --output json \
        -- /usr/bin/touch producer-ran
    require_success "legacy current-directory result scan"
    assert_file_exists "$current_results/producer-ran" \
        "current-directory results path does not block the producer"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "run" and d["resultsPath"].endswith("legacy-current-results") and d["process"]["status"] == 0' \
        "current-directory results path remains a non-destructive scan"

    capture "$BIN" inspect "$BASE" --summary-only --output json
    require_success "legacy inspect contract"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "inspect" and d["artifact"]["sampleCount"] == 3 and "samples" not in d["artifact"]' \
        "legacy inspect contract remains compatible"

    capture "$BIN" gate "$BASE" \
        --rule "Mean of Accuracy>=0.5" \
        --output json
    require_success "legacy absolute gate"
    assert_json "$LAST_STDOUT" \
        'd["schemaVersion"] == "xceval/v1" and d["command"] == "gate" and d["passed"] is True and d["rules"][0]["actual"] == 0.5' \
        "legacy absolute gates remain compatible"
}

run_group() {
    local name="$1"
    local function_name="$2"
    local selected="${XCEVAL_AGENT_TEST_GROUP:-all}"
    if [[ "$selected" != "all" && "$selected" != "$name" ]]; then
        return
    fi

    printf '[group] %s\n' "$name"
    set +e
    (
        set -e
        "$function_name"
    )
    local status=$?
    set -e
    if [[ $status -ne 0 ]]; then
        GROUP_FAILURES=$((GROUP_FAILURES + 1))
        printf '[failed] %s\n' "$name" >&2
    fi
}

run_group contracts test_stable_errors_and_contracts
run_group artifact-ids test_artifact_content_ids
run_group targets test_targets
run_group selections test_selection_manifests
run_group sample-compare test_sample_compare
run_group delta-gates test_delta_gates
run_group operations test_operation_receipts_and_timeouts
run_group safe-paths test_safe_paths
run_group datasets test_datasets
run_group compatibility test_existing_compatibility

if [[ $GROUP_FAILURES -ne 0 ]]; then
    printf 'Agent-loop integration groups failed: %d\n' "$GROUP_FAILURES" >&2
    exit 1
fi

printf 'Agent-loop integration groups passed.\n'
