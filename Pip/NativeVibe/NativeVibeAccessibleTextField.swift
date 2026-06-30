import SwiftUI
import AppKit

/// NSTextField that reliably accepts first responder for AppAgent typing.
private final class FocusableTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}

/// AppKit static label with reliable Accessibility `value` for AppAgent QA.
struct NativeVibeAccessibleLabel: NSViewRepresentable {
    var text: String
    var axIdentifier: String
    var fontSize: CGFloat = 12
    var weight: NSFont.Weight = .regular
    var textColor: NSColor = .labelColor
    var multiline: Bool = false

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = .systemFont(ofSize: fontSize, weight: weight)
        label.textColor = textColor
        label.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail
        label.maximumNumberOfLines = multiline ? 0 : 1
        label.setAccessibilityIdentifier(axIdentifier)
        label.setAccessibilityValue(text)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.stringValue = text
        label.font = .systemFont(ofSize: fontSize, weight: weight)
        label.textColor = textColor
        label.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail
        label.maximumNumberOfLines = multiline ? 0 : 1
        label.setAccessibilityIdentifier(axIdentifier)
        label.setAccessibilityValue(text)
    }
}

/// AppKit text field with reliable Accessibility `value` for AppAgent QA.
struct NativeVibeAccessibleTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var axIdentifier: String
    var bordered: Bool = true
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusableTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = bordered
        field.isBezeled = bordered
        field.bezelStyle = bordered ? .roundedBezel : .squareBezel
        field.drawsBackground = bordered
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(axIdentifier)
        field.setAccessibilityValue(text)
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.focusField(_:)))
        field.addGestureRecognizer(click)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(axIdentifier)
        field.setAccessibilityValue(text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeVibeAccessibleTextField

        init(parent: NativeVibeAccessibleTextField) {
            self.parent = parent
        }

        @objc func focusField(_ sender: NSClickGestureRecognizer) {
            guard let field = sender.view as? NSTextField else { return }
            field.window?.makeFirstResponder(field)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            field.setAccessibilityValue(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit?()
                return true
            }
            return false
        }
    }
}