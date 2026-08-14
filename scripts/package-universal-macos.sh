#!/usr/bin/env bash
set -euo pipefail

input=${1:?input directory required}
output=${2:?output directory required}
arm_app=$(find "$input" -path '*aarch64*' -name 'DayPlan.app' -type d -print -quit)
intel_app=$(find "$input" -path '*x86_64*' -name 'DayPlan.app' -type d -print -quit)
test -n "$arm_app"
test -n "$intel_app"
mkdir -p "$output"
ditto "$arm_app" "$output/DayPlan.app"
lipo -create "$arm_app/Contents/MacOS/dayplan-desktop" "$intel_app/Contents/MacOS/dayplan-desktop" -output "$output/DayPlan.app/Contents/MacOS/dayplan-desktop"
codesign --force --deep --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$output/DayPlan.app"
codesign --verify --deep --strict --verbose=2 "$output/DayPlan.app"
