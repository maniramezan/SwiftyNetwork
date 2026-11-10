#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <iOS simulator UDID>" >&2
    exit 2
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
derived="$root/.build/xcode-identity"
products="$derived/Build/Products/Debug-iphonesimulator"
bundle="$products/IntegrationHost.app/PlugIns/NetworkIdentityTests.xctest/NetworkIdentityTests"

xcodebuild test \
    -project "$root/Tests/XcodeIntegration/NetworkIdentity.xcodeproj" \
    -scheme NetworkIdentity \
    -destination "platform=iOS Simulator,id=$1" \
    -derivedDataPath "$derived" \
    -parallel-testing-enabled NO

check_symbols() {
    local binary="$1"
    local symbols
    symbols="$(nm -gU "$binary")"
    symbols="$(printf '%s\n' "$symbols" | grep '\$s13SwiftyNetwork' || true)"
    if [ -n "$symbols" ]; then
        echo "Unexpected SwiftyNetwork definitions in $binary:" >&2
        echo "$symbols" >&2
        exit 1
    fi
}

check_symbols "$bundle"
testing_framework="$products/PackageFrameworks/SwiftyNetworkTesting.framework/SwiftyNetworkTesting"
if [ -f "$testing_framework" ]; then
    symbols="$(nm -gU "$testing_framework")"
    symbols="$(printf '%s\n' "$symbols" | grep '\$s13SwiftyNetwork' | swift demangle \
        | grep -v '(extension in SwiftyNetworkTesting):' || true)"
    if [ -n "$symbols" ]; then
        echo "Unexpected SwiftyNetwork definitions in $testing_framework:" >&2
        echo "$symbols" >&2
        exit 1
    fi
fi
