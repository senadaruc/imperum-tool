import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular) // Dock icon + window + menu-bar item (discoverable)
let controller = AppController()
controller.start()
app.run()
