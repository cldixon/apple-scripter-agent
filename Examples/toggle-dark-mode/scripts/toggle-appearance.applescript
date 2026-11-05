-- Step 0 of toggle-dark-mode.
-- Flips System Settings > Appearance between Light and Dark. Needs the Automation
-- permission for System Events, not Accessibility. What it does when Appearance is set to
-- "Auto" has not been verified.
-- Output: the new appearance, "Dark" or "Light".
on run argv
	tell application "System Events"
		tell appearance preferences
			set dark mode to not dark mode
			set isDark to dark mode
		end tell
	end tell
	if isDark then return "Dark"
	return "Light"
end run
