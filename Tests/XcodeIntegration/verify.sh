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

# Fails when the test bundle defines SwiftyNetwork symbols, which means it embeds a second copy of
# the core instead of loading the one the app's frameworks share.
symbols="$(nm -gU "$bundle" | grep '\$s13SwiftyNetwork' | swift demangle || true)"
if [ -n "$symbols" ]; then
    echo "Unexpected SwiftyNetwork definitions in $bundle:" >&2
    echo "$symbols" >&2
    exit 1
fi
