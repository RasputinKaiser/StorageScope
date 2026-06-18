import Foundation

enum L10n {
    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .main)
    }
}
