import Foundation

enum GitChangeKind: String, Sendable {
    case added, modified, deleted, conflicted, untracked, renamed
    var badge: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .conflicted: return "!"
        case .untracked: return "U"
        case .renamed: return "R"
        }
    }
}

/// Compact hunk ranges: a 100,000-line addition needs one range, not 100,000 entries.
struct GitLineMarkers: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let lines: ClosedRange<Int>
        let kind: GitChangeKind
    }
    private(set) var segments: [Segment] = []
    var isEmpty: Bool { segments.isEmpty }
    mutating func append(_ range: ClosedRange<Int>, kind: GitChangeKind) {
        if let last = segments.last, last.kind == kind, range.lowerBound <= last.lines.upperBound + 1 {
            segments[segments.count - 1] = Segment(lines: last.lines.lowerBound...max(last.lines.upperBound, range.upperBound), kind: kind)
        } else { segments.append(Segment(lines: range, kind: kind)) }
    }
    subscript(line: Int) -> GitChangeKind? {
        var low = 0, high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].lines.lowerBound <= line { low = middle + 1 } else { high = middle }
        }
        guard low > 0, segments[low - 1].lines.contains(line) else { return nil }
        return segments[low - 1].kind
    }
}
