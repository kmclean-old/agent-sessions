import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceMode: AppearanceMode = .system

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            HarnessIntegrationsView(store: store)
                .tabItem { Label("Harness Integrations", systemImage: "terminal") }
        }
        .frame(width: 680, height: 540)
    }
}
