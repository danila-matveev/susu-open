// Reads the (final text, text after the user's edit) pairs the word search works on.
import Foundation
import SusuCore

enum HistoryPairs {
    /// Every dictation whose `edited_text` differs from `final_text`, newest first. Pages through the feed so the
    /// UI can show progress and cancel.
    static func load(from history: HistoryStore, pageSize: Int = 1000,
                     progress: @Sendable (Int) -> Void = { _ in }) async throws -> [(final: String, edited: String)] {
        var out: [(final: String, edited: String)] = []
        var cursor: FeedCursor?
        var seen = 0
        repeat {
            try Task.checkCancellation()
            let page = try await history.feed(filter: HistoryFilter(kind: .dictation), after: cursor, limit: pageSize)
            for day in page.days {
                for d in day.items {
                    guard let edited = d.editedText?.trimmingCharacters(in: .whitespacesAndNewlines), !edited.isEmpty,
                          let final = (d.finalText ?? d.rawText)?.trimmingCharacters(in: .whitespacesAndNewlines), !final.isEmpty,
                          edited != final else { continue }
                    out.append((final, edited))
                }
            }
            seen += page.days.reduce(0) { $0 + $1.items.count }
            progress(seen)
            cursor = page.next
        } while cursor != nil
        return out
    }
}
