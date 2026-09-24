#!/bin/bash
# Builds the Go bridge from the sibling headwire checkout, then the app.
# Extra arguments go to xcodebuild, e.g.:
#   ./build.sh test CODE_SIGNING_ALLOWED=NO       compile and unit-test, unsigned
#   ./build.sh build -allowProvisioningUpdates    development-signed (needs Config/Developer.xcconfig)
set -euo pipefail
cd "$(dirname "$0")"
# A development build is named by its UTC time, as the version the command
# line reports and as CFBundleVersion, which must change for a system
# extension update to replace the installed one. A release names both after
# its tag.
stamp=$(date -u +%Y%m%d%H%M%S)
number=${BUILD_NUMBER:-${stamp:0:8}.${stamp:8}}
VERSION=${VERSION:-dev-$stamp} "${HEADWIRE:-../headwire}/bridge/apple/build.sh" build
# Include the Apple source license in both platform documents before signing.
for platform in darwin ios; do
	printf '\nSources: headwire-apple/LICENSE\n\n' >> "build/$platform/ThirdPartyLicenses.txt"
	cat LICENSE >> "build/$platform/ThirdPartyLicenses.txt"
done
# The suite is queues, continuations and deadlines, so it runs under the
# thread sanitizer. The Go archive it links is uninstrumented but not driven
# concurrently by these tests.
[ "${1:-build}" != test ] || set -- "$@" -enableThreadSanitizer YES
# SCHEME=HeadwireiOS builds the iOS app, which has no tests of its own.
scheme=${SCHEME:-Headwire}
[ "$scheme" = Headwire ] || set -- -destination generic/platform=iOS "${@:-build}"
xcodebuild -project Headwire.xcodeproj -scheme "$scheme" -configuration "${CONFIGURATION:-Debug}" \
	-derivedDataPath build/DerivedData CURRENT_PROJECT_VERSION="$number" "${@:-build}"

# What a validation result was obtained on. Both trees are inputs, so both
# revisions are recorded, and a dirty tree says the revision is not the whole
# answer.
describe() { # tree
	git -C "$1" rev-parse HEAD 2> /dev/null || echo unknown
	[ -z "$(git -C "$1" status --porcelain 2> /dev/null)" ] || echo "  (uncommitted changes)"
}
{
	date -u +'built: %Y-%m-%dT%H:%M:%SZ'
	echo "xcode: $(xcodebuild -version | tr '\n' ' ')"
	echo "sdk: $(xcrun --show-sdk-version) / ios $(xcrun --sdk iphoneos --show-sdk-version)"
	echo "go: $(go version)"
	echo "build: $number"
	echo "scheme: $scheme ${CONFIGURATION:-Debug}"
	echo "headwire-apple: $(describe .)"
	echo "headwire: $(describe "${HEADWIRE:-../headwire}")"
	echo "bridge ref: $(cat Config/Headwire.ref)"
} > build/build-info.txt
