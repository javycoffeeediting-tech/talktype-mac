import AppKit

// --selftest runs the speech and language models on a clip and quits, for checking a build
// on machines with nobody at the microphone.
if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
    let next = index + 1
    SelfTest.run(wav: next < CommandLine.arguments.count ? CommandLine.arguments[next] : nil)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
