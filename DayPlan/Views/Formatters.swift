import Foundation
import SwiftUI

enum DisplayFormatters {
    static let dayTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

extension View {
    @ViewBuilder
    func dayPlanInlineNavigationTitle() -> some View {
        #if os(macOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    func dayPlanNoAutocapitalization() -> some View {
        #if os(macOS)
        self
        #else
        self.textInputAutocapitalization(.never)
        #endif
    }

    @ViewBuilder
    func dayPlanURLKeyboard() -> some View {
        #if os(macOS)
        self
        #else
        self.keyboardType(.URL)
        #endif
    }

    @ViewBuilder
    func dayPlanAutocorrectionDisabled() -> some View {
        #if os(macOS)
        self
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
