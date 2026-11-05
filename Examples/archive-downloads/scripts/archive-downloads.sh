#!/bin/zsh
# Step 0 of archive-downloads.
# Moves regular files at the top level of ~/Downloads that were last modified more than
# 30 days ago into ~/Downloads/Archive/<year-month of the file's modification date>/.
# Never overwrites: a name that is taken gets " 2", " 3"... before its extension, and `mv -n`
# refuses to replace a file that appears in the meantime.
#
# Inputs (all optional, as AUTOMATION_VAR_<name>; the manifest sets none, tests set them):
#   dryRun  "1" or "true": only print what would move.
#   folder  the folder to tidy instead of ~/Downloads.
#   days    the age in days instead of 30 (0 archives every file, for tests).
# Run by hand with a dry run:  AUTOMATION_VAR_dryRun=1 zsh archive-downloads.sh
# Script tests copy tests/fixtures/downloads-case and run with HOME set to the copy, so
# $HOME/Downloads is its Downloads folder; they pass days=0 because copied files are new.
#
# Output: one summary line, then one "old -> new" line per file (sorted by name).

emulate -L zsh
setopt no_unset pipe_fail
zmodload -F zsh/stat b:zstat
zmodload zsh/datetime

folder=${AUTOMATION_VAR_folder:-$HOME/Downloads}
days=${AUTOMATION_VAR_days:-30}
case ${AUTOMATION_VAR_dryRun:-} in
  1|true|yes) dry_run=1 ;;
  *) dry_run=0 ;;
esac

if [[ ! -d $folder ]]; then
  print -u2 -r -- "No folder at $folder."
  exit 1
fi
if [[ $days != <-> ]]; then
  print -u2 -r -- "days must be a whole number, not \"$days\"."
  exit 1
fi

archive=$folder/Archive
cutoff=$(( EPOCHSECONDS - days * 86400 ))
moved=0
skipped=0
lines=()

# (N) no error when empty, (.) regular files only (not folders, not the Archive folder,
# not symlinks), (on) sorted by name. Hidden files such as .DS_Store are not matched.
for file in $folder/*(N.on); do
  zstat -A mtime +mtime -- $file || { (( skipped++ )); continue; }
  (( mtime[1] <= cutoff )) || continue

  strftime -s month %Y-%m $mtime[1]
  destination_dir=$archive/$month
  name=${file:t}
  base=${name:r}
  extension=${name:e}
  # "archive.tar.gz" keeps ".gz" as its extension; a name with no dot has none.
  [[ $name == $base ]] && extension=""
  target=$destination_dir/$name
  n=2
  while [[ -e $target || -L $target ]]; do
    if [[ -n $extension ]]; then
      target="$destination_dir/$base $n.$extension"
    else
      target="$destination_dir/$base $n"
    fi
    (( n++ ))
  done

  if (( dry_run )); then
    lines+=("${file#$folder/} -> ${target#$folder/}")
    (( moved++ ))
    continue
  fi
  if ! mkdir -p -- $destination_dir; then
    (( skipped++ ))
    continue
  fi
  # mv -n never replaces an existing file. It can still fail (a file in use on another
  # volume, no permission): count those and carry on.
  if mv -n -- $file $target 2>/dev/null && [[ ! -e $file && -e $target ]]; then
    lines+=("${file#$folder/} -> ${target#$folder/}")
    (( moved++ ))
  else
    (( skipped++ ))
  fi
done

if (( dry_run )); then
  summary="Dry run: would move $moved file(s) older than $days days into Archive."
else
  summary="Moved $moved file(s) older than $days days into Archive."
fi
(( skipped )) && summary+=" Skipped $skipped that could not be moved."
print -r -- $summary
(( ${#lines} )) && print -rl -- $lines
exit 0
