import Foundation

/// Keys for values stored in UserDefaults (read with @AppStorage in views).
enum SettingsKey {
    static let tileSize = "tileSize"
    static let autoHide = "autoHide"
    static let showTrash = "showTrash"
    static let appRows = "appRows"
    static let appZoom = "appZoom"          // 1.0 = off
}

enum SettingsDefault {
    static let tileSize: Double = 48
    static let autoHide = true
    static let appRows = 1
    static let appZoom = 1.6
}

extension UserDefaults {
    var tileSize: Double {
        object(forKey: SettingsKey.tileSize) as? Double ?? SettingsDefault.tileSize
    }
    var appRows: Int {
        object(forKey: SettingsKey.appRows) as? Int ?? SettingsDefault.appRows
    }
    var autoHide: Bool {
        object(forKey: SettingsKey.autoHide) as? Bool ?? SettingsDefault.autoHide
    }
}
