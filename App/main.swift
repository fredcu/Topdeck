// SPDX-License-Identifier: MIT
import AppKit

// LSUIElement (project.yml) makes this an accessory app: no Dock icon, no menu bar,
// and the notch panel never steals focus. First efficiency lever.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
