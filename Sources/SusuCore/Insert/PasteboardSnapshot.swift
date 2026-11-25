#if os(macOS)
import AppKit

/// Full copy of a pasteboard: every item, every type, raw data per type (spec 3.6 step 2).
public struct PasteboardSnapshot: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var entries: [String: Data]
        public init(entries: [String: Data]) { self.entries = entries }
    }

    public var items: [Item]
    public init(items: [Item]) { self.items = items }

    public static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var items: [Item] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: [String: Data] = [:]
            for type in item.types {
                // Types whose data can't be materialised (dead promise) are skipped.
                if let data = item.data(forType: type) { entries[type.rawValue] = data }
            }
            if !entries.isEmpty { items.append(Item(entries: entries)) }
        }
        return PasteboardSnapshot(items: items)
    }

    /// Replace the pasteboard contents with this snapshot (an empty snapshot just clears it).
    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let objects: [NSPasteboardItem] = items.map { snap in
            let item = NSPasteboardItem()
            for (type, data) in snap.entries {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
    }
}
#endif
