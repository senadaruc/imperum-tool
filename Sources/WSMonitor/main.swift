import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // LSUIElement equivalent: no Dock icon
let controller = AppController()
controller.start()
app.run()
