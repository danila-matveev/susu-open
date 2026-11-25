// Test seams for the screens: "now" and the user name. Real values in the app; snapshot tests pin them so references do not rot.
import Foundation

enum AppClock {
    // ponytail: written only by tests, before any view exists; plain static is enough.
    nonisolated(unsafe) static var fixed: Date?
    /// Same idea for the greeting: tests must not render the real user name.
    nonisolated(unsafe) static var fixedFirstName: String?
    static var now: Date { fixed ?? Date() }
}
