#!/bin/sh

set -eu

quagmire_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
quagmire_package_dir=$(dirname -- "$quagmire_script_dir")
quagmire_derived_root=${QUAGMIRE_DERIVED_DATA_ROOT:-${TMPDIR:-/tmp}/quagmire-verify}
# Builds are incremental, reusing the last run's products, unless
# QUAGMIRE_VERIFY_CLEAN=1 asks for clean ones.
quagmire_build_action=build
if [ "${QUAGMIRE_VERIFY_CLEAN:-}" = "1" ]; then
    quagmire_build_action="clean build"
fi

echo "Running Quagmire package tests"
if [ "${QUAGMIRE_VERIFY_CLEAN:-}" = "1" ]; then
    swift package --package-path "$quagmire_package_dir" clean
fi
swift test --package-path "$quagmire_package_dir"

echo "Building Quagmire for macOS"
(
    cd "$quagmire_package_dir"
    xcodebuild \
        -scheme Quagmire \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$quagmire_derived_root/macos" \
        CODE_SIGNING_ALLOWED=NO \
        $quagmire_build_action
)

echo "Building QuagmireExtras for macOS"
(
    cd "$quagmire_package_dir"
    xcodebuild \
        -scheme QuagmireExtras \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$quagmire_derived_root/extras-macos" \
        CODE_SIGNING_ALLOWED=NO \
        $quagmire_build_action
)

echo "Building Quagmire for iOS Simulator"
(
    cd "$quagmire_package_dir"
    xcodebuild \
        -scheme Quagmire \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$quagmire_derived_root/ios-simulator" \
        CODE_SIGNING_ALLOWED=NO \
        $quagmire_build_action
)

echo "Building QuagmireExtras for iOS Simulator"
(
    cd "$quagmire_package_dir"
    xcodebuild \
        -scheme QuagmireExtras \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$quagmire_derived_root/extras-ios-simulator" \
        CODE_SIGNING_ALLOWED=NO \
        $quagmire_build_action
)
