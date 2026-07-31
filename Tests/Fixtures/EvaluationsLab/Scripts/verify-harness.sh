#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
fixture_directory=${script_directory:h}
expected_tuist_version=4.202.2
default_developer_directory=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer
developer_directory="${DEVELOPER_DIR:-$default_developer_directory}"
require_toolchain="${EVALUATIONS_LAB_REQUIRE_TOOLCHAIN:-0}"

function skip_or_fail {
    local reason=$1

    if [[ "$require_toolchain" == "1" ]]; then
        print -u2 "ERROR: $reason"
        exit 1
    fi

    print "SKIP: $reason"
    exit 0
}

xcodebuild_path="$developer_directory/usr/bin/xcodebuild"
if [[ ! -x "$xcodebuild_path" ]]; then
    skip_or_fail "Xcode 27 is unavailable at $developer_directory."
fi

xcode_version="$("$xcodebuild_path" -version 2>/dev/null || true)"
if [[ "$xcode_version" != Xcode\ 27* ]]; then
    skip_or_fail "DEVELOPER_DIR does not select Xcode 27."
fi

tuist_binary="${TUIST_BINARY:-}"
if [[ -z "$tuist_binary" ]]; then
    tuist_binary="$(command -v tuist || true)"
fi
if [[ -z "$tuist_binary" || ! -x "$tuist_binary" ]]; then
    skip_or_fail "Tuist $expected_tuist_version is unavailable."
fi

tuist_version="$("$tuist_binary" version 2>/dev/null || true)"
if [[ "$tuist_version" != "$expected_tuist_version" ]]; then
    skip_or_fail "Expected Tuist $expected_tuist_version, found '$tuist_version'."
fi

export DEVELOPER_DIR="$developer_directory"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$fixture_directory/.tuist-state}"

print "==> Generating with Tuist $tuist_version and ${xcode_version%%$'\n'*}"
"$tuist_binary" generate --path "$fixture_directory" --no-open

"$script_directory/build-platform-matrix.sh"

print "==> Running focused deterministic macOS verification tests"
"$xcodebuild_path" \
    -project "$fixture_directory/EvaluationsLab.xcodeproj" \
    -scheme EvaluationsLabVerificationTests \
    -destination "platform=macOS" \
    -derivedDataPath "$fixture_directory/.derived-data/release-verification-tests" \
    CODE_SIGNING_ALLOWED=NO \
    test

full_result_bundle="$fixture_directory/.derived-data/full-tests.xcresult"
evaluation_export="$fixture_directory/.verification-export"
rm -rf "$full_result_bundle" "$evaluation_export"

print "==> Running the complete deterministic and opt-in-skipped test suite"
"$xcodebuild_path" \
    -project "$fixture_directory/EvaluationsLab.xcodeproj" \
    -scheme EvaluationsLabTests \
    -destination "platform=macOS" \
    -derivedDataPath "$fixture_directory/.derived-data/full-tests" \
    -resultBundlePath "$full_result_bundle" \
    CODE_SIGNING_ALLOWED=NO \
    test

print "==> Exporting Swift Testing evaluation attachments"
/usr/bin/xcrun xcresulttool export evaluations \
    --path "$full_result_bundle" \
    --output-path "$evaluation_export"

exported_result_count="$(
    find "$evaluation_export" -type f -name '*.xcevalresult' | wc -l | tr -d ' '
)"
if [[ "$exported_result_count" -lt 1 ]]; then
    print -u2 "ERROR: xcresulttool exported no .xcevalresult attachments."
    exit 1
fi
print "Exported $exported_result_count evaluation attachment(s)."

print "==> Building and running the deterministic CLI"
"$xcodebuild_path" \
    -project "$fixture_directory/EvaluationsLab.xcodeproj" \
    -scheme EvaluationsLabCLI \
    -destination "platform=macOS" \
    -derivedDataPath "$fixture_directory/.derived-data/release-verification-cli" \
    CODE_SIGNING_ALLOWED=NO \
    build

EVALUATIONS_LAB_OUTPUT_DIR="$fixture_directory/.verification-output" \
    "$fixture_directory/.derived-data/release-verification-cli/Build/Products/Debug/EvaluationsLabCLI"

print "EvaluationsLab verification succeeded."
