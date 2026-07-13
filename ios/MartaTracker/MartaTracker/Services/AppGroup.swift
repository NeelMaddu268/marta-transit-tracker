import Foundation

/// Shared container between the app and the widget extension. Commutes live in
/// these defaults so the widget can read them.
enum AppGroup {
    static let id = "group.com.personal.martatracker"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: id) ?? .standard
    }
}
