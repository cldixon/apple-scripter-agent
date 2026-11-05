-- Step 0 of quick-reminder.
-- Asks for one line of text. Output: the text, trimmed, or "" when the person cancels,
-- leaves it empty or does not answer within 100 seconds (the step's timeout is 120).
--
-- The dialog is shown by System Events after `activate`, so it comes to the front even
-- though the runner is a background app. Cancel raises error -128, which is caught here
-- so a cancelled run is not counted as a failure.
on run argv
	try
		tell application "System Events"
			activate
			set answer to display dialog "Remind me today about:" default answer "" with title "Add to Inbox" buttons {"Cancel", "Add"} default button "Add" cancel button "Cancel" giving up after 100
		end tell
	on error errorMessage number errorNumber
		if errorNumber is -128 then return ""
		error errorMessage number errorNumber
	end try
	if gave up of answer then return ""
	return my trimText(text returned of answer)
end run

on trimText(t)
	set whitespace to {space, tab, return, linefeed, character id 160}
	repeat while t is not "" and (character 1 of t) is in whitespace
		if (count of t) is 1 then return ""
		set t to text 2 thru -1 of t
	end repeat
	repeat while t is not "" and (character -1 of t) is in whitespace
		if (count of t) is 1 then return ""
		set t to text 1 thru -2 of t
	end repeat
	return t
end trimText
