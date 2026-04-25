import SwiftUI
import AppKit
import SyncCastDiscovery
import SyncCastRouter

@main
struct SyncCastApp: App {
    @State private var model = AppModel()

    init() {
        // Hide from Dock — menubar-only app.
        NSApp?.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MainPopover()
                .environment(model)
                .frame(width: 340)
        } label: {
            Label {
                Text("SyncCast")
            } icon: {
                Image(systemName: model.statusIconName)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
