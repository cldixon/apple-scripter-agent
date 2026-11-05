-- Step 0 of copy-finder-paths.
-- Output: the POSIX paths of the items selected in Finder, one per line, or "" when nothing
-- is selected. Folders end with "/". When the desktop is frontmost, Finder's selection is
-- the desktop selection.
on run argv
	tell application "Finder"
		set theSelection to selection
		if theSelection is {} then return ""
		try
			-- One Apple Event for the whole selection.
			set selectedItems to theSelection as alias list
		on error
			-- Fallback: convert item by item.
			set selectedItems to {}
			repeat with anItem in theSelection
				set end of selectedItems to (contents of anItem) as alias
			end repeat
		end try
	end tell
	set paths to {}
	repeat with anAlias in selectedItems
		set end of paths to POSIX path of (contents of anAlias)
	end repeat
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to linefeed
	set joined to paths as text
	set AppleScript's text item delimiters to savedDelimiters
	return joined
end run
