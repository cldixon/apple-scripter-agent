#!/usr/bin/env bash
# Builds a distributable AutomationAgent DMG: archive (Release, Developer ID), check the
# bundle and its signatures, make a DMG, notarize it, staple it. See docs/RELEASING.md.
#
# Usage: scripts/release.sh [--skip-notarize | --unsigned] [--version X.Y.Z] [--build-number N]
#
#   --skip-notarize   Signed build and DMG, without notarizing (local testing).
#   --unsigned        No signing at all (CODE_SIGNING_ALLOWED=NO): what CI publishes when
#                     the signing secrets are missing. Gatekeeper will block it.
#   --version         MARKETING_VERSION (default: the one in Config/Base.xcconfig).
#   --build-number    CURRENT_PROJECT_VERSION (default: the one in Config/Base.xcconfig).
#
# Environment:
#   DEVELOPMENT_TEAM or APPLE_TEAM_ID   Team id (default: Config/Local.xcconfig).
#   Notarization, one of:
#     NOTARY_KEYCHAIN_PROFILE           A profile saved with `xcrun notarytool store-credentials`.
#     NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH
#                                       An App Store Connect API key (.p8 file).
#   RELEASE_DIR                         Output folder (default: build/release).
set -euo pipefail

cd "$(dirname "$0")/.."

project="AutomationAgent.xcodeproj"
scheme="AutomationAgent"
app_name="AutomationAgent"
volume_name="Automation Agent"
release_dir="${RELEASE_DIR:-build/release}"

mode="notarize"
version=""
build_number=""

fail() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) mode="signed" ;;
    --unsigned) mode="unsigned" ;;
    --version) version="${2:?--version needs a value}"; shift ;;
    --build-number) build_number="${2:?--build-number needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option '$1' (see --help)" ;;
  esac
  shift
done

# Reads a setting's value from an xcconfig file, or prints nothing.
xcconfig_value() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^[:space:]/]*).*$/\1/p" "$file" | tail -n 1
}

version="${version:-$(xcconfig_value MARKETING_VERSION Config/Base.xcconfig)}"
build_number="${build_number:-$(xcconfig_value CURRENT_PROJECT_VERSION Config/Base.xcconfig)}"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
  || fail "version '$version' is not of the form X.Y.Z (pass --version 1.2.3, without a leading v)"
[[ "$build_number" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "build number '$build_number' is not numeric"

team="${DEVELOPMENT_TEAM:-${APPLE_TEAM_ID:-$(xcconfig_value DEVELOPMENT_TEAM Config/Local.xcconfig)}}"

# --- Preflight: fail before the slow build if anything is missing ----------------------

scripts/check-xcode.sh
command -v xcodegen >/dev/null || fail "xcodegen is not installed (brew install xcodegen)"

notary_args=()
signing_identity=""
if [[ "$mode" != "unsigned" ]]; then
  [[ -n "$team" ]] || fail "no team id. Set DEVELOPMENT_TEAM (or APPLE_TEAM_ID), or set it in Config/Local.xcconfig."
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail "team id '$team' does not look like a 10-character Apple team id"

  # The SHA-1 of the Developer ID Application identity for this team, used to sign the DMG
  # (and proof that xcodebuild will find one for the app).
  signing_identity="$(security find-identity -v -p codesigning \
    | grep "\"Developer ID Application: .*($team)\"" | head -n 1 | awk '{print $2}' || true)"
  [[ -n "$signing_identity" ]] || fail "no valid 'Developer ID Application' certificate for team $team in your keychains.
Create one at https://developer.apple.com/account/resources/certificates (needs the Account Holder role),
or import the .p12. 'security find-identity -v -p codesigning' lists what you have."
fi

if [[ "$mode" == "notarize" ]]; then
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  elif [[ -n "${NOTARY_KEY_ID:-}" || -n "${NOTARY_ISSUER_ID:-}" || -n "${NOTARY_KEY_PATH:-}" ]]; then
    missing=()
    [[ -n "${NOTARY_KEY_ID:-}" ]] || missing+=(NOTARY_KEY_ID)
    [[ -n "${NOTARY_ISSUER_ID:-}" ]] || missing+=(NOTARY_ISSUER_ID)
    [[ -n "${NOTARY_KEY_PATH:-}" ]] || missing+=(NOTARY_KEY_PATH)
    [[ ${#missing[@]} -eq 0 ]] || fail "incomplete App Store Connect API key: ${missing[*]} not set."
    [[ -f "$NOTARY_KEY_PATH" ]] || fail "NOTARY_KEY_PATH '$NOTARY_KEY_PATH' is not a file (the AuthKey_XXXX.p8 download)"
    notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  else
    fail "no notarization credentials. Set NOTARY_KEYCHAIN_PROFILE, or NOTARY_KEY_ID + NOTARY_ISSUER_ID +
NOTARY_KEY_PATH (App Store Connect API key). Use --skip-notarize for a local signed build."
  fi
fi

# --- Build -----------------------------------------------------------------------------

step "Generating the Xcode project"
xcodegen generate

work="$release_dir/work"
archive="$work/$app_name.xcarchive"
app="$work/$app_name.app"
dmg="$release_dir/$app_name-$version.dmg"
if [[ "$mode" == "unsigned" ]]; then
  dmg="$release_dir/$app_name-$version-unsigned.dmg"
fi

rm -rf "$work" "$dmg"
mkdir -p "$work"

build_settings=(MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number")
if [[ "$mode" == "unsigned" ]]; then
  build_settings+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
else
  build_settings+=(DEVELOPMENT_TEAM="$team")
fi

step "Archiving $app_name $version ($build_number), $mode"
xcodebuild archive \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -derivedDataPath "$work/DerivedData" \
  "${build_settings[@]}"

# The archive already holds the app signed with Developer ID (Release.xcconfig), so copy
# it out with ditto, which keeps signatures, extended attributes and symlinks intact.
archived_app="$archive/Products/Applications/$app_name.app"
[[ -d "$archived_app" ]] || fail "the archive has no $archived_app (is SKIP_INSTALL set on the app target?)"
ditto "$archived_app" "$app"

step "Checking the bundle layout"
scripts/verify-bundle.sh "$app"

runner="$app/Contents/Library/LoginItems/AutomationAgentRunner.app"

# Prints a field (TeamIdentifier, Timestamp, ...) from `codesign -dvv`.
signature_field() {
  codesign -dvv "$1" 2>&1 | sed -n -E "s/^$2=(.*)$/\1/p" | head -n 1
}

if [[ "$mode" != "unsigned" ]]; then
  step "Checking signatures"
  codesign --verify --deep --strict --verbose=2 "$app"
  for bundle in "$runner" "$app"; do
    name="$(basename "$bundle")"
    details="$(codesign -dvv "$bundle" 2>&1)"
    grep -q '^Authority=Developer ID Application:' <<<"$details" \
      || fail "$name is not signed with a Developer ID Application certificate"
    grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' <<<"$details" \
      || fail "$name does not have the hardened runtime enabled"
    [[ -n "$(signature_field "$bundle" Timestamp)" ]] \
      || fail "$name has no secure timestamp (OTHER_CODE_SIGN_FLAGS = --timestamp)"
    if codesign -d --entitlements - --xml "$bundle" 2>/dev/null | grep -q 'get-task-allow'; then
      fail "$name has the get-task-allow entitlement; notarization will reject it"
    fi
  done
  # The runner only accepts XPC clients signed by its own team (docs/ARCHITECTURE.md).
  app_team="$(signature_field "$app" TeamIdentifier)"
  runner_team="$(signature_field "$runner" TeamIdentifier)"
  [[ "$app_team" == "$team" && "$runner_team" == "$team" ]] \
    || fail "team ids differ: app '$app_team', runner '$runner_team', expected '$team'"
  echo "Signatures OK: Developer ID, hardened runtime, timestamped, team $team"
fi

# --- DMG -------------------------------------------------------------------------------

step "Creating $dmg"
staging="$work/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/$app_name.app"
ln -s /Applications "$staging/Applications"

# hdiutil sometimes fails with "Resource busy" on CI machines; retry a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "$volume_name" -srcfolder "$staging" -ov -format UDZO "$dmg"; then
    break
  fi
  [[ $attempt -lt 5 ]] || fail "hdiutil could not create the DMG"
  echo "hdiutil failed (attempt $attempt), retrying..." >&2
  sleep $((attempt * 5))
done

if [[ "$mode" != "unsigned" ]]; then
  codesign --sign "$signing_identity" --timestamp "$dmg"
  codesign --verify --strict --verbose=2 "$dmg"
fi

# --- Notarize --------------------------------------------------------------------------

if [[ "$mode" == "notarize" ]]; then
  step "Notarizing (this usually takes a few minutes)"
  result="$work/notarytool.json"
  if ! xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --output-format json >"$result"; then
    cat "$result" >&2 || true
    fail "notarytool submit failed"
  fi
  status="$(plutil -extract status raw "$result" 2>/dev/null || true)"
  submission="$(plutil -extract id raw "$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    echo "Notarization status: ${status:-unknown} (submission ${submission:-unknown}). Apple's log:" >&2
    if [[ -n "$submission" ]]; then
      xcrun notarytool log "$submission" "${notary_args[@]}" >&2 || true
    fi
    fail "notarization was not accepted"
  fi
  echo "Notarization accepted (submission $submission)"

  step "Stapling"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"

  step "Gatekeeper assessment"
  spctl -a -vv -t open --context context:primary-signature "$dmg"
  # Gatekeeper's check of the app inside, as a user will see it after copying it out.
  mount_point="$(mktemp -d)"
  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null
  spctl_status=0
  spctl -a -vv -t execute "$mount_point/$app_name.app" || spctl_status=$?
  hdiutil detach "$mount_point" -quiet || true
  [[ $spctl_status -eq 0 ]] || fail "Gatekeeper rejects the notarized app"
elif [[ "$mode" == "signed" ]]; then
  echo
  echo "Skipped notarization: Gatekeeper will report this build as 'Unnotarized Developer ID'"
  echo "on other Macs. spctl's view of it:"
  spctl -a -vv -t execute "$app" || true
fi

rm -rf "$staging"

echo
case "$mode" in
  notarize) echo "Release ready (signed, notarized, stapled):" ;;
  signed) echo "Signed DMG ready (NOT notarized):" ;;
  unsigned) echo "UNSIGNED DMG ready (Gatekeeper will block it; for testing only):" ;;
esac
if [[ "$dmg" == /* ]]; then echo "$dmg"; else echo "$PWD/$dmg"; fi
