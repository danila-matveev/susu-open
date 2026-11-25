// Names and icons of installed apps by bundle id (NSWorkspace), plus the list of running apps.
import SwiftUI
import AppKit

struct AppInfo: Identifiable, Equatable {
    var id: String { bundleId }
    let bundleId: String
    let name: String
}

@MainActor
enum AppCatalog {
    private static var names: [String: String?] = [:]
    private static var icons: [String: NSImage?] = [:]

    private static func url(_ bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    /// Display name of an installed app, nil if the app is not on this Mac.
    static func installedName(_ bundleId: String) -> String? {
        if let cached = names[bundleId] { return cached }
        var name: String?
        if let url = url(bundleId) {
            let shown = FileManager.default.displayName(atPath: url.path)
            name = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
        }
        names[bundleId] = name
        return name
    }

    static func icon(_ bundleId: String) -> NSImage? {
        if let cached = icons[bundleId] { return cached }
        let image = url(bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleId] = image
        return image
    }

    /// Regular (Dock) apps that are running now, sorted by name, without Susu itself.
    static func running() -> [AppInfo] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [AppInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { continue }
            out.append(AppInfo(bundleId: id, name: app.localizedName ?? installedName(id) ?? id))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// 20-pt app icon with a letter fallback (prototype `.appico`).
struct AppIconView: View {
    let bundleId: String
    let fallbackName: String
    var size: CGFloat = 20

    var body: some View {
        if let image = AppCatalog.icon(bundleId) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Text(String(fallbackName.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(Palette.ink2)
                .frame(width: size, height: size)
                .background(Palette.bgFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
