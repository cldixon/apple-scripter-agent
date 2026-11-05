import AppKit
import Shared

/// The runner's own test window. Automations type into its text view, so a harness test
/// needs no Automation permission and does not depend on other apps.
@MainActor
final class HarnessController {
    private var window: NSWindow?
    private var textView: NSTextView?

    /// Runs one harness test: first by calling the automation directly, then (for hotkey
    /// triggers with `fire: trigger`) by posting the real hotkey.
    func run(
        _ test: ManifestTest.HarnessTest,
        name: String,
        manifest: AutomationManifest,
        perform: @MainActor () async -> RunRecord?
    ) async -> [TestReport.Result] {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let textView = show()
        defer { hide(returningTo: previousApp) }

        // The runner is a background app: macOS lets it take focus only when the app in front
        // yields it (the main app does before validating). Without focus, typed text would go
        // to whatever app is in front, so the automation is not run at all.
        guard await waitForFocus(on: textView, timeout: .milliseconds(1500)) else {
            return [.init(name: "\(name) (focus)", passed: false, message: Self.noFocusMessage)]
        }

        let expected: String
        do {
            expected = try Template.render(test.expectText, variables: [:], now: Date())
        } catch {
            return [.init(name: name, passed: false, message: error.localizedDescription)]
        }

        var results: [TestReport.Result] = []

        textView.string = ""
        try? await Task.sleep(for: .milliseconds(400))
        let record = await perform()
        try? await Task.sleep(for: .milliseconds(300))
        results.append(compare(
            name: "\(name) (direct call)", expected: expected, actual: textView.string, record: record
        ))

        if test.fire == .trigger, case .hotkey(let hotkey) = manifest.trigger,
           let keyCode = KeyCodes.virtualKeyCode(for: hotkey.key) {
            textView.string = ""
            do {
                try SystemActions.press(keyCode: keyCode, flags: SystemActions.eventFlags(for: hotkey.modifiers))
                let typed = await waitForText(in: textView, timeout: .seconds(3))
                results.append(compare(name: "\(name) (hotkey \(hotkey.displayString))", expected: expected,
                                       actual: typed, record: nil))
            } catch {
                results.append(.init(name: "\(name) (hotkey)", passed: false, message: error.localizedDescription))
            }
        }
        return results
    }

    private func compare(name: String, expected: String, actual: String, record: RunRecord?) -> TestReport.Result {
        if let record, record.outcome == .failed {
            return .init(name: name, passed: false, message: record.error ?? "The run failed.")
        }
        let passed = actual == expected
        return .init(
            name: name,
            passed: passed,
            message: passed ? "Window shows \"\(actual)\"" : "Expected \"\(expected)\", window shows \"\(actual)\""
        )
    }

    static let noFocusMessage = """
        The test window could not take keyboard focus (another app kept it), so the automation \
        was not run. This is a problem with the test harness, not the automation. Retry with \
        the Automation Agent window in front.
        """

    /// Waits until the test window is the active app's key window with the text view focused.
    private func waitForFocus(on textView: NSTextView, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let window, NSApp.isActive, window.isKeyWindow, window.firstResponder === textView {
                return true
            }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits until the text view has content that stops changing, or the timeout passes.
    private func waitForText(in textView: NSTextView, timeout: Duration) async -> String {
        let deadline = ContinuousClock.now + timeout
        var last = ""
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            let current = textView.string
            if !current.isEmpty, current == last { return current }
            last = current
        }
        return textView.string
    }

    private func show() -> NSTextView {
        if let window, let textView {
            present(window, focusing: textView)
            return textView
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Automation Agent — Test Harness"
        window.isReleasedWhenClosed = false
        window.level = .floating

        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as? NSTextView ?? NSTextView()
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        window.contentView = scrollView
        window.center()

        self.window = window
        self.textView = textView
        present(window, focusing: textView)
        return textView
    }

    private func present(_ window: NSWindow, focusing textView: NSTextView) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    private func hide(returningTo previousApp: NSRunningApplication?) {
        window?.orderOut(nil)
        guard let previousApp else { return }
        NSApp.yieldActivation(to: previousApp)
        previousApp.activate()
    }
}
