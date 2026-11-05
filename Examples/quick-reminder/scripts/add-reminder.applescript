-- Step 1 of quick-reminder.
-- Input: {"text": "<step 0's askText answer>"}. Adds a reminder due today (all day) to the
-- list "Inbox", creating the list in the default account when no list has that name.
-- Output: the notification text.
-- Cancel in step 0's prompt ends the run as skipped before this step, so only an empty
-- answer needs handling here.
use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	set reminderText to my trimmed(my inputValue(item 1 of argv, "text"))
	if reminderText is "" then return "Nothing was typed, so no reminder was added."
	set now to current date
	set today to now - (time of now)
	tell application "Reminders"
		if not (exists list "Inbox") then
			make new list with properties {name:"Inbox"}
		end if
		tell list "Inbox"
			set newReminder to make new reminder with properties {name:reminderText}
		end tell
		try
			-- An all-day due date shows "Today" without a time or an alert.
			set allday due date of newReminder to today
		on error
			-- Older Reminders dictionaries have only due date (a date with a time).
			set due date of newReminder to today
		end try
	end tell
	return "Added \"" & reminderText & "\" to Inbox, due today."
end run

-- The string value of `keyName` in the JSON object text `jsonText`, or "".
on inputValue(jsonText, keyName)
	set ca to current application
	set jsonString to ca's NSString's stringWithString:jsonText
	set jsonData to jsonString's dataUsingEncoding:(ca's NSUTF8StringEncoding)
	set parsed to ca's NSJSONSerialization's JSONObjectWithData:jsonData options:0 |error|:(missing value)
	if parsed is missing value then return ""
	set found to parsed's objectForKey:keyName
	if found is missing value then return ""
	return found as text
end inputValue

-- `t` without leading and trailing spaces, tabs and line breaks.
on trimmed(t)
	set ca to current application
	set whitespace to ca's NSCharacterSet's whitespaceAndNewlineCharacterSet()
	return ((ca's NSString's stringWithString:t)'s stringByTrimmingCharactersInSet:whitespace) as text
end trimmed
