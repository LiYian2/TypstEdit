import AppKit
import Combine

@MainActor
final class DocumentTab: ObservableObject, Identifiable {
    let id: URL
    let url: URL
    let projectFolder: URL
    // Notify only after the canonical text changes: synchronous redraws must see the new text.
    var source: String { didSet { if source != oldValue { objectWillChange.send(); scheduleAutoSave() } } }
    @Published private(set) var savedSource: String
    @Published private(set) var autoSaveError: String?
    private var autoSaveEnabled = false
    private var autoSaveSuspended = false
    private var autoSaveTask: Task<Void, Never>?
    let controller = EditorController()
    private var controllerObservation: AnyCancellable?
    var editor: EditorView.Session?
    var exportedPDFURL: URL?
    var lastSaved: Date?
    var pendingLine: Int?
    var isDirty: Bool { source != savedSource }

    init(url: URL, projectFolder: URL, source: String) {
        self.url = url.standardizedFileURL
        self.id = Self.identity(url)
        self.projectFolder = projectFolder.standardizedFileURL
        self.source = source
        self.savedSource = source
        controllerObservation = controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    static func identity(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    func save() throws {
        do {
            // Refuse to silently replace edits made by another application.
            guard try String(contentsOf: id, encoding: .utf8) == savedSource else { throw DocumentSaveError.externalChange }
            // Write through the canonical path so opening a symlink does not replace the link.
            try source.write(to: id, atomically: true, encoding: .utf8)
            savedSource = source
            lastSaved = Date()
            autoSaveError = nil
            autoSaveTask?.cancel()
        } catch {
            autoSaveError = error.localizedDescription
            throw error
        }
    }

    func configureAutoSave(_ enabled: Bool) {
        autoSaveEnabled = enabled
        autoSaveTask?.cancel()
        if enabled { scheduleAutoSave() }
    }

    func suspendAutoSave(_ suspended: Bool) {
        autoSaveSuspended = suspended
        autoSaveTask?.cancel()
        if !suspended { scheduleAutoSave() }
    }

    func scheduleAutoSave(delay: Duration = .seconds(1)) {
        autoSaveTask?.cancel()
        guard autoSaveEnabled, !autoSaveSuspended, isDirty, autoSaveError == nil else { return }
        let revision = source
        autoSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.autoSaveEnabled, !self.autoSaveSuspended, !Task.isCancelled, self.source == revision,
                  self.editor?.textView.hasMarkedText() != true else { return }
            do {
                try self.save()
                NotificationCenter.default.post(name: .documentDidSave, object: self)
            } catch {
                self.autoSaveError = error.localizedDescription
            }
        }
    }

    func dispose() {
        configureAutoSave(false)
        editor?.detach()
        editor = nil
    }
}

enum DocumentSaveError: LocalizedError {
    case externalChange
    var errorDescription: String? {
        L10n.text("The file changed outside TypstEdit. Your draft is retained; reopen the file to review the disk version before saving.",
                  "文件已在 TypstEdit 外修改。草稿已保留，请先核对磁盘版本再保存。")
    }
}

@MainActor
final class DocumentWorkspace: ObservableObject {
    @Published private(set) var tabs: [DocumentTab] = []
    @Published private(set) var activeID: URL?
    private var observations: [URL: AnyCancellable] = [:]
    var active: DocumentTab? { tabs.first { $0.id == activeID } }
    var isDirty: Bool { tabs.contains { $0.isDirty } }

    func open(_ url: URL, projectFolder: URL) throws -> DocumentTab {
        let id = DocumentTab.identity(url)
        if let existing = tabs.first(where: { $0.id == id }) { return existing }
        let tab = DocumentTab(url: url, projectFolder: projectFolder,
                              source: try String(contentsOf: url, encoding: .utf8))
        observations[id] = tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        tabs.append(tab)
        return tab
    }

    func activate(_ tab: DocumentTab) { activeID = tab.id }

    /// Call only after the document's Save/Cancel/Discard check succeeds.
    func close(_ tab: DocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.dispose()
        observations.removeValue(forKey: tab.id)
        tabs.remove(at: index)
        if activeID == tab.id { activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    func closeAll() {
        for tab in tabs { tab.dispose() }
        observations.removeAll()
        tabs.removeAll()
        activeID = nil
    }
}

extension Notification.Name {
    static let documentSourceDidChange = Notification.Name("documentSourceDidChange")
    static let documentDidSave = Notification.Name("documentDidSave")
}
