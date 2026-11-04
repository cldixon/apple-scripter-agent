#!/usr/bin/env bash
# Checks that a built AutomationAgent.app has the runner and its launch agent where
# SMAppService and launchd expect them. Usage: scripts/verify-bundle.sh path/to/AutomationAgent.app
set -euo pipefail

app="${1:?usage: $0 path/to/AutomationAgent.app}"
label="dev.cldixon.AutomationAgent.Runner"
runner="$app/Contents/Library/LoginItems/AutomationAgentRunner.app"
agent="$app/Contents/Library/LaunchAgents/$label.plist"

fail() { echo "error: $*" >&2; exit 1; }

[[ -d "$app" ]] || fail "no app at $app"
[[ -d "$runner" ]] || fail "runner not embedded at $runner"
[[ -f "$agent" ]] || fail "launch agent plist missing at $agent"

plutil -lint "$agent" >/dev/null || fail "launch agent plist is not valid"

program="$(plutil -extract BundleProgram raw "$agent")"
[[ -x "$app/$program" ]] || fail "BundleProgram $program is not an executable inside the app"

[[ "$(plutil -extract Label raw "$agent")" == "$label" ]] || fail "launch agent Label is not $label"
plutil -p "$agent" | grep -q "\"$label.xpc\"" \
  || fail "MachServices does not list $label.xpc"

[[ "$(plutil -extract LSUIElement raw "$runner/Contents/Info.plist")" == "true" ]] \
  || fail "runner is not an LSUIElement (background) app"
[[ "$(plutil -extract CFBundleIdentifier raw "$runner/Contents/Info.plist")" == "$label" ]] \
  || fail "runner bundle identifier is not $label"

echo "Bundle layout OK: $app"
