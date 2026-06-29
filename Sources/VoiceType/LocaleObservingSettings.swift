import SwiftUI

/// Wrapper that re-renders SettingsView whenever the selected language changes.
/// Changing locale via .environment doesn't hot-swap unless the view is recreated,
/// so we use `id:` to force a full rebuild on language change.
struct LocaleObservingSettings: View {
    let vm: SettingsViewModel
    @ObservedObject var lm: LocalizationManager

    var body: some View {
        SettingsView(vm: vm)
            .environment(\.locale, lm.activeLocale)
            .environmentObject(lm)
            .id(lm.selectedID)   // force full rebuild on language change
    }
}
