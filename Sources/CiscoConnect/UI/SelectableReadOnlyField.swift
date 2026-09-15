import AppKit
import SwiftUI

/// A native macOS text field that prevents changes while preserving selection and Copy.
struct SelectableReadOnlyField: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        configuredReadOnlyField(NSTextField())
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }
}

/// Secure counterpart used while a connected profile's password remains hidden.
struct SelectableReadOnlySecureField: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSSecureTextField {
        configuredReadOnlyField(NSSecureTextField())
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSecureTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }
}

private func configuredReadOnlyField<Field: NSTextField>(_ field: Field) -> Field {
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.isEditable = false
    field.isSelectable = true
    field.isBezeled = true
    field.isBordered = true
    field.drawsBackground = true
    field.bezelStyle = .roundedBezel
    field.lineBreakMode = .byTruncatingTail
    field.usesSingleLineMode = true
    field.font = NSFont.preferredFont(forTextStyle: .body)
    return field
}
