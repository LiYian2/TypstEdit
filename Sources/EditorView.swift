import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: EditorController
    @EnvironmentObject var themeManager: ThemeManager
    var onCommit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = context.coordinator.scrollView
        let textView = context.coordinator.textView
        
        // --- MODIFICATION TRANSPARENCE ---
        // On force le fond transparent au démarrage
        textView.backgroundColor = .clear
        textView.textColor = NSColor(themeManager.textColor)
        textView.insertionPointColor = NSColor(themeManager.textColor)
        
        // Connecter le contrôleur
        DispatchQueue.main.async {
            controller.textView = textView
            scrollView.verticalRulerView?.needsDisplay = true
        }
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let textView = context.coordinator.textView
        let textStorage = context.coordinator.textStorage
        
        // Always use dark appearance
        nsView.appearance = NSAppearance(named: .darkAqua)
        
        // Update text if changed
        if textView.string != text && !textView.hasMarkedText() {
            let selectedRange = textView.selectedRange()
            context.coordinator.highlighter.invalidate()
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
            textStorage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                       .foregroundColor: NSColor(white: 0.9, alpha: 1)],
                                      range: NSRange(location: 0, length: textStorage.length))
            textStorage.endEditing()
            context.coordinator.scheduleHighlighting()
            if selectedRange.location + selectedRange.length <= text.utf16.count {
                textView.setSelectedRange(selectedRange)
            }
        }
        context.coordinator.ruler.errors = Set(controller.errors.filter { $0.line > 0 }.map(\.line))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: EditorView
        let highlighter = SyntaxHighlighter()
        
        let scrollView: NSScrollView
        let textView: NSTextView
        let textStorage: NSTextStorage
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer
        let ruler: LineNumberRulerView
        var highlightTask: DispatchWorkItem?
        var scrollObserver: NSObjectProtocol?
        var tokenTask: Task<Void, Never>?
        var tokenizer: Task<[SyntaxHighlighter.Span], Never>?
        var revision = 0

        @MainActor init(_ parent: EditorView) {
            self.parent = parent
            
            self.textStorage = NSTextStorage()
            self.layoutManager = NSLayoutManager()
            self.textStorage.addLayoutManager(layoutManager)
            
            self.textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            self.textContainer.widthTracksTextView = true
            self.layoutManager.addTextContainer(textContainer)
            
            self.textView = NSTextView(frame: .zero, textContainer: textContainer)
            self.scrollView = NSScrollView()
            self.ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
            
            super.init()
            
            // --- CONFIGURATION SCROLLVIEW ---
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .noBorder
            
            // --- MODIFICATION TRANSPARENCE ---
            scrollView.drawsBackground = false // CRUCIAL: Désactive le fond gris par défaut
            scrollView.backgroundColor = .clear
            
            scrollView.documentView = textView
            ruler.clientView = textView
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.ruler.needsDisplay = true
                    if let self { self.highlighter.renderVisible(in: self.textView) }
                }
            }
            
            // --- CONFIGURATION TEXTVIEW ---
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainerInset = NSSize(width: 0, height: 10)
            
            // --- MODIFICATION TRANSPARENCE ---
            textView.drawsBackground = false // CRUCIAL: Désactive le fond blanc par défaut
            textView.backgroundColor = .clear
            
            textView.isRichText = false
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            
            textView.delegate = self
            textStorage.delegate = self

        }

        deinit {
            highlightTask?.cancel()
            tokenTask?.cancel()
            tokenizer?.cancel()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Do not replace attributed text or compile provisional Chinese IME composition.
            guard !textView.hasMarkedText() else { return }
            highlighter.invalidate()
            parent.text = textView.string
            parent.onCommit()
            scheduleHighlighting()
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            revision &+= 1
            highlightTask?.cancel()
            tokenTask?.cancel()
            tokenizer?.cancel()
            highlighter.invalidate()
            // NSTextStorage also reports provisional IME edits, so the index never gets stale.
            ruler.applyEdit(in: storage.mutableString, editedRange: editedRange, changeInLength: delta)
        }

        func scheduleHighlighting() {
            highlightTask?.cancel()
            tokenTask?.cancel()
            tokenizer?.cancel()
            let scheduledRevision = revision
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.revision == scheduledRevision, !self.textView.hasMarkedText() else { return }
                let snapshot = self.textView.string
                let tokenizer = Task.detached(priority: .userInitiated) {
                    await SyntaxTokenizationWorker.shared.tokenize(snapshot)
                }
                self.tokenizer = tokenizer
                self.tokenTask = Task { @MainActor [weak self] in
                    let spans = await tokenizer.value
                    guard !Task.isCancelled, let self, self.revision == scheduledRevision, !self.textView.hasMarkedText() else { return }
                    self.highlighter.install(spans, in: self.textView)
                    self.tokenizer = nil
                    self.tokenTask = nil
                    self.parent.controller.refreshSearch()
                }
            }
            highlightTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
        }
    }
}

/// Serialize tokenization so a retiring snapshot cannot overlap the next token buffer.
private actor SyntaxTokenizationWorker {
    static let shared = SyntaxTokenizationWorker()
    func tokenize(_ source: String) -> [SyntaxHighlighter.Span] {
        guard !Task.isCancelled else { return [] }
        return SyntaxHighlighter.spans(in: source, isCancelled: { Task.isCancelled })
    }
}
