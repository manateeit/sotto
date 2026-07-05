import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService.mainApp` (DESIGN.md §5 M3). No helper bundle
/// needed — the main app registers itself.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister; throws the underlying SMAppService error so the caller
    /// can surface it. Safe to call repeatedly.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}
