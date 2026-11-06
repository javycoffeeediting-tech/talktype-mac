import AppKit

// --selftest runs the speech and language models on a clip and quits, for checking a build
// on machines with nobody at the microphone.
if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
    let next = index + 1
    SelfTest.run(wav: next < CommandLine.arguments.count ? CommandLine.arguments[next] : nil)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)

    // The application only holds its delegate weakly.
    withExtendedLifetime(appDelegate) {
        application.run()
    }
}
