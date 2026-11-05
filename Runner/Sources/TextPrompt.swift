import AppKit

/// The runner's own text prompt for the `askText` primitive: an alert with a text field,
/// floating above other windows. It is shown without a modal run loop, so the runner keeps
/// handling hotkeys and commands while it is open, and a step timeout can close it.
@MainActor
final class TextPrompt: NSObject {
    private let alert = NSAlert()
    private let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    private var continuation: CheckedContinuation<String?, Never>?

    private init(prompt: String, defaultValue: String) {
        super.init()
        alert.messageText = prompt
        alert.informativeText = ""
        field.stringValue = defaultValue
        field.placeholderString = "Type here"
        alert.accessoryView = field
        let okButton = alert.addButton(withTitle: "OK")
        okButton.target = self
        okButton.action = #selector(confirm)
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
    }

    /// Asks the user for text. Returns nil when they press Cancel (or Escape), or when the
    /// waiting task is cancelled, for example by the step's timeout.
    static func ask(prompt: String, defaultValue: String) async -> String? {
        let panel = TextPrompt(prompt: prompt, defaultValue: defaultValue)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                panel.show(continuation)
            }
        } onCancel: {
            Task { @MainActor in
                panel.finish(nil)
            }
        }
    }

    private func show(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
        alert.layout()
        let window = alert.window
        window.level = .floating
        window.hidesOnDeactivate = false
        window.initialFirstResponder = field
        window.center()
        // The runner is a background (LSUIElement) app; since macOS 14 activation is
        // cooperative and may be refused, so the floating level keeps the panel visible anyway.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    @objc private func confirm() {
        finish(field.stringValue)
    }

    @objc private func cancel() {
        finish(nil)
    }

    private func finish(_ answer: String?) {
        guard let continuation else { return }
        self.continuation = nil
        alert.window.orderOut(nil)
        continuation.resume(returning: answer)
    }
}
