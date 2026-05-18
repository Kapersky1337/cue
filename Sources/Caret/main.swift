import Cocoa

// Redirect NSLog/stderr to a fixed file so we can tail it from anywhere.
// /tmp/cue.log is wiped on every macOS reboot and is otherwise stable.
freopen("/tmp/cue.log", "a+", stderr)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
