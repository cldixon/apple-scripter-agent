#!/usr/bin/env bash
# Fails with the fix when xcode-select points at the Command Line Tools instead of Xcode:
# xcodebuild only ships with the full Xcode app.
set -euo pipefail

developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" != *.app/Contents/Developer ]]; then
  echo "error: xcodebuild needs the full Xcode app, but xcode-select points at '${developer_dir:-nothing}'." >&2
  echo "Fix:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  echo "  sudo xcodebuild -license accept" >&2
  echo "  xcodebuild -runFirstLaunch" >&2
  exit 1
fi
