#!/bin/bash
# Builds a signed Headwire from files alone, with no Xcode account sign-in:
# a notarized macOS app, or a development-signed iOS .ipa for the devices its
# profiles name. SIGNING_DIR holds:
#
#   signing.pem | signing.p12 + signing.p12.password
#                         The signing certificate and key: Developer ID
#                         Application for macos, Apple Development for ios.
#   notary.json           {"key":"path/to/AuthKey_XXXX.p8","key-id":"...",
#                         "issuer":"..."}, an App Store Connect API key with
#                         the Developer role. macos only. Omit it to skip
#                         notarization, which leaves a build that loads only
#                         with SIP off.
#   app.provisionprofile, extension.provisionprofile   (macos)
#   app.mobileprovision, extension.mobileprovision     (ios)
#                         Regenerate and replace them after changing any
#                         Network Extension, System Extension, or App Group
#                         capability, or signing fails with the entitlement
#                         simply missing. Both iOS App IDs need Network
#                         Extensions and the App Group group.BUNDLE_ID_PREFIX,
#                         which is also the keychain access group they share.
#
# Usage: ./sign.sh macos|ios SIGNING_DIR [xcodebuild args...]
set -euo pipefail
cd "$(dirname "$0")"
usage='usage: sign.sh macos|ios SIGNING_DIR'
platform=${1:?$usage}
dir=$(cd "${2:?$usage}" && pwd)
shift 2

prefix=$(sed -n 's/^BUNDLE_ID_PREFIX *= *//p' Config/Common.xcconfig)
team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Developer.xcconfig)
[ -n "$team" ] || {
	echo "set DEVELOPMENT_TEAM in Config/Developer.xcconfig" >&2
	exit 1
}

# A keychain of its own, unlocked for this build only: the login keychain
# would prompt, and codesign over ssh has no one to prompt.
signing_work=$(mktemp -d)
keychain=$signing_work/headwire-signing.keychain-db
password=$(uuidgen)
security create-keychain -p "$password" "$keychain"
# Xcode finds profiles only by UUID in this directory, and a profile left
# there outlives the build, so the UUIDs staged there are removed again.
profiles=~/Library/MobileDevice/Provisioning\ Profiles
staged=
cleanup() {
	security delete-keychain "$keychain"
	rm -rf "$signing_work"
	for uuid in $staged; do
		rm -f "$profiles/$uuid.mobileprovision"
	done
}
trap cleanup EXIT
security set-keychain-settings "$keychain"
security unlock-keychain -p "$password" "$keychain"
p12=$dir/signing.p12
p12password=$(cat "$dir/signing.p12.password" 2> /dev/null || true)
if [ -f "$dir/signing.pem" ]; then
	# security import reads no PEM identity, so repack. The password is
	# argv-visible either way, but a fresh one at least never outlives the
	# build.
	p12=$signing_work/headwire-signing.p12
	p12password=$(uuidgen)
	openssl pkcs12 -export -legacy -in "$dir/signing.pem" -out "$p12" -passout "pass:$p12password" 2> /dev/null ||
		openssl pkcs12 -export -in "$dir/signing.pem" -out "$p12" -passout "pass:$p12password"
fi
security import "$p12" -k "$keychain" -P "$p12password" -T /usr/bin/codesign -T /usr/bin/security
# Lets codesign use the key without the interactive "allow access" dialog.
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" > /dev/null
# shellcheck disable=SC2046 # one argument per existing keychain
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d ' "')
security find-identity -v -p codesigning "$keychain"

mkdir -p "$profiles"
# Stages one profile and sets profile_name. It records the UUID in $staged, so
# it must not run in a command substitution, whose subshell would drop that.
stage() { # profile-file
	local plist uuid
	plist=$(security cms -D -i "$1")
	uuid=$(plutil -extract UUID raw -o - - <<< "$plist")
	cp "$1" "$profiles/$uuid.mobileprovision"
	staged="$staged $uuid"
	profile_name=$(plutil -extract Name raw -o - - <<< "$plist")
}

export_archive() { # archive method outdir. Uses $team, $app_profile, $ext_profile
	rm -rf "$3"
	mkdir -p "$3"
	cat > "$3.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>$2</string>
	<key>teamID</key><string>$team</string>
	<key>signingStyle</key><string>manual</string>
	<key>destination</key><string>export</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$prefix</key><string>$app_profile</string>
		<key>$prefix.extension</key><string>$ext_profile</string>
	</dict>
</dict>
</plist>
PLIST
	xcodebuild -exportArchive -archivePath "$1" -exportOptionsPlist "$3.plist" -exportPath "$3"
}

require_entitlements() { # "want..." bundle...
	# A profile lacking a capability still signs. The entitlement is simply
	# dropped, and the extension then fails to load with no useful error.
	local wants=$1 bundle entitlements want
	shift
	for bundle; do
		entitlements=$(codesign -d --entitlements - --xml "$bundle" | plutil -convert xml1 -o - -)
		for want in $wants; do
			grep -q "$want" <<< "$entitlements" || {
				echo "$bundle: no $want entitlement. Regenerate its profile" >&2
				exit 1
			}
		done
	done
}

require_notices() { # archive resource
	local text
	text=$(unzip -p "$1" "$2")
	for s in tailscale.com/LICENSE headwire-apple/LICENSE go/LICENSE; do
		grep -qF "Sources: $s" <<< "$text" || {
			echo "$1: $2 lacks $s" >&2
			exit 1
		}
	done
}

case $platform in
macos)
	suffix=provisionprofile identity="Developer ID Application"
	archive=build/Headwire.xcarchive method=developer-id out=build/Export
	set -- NE_PROVIDER_ENTITLEMENT=packet-tunnel-provider-systemextension "$@"
	;;
ios)
	suffix=mobileprovision identity="Apple Development"
	archive=build/HeadwireiOS.xcarchive method=debugging out=build/Export-iOS
	export SCHEME=HeadwireiOS
	;;
*)
	echo "$usage" >&2
	exit 2
	;;
esac

stage "$dir/app.$suffix"
app_profile=$profile_name
stage "$dir/extension.$suffix"
ext_profile=$profile_name
echo "profiles: $app_profile, $ext_profile"

CONFIGURATION=Release ./build.sh archive -archivePath "$archive" \
	CODE_SIGN_STYLE=Manual \
	CODE_SIGN_IDENTITY="$identity" \
	OTHER_CODE_SIGN_FLAGS="--keychain $keychain" \
	PROFILE_APP="$app_profile" PROFILE_EXTENSION="$ext_profile" \
	"$@"

export_archive "$archive" "$method" "$out"

if [ "$platform" = ios ]; then
	unzip -q "$out/Headwire.ipa" -d "$signing_work/ipa"
	app=$signing_work/ipa/Payload/Headwire.app
	require_entitlements "packet-tunnel-provider group.$prefix" "$app" "$app/PlugIns/HeadwireTunneliOS.appex"
	require_notices "$out/Headwire.ipa" Payload/Headwire.app/ThirdPartyLicenses.txt
	echo "built $out/Headwire.ipa. Install with: xcrun devicectl device install app --device DEVICE $out/Headwire.ipa"
	exit 0
fi

app=$out/Headwire.app
if [ -f "$dir/notary.json" ]; then
	# The extension is nested inside the app, so one submission covers both.
	ditto -c -k --keepParent "$app" "$out/Headwire.zip"
	xcrun notarytool submit "$out/Headwire.zip" --wait \
		--key "$(plutil -extract key raw -o - "$dir/notary.json")" \
		--key-id "$(plutil -extract key-id raw -o - "$dir/notary.json")" \
		--issuer "$(plutil -extract issuer raw -o - "$dir/notary.json")"
	xcrun stapler staple "$app"
	# The zip above was the submission, made before the ticket existed.
	# Replace it with the stapled app, so a copy of it launches offline.
	rm -f "$out/Headwire.zip"
	ditto -c -k --keepParent "$app" "$out/Headwire.zip"
fi

sysext=$app/Contents/Library/SystemExtensions/$prefix.extension.systemextension
codesign --verify --deep --strict --verbose=2 "$app"
require_entitlements "packet-tunnel-provider-systemextension group.$prefix" "$app" "$sysext"
require_entitlements com.apple.developer.system-extension.install "$app"
# Gatekeeper accepts only a notarized, stapled build, so an un-notarized one
# here is expected to be rejected and loads only with SIP off.
if [ -f "$dir/notary.json" ]; then
	xcrun stapler validate "$app"
	spctl --assess --type execute --verbose "$app"
fi
require_notices "$out/Headwire.zip" Headwire.app/Contents/Resources/ThirdPartyLicenses.txt
echo "built $app"
