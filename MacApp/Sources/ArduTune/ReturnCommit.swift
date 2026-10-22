import AppKit

/// У всій програмі: Return у текстовому полі підтверджує значення (його обробляє саме поле: onSubmit/action),
/// після чого поле перестає бути активним, доки на нього знову не натиснути.
/// Багаторядкові редактори (TextEditor, NSTextView не в ролі field editor) не чіпаємо.
enum ReturnCommit {
    nonisolated(unsafe) private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 36 || e.keyCode == 76,                       // Return, Enter на цифровій клавіатурі
                  e.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .option, .control]),
                  let win = e.window ?? NSApp.keyWindow,
                  let tv = win.firstResponder as? NSTextView, tv.isFieldEditor else { return e }
            // подію віддаємо полю (воно підтвердить значення), а фокус знімаємо після її обробки
            DispatchQueue.main.async { [weak win] in
                guard let win, let tv = win.firstResponder as? NSTextView, tv.isFieldEditor else { return }
                win.makeFirstResponder(nil)
            }
            return e
        }
    }
}
