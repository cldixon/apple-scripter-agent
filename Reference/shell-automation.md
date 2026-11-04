# Shell automation on macOS

Notes for `shell` steps and for the macOS command-line tools that control system settings.
Man pages for these tools are in the library too (sources `man: pmset`, `man: defaults`, ...).

## How shell steps run here

A `shell` step runs its script with `/bin/zsh` as a child of the runner.

- Input: `$AUTOMATION_INPUT` holds the JSON object of every named output so far, and each
  value is also in `$AUTOMATION_VAR_<name>` (for a step output named `clip`:
  `$AUTOMATION_VAR_clip`). Prefer the per-name variables; they need no JSON parsing.
- Output: everything printed to stdout, with one trailing newline removed. Print only the
  result; send diagnostics to stderr (`print -u2 "..."` or `>&2`).
- Exit status: non-zero fails the step; stderr becomes the error message.
- Environment: the runner is started by launchd, so `PATH` is minimal
  (`/usr/bin:/bin:/usr/sbin:/sbin`). Homebrew tools (`/opt/homebrew/bin`) are not on it:
  use absolute paths, and only rely on tools that ship with macOS.
- No terminal: commands that prompt (sudo, interactive ssh, `read`) hang until the step
  times out. `sudo` is never available.
- Working directory: the automation's folder, so `scripts/helper.sh` paths resolve.
- Start scripts with `set -euo pipefail` to stop on the first error.

```zsh
#!/bin/zsh
set -euo pipefail
text=${AUTOMATION_VAR_clip:-}
count=$(print -r -- "$text" | wc -w | tr -d " ")
print -r -- "$count words"
```

## Reading the JSON input in shell

```zsh
# macOS 15 and later ship /usr/bin/jq
name=$(print -r -- "$AUTOMATION_INPUT" | /usr/bin/jq -r '.name // empty')

# plutil reads JSON too (works on every supported macOS); raw prints a string value
name=$(print -r -- "$AUTOMATION_INPUT" | /usr/bin/plutil -extract name raw -o - -)

# Or let JavaScript parse it
name=$(/usr/bin/osascript -l JavaScript -e 'function run(a){return JSON.parse(a[0]).name || ""}' "$AUTOMATION_INPUT")
```

`plutil -extract` fails (exit 1) when the key is missing; add `|| true` if that is fine.
`/usr/bin/python3` is a stub that offers to install the command line tools: do not use it.

## zsh essentials

```zsh
name="My File.txt"
print -r -- "$name"            # print raw, no escape processing (safer than echo)
files=( ~/Desktop/*.pdf(N) )   # glob into an array; (N) = empty when nothing matches
print -r -- ${#files}          # array length
for f in $files; do print -r -- "${f:t}"; done   # :t = basename, :h = dirname, :r = no extension, :e = extension
upper=${name:u}; lower=${name:l}
if [[ -f $f && $f == *.pdf ]]; then ...; fi
count=$(( count + 1 ))
lines=("${(@f)$(pbpaste)}")    # split command output into lines
joined=${(j:, :)lines}         # join an array with ", "
```

- zsh does not split unquoted variables on spaces (unlike bash), but quote anyway.
- Arrays are 1-based in zsh.
- `${var:-default}` for unset values; with `set -u`, reading an unset variable is an error.
- Heredocs: `cat <<'EOF'` (quoted) keeps `$` literal.

## osascript from the shell

```zsh
osascript -e 'tell application "Finder" to get name of every disk'
osascript -e 'display notification "Done" with title "Backup"'
osascript -l JavaScript -e 'Application("Music").currentTrack.name()'

# Pass arguments safely instead of splicing them into the source:
osascript - "$title" "$body" <<'EOF'
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
EOF
```

- Each `-e` adds a line of source. `osascript script.applescript arg1 arg2` passes args to
  `on run argv`.
- Apple Events sent this way are attributed to the runner (the responsible process), and
  need `automation:<bundle id>` permissions declared, just like `applescript` steps.
- Prefer an `applescript` or `jxa` step over osascript inside shell: it is compiled at
  install time and its target apps are checked.

## defaults: preferences

```zsh
defaults read com.apple.dock autohide
defaults write com.apple.dock autohide -bool true && killall Dock
defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults read -g AppleInterfaceStyle            # "Dark" or an error when Light
defaults delete com.apple.dock autohide-delay
defaults -currentHost read com.apple.screensaver
defaults read-type com.apple.dock tilesize
defaults domains | tr ',' '\n'
```

- Types: `-string`, `-int`, `-float`, `-bool`, `-date`, `-array`, `-array-add`, `-dict`,
  `-dict-add`.
- Apps read preferences at launch: restart the app (`killall Dock`, `killall Finder`,
  `killall SystemUIServer`) for changes to show.
- Sandboxed apps keep preferences in their container; `defaults read <bundle id>` still
  works through cfprefsd. Never edit the plist files directly while the app runs.
- Writing another app's defaults is a destructive change: mark the manifest `destructive`.

## Power: pmset and caffeinate

```zsh
pmset -g                  # current settings
pmset -g batt             # battery percentage and charging state
pmset -g assertions       # what prevents sleep
pmset -g sched            # scheduled power events
pmset sleepnow            # sleep now (no root needed)
pmset displaysleepnow     # turn the display off
caffeinate -d -t 3600 &   # keep the display awake for an hour
caffeinate -i -w $pid     # keep the Mac awake while a process runs
```

Changing settings (`pmset -a displaysleep 10`, `pmset schedule ...`) needs root, which
automations do not have. Parse battery level with
`pmset -g batt | grep -Eo '[0-9]+%' | head -1`.

## Network: networksetup and scutil

```zsh
networksetup -listallhardwareports           # Hardware Port / Device (e.g. Wi-Fi / en0)
networksetup -listallnetworkservices
networksetup -getinfo "Wi-Fi"                # IP, router
networksetup -getairportpower en0            # Wi-Fi On/Off
networksetup -setairportpower en0 off        # turn Wi-Fi off (no admin needed on most Macs)
networksetup -getdnsservers "Wi-Fi"
networksetup -setdnsservers "Wi-Fi" 1.1.1.1  # needs admin rights
networksetup -switchtolocation "Office"      # network location
scutil --get ComputerName
scutil --get LocalHostName
scutil --dns | head -20
scutil --nwi                                 # primary interface and reachability
scutil --proxy
ipconfig getifaddr en0                       # IPv4 address of en0
```

- The Wi-Fi device is not always `en0`; read it from `-listallhardwareports`.
- Recent macOS hides the Wi-Fi network name (SSID) from processes without Location
  Services permission; `networksetup -getairportnetwork` may report no network.
- `scutil --set` changes need admin rights.

## Spotlight: mdfind and mdls

```zsh
mdfind -name "invoice"                                   # file name contains
mdfind -onlyin ~/Documents "budget 2024"                 # full-text, one folder
mdfind "kMDItemContentType == 'com.adobe.pdf'"
mdfind "kMDItemContentTypeTree == 'public.image' && kMDItemFSContentChangeDate >= \$time.today(-7)"
mdfind "kMDItemWhereFroms == '*github.com*'"
mdfind -count "kMDItemKind == 'Folder'"
mdls -name kMDItemContentType -name kMDItemPixelWidth photo.jpg
mdls -raw -name kMDItemWhereFroms file.zip
```

- Queries use `==`, `!=`, `<`, `>`, wildcards `*`, and modifiers `c` (case-insensitive),
  `d` (diacritic-insensitive), `w` (word): `kMDItemDisplayName == "*report*"cd`.
- `$time.today(-7)`, `$time.now(-3600)`, `$time.this_week` for dates (escape `$` in
  double quotes).
- Spotlight skips folders the user excluded and some system locations; results can lag
  behind very recent file changes.

## Property lists: plutil

```zsh
plutil -p ~/Library/Preferences/com.apple.dock.plist      # readable dump
plutil -convert json -o - Info.plist                      # to JSON on stdout
plutil -extract CFBundleShortVersionString raw /Applications/Safari.app/Contents/Info.plist
plutil -replace autohide -bool YES file.plist
plutil -insert items.0 -string "first" file.plist
plutil -remove key file.plist
plutil -lint file.plist
```

`raw` prints strings, numbers and booleans without quoting; it fails on arrays and dicts
(use `-convert json` or `json` format for those). Key paths use dots: `items.0.name`.

## launchd: launchctl

```zsh
launchctl list | grep -i dropbox
launchctl print gui/$(id -u)/com.example.agent        # state of one job
launchctl kickstart -k gui/$(id -u)/com.example.agent # restart a job
launchctl bootout gui/$(id -u)/com.example.agent      # unload
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.agent.plist
launchctl setenv NAME value                           # environment for apps launched later
```

- The old `load`/`unload` forms still work but are deprecated.
- Automations here are triggered by the runner (hotkeys, manual runs). Do not install
  launch agents from an automation without the user explicitly asking; it creates
  background jobs outside the catalog.

## Files, apps and the clipboard

```zsh
open -a "Safari" "https://example.com"
open -b com.apple.TextEdit file.txt       # by bundle id
open -R ~/Downloads/file.zip              # reveal in Finder
open ~/Downloads                          # open a folder
pbpaste | wc -w                           # clipboard text in
print -rn -- "$result" | pbcopy           # clipboard text out (-n: no newline)
say "Build finished"
afplay /System/Library/Sounds/Glass.aiff
screencapture -x ~/Desktop/shot.png       # needs Screen Recording permission
sips -Z 1600 in.jpg --out out.jpg         # resize the longest side to 1600 px
sips -s format png in.heic --out out.png  # convert
textutil -convert txt doc.docx -stdout    # documents to text
ditto -c -k --keepParent folder folder.zip
xattr -d com.apple.quarantine app.zip
mv file ~/.Trash/                         # "move to Trash" without Finder
```

## BSD tool differences

macOS ships BSD versions of many tools; GNU options from Linux examples often fail.

- `sed -i '' 's/a/b/' file` (the empty string after `-i` is required); `sed -E` for
  extended regular expressions.
- `date -v-1d +%Y-%m-%d` (yesterday), `date -j -f "%Y-%m-%d" "2024-05-01" +%s` (parse),
  `date -u +%Y-%m-%dT%H:%M:%SZ` (ISO 8601 UTC). There is no `date -d`.
- `stat -f "%z %Sm" file` (size, modification date); not `stat -c`.
- `readlink -f` exists on macOS 13+; `realpath` too.
- `grep -E` for extended regex; `grep -P` is not available.
- `find . -name "*.log" -mtime +30 -print0 | xargs -0 rm` (destructive: mark it).
- `base64 -i in -o out`; `md5 -q file`; `shasum -a 256 file`.
- `system_profiler SPHardwareDataType`, `sw_vers -productVersion`, `sysctl -n hw.memsize`.
- `diskutil list`, `diskutil info /`, `df -h /`.
