#!/usr/bin/env bash
# Native development checks, shared by local runs and the unsigned CI job.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
GOBIN="$work" go install mvdan.cc/sh/v3/cmd/shfmt@v3.14.1
GOBIN="$work" go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install -q shellcheck-py==0.11.0.1
# actionlint finds shellcheck here for workflow run blocks.
PATH="$work/venv/bin:$PATH"

"$work/shfmt" -d ./*.sh scripts
"$work/shfmt" -f ./*.sh scripts | xargs shellcheck
"$work/actionlint" .github/workflows/*.yml
plutil -lint Config/*.plist Config/*.entitlements
xcrun swift-format lint --strict -r App CLI Controller Extension Provider Shared iOS Tests
./build.sh test CODE_SIGNING_ALLOWED=NO

# Installing a network system extension fails unless the extension bundle
# carries this key.
plutil -extract NSSystemExtensionUsageDescription raw \
	build/DerivedData/Build/Products/Debug/Headwire.app/Contents/Library/SystemExtensions/*.systemextension/Contents/Info.plist \
	> /dev/null

# The one check that covers main.swift's dispatch, the linked Go bridge and
# CLI.swift's C callback, which no unit test reaches. Every command here works
# without a connected profile, a system extension or root. Exit status is as
# the shared CLI defines it: 0 success, 1 execution failure, 2 usage or
# configuration error.
headwire=build/DerivedData/Build/Products/Debug/Headwire.app/Contents/MacOS/Headwire
expect() { # status pattern command...
	local want=$1 pattern=$2 got=0 output
	shift 2
	output=$("$headwire" "$@" 2>&1) || got=$?
	if [ "$got" != "$want" ] || ! grep -q "$pattern" <<< "$output"; then
		echo "headwire $*: exit $got, want $want matching '$pattern':" >&2
		printf '%s\n' "$output" >&2
		exit 1
	fi
}

expect 0 '^headwire ' version
# The transport callback's error path: no profile is connected here.
expect 1 'no profile is connected' show
# Profile names never reach the root provider unchecked.
expect 1 'invalid profile name' up ../escape
expect 2 'unknown command' nonsense
echo "cli-smoke: ok"
