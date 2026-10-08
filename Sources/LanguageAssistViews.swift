import SwiftUI
import AppKit

final class AssistTextView: NSTextView {
    var assistKey: ((NSEvent) -> Bool)?
    var requestCompletion: (() -> Void)?
    var hoverMoved: ((Int) -> Void)?
    var hoverExited: (() -> Void)?
    private var assistTracking: NSTrackingArea?
    override func complete(_ sender: Any?) { requestCompletion?() }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), assistKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let assistTracking { removeTrackingArea(assistTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking); assistTracking = tracking
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoverMoved?(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hoverExited?() }
    override func resignFirstResponder() -> Bool { hoverExited?(); return super.resignFirstResponder() }
}

@MainActor
final class CompletionPresentation: ObservableObject {
    let items: [LanguageCompletion]
    @Published var selected = 0
    let accept: (Int) -> Void
    init(items: [LanguageCompletion], accept: @escaping (Int) -> Void) { self.items = items; self.accept = accept }
    func move(_ delta: Int) { selected = (selected + delta + items.count) % items.count }
}

struct CompletionListView: View {
    @ObservedObject var model: CompletionPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("↑ ↓ select · Return/Tab insert · Esc dismiss", "↑ ↓ 选择 · 回车/Tab 插入 · Esc 关闭")).font(.caption2).foregroundColor(.secondary).padding(8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items.indices, id: \.self) { index in
                            Button { model.accept(index) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.items[index].label).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                    if !model.items[index].detail.isEmpty { Text(model.items[index].detail).font(.caption2).foregroundColor(.secondary).lineLimit(1) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(model.selected == index ? Color.accentColor.opacity(0.3) : .clear)
                            }.buttonStyle(.plain).id(index)
                        }
                    }
                }.onChange(of: model.selected) { index in proxy.scrollTo(index) }
            }
        }.frame(width: 440, height: min(300, CGFloat(model.items.count) * 35 + 36)).preferredColorScheme(.dark)
    }
}

struct LanguageHoverView: View {
    let text: String
    var body: some View {
        ScrollView {
            // Render server documentation as inert text; no remote HTML, commands or automatic links.
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(width: 520, height: 260).preferredColorScheme(.dark)
    }
}

extension EditorView.Session {
    func configureAssistance() {
        guard let view = textView as? AssistTextView else { return }
        view.requestCompletion = { [weak self] in self?.complete(explicit: true) }
        view.assistKey = { [weak self] event in self?.handleAssistKey(event) ?? false }
        view.hoverMoved = { [weak self] position in self?.scheduleHover(at: position) }
        view.hoverExited = { [weak self] in self?.closeHover() }
    }

    func dismissAssistance() {
        completionTask?.cancel(); completionTask = nil
        completionModel = nil
        if let completionEventMonitor { NSEvent.removeMonitor(completionEventMonitor); self.completionEventMonitor = nil }
        if let completionInactiveObserver { NotificationCenter.default.removeObserver(completionInactiveObserver); self.completionInactiveObserver = nil }
        completionPopover?.close(); completionPopover?.contentViewController = nil; completionPopover = nil
        closeHover()
    }
    func closeHover() {
        hoverTask?.cancel(); hoverTask = nil; hoverRange = nil
        hoverPopover?.close(); hoverPopover?.contentViewController = nil; hoverPopover = nil
    }
    func completionPrefix() -> NSRange? {
        let selection = textView.selectedRange(), source = textView.string as NSString
        guard selection.length == 0, selection.location <= source.length else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        var start = selection.location
        while start > 0, let scalar = UnicodeScalar(source.character(at: start - 1)), allowed.contains(scalar) { start -= 1 }
        return NSRange(location: start, length: selection.location - start)
    }
    func complete(explicit: Bool) {
        dismissAssistance()
        guard let document = parent?.document, let prefix = completionPrefix(), !textView.hasMarkedText(),
              textView.window?.firstResponder === textView, textView.window?.isKeyWindow == true, LanguageSettings.shared.enabled,
              explicit || LanguageSettings.shared.autoComplete else { return }
        let source = textView.string, caret = textView.selectedRange(), currentRevision = revision
        if !explicit {
            let string = source as NSString
            let previous = caret.location > 0 ? string.substring(with: NSRange(location: caret.location - 1, length: 1)) : ""
            // Avoid prose/CJK requests; explicit completion remains available anywhere.
            let line = string.lineRange(for: NSRange(location: caret.location, length: 0))
            let before = string.substring(with: NSRange(location: line.location, length: caret.location - line.location))
            let preceding = prefix.location > 0 ? string.substring(with: NSRange(location: prefix.location - 1, length: 1)) : ""
            let codeLine = before.contains("#") || before.contains("$") || before.hasPrefix(" ") || before.hasPrefix("\t")
            guard codeLine || ["#", ".", "@", "<", "/"].contains(preceding) || ["#", ".", "@", "<", "/"].contains(previous) else { return }
            guard (prefix.length > 0 && prefix.length <= 100 && string.substring(with: prefix).unicodeScalars.allSatisfy({ $0.isASCII }))
                    || ["#", ".", "@", "<", "/"].contains(previous) else { return }
        }
        guard let context = try? LanguageSettings.shared.context(for: document), context.source == source else { return }
        let token = UUID(); completionToken = token
        completionTask = Task { @MainActor [weak self] in
            do {
                if !explicit { try await Task.sleep(for: .milliseconds(180)) }
                let response = try await TypstLanguageService.shared.request("textDocument/completion", document: context, position: caret.location)
                let items = LanguageCompletion.decode(response, source: source, fallback: prefix)
                guard let self, !Task.isCancelled, self.completionToken == token, self.parent?.document === document,
                      self.revision == currentRevision, self.textView.selectedRange() == caret,
                      self.textView.string == source, !self.textView.hasMarkedText(), self.textView.window?.firstResponder === self.textView,
                      self.textView.window?.isKeyWindow == true,
                      LanguageSettings.shared.enabled, explicit || LanguageSettings.shared.autoComplete else { return }
                if items.isEmpty { if explicit { document.controller.languageStatus = L10n.text("No completions here.", "此处没有补全候选。") }; return }
                document.controller.languageStatus = ""
                self.showCompletions(items, source: source, caret: caret)
            } catch {
                guard let self, !Task.isCancelled, self.parent?.document === document else { return }
                if explicit { document.controller.languageStatus = error.localizedDescription }
            }
        }
    }
    func showCompletions(_ items: [LanguageCompletion], source: String, caret: NSRange) {
        guard let rect = anchorRect(caret.location) else { return }
        closeHover()
        guard let document = parent?.document else { return }
        let currentRevision = revision
        let model = CompletionPresentation(items: items) { [weak self, weak document] index in
            guard let document else { return }
            self?.acceptCompletion(index, source: source, caret: caret, document: document, revision: currentRevision)
        }
        completionModel = model
        let popover = NSPopover(); popover.animates = false; popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 440, height: min(300, CGFloat(items.count) * 35 + 36))
        popover.contentViewController = NSHostingController(rootView: CompletionListView(model: model))
        completionPopover = popover
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        textView.window?.makeFirstResponder(textView)
        completionEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.completionModel != nil else { return event }
            let popup = self.completionPopover?.contentViewController?.view.window
            if event.type == .keyDown, (event.window === self.textView.window || event.window === popup), !self.textView.hasMarkedText() {
                if self.handleAssistKey(event) { return nil }
            } else if event.type != .keyDown, event.window !== popup { self.dismissAssistance() }
            return event
        }
        completionInactiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissAssistance() }
        }
    }
    func handleAssistKey(_ event: NSEvent) -> Bool {
        // Option changes the produced character (e.g. Shift-Option-F → Ï), so route by key code.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 3, modifiers == [.option, .shift] {
            dismissAssistance(); parent?.controller.formatDocument(); return true
        }
        if event.keyCode == 53, event.modifierFlags.contains(.option) { complete(explicit: true); return true }
        guard let model = completionModel, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
        switch event.keyCode {
        case 126: model.move(-1); return true
        case 125: model.move(1); return true
        case 36, 48: model.accept(model.selected); return true
        case 53: dismissAssistance(); return true
        default: return false
        }
    }
    func acceptCompletion(_ index: Int, source: String, caret: NSRange, document: DocumentTab, revision requestedRevision: Int) {
        guard let model = completionModel, model.items.indices.contains(index), textView.string == source,
              !textView.hasMarkedText(), parent?.document === document, revision == requestedRevision, textView.selectedRange() == caret else { dismissAssistance(); return }
        let item = model.items[index]
        let offsetDelta = item.additional.filter { $0.range.location < item.edit.range.location }.reduce(0) { $0 + $1.text.utf16.count - $1.range.length }
        let selection = item.selection.map { NSRange(location: item.edit.range.location + offsetDelta + $0.location, length: $0.length) }
            ?? NSRange(location: item.edit.range.location + offsetDelta + item.edit.text.utf16.count, length: 0)
        let result = LanguageEdit.applying(([item.edit] + item.additional).sorted { $0.range.location < $1.range.location }, to: source)
        dismissAssistance()
        textView.window?.makeFirstResponder(textView)
        applyAssistedSource(result, selection: selection)
    }
    func applyAssistedSource(_ source: String, selection: NSRange? = nil) {
        guard !textView.hasMarkedText(), textView.string != source else { return }
        let old = textView.string as NSString, new = source as NSString
        var prefix = 0, suffix = 0
        while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        // Ensure replacements never start or end inside a UTF-16 surrogate pair.
        if prefix > 0, prefix < old.length, (0xDC00...0xDFFF).contains(old.character(at: prefix)) { prefix -= 1 }
        while suffix < min(old.length, new.length) - prefix,
              old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) { suffix += 1 }
        if suffix > 0, old.length - suffix < old.length, (0xDC00...0xDFFF).contains(old.character(at: old.length - suffix)) { suffix -= 1 }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let insertion = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        let oldSelection = textView.selectedRange()
        isApplyingAssistance = true
        defer { isApplyingAssistance = false }
        textView.breakUndoCoalescing()
        textView.insertText(insertion, replacementRange: range)
        textView.breakUndoCoalescing()
        func map(_ offset: Int) -> Int {
            if offset <= prefix { return offset }
            if offset >= old.length - suffix { return min(new.length, offset + new.length - old.length) }
            return min(new.length - suffix, prefix + max(0, offset - prefix))
        }
        let lower = map(oldSelection.location), upper = max(lower, map(NSMaxRange(oldSelection)))
        let target = selection ?? NSRange(location: lower, length: upper - lower)
        if NSMaxRange(target) <= new.length { textView.setSelectedRange(target) }
        commitCurrentText()
    }
    func anchorRect(_ offset: Int) -> NSRect? {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        let text = textView.string as NSString
        if offset >= text.length {
            var rect = layout.extraLineFragmentRect
            if rect.isEmpty, text.length > 0 { rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: text.length - 1), effectiveRange: nil) }
            return rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        }
        let glyph = layout.glyphIndexForCharacter(at: offset)
        return layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }
    func scheduleHover(at offset: Int) {
        guard LanguageSettings.shared.enabled, LanguageSettings.shared.hover, completionModel == nil,
              let document = parent?.document, !textView.hasMarkedText(), textView.window?.isKeyWindow == true else { closeHover(); return }
        let source = textView.string as NSString
        guard offset < source.length, offset >= 0, let scalar = UnicodeScalar(source.character(at: offset)),
              CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains(scalar) else { closeHover(); return }
        let word = textView.selectionRange(forProposedRange: NSRange(location: offset, length: 0), granularity: .selectByWord)
        if hoverRange == word { return }
        closeHover(); hoverRange = word
        let currentRevision = revision, token = UUID(); hoverToken = token
        guard let context = try? LanguageSettings.shared.context(for: document), context.source == textView.string else { return }
        hoverTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
                let response = try await TypstLanguageService.shared.request("textDocument/hover", document: context, position: offset)
                let contents = LanguageCompletion.documentation((response as? [String: Any])?["contents"])
                guard let self, !Task.isCancelled, self.hoverToken == token, self.parent?.document === document,
                      self.revision == currentRevision, self.hoverRange == word, self.textView.string == context.source,
                      !self.textView.hasMarkedText(), self.textView.window?.isKeyWindow == true,
                      LanguageSettings.shared.enabled, LanguageSettings.shared.hover, !contents.isEmpty, let rect = self.anchorRect(offset) else { return }
                let popover = NSPopover(); popover.animates = false; popover.behavior = .transient
                popover.contentSize = NSSize(width: 520, height: 260)
                popover.contentViewController = NSHostingController(rootView: LanguageHoverView(text: contents))
                self.hoverPopover = popover; popover.show(relativeTo: rect, of: self.textView, preferredEdge: .maxY)
            } catch { /* Hover is optional and never interrupts typing. */ }
        }
    }
}
