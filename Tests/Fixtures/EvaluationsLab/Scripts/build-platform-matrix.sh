#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
fixture_directory=${script_directory:h}
project_path="$fixture_directory/EvaluationsLab.xcodeproj"
build_root="${EVALUATIONS_LAB_BUILD_ROOT:-$fixture_directory/.derived-data/platform-matrix}"

if [[ ! -d "$project_path" ]]; then
    print -u2 "EvaluationsLab.xcodeproj is missing. Run 'tuist generate --no-open' first."
    exit 1
fi

function build_platform {
    local scheme=$1
    local destination=$2
    local derived_data_name=$3

    print "==> Building $scheme for $destination"
    xcodebuild \
        -project "$project_path" \
        -scheme "$scheme" \
        -destination "$destination" \
        -derivedDataPath "$build_root/$derived_data_name" \
        CODE_SIGNING_ALLOWED=NO \
        build
}

build_platform \
    EvaluationsLabPlatformMacOS \
    "generic/platform=macOS" \
    macos

build_platform \
    EvaluationsLabPlatformIOSSimulator \
    "generic/platform=iOS Simulator" \
    ios-simulator

build_platform \
    EvaluationsLabPlatformVisionOSSimulator \
    "generic/platform=visionOS Simulator" \
    visionos-simulator

build_platform \
    EvaluationsLabPlatformWatchOSSimulator \
    "generic/platform=watchOS Simulator" \
    watchos-simulator

print "Platform compile matrix succeeded."
