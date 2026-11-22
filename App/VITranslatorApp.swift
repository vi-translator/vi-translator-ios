import SwiftUI

@main
struct VITranslatorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.kit, Kit(dark: model.dark))
                .environment(\.layoutDirection, I18n.rtl ? .rightToLeft : .leftToRight)
                .environment(\.locale, Locale(identifier: model.uiLang))
                .preferredColorScheme(model.dark ? .dark : .light)
                .id(model.uiLang)
        }
        .onChange(of: phase) { p in model.scene(p) }
    }
}
