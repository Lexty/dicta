import DictaCore
import DictaIPC
import Foundation

// The client agterm's keymap invokes. It must stay tiny: it links DictaCore and Foundation and
// nothing else, so its cold start stays in the low milliseconds, and it NEVER touches the
// microphone — the TCC grant belongs to the daemon's signed bundle alone.
//
// Usage (from keymap.conf; always an absolute path, never through a login shell):
//   dictactl toggle --session "$AGT_SESSION_ID" --socket "$AGT_SOCKET" --mode clean|raw
//   dictactl start --session "$AGT_SESSION_ID" --socket "$AGT_SOCKET"
//   dictactl stop --mode clean|raw
//   dictactl abort
//   dictactl status
//   dictactl last [--raw]

let arguments = Array(CommandLine.arguments.dropFirst())

func value(of flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("dictactl: \(message)\n".utf8))
    // A failure the user cannot see is the failure mode that matters here: they pressed stop,
    // nothing happened, and they keep talking into a recording that will hit the duration cap. So
    // say it out loud on the desktop, not only on a stderr nobody is reading.
    notify(message)
    exit(code)
}

/// Deliberately re-implemented here rather than reused from DictaRuntime: this path runs when the
/// daemon is unreachable, so it must not depend on anything the daemon owns.
func notify(_ message: String) {
    let candidates = ["/opt/homebrew/bin/agtermctl", "/usr/local/bin/agtermctl"]
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["notify", message, "--title", "dicta"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

guard let command = arguments.first else {
    fail("нужна команда: start | stop | abort | status | last", code: 2)
}

var request: Request
switch command {
case "start":
    guard let session = value(of: "--session"), !session.isEmpty else {
        fail("start требует --session (передайте \"$AGT_SESSION_ID\")", code: 2)
    }
    request = Request(cmd: "start", sessionID: session, socket: value(of: "--socket"))
case "stop":
    let mode = value(of: "--mode").flatMap(StopMode.init(rawValue:)) ?? .clean
    request = Request(cmd: "stop", mode: mode)
case "toggle":
    // What the chords actually call. Start-or-stop is decided inside the daemon, atomically —
    // deciding it here would take two round trips with a race between them.
    guard let session = value(of: "--session"), !session.isEmpty else {
        fail("toggle требует --session (передайте \"$AGT_SESSION_ID\")", code: 2)
    }
    request = Request(
        cmd: "toggle",
        sessionID: session,
        socket: value(of: "--socket"),
        mode: value(of: "--mode").flatMap(StopMode.init(rawValue:)) ?? .clean
    )
case "abort":
    request = Request(cmd: "abort")
case "status":
    request = Request(cmd: "status")
case "last":
    request = Request(cmd: "last", raw: arguments.contains("--raw"))
default:
    fail("неизвестная команда \(command)", code: 2)
}

do {
    let response = try ControlClient.send(request)
    if let text = response.text { print(text) }
    else if let message = response.message { print(message) }
    else { print(response.state) }
    exit(response.ok ? 0 : 1)
} catch let error as ControlClient.Failure {
    fail("\(error)", code: 3)
} catch {
    fail("\(error)", code: 3)
}
