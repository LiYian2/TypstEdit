import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var compiler = TypstCompiler()
    @StateObject private var fileSystem = FileSystemModel()
    
    @State private var selectedFile: URL?
    @State private var sourceCode: String = ""
    @State private var currentPDFURL: URL? // Preview PDF for live viewing
    @State private var exportedPDFURL: URL?
    @State private var loadedFile: URL?
    @State private var savedSource = ""
    @State private var operationError: String?
    @State private var isExporting = false
    @State private var pendingLine: Int?
    @ObservedObject private var settings = CompilerSettings.shared
    
    // Debounce timer
    @State private var workItem: DispatchWorkItem?
    @State private var compilationTask: Task<Void, Never>?
    @State private var compilationRequest = UUID()
    
    @StateObject private var editorController = EditorController()
    
    @State private var reloadToken: UUID = UUID()
    @State private var lastSaved: Date?
    @State private var showSavePopup: Bool = false
    @EnvironmentObject var themeManager: ThemeManager
    
    // MARK: - Computed Properties for UI Components
    
    private var editorBox: some View {
        ZStack {
            themeManager.editorBackground
            
            VStack(spacing: 0) {
                // Formatting Toolbar above editor
                HStack {
                    ToolbarView(controller: editorController)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.1))
               
                // Editor
                EditorView(text: $sourceCode, controller: editorController, onCommit: {
                    scheduleCompilation()
                })
                .environmentObject(themeManager)
                .padding(8)
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(12)
        .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
        .padding(.vertical, 12)
    }
    
    var body: some View {
        ZStack {
            // Main Background with Visual Effect
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow,
                state: .active,
                emphasized: false
            )
            .ignoresSafeArea()
            
            themeManager.mainBackground.ignoresSafeArea() // Should be .clear
            
            if fileSystem.currentFolder == nil {
                WelcomeView(model: fileSystem, onOpen: { url in
                    self.selectedFile = url
                    let folder = url.deletingLastPathComponent()
                    fileSystem.currentFolder = folder
                    fileSystem.loadFiles()
                })
                .background(themeManager.mainBackground)
            } else {
                // Unified HSplitView for Transparency
                HSplitView {
                    // LEFT: Sidebar (starts minimized)
                    SidebarView(model: fileSystem, selectedFile: $selectedFile, compiler: compiler, editorController: editorController, onOpenFolder: openProjectFolder, onNavigateError: navigateToError)
                        .frame(minWidth: 200, idealWidth: 200, maxWidth: 400)
                    
                    // RIGHT: Main Content (Editor + PDF)
                    if selectedFile != nil {
                         ZStack {
                            themeManager.contentOverlay.ignoresSafeArea() 
                            themeManager.mainBackground.ignoresSafeArea() // .clear
                            
                            ResizableSplitView(initialWidth: 500) {
                                // Left Pane: Line Numbers + Editor
                                HStack(spacing: 8) { // Added spacing
                                    editorBox
                                        .padding(.trailing, 0) // Remove padding as handle provides spacing
                                }
                            } right: {
                                // PDF Preview Area with Shadow Box
                                ZStack {
                                    themeManager.pdfBackground
                                    
                                    PreviewView(url: currentPDFURL, reloadToken: reloadToken)
                                        .padding(20)
                                }
                                .cornerRadius(12)
                                .shadow(color: themeManager.shadowColor, radius: themeManager.shadowRadius, x: 0, y: 5)
                                .padding(.vertical, 12)
                                .padding(.leading, 0) // Remove padding as handle provides spacing
                                .padding(.trailing, 12) // Keep trailing padding for window edge
                            }
                        }
                        .layoutPriority(1)
                    } else {
                        // Empty state when no file selected but folder open
                         ZStack {
                            themeManager.contentOverlay.ignoresSafeArea()
                            Text(L10n.text("Select a file", "选择一个 Typst 文件"))
                                .foregroundColor(themeManager.textColor)
                         }
                         .frame(maxWidth: .infinity, maxHeight: .infinity)
                         .layoutPriority(1)
                    }
                }
                // Toolbar attached to the main split view
                .toolbar {
                    // Undo/Redo on the left
                    ToolbarItem(placement: .navigation) {
                        HStack(spacing: 8) {
                            Button(action: editorController.undo) {
                                Image(systemName: "arrow.uturn.backward")
                                    .foregroundColor(themeManager.textColor)
                            }
                            .help(L10n.text("Undo (Cmd+Z)", "撤销（Cmd+Z）"))
                            .buttonStyle(.plain)
                            
                            Button(action: editorController.redo) {
                                Image(systemName: "arrow.uturn.forward")
                                    .foregroundColor(themeManager.textColor)
                            }
                            .help(L10n.text("Redo (Cmd+Shift+Z)", "重做（Cmd+Shift+Z）"))
                            .buttonStyle(.plain)
                        }
                    }
                    
                    ToolbarItem(placement: .principal) {
                        Text((selectedFile?.lastPathComponent ?? "") + (sourceCode == savedSource ? "" : " •"))
                            .font(.headline)
                            .foregroundColor(themeManager.textColor)
                    }
                    
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 8) {
                            
                            // Search Bar with Popup
                            VStack(spacing: 0) {
                                HStack(spacing: 4) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 12))
                                    TextField(L10n.text("Search", "搜索"), text: $editorController.searchQuery)
                                        .textFieldStyle(.plain)
                                        .frame(width: 120)
                                        .foregroundColor(themeManager.textColor)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.2))
                                .cornerRadius(6)
                                
                                // Search results popup (appears when there are matches)
                                if !editorController.searchQuery.isEmpty && editorController.matchCount > 0 {
                                    HStack(spacing: 8) {
                                        // Match counter
                                        Text("\(editorController.currentMatchIndex + 1) / \(editorController.matchCount)")
                                            .font(.caption)
                                            .foregroundColor(themeManager.secondaryTextColor)
                                        
                                        Divider()
                                            .frame(height: 12)
                                        
                                        // Previous match button
                                        Button(action: { editorController.previousMatch() }) {
                                            Image(systemName: "chevron.up")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help(L10n.text("Previous", "上一个"))
                                        
                                        // Next match button
                                        Button(action: { editorController.nextMatch() }) {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help(L10n.text("Next", "下一个"))
                                        
                                        Divider()
                                            .frame(height: 12)
                                        
                                        // Done button
                                        Button(action: { 
                                            editorController.searchQuery = ""
                                            editorController.clearSearch()
                                        }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .help(L10n.text("Done", "完成"))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(6)
                                    .offset(y: 2)
                                }
                            }
                            
                            // Divider
Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 16)
                            
                            // Actions: Save, Print, Share
                            HStack(spacing: 12) {
                                Button(action: saveFile) {
                                    Image(systemName: "square.and.arrow.down")
                                        .foregroundColor(themeManager.textColor)
                                }
                                .help(L10n.text("Save (Cmd+S)", "保存（Cmd+S）"))
                                .accessibilityLabel(L10n.text("Save", "保存"))
                                .keyboardShortcut("s", modifiers: .command)
                                .buttonStyle(.plain)
                                
                                Button(action: exportPDF) {
                                    Image(systemName: "doc.badge.arrow.up")
                                }
                                .help(L10n.text("Export PDF (Cmd+Shift+E)", "导出 PDF（Cmd+Shift+E）"))
                                .disabled(isExporting)
                                .accessibilityLabel(L10n.text("Export PDF", "导出 PDF"))
                                .buttonStyle(.plain)
                                // Print Button
                                Button(action: printPDF) {
                                    Image(systemName: "printer")
                                        .foregroundColor(themeManager.textColor)
                                }
                                .help(L10n.text("Print", "打印"))
                                .accessibilityLabel(L10n.text("Print", "打印"))
                                .disabled(currentPDFURL == nil || compiler.isCompiling || !compiler.errors.isEmpty)
                                .buttonStyle(.plain)
                                
                                // Share Button (Native Anchor)
                                ShareButton(fileURL: exportedPDFURL)
                                    .frame(width: 20, height: 20)
                                    .help(L10n.text("Share last exported PDF", "分享最近导出的 PDF"))
                            }
                            
                            Text(compiler.compilationStatus)
                                .font(.caption)
                                .lineLimit(1)
                                .help(compiler.compilationStatus)
                                .accessibilityLabel(compiler.compilationStatus)
                            // Save Status & Finder
                            if let lastSaved = lastSaved {
                                Text(L10n.text("Saved: ", "已保存：") + lastSaved.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                        }
                    }
                }
                // Important: Hide explicit window toolbar background to use our transparency
                .toolbarBackground(.hidden, for: .windowToolbar)
                .onChange(of: compiler.errors) { newErrors in
                    editorController.errors = newErrors.filter { error in
                        guard let path = error.filePath else { return true }
                        return URL(fileURLWithPath: path).lastPathComponent.hasPrefix("typstedit-preview-") || path == selectedFile?.path
                    }
                    editorController.needsRedraw()
                }
            }
            
            // Save Popup
            if showSavePopup {
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text(L10n.text("Saved!", "已保存！"))
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.8))
                .cornerRadius(12)
                .transition(.scale.combined(with: .opacity))
                .zIndex(100)
            }
        }
        .background(DocumentWindowGuard(edited: loadedFile != nil && sourceCode != savedSource,
            canClose: confirmDiscard, onClose: { cancelCompilation(); compiler.cleanUp() },
            onTerminate: { cancelCompilation(); compiler.cleanUp(waitForExit: true) }))
        .focusedSceneValue(\.documentActions, DocumentActions(open: openFile, save: saveFile, export: exportPDF, refresh: refreshPreview, insert: insertSnippet, hasDocument: selectedFile != nil))
        .alert(L10n.text("Operation failed", "操作失败"), isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button(L10n.text("OK", "确定")) { operationError = nil }
        } message: { Text(operationError ?? "") }
        .onChange(of: selectedFile) { newValue in
            guard newValue != loadedFile else { return }
            if confirmDiscard() { loadFile(url: newValue) }
            else { selectedFile = loadedFile; pendingLine = nil }
        }
        .onChange(of: fileSystem.currentFolder) { folder in
            if let selectedFile, let folder, !selectedFile.path.hasPrefix(folder.path + "/") {
                self.selectedFile = nil
            } else { scheduleCompilation() }
        }
        .onChange(of: settings.choice) { _ in refreshPreview() }
        .onChange(of: settings.customPath) { _ in refreshPreview() }
        .onChange(of: settings.lowMemoryMode) { _ in refreshPreview() }
        .onChange(of: settings.useSystemFonts) { _ in refreshPreview() }
        .onChange(of: settings.fontPaths) { _ in refreshPreview() }
        .onChange(of: settings.rootPath) { _ in refreshPreview() }
        .onDisappear { cancelCompilation(); compiler.cleanUp() }
        .onReceive(NotificationCenter.default.publisher(for: .pdfDidUpdate)) { notification in
            guard let sender = notification.object as? TypstCompiler, sender === compiler,
                  let url = notification.userInfo?["url"] as? URL else { return }
            currentPDFURL = url
            reloadToken = UUID()
        }

        .preferredColorScheme(.dark)
    }
    
    func insertSnippet(_ key: String) {
        switch key {
        case "table": editorController.insertTableSnippet()
        case "image": editorController.insertImageSnippet()
        case "chart": editorController.insertChartSnippet()
        case "timeline": editorController.insertTimelineSnippet()
        default: break
        }
    }

    func confirmDiscard() -> Bool {
        guard loadedFile != nil, sourceCode != savedSource else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.text("Save changes before leaving this file?", "离开文件前保存修改？")
        alert.addButton(withTitle: L10n.text("Save", "保存"))
        alert.addButton(withTitle: L10n.text("Cancel", "取消"))
        alert.addButton(withTitle: L10n.text("Discard", "放弃修改"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveFile()
            return sourceCode == savedSource
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func navigateToError(_ error: TypstError) {
        guard error.line > 0 else { return }
        if let path = error.filePath,
           !URL(fileURLWithPath: path).lastPathComponent.hasPrefix("typstedit-preview-"),
           let selectedFile {
            let target = URL(fileURLWithPath: path, relativeTo: selectedFile.deletingLastPathComponent()).standardizedFileURL
            if target != selectedFile, target.pathExtension == "typ", FileManager.default.fileExists(atPath: target.path) {
                pendingLine = error.line
                self.selectedFile = target
                return
            }
        }
        editorController.goToLine(error.line)
    }

    func openProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url, confirmDiscard() else { return }
        loadFile(url: nil)
        selectedFile = nil
        fileSystem.currentFolder = folder
        fileSystem.loadFiles()
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "typ") ?? .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard confirmDiscard() else { return }
            fileSystem.currentFolder = url.deletingLastPathComponent()
            fileSystem.loadFiles()
            selectedFile = url
        }
    }

    func loadFile(url: URL?) {
        do {
            let content = try url.map { try String(contentsOf: $0, encoding: .utf8) } ?? ""
            cancelCompilation()
            compiler.cleanUp()
            currentPDFURL = nil
            exportedPDFURL = nil
            lastSaved = nil
            editorController.clearSearch()
            editorController.textView?.undoManager?.removeAllActions()
            sourceCode = content
            savedSource = content
            loadedFile = url
            if let url { RecentFilesManager.shared.add(url: url) }
            scheduleCompilation()
            if let line = pendingLine {
                pendingLine = nil
                DispatchQueue.main.async { editorController.goToLine(line) }
            }
        } catch {
            pendingLine = nil
            selectedFile = loadedFile
            operationError = error.localizedDescription
        }
    }

    func saveFile() {
        guard let url = loadedFile else { return }
        do {
            // Save .typ file
            try sourceCode.write(to: url, atomically: true, encoding: .utf8)
            RecentFilesManager.shared.add(url: url)
            savedSource = sourceCode
            
            // Trigger compilation to generate PDF
            scheduleCompilation()
            
            // UI Feedback
            lastSaved = Date()
            withAnimation {
                showSavePopup = true
            }
            // Hide after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showSavePopup = false
                }
            }
        } catch {
            operationError = error.localizedDescription
        }
    }
    
    func exportPDF() {
        guard let file = selectedFile, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = file.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let source = sourceCode
        let folder = fileSystem.currentFolder
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                try await compiler.export(source: source, fileURL: file, projectFolder: folder, destination: destination)
                exportedPDFURL = destination
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { operationError = error.localizedDescription }
        }
    }

    func printPDF() {
        
        guard let url = currentPDFURL else {
            return
        }
        
        guard let document = PDFDocument(url: url) else {
            return
        }
        
        
        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        
        // Scale to fit logic is complex in code, but standard print op handles typical cases
        let op = document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true)
        op?.run()
    }
    
    func refreshPreview() {
        cancelCompilation()
        compiler.cleanUp()
        scheduleCompilation()
    }

    func scheduleCompilation() {
        cancelCompilation()
        guard let url = selectedFile else { return }
        let request = compilationRequest
        let currentSource = sourceCode
        let fileURL = url
        let folder = fileSystem.currentFolder
        
        let newWorkItem = DispatchWorkItem {
            guard compilationRequest == request else { return }
            compilationTask = Task { @MainActor in
                guard compilationRequest == request, !Task.isCancelled else { return }
                await compiler.updateContent(source: currentSource, fileURL: fileURL, projectFolder: folder)
            }
        }
        workItem = newWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: newWorkItem)
    }

    func cancelCompilation() {
        compilationRequest = UUID()
        workItem?.cancel()
        compilationTask?.cancel()
    }
}
import PDFKit



extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
