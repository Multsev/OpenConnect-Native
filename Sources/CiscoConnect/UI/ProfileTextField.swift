import AppKit
import SwiftUI

/// The same native control remains mounted when a VPN profile becomes locked.
/// SwiftUI's disabled TextField also disables selection, so use isEditable here.
struct ProfileTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var editable: Bool
    var secure = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = secure ? NSSecureTextField() : NSTextField()
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        // Do not set isBordered: that changes the cell back to a square border.
        field.drawsBackground = true
        field.isSelectable = true
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.isEditable && !editable {
            // Finish the old field editor before locking, including keyboard-triggered connects.
            if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        }
        field.isEditable = editable
        field.isSelectable = true
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ProfileTextField
        init(_ parent: ProfileTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard parent.editable, let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
