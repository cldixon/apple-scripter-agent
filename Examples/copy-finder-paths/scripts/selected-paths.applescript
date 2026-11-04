-- scripts/selected-paths.applescript
tell application "Finder"
  set out to {}
  repeat with f in (get selection)
    set end of out to POSIX path of (f as alias)
  end repeat
end tell
set AppleScript's text item delimiters to linefeed
return out as text
