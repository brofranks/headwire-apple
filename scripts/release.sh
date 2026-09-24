#!/bin/bash
# Build the same notarized ZIP locally and in GitHub Actions.
set -euo pipefail
cd "$(dirname "$0")/.."
die() {
	echo "release.sh: $1" >&2
	exit 1
}
dir=${1:?usage: release.sh SIGNING_DIR vX.Y.Z}
tag=${2:?usage: release.sh SIGNING_DIR vX.Y.Z}
version=${tag#v}
if [[ $(sed -n 's/^MARKETING_VERSION *= *//p' Config/Common.xcconfig) != "$version" ]]; then
	echo 'release tag must match MARKETING_VERSION in Config/Common.xcconfig' >&2
	exit 2
fi
# A distributable system extension must be notarized, never silently unsigned.
test -s "$dir/notary.json" || die "no notary.json in $dir, the build would not be notarized"
engine=$(cd "${HEADWIRE:-../headwire}" && pwd)
ref=$(cat Config/Headwire.ref)
test "$(git -C "$engine" rev-parse HEAD)" = "$ref" ||
	die "engine checkout is not at the pinned commit $ref"
# The recorded commits describe the build only if both trees are clean.
test -z "$(git -C "$engine" status --porcelain)" || die 'engine tree has uncommitted changes'
test -z "$(git status --porcelain)" || die 'app tree has uncommitted changes'
# The bridge links the tag into the command line's `version`, and the bundle
# reports it as CFBundleVersion.
export VERSION="$tag" BUILD_NUMBER="$version"
mkdir -p build
./sign.sh macos "$dir" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO
app=build/Export/Headwire.app
test "$("$app/Contents/MacOS/Headwire" version)" = "headwire $tag" ||
	die "the built app does not report version headwire $tag"
# ONLY_ACTIVE_ARCH=NO above adds the slice this host does not build for.
lipo -archs "$app/Contents/MacOS/Headwire" | grep -q x86_64 ||
	die 'the built binary has no x86_64 slice'
# Only assemble release assets after every signature and notarization check
# passes.
mkdir -p build/releases
out="build/releases/$tag"
mkdir "$out"
cp build/Export/Headwire.zip "$out/Headwire_${tag}_macos_universal.zip"
cp build/build-info.txt "$out/"
(cd "$out" && shasum -a 256 ./*.zip build-info.txt > SHA256SUMS)
echo "Release assets: $out"
