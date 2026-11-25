// «Запуск при входе»: registers the app as a login item (macOS 13+ SMAppService).
import ServiceManagement

public enum LaunchAtLogin {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters the main app. Throws if the system refuses (e.g. unsigned dev build).
    public static func set(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        }
    }
}
