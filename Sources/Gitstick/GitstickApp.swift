import AppKit
import SwiftUI

@main
struct GitstickApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Menubar-only: no Dock icon, no app menu. (The bundled .app also sets LSUIElement.)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
