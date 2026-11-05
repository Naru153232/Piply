import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    static let defaultsKey = "appLanguage"

    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .japanese: return "日本語"
        case .english: return "English"
        }
    }

    static var saved: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .japanese
    }
}

enum L10n {
    static func text(_ japanese: String, _ english: String) -> String {
        AppLanguage.saved == .japanese ? japanese : english
    }
}

struct AppLanguagePicker: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.japanese.rawValue

    var body: some View {
        Picker(L10n.text("言語", "Language"), selection: $language) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.displayName).tag(language.rawValue)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 150, alignment: .trailing)
    }
}
