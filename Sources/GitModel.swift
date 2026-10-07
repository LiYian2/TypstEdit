import Foundation
import Combine

struct GitFileChange: Identifiable, Sendable, Equatable {
    var id: String { path }
    let path: String
    let index: Character
    let worktree: Character
    let originalPath: String?
    var kind: GitChangeKind {
        if index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") { return .conflicted }
        if index == "?" { return .untracked }
        if index == "D" || worktree == "D" { return .deleted }
        if index == "R" || worktree == "R" { return .renamed }
        if index == "A" || worktree == "A" { return .added }
        return .modified
    }
    var staged: Bool { index != " " && index != "?" }
    var unstaged: Bool { worktree != " " }
}

struct GitSnapshot: Sendable {
    var root: URL?
    var branch = ""
    var changes: [GitFileChange] = []
    var lines = GitLineMarkers()

    static func parseStatus(_ output: String) -> (String, [GitFileChange]) {
        let records = output.components(separatedBy: "\0")
        var branch = "", changes: [GitFileChange] = [], i = 0
        while i < records.count {
            let record = records[i]; i += 1
            if record.hasPrefix("## ") { branch = String(record.dropFirst(3)); continue }
            guard record.count >= 4 else { continue }
            let xy = Array(record.prefix(2))
            let path = String(record.dropFirst(3))
            // In -z format a rename has destination first, then a separate source record.
            var originalPath: String?
            if xy.contains("R") || xy.contains("C") {
                guard i < records.count, !records[i].isEmpty else { continue }
                originalPath = records[i]; i += 1
            }
            guard !path.components(separatedBy: "/").contains(where: { $0.hasPrefix(".typstedit-") }) else { continue }
            changes.append(GitFileChange(path: path, index: xy[0], worktree: xy[1], originalPath: originalPath))
        }
        return (branch, changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    static func parseHunks(_ diff: String, lineCount: Int) -> GitLineMarkers {
        var lines = GitLineMarkers()
        for line in diff.components(separatedBy: .newlines) where line.hasPrefix("@@ ") {
            let parts = line.split(separator: " ")
            guard parts.count >= 4 else { continue }
            func range(_ value: Substring) -> (Int, Int)? {
                let fields = value.dropFirst().split(separator: ",")
                guard let start = fields.first.flatMap({ Int($0) }) else { return nil }
                return (start, fields.count > 1 ? Int(fields[1]) ?? 0 : 1)
            }
            guard let (_, removed) = range(parts[1]), let (start, added) = range(parts[2]) else { continue }
            if added == 0 {
                let anchor = min(max(1, start), max(1, lineCount))
                lines.append(anchor...anchor, kind: .deleted)
            } else if start > 0, start <= lineCount {
                lines.append(start...min(start + added - 1, lineCount), kind: removed == 0 ? .added : .modified)
            }
        }
        return lines
    }
}

/// Serial, bounded Git subprocesses. No index mutations, hooks, shell, or diff drivers.
actor GitReader {
    static let shared = GitReader()
    private var baselineKey = ""
    private var baseline = ""
    private var comparedKey = ""
    private var comparedSource = ""
    private var comparedLines = GitLineMarkers()
    private var executable: String?
    private var checkedExecutable = false

    private func clearCache() {
        baselineKey = ""; baseline = ""
        comparedKey = ""; comparedSource = ""; comparedLines = GitLineMarkers()
    }

    func snapshot(folder: URL, file: URL?, source: String?) -> GitSnapshot {
        guard !Task.isCancelled else { return GitSnapshot() }
        // Avoid launching Apple's git stub (and its installer) for ordinary folders.
        var ancestor = folder.resolvingSymlinksInPath().standardizedFileURL
        while !FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
            guard ancestor.path != "/" else { clearCache(); return GitSnapshot() }
            let parent = ancestor.deletingLastPathComponent().standardizedFileURL
            guard parent.path != ancestor.path else { clearCache(); return GitSnapshot() }
            ancestor = parent
        }
        if !checkedExecutable {
            checkedExecutable = true
            executable = ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first(where: FileManager.default.isExecutableFile(atPath:))
            if executable == nil {
                let tools = CLIProcess.run(executable: "/usr/bin/xcode-select", arguments: ["-p"], directory: nil, timeout: 3, mergeStandardError: false)
                if tools.status == 0 { executable = "/usr/bin/git" }
            }
        }
        guard let executable, !Task.isCancelled else { return GitSnapshot() }
        func git(_ arguments: [String], at directory: URL) -> CLIResult {
            CLIProcess.run(executable: executable, arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments,
                           directory: directory, timeout: 3, mergeStandardError: false)
        }
        let repository = git(["rev-parse", "--show-toplevel"], at: folder)
        guard repository.status == 0, !Task.isCancelled else { clearCache(); return GitSnapshot() }
        let root = URL(fileURLWithPath: repository.output.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath()
        let status = git(["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all", "--renames"], at: root)
        guard status.status == 0, !Task.isCancelled else { return GitSnapshot() }
        let (branch, changes) = GitSnapshot.parseStatus(status.output)
        var result = GitSnapshot(root: root, branch: branch, changes: changes)
        guard let file, let source else { clearCache(); return result }
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard path.hasPrefix(prefix) else { return result }
        let relative = String(path.dropFirst(prefix.count))
        let ignored = git(["check-ignore", "--", relative], at: root)
        guard ignored.status != 0, !Task.isCancelled else { return result }
        let head = git(["rev-parse", "--verify", "HEAD"], at: root)
        let baselinePath = changes.first(where: { $0.path == relative })?.originalPath ?? relative
        let key = root.path + "\0" + head.output + "\0" + baselinePath
        if key != baselineKey {
            let blob = git(["show", "--no-ext-diff", "HEAD:" + baselinePath], at: root)
            guard !Task.isCancelled else { return result }
            if blob.status == 0 { baseline = blob.output }
            else {
                // New/staged-added files have no HEAD blob. Do not mark tracked files
                // as new merely because Git failed (permissions, missing objects, etc.).
                let tracked = git(["ls-files", "--error-unmatch", "--", relative], at: root)
                guard tracked.status != 0 || changes.contains(where: { $0.path == relative && $0.kind == .added }) else { return result }
                baseline = ""
            }
            baselineKey = key
        }
        guard !baseline.contains("\0"), !source.contains("\0") else { return result }
        if comparedKey == key, comparedSource == source {
            result.lines = comparedLines
            return result
        }
        if baseline == source {
            comparedKey = key; comparedSource = source; comparedLines = GitLineMarkers()
            return result
        }
        guard !Task.isCancelled, baseline != source else { return result }
        do {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-git-\(UUID())")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let old = temporary.appendingPathComponent("before"), new = temporary.appendingPathComponent("after")
            // Match NSString's logical lines, including CRLF and Unicode separators.
            let oldText = Self.logicalLines(baseline), newText = Self.logicalLines(source)
            try oldText.write(to: old, atomically: true, encoding: .utf8)
            try newText.write(to: new, atomically: true, encoding: .utf8)
            let diff = git(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=0", "--", old.path, new.path], at: temporary)
            if diff.status == 1 {
                result.lines = GitSnapshot.parseHunks(diff.output, lineCount: newText.components(separatedBy: "\n").count)
                comparedKey = key; comparedSource = source; comparedLines = result.lines
            }
        } catch { /* Decorations are optional; editing must remain available. */ }
        return result
    }

    static func logicalLines(_ text: String) -> String {
        let separators = CharacterSet(charactersIn: "\r\u{85}\u{2028}\u{2029}")
        guard text.rangeOfCharacter(from: separators) != nil else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{85}", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }
}

@MainActor
final class GitModel: ObservableObject {
    @Published private(set) var snapshot = GitSnapshot()
    private var generation = UUID()
    private var worker: Task<GitSnapshot, Never>?

    func refresh(folder: URL?, tab: DocumentTab?) async {
        worker?.cancel()
        let token = UUID(); generation = token
        guard let folder else { snapshot = GitSnapshot(); return }
        let file = tab?.id, source = tab?.source
        let task = Task.detached(priority: .utility) { await GitReader.shared.snapshot(folder: folder, file: file, source: source) }
        worker = task
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard !Task.isCancelled, generation == token, tab?.source == source else { return }
        snapshot = result
        tab?.controller.gitChanges = result.lines
    }

    func change(for url: URL, directory: Bool = false) -> GitChangeKind? {
        guard let root = snapshot.root else { return nil }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        if let exact = snapshot.changes.first(where: { $0.path == relative || $0.path == relative + "/" }) { return exact.kind }
        if directory { return snapshot.changes.contains(where: { $0.path.hasPrefix(relative + "/") }) ? .modified : nil }
        return snapshot.changes.contains(where: { $0.kind == .untracked && relative.hasPrefix($0.path) && $0.path.hasSuffix("/") }) ? .untracked : nil
    }
}
