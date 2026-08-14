import DictaCore
import DictaIPC
import DictaRuntime
import Foundation

// The resident daemon. Wiring only -- every decision it performs is a pure value in DictaCore and
// every effect leaves through a seam in DictaRuntime.
//
// What is wired here today is step 1 of §10 with a real microphone in front of it: a chord reaches
// `dictactl`, the daemon resolves the pane from the live tree, AVAudioEngine records at 16 kHz
// mono, and `agtermctl session type` puts the transcript into the input line as ONE line with
// single spaces. Recognition is still `FakeTranscriber`, so what arrives is the canned transcript
// -- deliberately, until Task 10: if the sanitiser were ever bypassed, that transcript's newline
// would submit the prompt on the spot (D8).
//
// Task 10 replaces exactly one line of this file: `FakeTranscriber` becomes `ParakeetTranscriber`.
// Nothing else about the wiring changes, which is the whole point of the seams.

let usage = """
usage: Dicta [options]

options:
  --control <path>         dicta's own control socket (defaults to the one under
                           ~/Library/Application Support/dev.personal.dicta)
  --agterm-socket <path>   agterm's control socket, when it is not the default one
  --help                   print this
"""

var controlSocket = Paths.current.socket.path
var agtermSocket: String?

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    func value(_ flag: String) -> String {
        guard let next = arguments.first else {
            FileHandle.standardError.write(Data("dicta: \(flag) needs a value\n".utf8))
            exit(2)
        }
        arguments.removeFirst()
        return next
    }
    switch argument {
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--control":
        controlSocket = value("--control")
    case "--agterm-socket":
        agtermSocket = value("--agterm-socket")
    default:
        FileHandle.standardError.write(Data("dicta: unknown option \(argument)\n".utf8))
        exit(2)
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("dicta: \(message)\n".utf8))
}

// Diagnosed here rather than on the first chord (§7): every chord is dead until it is fixed, and
// discovering that by pressing one and getting nothing is the failure this check exists to avoid.
guard let agtermctl = Agterm.locate() else {
    log("agtermctl is not installed -- dicta cannot reach agterm, so nothing would be delivered")
    exit(EXIT_FAILURE)
}

// An immutable copy: the provider closure outlives the argument parsing, and a top-level `var` in a
// main.swift is main-actor state.
let defaultAgtermSocket = agtermSocket

// The microphone. It belongs to this bundle's TCC grant and to nothing else (D11, invariant 8):
// `dictactl` links none of this, and a second binary opening the device would fracture the grant.
let capture = AudioCapture()

let daemon = Daemon(
    configuration: Daemon.Configuration(socketPath: controlSocket),
    capture: capture,
    transcriber: FakeTranscriber(),
    filter: NoFilter(),
    // The real record (§9), created on demand under the support directory. Even with capture and
    // recognition faked, every attempt lands here -- which is what makes `dictactl last` work
    // today, and what makes invariant 10 observable before the microphone exists.
    history: FileHistory(),
    clock: SystemClock(),
    // One `Agterm` per attempt, addressed at the agterm the chord fired in ($AGT_SOCKET, F3). The
    // command line's `--agterm-socket` is the fallback for a keymap that does not pass it.
    terminal: { requested in
        let agterm = Agterm(executable: agtermctl, agtermSocket: requested ?? defaultAgtermSocket)
        return Daemon.Terminal(resolver: agterm, injector: agterm, notifier: agterm)
    }
)

do {
    try daemon.start()
} catch {
    // Includes §7's "second daemon instance attempted" row: a live socket means a live daemon, and
    // two of them would fight over one microphone.
    log("\(error)")
    exit(EXIT_FAILURE)
}

log("listening on \(controlSocket)")
log("step 2: capture is REAL; recognition is a FAKE -- every dictation delivers the canned "
    + "transcript")

// Asked for at startup, not on the first chord (§7's spirit and D11's): the TCC dialog is a modal
// the user reads at their own pace, and a chord that waits for it spends its 150 ms budget on a
// dialog and then faults. Reported loudly either way, so a denied microphone is visible before the
// first chord rather than during it.
log("microphone: \(capture.access.rawValue)")
capture.requestAccessIfNeeded { access in
    log("microphone: \(access.rawValue)")
    if access != .granted {
        log("dicta cannot record until the microphone is granted in System Settings > Privacy & "
            + "Security > Microphone")
    }
}

// SIGTERM is what a LaunchAgent sends on unload, and SIGINT is what `Scripts/run.sh` gets from a
// terminal. Both must remove the socket file, or the next start would find a path with nobody
// behind it and `dictactl` would report a crashed daemon that never crashed.
var signalSources: [any DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        log("stopping")
        daemon.stop()
        exit(0)
    }
    source.resume()
    // Retained deliberately: a cancelled source stops delivering, and the daemon runs until killed.
    signalSources.append(source)
}

// `RunLoop.main.run()` rather than `dispatchMain()`, and the difference is not cosmetic: sleep is
// announced through `NSWorkspace`'s notification centre, which needs a live run loop on the main
// thread to receive it. Under `dispatchMain()` there is none, so `willSleepNotification` would
// never arrive and §7's sleep row would silently stop holding -- the machine would suspend
// mid-sentence and the attempt would come back looking like a quiet room (invariant 7). The main
// run loop serves the main dispatch queue too, so the signal sources above still fire.
RunLoop.main.run()
