import SwiftUI
import AppKit

/// Small mono "copy" affordance that flashes a confirmation after writing
/// `value` to the general pasteboard.
struct CopyButton: View {
    let value: String
    var label: String = "copy"

    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Text(copied ? "✓ copied" : label)
                .font(Theme.Font.mono(size: 10, wght: 400))
                .foregroundStyle(copied ? Theme.Color.accent : Theme.Color.textFaint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
        .accessibilityLabel("Copy \(value)")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }
}
