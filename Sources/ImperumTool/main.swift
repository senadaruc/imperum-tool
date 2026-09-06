import AppKit

LegacyMigration.run()
let app = NSApplication.shared
app.setActivationPolicy(.regular) // Dock icon + window + menu-bar item (discoverable)
let controller = AppController()
app.delegate = controller          // enables Dock-icon click to reopen the window
controller.start()
app.run()
