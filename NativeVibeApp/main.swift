import AppKit

NativeVibeRuntime.markStandalone()

let app = NSApplication.shared
let delegate = NativeVibeAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()