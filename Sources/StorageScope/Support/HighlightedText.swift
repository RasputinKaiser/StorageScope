import SwiftUI

/// Renders `text` with substrings matched by `query` highlighted via accent color.
/// Extracted as a dedicated `View` struct because the inline ternary
/// `? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary)` causes Swift type-checker
/// timeouts inside long HStack body expressions (see v0.5.0 learning record and the
/// established `FileTypeRowLabel` pattern in `TypeBreakdownView.swift`).
///
/// Matched ranges come from a per-term case-insensitive substring search of `text`
/// for every whitespace-delimited term in `query`. Adjacent / overlapping matches
/// are merged into disjoint runs so the rendered `AttributedString` is minimal.
struct HighlightedText: View {
    let text: String
    let query: String
    private let matchedColor: Color
    private let defaultColor: Color?

    init(_ text: String, query: String, matchedColor: Color = .accentColor, defaultColor: Color? = nil) {
        self.text = text
        self.query = query
        self.matchedColor = matchedColor
        self.defaultColor = defaultColor
    }

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(text).foregroundStyleOptional(defaultColor)
        } else if let highlighted = buildAttributed() {
            Text(highlighted)
        } else {
            Text(text).foregroundStyleOptional(defaultColor)
        }
    }

    private func buildAttributed() -> AttributedString? {
        let terms = query.split(separator: " ", omittingEmptySubsequences: true)
        guard !terms.isEmpty else { return nil }

        var attributed = AttributedString(text)
        var matched = false
        for term in terms {
            let termStr = String(term)
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let range = attributed[searchStart...].range(of: termStr, options: .caseInsensitive) {
                var run = attributed[range]
                run.foregroundColor = matchedColor
                attributed.replaceSubrange(range, with: run)
                matched = true
                if range.upperBound < attributed.endIndex {
                    searchStart = range.upperBound
                } else {
                    break
                }
            }
        }
        return matched ? attributed : nil
    }
}

private extension View {
    @ViewBuilder
    func foregroundStyleOptional(_ color: Color?) -> some View {
        if let color {
            self.foregroundStyle(color)
        } else {
            self
        }
    }
}