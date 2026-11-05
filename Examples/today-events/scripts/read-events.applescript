-- Step 0 of today-events.
-- Reads every event that can occur today, from every calendar, and leaves the date logic
-- to step 1 (format-events.js), which is pure and can be tested with fixed inputs.
--
-- Calendar's `whose` filter is fast, but it only sees the first occurrence of a repeating
-- event. So one-off events come from `whose`, and repeating events are found by reading
-- every event's rule in one Apple Event per calendar; step 1 expands them.
--
-- Output: tab-separated lines; dates are local time as yyyy-MM-ddTHH:mm:ss.
--   now   <TAB> date
--   event <TAB> calendar <TAB> title <TAB> start <TAB> end <TAB> true|false (all day)
--         <TAB> recurrence rule or empty <TAB> excluded dates, comma-separated
on run argv
	set now to current date
	set dayStart to now - (time of now)
	set dayEnd to dayStart + 1 * days
	set output to {"now" & tab & my isoText(now)}
	tell application "Calendar"
		repeat with calendarRef in (every calendar)
			set aCalendar to contents of calendarRef
			try
				set calendarName to name of aCalendar
				-- One-off events that overlap today.
				set candidates to (every event of aCalendar whose start date < dayEnd and end date > dayStart)
				repeat with eventRef in candidates
					set anEvent to contents of eventRef
					if my ruleOf(anEvent) is "" then set end of output to my eventLine(calendarName, anEvent, "")
				end repeat
				-- Repeating events that started before the end of today.
				set rules to recurrence of every event of aCalendar
				set startDates to start date of every event of aCalendar
				repeat with i from 1 to count of rules
					set rule to item i of rules
					if rule is not missing value and rule is not "" and (item i of startDates) < dayEnd then
						set end of output to my eventLine(calendarName, event i of aCalendar, rule)
					end if
				end repeat
			on error errorMessage number errorNumber
				-- A timeout or a denied permission must not look like an empty day.
				if errorNumber is -1712 or errorNumber is -1743 then error errorMessage number errorNumber
				-- Otherwise skip a calendar that cannot be read (for example a broken subscription).
			end try
		end repeat
	end tell
	return my joinList(output, linefeed)
end run

on ruleOf(anEvent)
	tell application "Calendar" to set rule to recurrence of anEvent
	if rule is missing value then return ""
	return rule
end ruleOf

on eventLine(calendarName, anEvent, rule)
	set excluded to {}
	tell application "Calendar"
		set eventTitle to summary of anEvent
		set startDate to start date of anEvent
		set endDate to end date of anEvent
		set isAllDay to allday event of anEvent
		if rule is not "" then
			try
				set excluded to excluded dates of anEvent
			end try
		end if
	end tell
	if eventTitle is missing value or eventTitle is "" then set eventTitle to "(No title)"
	set excludedTexts to {}
	repeat with dateRef in excluded
		set end of excludedTexts to my isoText(contents of dateRef)
	end repeat
	set fields to {"event", my clean(calendarName), my clean(eventTitle), my isoText(startDate), my isoText(endDate), (isAllDay as text), rule, my joinList(excludedTexts, ",")}
	return my joinList(fields, tab)
end eventLine

-- yyyy-MM-ddTHH:mm:ss from the date's components: independent of the Mac's date format.
on isoText(d)
	set secondsToday to time of d
	set hh to secondsToday div hours
	set mm to (secondsToday mod hours) div minutes
	set ss to secondsToday mod minutes
	return ((year of d) as text) & "-" & my pad(month of d as integer) & "-" & my pad(day of d) & "T" & my pad(hh) & ":" & my pad(mm) & ":" & my pad(ss)
end isoText

on pad(n)
	return text -2 thru -1 of ("0" & ((n as integer) as text))
end pad

-- Tabs and line breaks would break the line format: replace them with spaces.
on clean(t)
	set t to t as text
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to {tab, return, linefeed}
	set parts to text items of t
	set AppleScript's text item delimiters to space
	set t to parts as text
	set AppleScript's text item delimiters to savedDelimiters
	return t
end clean

on joinList(theList, separator)
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to separator
	set joined to theList as text
	set AppleScript's text item delimiters to savedDelimiters
	return joined
end joinList
