import AppKit
import Foundation

// Declaring this process non-interactive immediately, before any Apple Event
// or window-server activity, is what keeps LaunchServices/RunningBoard from
// classifying this short-lived process as an interactive foreground app -
// which is what caused a transient Dock icon to appear and bounce each time
// /usr/bin/osascript sent an Apple Event on Retrace's behalf.
_ = NSApplication.shared.setActivationPolicy(.prohibited)

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

guard CommandLine.arguments.count > 1 else {
    writeStderr("usage: RetraceAppleScriptHelper <script-source>")
    exit(64)
}

let source = CommandLine.arguments[1]

guard let script = NSAppleScript(source: source) else {
    writeStderr("Failed to parse AppleScript source. (-2741)")
    exit(1)
}

var errorInfo: NSDictionary?
let result = script.executeAndReturnError(&errorInfo)

if let errorInfo {
    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
    let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? -1
    writeStderr("\(message) (\(number))")
    exit(1)
}

print(result.stringValue ?? "")
exit(0)
