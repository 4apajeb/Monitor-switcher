import AppKit

// Command-line helpers (also handy for emergencies):
//   MonitorSwitcher --restore   turn every monitor back on and send it to the Mac input
//   MonitorSwitcher --probe     print what the app sees: displays, DDC status, input devices
let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--restore") {
    CLI.restore()
    exit(0)
}
if arguments.contains("--probe") {
    CLI.probe()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
