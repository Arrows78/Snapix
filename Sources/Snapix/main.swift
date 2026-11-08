import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    let out = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
    exit(MainActor.assumeIsolated { SelfTest.run(outDir: out) })
}

if let i = CommandLine.arguments.firstIndex(of: "--check") {
    let rest = Array(CommandLine.arguments[(i + 1)...])
    exit(MainActor.assumeIsolated { DevChecks.run(rest) })
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
