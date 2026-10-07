import AppKit
import SwiftUI
import PDFKit

@main
struct CompilerTests {
    @MainActor
    static func main() async throws {
        testExecutablePriorityAndInvalidCustomDoNotSilentlyFallback()
        testPATHDiscoveryAndDeduplication()
        await testUnresponsiveExecutableIsStopped()
        testWatchParserSplitUTF8ANSIAndDiagnostics()
        testNativeRulerSharesEditorScrollViewAndUTF16LogicalLines()
        testIncrementalLineIndexMatchesFullRebuild()
        testUnicodeInsertionAndEndOfFileNavigation()
        testKeywordAndUnicodeHighlighting()
        testTokenizerCancellation()
        testMarkedTextDefersBindingAndCompile()
        testVisibleSyntaxUsesTemporaryDrawingAttributes()
        try await testPreviewLatestRequestWins()
        try testFontConfigurationValidation()
        try await testRealCompileRelativeCrossFolderImportsAndExportFailurePreservesPDF()
        try await testWatchSuccessErrorRecoveryAndCleanup()
        try await testLowMemoryPreviewReleasesCompiler()
        try await testRapidPreviewRequestsKeepLatestRevision()
        print("PASS: 17 regression groups (resolver, PATH, process timeout, diagnostics, gutter, incremental UTF16/CRLF edits, Unicode/search, syntax, cancellation, visible drawing, IME, PDF coalescing, fonts, export/imports, watch lifecycle, low-memory preview, rapid revisions)")
    }

    static func testExecutablePriorityAndInvalidCustomDoNotSilentlyFallback() {
        let valid = Set(["/system/typst", "/bundle/typst", "/with spaces/typst"])
        let executable: (String) -> Bool = { valid.contains($0) }
        expectEqual(TypstExecutableResolver.resolve(choice: .automatic, customPath: "", bundledPath: "/bundle/typst", systemPaths: ["/missing", "/system/typst"], isExecutable: executable), "/system/typst")
        expectEqual(TypstExecutableResolver.resolve(choice: .automatic, customPath: "", bundledPath: "/bundle/typst", systemPaths: [], isExecutable: executable), "/bundle/typst")
        expectEqual(TypstExecutableResolver.resolve(choice: .custom, customPath: "/with spaces/typst", bundledPath: "/bundle/typst", isExecutable: executable), "/with spaces/typst")
        expectNil(TypstExecutableResolver.resolve(choice: .custom, customPath: "/missing", bundledPath: "/bundle/typst", isExecutable: executable))
        expectNil(TypstExecutableResolver.resolve(choice: .custom, customPath: "relative", bundledPath: "/bundle/typst", isExecutable: executable))
        expectEqual(TypstExecutableResolver.resolve(choice: .bundled, customPath: "", bundledPath: "/bundle/typst", systemPaths: ["/system/typst"], isExecutable: executable), "/bundle/typst")
    }

    static func testPATHDiscoveryAndDeduplication() {
        let paths = TypstExecutableResolver.candidates(environment: ["PATH": "/custom/bin:/opt/homebrew/bin:/custom/bin"], home: "/test")
        expectEqual(paths.first, "/custom/bin/typst")
        expectEqual(paths.filter { $0 == "/custom/bin/typst" }.count, 1)
        expectTrue(paths.contains("/test/.cargo/bin/typst"))
    }

    static func testUnresponsiveExecutableIsStopped() async {
        let start = ContinuousClock.now
        let result = await Task.detached {
            CLIProcess.run(executable: "/usr/bin/python3", arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready',flush=True); time.sleep(10)"], directory: nil, timeout: 0.5)
        }.value
        expectTrue(result.output.contains("ready"))
        expectTrue(result.status != 0)
        expectTrue(start.duration(to: .now) < .seconds(3))
    }

    static func testWatchParserSplitUTF8ANSIAndDiagnostics() {
        var parser = WatchOutputParser()
        let data = Data("\u{001B}[31m/tmp/中文.typ:12:4: error: 中文错误\u{001B}[0m\ncompiled with errors\n".utf8)
        var lines: [String] = []
        for byte in data { lines += parser.append(Data([byte])) }
        expectEqual(lines.count, 2)
        let error = WatchOutputParser.diagnostic(lines[0])
        expectEqual(error?.line, 12)
        expectEqual(error?.message, "中文错误")
        expectEqual(error?.filePath, "/tmp/中文.typ")
        expectNil(WatchOutputParser.diagnostic(lines[1]))
        expectNil(WatchOutputParser.diagnostic("/tmp/main.typ:2:1: warning: test"))
        expectEqual(WatchOutputParser.diagnostic("error: fonts unavailable")?.line, 0)
    }

    @MainActor
    static func testNativeRulerSharesEditorScrollViewAndUTF16LogicalLines() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 2000))
        scroll.documentView = text
        let ruler = LineNumberRulerView(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = text
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        ruler.updateLineStarts("中😀\r\nsecond\n\n")
        expectEqual(ruler.lineStarts, [0, 5, 12, 13])
        expectTrue(ruler.scrollView === scroll)
        expectTrue(ruler.clientView === text)
        ruler.updateLineStarts("")
        expectEqual(ruler.lineStarts, [0])
    }

    @MainActor
    static func testUnicodeInsertionAndEndOfFileNavigation() {
        let view = NSTextView()
        view.string = "中文😀\n"
        let controller = EditorController()
        controller.textView = view
        controller.goToLine(999)
        expectEqual(view.selectedRange().location, view.string.utf16.count)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        controller.wrapSelection(prefix: "😀", suffix: "中")
        expectEqual(view.selectedRange().location, 2)
        controller.searchQuery = "中文"
        let caret = NSRange(location: view.string.utf16.count, length: 0)
        view.setSelectedRange(caret)
        controller.refreshSearch()
        expectEqual(view.selectedRange(), caret)
    }

    static func testKeywordAndUnicodeHighlighting() {
        let source = "#let 中文 = \"😀\"\n= 标题\n// 注释"
        let spans = SyntaxHighlighter.spans(in: source)
        let string = source as NSString
        expectTrue(spans.contains { $0.style == 0 && string.substring(with: $0.range) == "let" })
        expectTrue(spans.contains { $0.style == 4 && string.substring(with: $0.range) == "= 标题" })
        expectTrue(spans.contains { $0.style == 5 && string.substring(with: $0.range) == "// 注释" })
    }

    @MainActor
    static func testIncrementalLineIndexMatchesFullRebuild() {
        let incremental = LineNumberRulerView(scrollView: nil, orientation: .verticalRuler)
        let reference = LineNumberRulerView(scrollView: nil, orientation: .verticalRuler)
        var binding = ""
        let editor = EditorView(text: Binding(get: { binding }, set: { binding = $0 }), controller: EditorController(), onCommit: {})
        let coordinator = EditorView.Coordinator(editor)
        var source = "中😀\r\nsecond\n\nend\r"
        incremental.updateLineStarts(source)
        coordinator.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: source)
        var seed: UInt64 = 871
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(bound))
        }
        let replacements = ["", "\n", "\r", "\r\n", "中文😀", "x", "\u{2028}", "\u{2029}"]
        for _ in 0..<3_000 {
            var boundaries = [0]
            var offset = 0
            for scalar in source.unicodeScalars {
                offset += scalar.value > 0xffff ? 2 : 1
                boundaries.append(offset)
            }
            let first = next(boundaries.count)
            let last = first + next(boundaries.count - first)
            let range = NSRange(location: boundaries[first], length: boundaries[last] - boundaries[first])
            let replacement = replacements[next(replacements.count)]
            source = (source as NSString).replacingCharacters(in: range, with: replacement)
            coordinator.textStorage.replaceCharacters(in: range, with: replacement)
            incremental.applyEdit(in: source as NSString, editedRange: NSRange(location: range.location, length: replacement.utf16.count), changeInLength: replacement.utf16.count - range.length)
            reference.updateLineStarts(source)
            expectEqual(incremental.lineStarts, reference.lineStarts)
            expectEqual(coordinator.ruler.lineStarts, reference.lineStarts)
        }
    }

    static func testTokenizerCancellation() {
        let source = String(repeating: "#let x = \"中文😀\" // comment\n", count: 10_000)
        var checks = 0
        let cancelled = SyntaxHighlighter.spans(in: source, isCancelled: { checks += 1; return checks > 100 })
        expectTrue(cancelled.isEmpty)
        expectTrue(checks <= 110)
    }

    @MainActor
    static func testFontConfigurationValidation() throws {
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        expectTrue(settings.useSystemFonts)
        expectEqual(try settings.fontArguments(), [])
        settings.useSystemFonts = false
        settings.fontPaths = "/System/Library/Fonts\n/System/Library/Fonts/\n"
        expectEqual(try settings.fontArguments(), ["--ignore-system-fonts", "--font-path", "/System/Library/Fonts"])
        settings.fontPaths = "/missing-font-directory"
        expectThrows(try settings.fontArguments())
        settings.fontPaths = "relative"
        expectThrows(try settings.fontArguments())
    }

    @MainActor
    static func testPreviewLatestRequestWins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit PDF \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func pdf(_ name: String) throws -> URL {
            let document = PDFDocument()
            let bitmap = try unwrap(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 800,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            let image = NSImage(cgImage: try unwrap(bitmap.makeImage()), size: NSSize(width: 200, height: 300))
            document.insert(try unwrap(PDFPage(image: image)), at: 0)
            let url = root.appendingPathComponent(name + ".pdf")
            expectTrue(document.write(to: url))
            return url
        }
        let first = try pdf("first"), latest = try pdf("latest")
        let coordinator = PreviewView.Coordinator()
        let view = PDFView()
        let token = UUID()
        coordinator.load(url: first, token: UUID(), in: view)
        coordinator.load(url: latest, token: token, in: view)
        for _ in 0..<50 where coordinator.lastURL != latest { try await Task.sleep(for: .milliseconds(20)) }
        expectEqual(coordinator.lastURL, latest)
        expectEqual(coordinator.lastToken, token)
        expectEqual(view.document?.pageCount, 1)
        coordinator.load(url: first, token: UUID(), in: view)
        coordinator.load(url: nil, token: nil, in: view)
        try await Task.sleep(for: .milliseconds(150))
        expectNil(view.document)
        expectNil(coordinator.lastURL)
        let retryURL = root.appendingPathComponent("retry.pdf")
        let retryToken = UUID()
        coordinator.load(url: retryURL, token: retryToken, in: view)
        try await Task.sleep(for: .milliseconds(150))
        try FileManager.default.copyItem(at: latest, to: retryURL)
        coordinator.load(url: retryURL, token: retryToken, in: view)
        for _ in 0..<50 where coordinator.lastURL != retryURL { try await Task.sleep(for: .milliseconds(20)) }
        expectEqual(coordinator.lastURL, retryURL)
    }

    @MainActor
    static func testVisibleSyntaxUsesTemporaryDrawingAttributes() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 1000))
        view.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.string = String(repeating: "#let value = 1\n", count: 100)
        scroll.documentView = view
        let source = view.string
        let originalAttributes = view.textStorage?.attributes(at: 1, effectiveRange: nil)
        let highlighter = SyntaxHighlighter()
        highlighter.install(SyntaxHighlighter.spans(in: source), in: view)
        expectEqual(view.string, source)
        expectTrue(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil) != nil)
        expectTrue(view.textStorage?.attribute(.font, at: 1, effectiveRange: nil) as? NSFont == originalAttributes?[.font] as? NSFont)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        highlighter.renderVisible(in: view)
        expectNil(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil))
        highlighter.invalidate()
    }

    @MainActor
    static func testMarkedTextDefersBindingAndCompile() {
        var source = "prefix"
        var compileCalls = 0
        let controller = EditorController()
        let editor = EditorView(text: Binding(get: { source }, set: { source = $0 }), controller: controller, onCommit: { compileCalls += 1 })
        let coordinator = EditorView.Coordinator(editor)
        let view = coordinator.textView
        view.string = source
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 6, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        expectTrue(view.hasMarkedText())
        expectEqual(source, "prefix")
        expectEqual(compileCalls, 0)
        view.insertText("你", replacementRange: view.markedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        expectFalse(view.hasMarkedText())
        expectEqual(source, "prefix你")
        expectTrue(compileCalls > 0)
        let reference = LineNumberRulerView(scrollView: nil, orientation: .verticalRuler)
        reference.updateLineStarts(view.string)
        expectEqual(coordinator.ruler.lineStarts, reference.lineStarts)
    }

    @MainActor
    static func testLowMemoryPreviewReleasesCompiler() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit low memory \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.typ")
        try "Saved".write(to: file, atomically: true, encoding: .utf8)
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        settings.choice = .bundled
        settings.lowMemoryMode = true
        settings.useSystemFonts = false
        let compiler = TypstCompiler(settings: settings)
        defer { compiler.cleanUp() }
        for content in ["First revision", "Second revision"] {
            await compiler.updateContent(source: content, fileURL: file, projectFolder: root)
            for _ in 0..<100 where compiler.isCompiling { try await Task.sleep(for: .milliseconds(100)) }
            expectFalse(compiler.hasRunningProcess)
            let pdf = try unwrap(compiler.previewURL)
            expectTrue(PDFDocument(url: pdf)?.string?.contains(content) == true)
        }
    }

    @MainActor
    static func testRapidPreviewRequestsKeepLatestRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit rapid \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.typ")
        try "Saved".write(to: file, atomically: true, encoding: .utf8)
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        settings.choice = .bundled
        settings.useSystemFonts = false
        for lowMemory in [false, true] {
            settings.lowMemoryMode = lowMemory
            let compiler = TypstCompiler(settings: settings)
            var requests: [Task<Void, Never>] = []
            for revision in 0..<12 {
                requests.append(Task { @MainActor in
                    await compiler.updateContent(source: "Revision \(revision)", fileURL: file, projectFolder: root)
                })
            }
            for request in requests { await request.value }
            // Explicit final request removes any dependence on scheduler ordering.
            await compiler.updateContent(source: "Latest revision", fileURL: file, projectFolder: root)
            for _ in 0..<100 {
                if let pdf = compiler.previewURL, PDFDocument(url: pdf)?.string?.contains("Latest revision") == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            expectTrue(PDFDocument(url: try unwrap(compiler.previewURL))?.string?.contains("Latest revision") == true)
            compiler.cleanUp()
            for _ in 0..<50 {
                if !(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".typstedit") }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            expectFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".typstedit") })
        }
    }

    @MainActor
    static func testRealCompileRelativeCrossFolderImportsAndExportFailurePreservesPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit tests \(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("chapters/main.typ")
        try "#let value = [Import succeeded]".write(to: root.appendingPathComponent("shared/module.typ"), atomically: true, encoding: .utf8)
        try "saved version".write(to: sourceURL, atomically: true, encoding: .utf8)
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        settings.choice = .bundled
        let compiler = TypstCompiler(settings: settings)
        let output = root.appendingPathComponent("export.pdf")
        for path in ["../shared/module.typ", "/shared/module.typ"] {
            try await compiler.export(source: "#import \"\(path)\": value\n#value\nUnsaved revision", fileURL: sourceURL, projectFolder: root, destination: output)
            let document = try unwrap(PDFDocument(url: output))
            expectTrue(document.string?.contains("Import succeeded") == true)
            expectTrue(document.string?.contains("Unsaved revision") == true)
        }
        // Custom compiler paths with spaces are executed directly, without shell quoting.
        let custom = root.appendingPathComponent("custom typst")
        try FileManager.default.createSymbolicLink(atPath: custom.path, withDestinationPath: try unwrap(settings.bundledPath))
        settings.choice = .custom
        settings.customPath = custom.path
        await settings.refresh()
        expectTrue(settings.version.hasPrefix("typst "))
        expectNil(settings.detectionError)
        // A filesystem-absolute import works only with an explicitly selected / project root.
        settings.rootPath = "/"
        let absoluteImport = root.resolvingSymlinksInPath().appendingPathComponent("shared/module.typ").path
        try await compiler.export(source: "#import \"\(absoluteImport)\": value\n#value", fileURL: sourceURL, projectFolder: root, destination: output)
        expectTrue(PDFDocument(url: output)?.string?.contains("Import succeeded") == true)
        settings.rootPath = ""
        let previous = try Data(contentsOf: output)
        do {
            try await compiler.export(source: "#unknown-function()", fileURL: sourceURL, projectFolder: root, destination: output)
            fail("Invalid source should not export")
        } catch { expectEqual(try Data(contentsOf: output), previous) }
        expectEqual(try String(contentsOf: sourceURL, encoding: .utf8), "saved version")
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: sourceURL.deletingLastPathComponent().path).contains { $0.hasPrefix(".typstedit") || $0.hasPrefix("typstedit-preview-") })
        settings.rootPath = root.appendingPathComponent("shared").path
        expectThrows(try settings.projectRoot(fileURL: sourceURL, folder: root))
    }

    @MainActor
    static func testWatchSuccessErrorRecoveryAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit watch \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.typ")
        try "Saved".write(to: file, atomically: true, encoding: .utf8)
        let suite = "TypstEditTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompilerSettings(defaults: defaults)
        settings.choice = .bundled
        let compiler = TypstCompiler(settings: settings)
        defer { compiler.cleanUp() }
        await compiler.updateContent(source: "Hello watch", fileURL: file, projectFolder: root)
        for _ in 0..<100 where compiler.previewURL == nil { try await Task.sleep(for: .milliseconds(100)) }
        expectNotNil(compiler.previewURL)
        expectFalse(compiler.isCompiling)
        await compiler.updateContent(source: "#unknown-function()", fileURL: file, projectFolder: root)
        for _ in 0..<100 where compiler.errors.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        expectFalse(compiler.errors.isEmpty)
        await compiler.updateContent(source: "Recovered", fileURL: file, projectFolder: root)
        for _ in 0..<100 where compiler.isCompiling || !compiler.errors.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        expectTrue(compiler.errors.isEmpty)
        expectFalse(compiler.isCompiling)
        let pdf = compiler.previewURL
        compiler.cleanUp()
        for _ in 0..<100 where pdf.map({ FileManager.default.fileExists(atPath: $0.path) }) == true { try await Task.sleep(for: .milliseconds(50)) }
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".typstedit") || $0.hasPrefix("typstedit-preview-") })
        expectFalse(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("pdf").path))
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    guard actual == expected else { fatalError("Expected \(expected), got \(actual)", file: file, line: line) }
}
private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    guard value else { fatalError("Expected true", file: file, line: line) }
}
private func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { expectTrue(!value, file: file, line: line) }
private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { expectTrue(value == nil, file: file, line: line) }
private func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { expectTrue(value != nil, file: file, line: line) }
private func unwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { fatalError("Unexpected nil", file: file, line: line) }; return value
}
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression() } catch { return }
    fatalError("Expected an error", file: file, line: line)
}
private func fail(_ message: String, file: StaticString = #file, line: UInt = #line) { fatalError(message, file: file, line: line) }
