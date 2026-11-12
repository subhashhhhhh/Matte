import Foundation

/// NSRegularExpression rather than Swift's Regex for scanning x.com's pages and scripts: it
/// is many times faster on multi-megabyte input, and supports lookbehind.
nonisolated extension NSRegularExpression {
    convenience init(_ pattern: String, options: NSRegularExpression.Options = []) {
        try! self.init(pattern: pattern, options: options)
    }

    /// Each match's capture groups (index 0 is the whole match); nil for a group that didn't take part.
    func captures(in s: String) -> [[String?]] {
        matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: s).map { String(s[$0]) }
            }
        }
    }

    func firstCaptures(in s: String) -> [String?]? {
        guard let m = firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }
}
