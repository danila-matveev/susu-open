// SusuCore: logic without UI. Modules live in subfolders (spec 2.3).
// Mac-only modules (Hotkey, Insert, Context, call capture) go behind `#if os(macOS)`;
// everything else must keep building for iOS (CI checks it).
public enum Susu {
    public static let version = "0.0.1"
    public static let bundleID = "app.susu.Susu"
}
