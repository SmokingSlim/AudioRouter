import AppKit

let app = NSApplication.shared
let delegate = AudioRouterApp()
app.delegate = delegate
app.run()
