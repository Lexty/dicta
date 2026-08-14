import DictaCore
import DictaIPC
import Foundation

// The client every chord spawns. It links DictaCore and DictaIPC and nothing else: no AVFoundation,
// no CoreML, no AppKit, and it never opens the microphone (D11, D12, invariant 8). Task 12 asserts
// that at the linker level, because a budget with no check drifts.
//
// Everything it decides lives in `ClientCommand` in DictaCore, where a test can reach it. What is
// left here is the part that cannot be pure: the socket, the desktop notification, and the exit
// code.
//
//     dictactl toggle --mode clean --session "$AGT_SESSION_ID" --socket "$AGT_SOCKET"
//     dictactl abort
//     dictactl status
//
// See `docs/keymap.snippet.conf`, which is checked against `ClientCommand.parse` by a test.

/// Says it out loud on the desktop, not only on a stderr nobody is reading (§7).
///
/// This is deliberately re-implemented here rather than reused from `DictaRuntime`: it runs
/// precisely when the daemon is unreachable, so it must not depend on anything the daemon owns —
/// and `dictactl` does not link `DictaRuntime` in the first place (D12).
func notify(_ message: String, agtermSocket: String?) {
    let candidates = ["/opt/homebrew/bin/agtermctl", "/usr/local/bin/agtermctl"]
    if let executable = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
    }) {
        var arguments = ["notify", "--title", "dicta"]
        // Addressing the agterm the chord was pressed in, rather than whichever instance answers
        // the default socket first. Before `--`, because everything after it is positional.
        if let socket = agtermSocket { arguments += ["--socket", socket] }
        // After `--`: a message beginning with a dash is a message, not a flag, and this notifier
        // runs precisely when something has already gone wrong.
        arguments += ["--", message]
        if run(executable, arguments) { return }
    }
    // agterm may be the thing that is broken. osascript is always there, and a failure the user
    // cannot see is the failure that matters here.
    let script = "display notification \(quoted(message)) with title \"dicta\""
    _ = run("/usr/bin/osascript", ["-e", script])
}

/// An AppleScript string literal: a raw line break inside one is a syntax error, and the message
/// this carries is often a multi-line reason.
func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n") + "\""
}

/// The ceiling on one notifier subprocess, and the grace after SIGTERM before SIGKILL.
///
/// Both halves matter, because this runs on the keypress's own process. `agtermctl` is reached
/// through agterm's control socket, and agterm being the thing that is wedged is not a hypothetical
/// here — this notifier exists precisely because something has already gone wrong. An unbounded
/// `waitUntilExit` then leaves the chord's process alive for ever, with the fallback that would
/// actually have reached the user (`osascript`) never tried. Three seconds is well past the
/// milliseconds a healthy `agtermctl notify` costs (F4 puts a whole `tree --json` at 38 ms) and
/// well inside the attention of somebody who has pressed a chord and seen nothing happen.
let notifyDeadline: TimeInterval = 3
let notifyGrace: TimeInterval = 1

/// Runs one short-lived helper and says whether it succeeded, never blocking beyond `deadline`.
///
/// Neither pipe is read — both ends are `/dev/null` — so this is free of the trap `ProcessRunner`
/// documents in `DictaRuntime`, where a killed child leaves a grandchild holding the write end and
/// the read never ends. Here the only thing waited on is the child's own exit.
@discardableResult
func run(_ executable: String, _ arguments: [String],
         deadline: TimeInterval = notifyDeadline) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    // Set before `run`, so a child that exits immediately still signals: `waitUntilExit` is what
    // this replaces, and it is the call that cannot be bounded.
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
    } catch {
        return false
    }
    guard finished.wait(timeout: .now() + deadline) == .success else {
        // SIGTERM first, then SIGKILL: a wedged helper that ignores the polite signal must not
        // outlive the keypress that spawned it, and the caller falls through to `osascript`.
        process.terminate()
        if finished.wait(timeout: .now() + notifyGrace) != .success, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        return false
    }
    return process.terminationStatus == 0
}

/// `notifying: false` for the verbs somebody is already watching (`Command.isTypedByHand`): stderr
/// is in front of them, and a desktop notification about a daemon that is merely BUSY is a false
/// alarm §7 would rather not have taught them to ignore.
func fail(_ message: String, code: Int32, agtermSocket: String? = nil,
          notifying: Bool = true) -> Never {
    FileHandle.standardError.write(Data("dictactl: \(message)\n".utf8))
    if notifying { notify(message, agtermSocket: agtermSocket) }
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--help" || arguments.first == "-h" {
    print(ClientCommand.usage)
    exit(ClientCommand.ExitCode.ok)
}

let invocation: ClientCommand.Invocation
switch ClientCommand.parse(arguments) {
case let .success(parsed):
    invocation = parsed
case let .failure(error):
    // A usage error is almost always a keymap line that no longer matches this build, and the user
    // finds out by pressing a chord and getting nothing. That deserves the same loudness as an
    // unreachable daemon.
    fail("\(error)", code: ClientCommand.ExitCode.usage)
}

let controlSocket = invocation.controlSocket ?? Paths.current.socket.path

do {
    let response = try ControlClient.send(invocation.request, to: controlSocket)
    if let text = response.text {
        print(text)
    } else if let message = response.message {
        print(message)
    } else {
        print(response.state.rawValue)
    }
    // A rejection is announced by the daemon, with its sound and its notification (§6). The client
    // only carries the exit code, or the user would hear about it twice.
    exit(response.kind == .rejected ? ClientCommand.ExitCode.rejected : ClientCommand.ExitCode.ok)
} catch let error as ControlClient.ClientError {
    fail("\(error)",
         code: ClientCommand.ExitCode.unreachable,
         agtermSocket: invocation.request.agtermSocket,
         notifying: !invocation.request.cmd.isTypedByHand)
} catch {
    fail("\(error)",
         code: ClientCommand.ExitCode.unreachable,
         agtermSocket: invocation.request.agtermSocket,
         notifying: !invocation.request.cmd.isTypedByHand)
}
