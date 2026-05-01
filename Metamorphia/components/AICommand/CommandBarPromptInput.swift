import AppKit
import SwiftUI

struct CommandBarPromptInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    var isFocused: Bool
    var font: NSFont = .systemFont(ofSize: 16, weight: .regular)
    var maxVisibleLines: Int = 8
    var onSubmit: () -> Void
    var onMoveUp: () -> Bool = { false }
    var onMoveDown: () -> Bool = { false }
    var onTab: () -> Bool = { false }
    var onReturn: () -> Bool = { false }
    var onEscape: () -> Bool = { false }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> CommandBarPromptScrollView {
        let scrollView = CommandBarPromptScrollView(font: font, maxVisibleLines: maxVisibleLines)
        scrollView.textView.delegate = context.coordinator
        scrollView.textView.string = text
        scrollView.textView.commandDelegate = context.coordinator
        scrollView.onMeasuredHeightChange = { height in
            context.coordinator.updateMeasuredHeight(height)
        }
        scrollView.recalculateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: CommandBarPromptScrollView, context: Context) {
        context.coordinator.parent = self
        scrollView.textView.commandDelegate = context.coordinator
        scrollView.onMeasuredHeightChange = { height in
            context.coordinator.updateMeasuredHeight(height)
        }

        if scrollView.textView.font != font {
            scrollView.textView.font = font
        }

        if scrollView.maxVisibleLines != maxVisibleLines {
            scrollView.maxVisibleLines = maxVisibleLines
        }

        if scrollView.textView.string != text {
            context.coordinator.isApplyingExternalChange = true
            scrollView.textView.string = text
            context.coordinator.isApplyingExternalChange = false
        }

        scrollView.recalculateHeight()

        // Only push focus *into* the text view; never actively resign it.
        // `isFocused` rides a SwiftUI @FocusState that has no `.focused()`
        // modifier bound to a real SwiftUI view here, so it reads as false
        // after every re-render even while the AppKit text view is the
        // window's first responder. Resigning from this path stole focus
        // on every keystroke.
        if isFocused,
           let window = scrollView.window,
           window.firstResponder !== scrollView.textView {
            window.makeFirstResponder(scrollView.textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, CommandBarPromptTextViewDelegate {
        var parent: CommandBarPromptInput
        var isApplyingExternalChange = false

        init(parent: CommandBarPromptInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalChange,
                  let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func handleMoveUp() -> Bool {
            parent.onMoveUp()
        }

        func handleMoveDown() -> Bool {
            parent.onMoveDown()
        }

        func handleTab() -> Bool {
            parent.onTab()
        }

        func handleReturn() -> Bool {
            parent.onReturn()
        }

        func handleEscape() -> Bool {
            parent.onEscape()
        }

        func submit() {
            parent.onSubmit()
        }

        func updateMeasuredHeight(_ height: CGFloat) {
            guard abs(parent.measuredHeight - height) > 0.5 else { return }
            DispatchQueue.main.async {
                self.parent.measuredHeight = height
            }
        }
    }
}

protocol CommandBarPromptTextViewDelegate: AnyObject {
    func handleMoveUp() -> Bool
    func handleMoveDown() -> Bool
    func handleTab() -> Bool
    func handleReturn() -> Bool
    func handleEscape() -> Bool
    func submit()
}

final class CommandBarPromptTextView: NSTextView {
    weak var commandDelegate: CommandBarPromptTextViewDelegate?

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(moveUp(_:)):
            if commandDelegate?.handleMoveUp() == true { return }
        case #selector(moveDown(_:)):
            if commandDelegate?.handleMoveDown() == true { return }
        case #selector(insertTab(_:)):
            if commandDelegate?.handleTab() == true { return }
        case #selector(cancelOperation(_:)):
            if commandDelegate?.handleEscape() == true { return }
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            if commandDelegate?.handleReturn() == true { return }
            commandDelegate?.submit()
            return
        default:
            break
        }

        super.doCommand(by: selector)
    }
}

final class CommandBarPromptScrollView: NSScrollView {
    let textView: CommandBarPromptTextView
    var maxVisibleLines: Int
    var onMeasuredHeightChange: ((CGFloat) -> Void)?

    init(font: NSFont, maxVisibleLines: Int) {
        self.textView = CommandBarPromptTextView(frame: .zero)
        self.maxVisibleLines = maxVisibleLines
        super.init(frame: .zero)

        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay

        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textColor = NSColor.white.withAlphaComponent(0.95)
        textView.insertionPointColor = .controlAccentColor
        textView.font = font
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        recalculateHeight()
    }

    func recalculateHeight() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let availableWidth = max(contentSize.width, 1)
        if abs(textContainer.containerSize.width - availableWidth) > 0.5 {
            textContainer.containerSize = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)
        }

        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let verticalInset = textView.textContainerInset.height * 2
        let lineHeight = ceil(layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)))
        let minHeight = ceil(lineHeight + verticalInset)
        let maxHeight = ceil(lineHeight * CGFloat(maxVisibleLines) + verticalInset)
        let contentHeight = ceil(usedRect.height + verticalInset)
        let clampedHeight = max(minHeight, min(maxHeight, contentHeight))

        hasVerticalScroller = contentHeight > maxHeight + 0.5
        onMeasuredHeightChange?(clampedHeight)
    }
}
