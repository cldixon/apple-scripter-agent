#!/bin/zsh
# Input: AUTOMATION_VAR_text holds the clipboard text from step 0.
print -r -- "${AUTOMATION_VAR_text}" | wc -w | tr -d ' '
