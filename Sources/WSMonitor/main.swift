import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // LSUIElement equivalent: no Dock icon
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.title = "WS …"
let menu = NSMenu()
menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
statusItem.menu = menu
app.run()
