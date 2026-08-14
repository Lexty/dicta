import DictaCore
import DictaIPC
import DictaRuntime
import Foundation

// The resident daemon. Wiring only -- every decision it performs is a pure value in DictaCore and
// every effect leaves through a seam in DictaRuntime.
//
// What is wired here is steps 1 and 2 of §10, whole: a chord reaches `dictactl`, the daemon
// resolves the pane from the live tree, AVAudioEngine records at 16 kHz mono, Parakeet TDT 0.6B v3
// recognises it on the ANE, and `agtermctl session type` puts the text into the input line as ONE
// line with single spaces. Both fakes are gone from this file, which is the whole point of the
// seams: the change from Task 6's wiring is two constructor arguments and a warm-up.
//
// The warm-up is not decoration. D10's normative half is that no model loads on the hot path, so
// the four `.mlmodelc` bundles are loaded and one dummy inference is run BEFORE the first chord --
// and when they cannot be, that is said here, loudly, rather than discovered by a chord that has
// already thrown away an utterance.

let usage = """
usage: Dicta [options]

options:
  --control <path>         dicta's own control socket (defaults to the one under
                           ~/Library/Application Support/dev.personal.dicta)
  --agterm-socket <path>   agterm's control socket, when it is not the default one
  --fetch-models           download the recognition models, then exit
  --help                   print this
"""

var controlSocket = Paths.current.socket.path
var agtermSocket: String?
var fetchModels = false

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    /// An empty value is refused rather than taken, and that is the client's rule arriving through
    /// the other door (`ClientCommand.parse`): an unset environment variable expands to an empty
    /// string, not to an absent argument, so a wrapper passing `--agterm-socket "$AGT_SOCKET"` with
    /// nothing in it would otherwise splice `--socket ""` into every `agtermctl` call the daemon
    /// makes — every chord refused, for a reason no message names.
    func value(_ flag: String) -> String {
        guard let next = arguments.first else {
            FileHandle.standardError.write(Data("dicta: \(flag) needs a value\n".utf8))
            exit(2)
        }
        arguments.removeFirst()
        guard !next.isEmpty else {
            FileHandle.standardError.write(Data("dicta: \(flag) was given an empty value\n".utf8))
            exit(2)
        }
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
    case "--fetch-models":
        fetchModels = true
    default:
        FileHandle.standardError.write(Data("dicta: unknown option \(argument)\n".utf8))
        exit(2)
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("dicta: \(message)\n".utf8))
}

// The one-shot fetch, before anything else is built: it downloads and exits, and a daemon that also
// bound the socket would be a second instance for the duration (§7).
//
// It is a separate invocation rather than something the daemon does at start-up on its own, and
// that is a deliberate refusal: the LaunchAgent starts at login, on whatever network the laptop
// woke up on, and pulling six hundred megabytes there without being asked is not a thing to do
// quietly.
if fetchModels {
    log("fetching the recognition models into \(ParakeetModels.directory.path) "
        + "-- this is large and slow, and it is done once")
    do {
        try ParakeetModels.fetch { log($0) }
    } catch {
        log("\(error)")
        exit(EXIT_FAILURE)
    }
    if let trouble = ParakeetModels.selfCheck() {
        // A download that reported success while leaving the directory incomplete is worse than one
        // that failed, so the check runs again over the result rather than trusting the exit code.
        log("\(trouble)")
        exit(EXIT_FAILURE)
    }
    // Naming the restart is not politeness, it is the other half of the remedy. A daemon that
    // started before the models existed has already published the load failure, and it never
    // retries -- loading on demand when a chord arrives is the one thing D10 forbids normatively.
    // So the fresh-install order in the README (install, then fetch) leaves a running daemon that
    // will refuse every dictation until it is restarted, and the user would discover that by
    // pressing a chord and losing an utterance.
    log("the recognition models are staged. A daemon that started before them has already given up "
        + "on loading, so restart it: "
        + "launchctl kickstart -k gui/\(getuid())/\(Paths.bundleID)")
    exit(0)
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

// Recognition (D10). Constructed cold and warmed below, after the socket is up: the load takes
// seconds, and spending them before binding would make every chord in that window report a daemon
// that is not there -- which is what `dictactl` says when nothing answers the socket.
let transcriber = ParakeetTranscriber()

// The Tier 0 replacement dictionary (D9a). Constructed once, read per attempt: it is the one file a
// user edits between dictations, and §7 forbids it from ever blocking one.
let dictionaryFile = FileDictionary()

let daemon = Daemon(
    // The parked target's path is spelled here rather than defaulted inside `Configuration`: it
    // names a file a live daemon writes, and a default would have every test that forgot the
    // parameter reach into the real one.
    configuration: Daemon.Configuration(
        socketPath: controlSocket,
        activeTargetFile: Paths.current.support.appendingPathComponent("active-target.json")
    ),
    capture: capture,
    transcriber: transcriber,
    filter: NoFilter(),
    // The real record (§9), created on demand under the support directory. Every attempt lands here
    // before its keystrokes are attempted, which is the only route by which recognised text
    // survives a delivery failure (invariant 10) -- and what `dictactl last` reads back.
    history: FileHistory(),
    clock: SystemClock(),
    // The Tier 0 dictionary (D9a), re-read per attempt so that editing a rule and dictating once is
    // the whole loop -- no restart, and no chance of testing a rule against the previous file.
    dictionary: { dictionaryFile.load() },
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

// The startup self-check, and then the warm-up, on a thread of their own.
//
// A thread rather than a `Task`: the load blocks (see `Blocking` in DictaRuntime), and blocking a
// cooperative thread on Darwin's non-overcommit pool is the deadlock CLAUDE.md records about the
// control socket. It is also why this does not hold up the socket -- a chord arriving mid-load
// waits for it inside `ParakeetTranscriber` and then recognises, rather than losing the utterance.
// Missing models go through `prepare()` like any other load failure rather than being caught here
// and returned on. `ParakeetEngine.loadModels` runs the same self-check and throws `modelsMissing`,
// which `prepare()` publishes as `.failed` -- so every later chord fails with the sentence that
// names `Dicta --fetch-models`. Returning early left the transcriber `.cold`, and a chord then hit
// `notPrepared`: "this is a wiring bug in dicta, not a setting", in the desktop notification AND in
// the record, for what is simply the state of a fresh install that has not fetched yet.
let warmUp = Thread {
    do {
        let summary = try transcriber.prepare()
        log(String(format: "recognition is warm: models loaded in %.1f s, dummy inference %.2f s",
                   summary.loadSeconds, summary.warmUpSeconds))
        if let warmUpError = summary.warmUpError {
            // The models are loaded, so dictation is not refused -- but the first real utterance
            // may now pay the ANE compilation the dummy inference exists to absorb, and that is
            // worth knowing before it is blamed on the recogniser being slow.
            log("the warm-up inference failed (\(warmUpError)) -- the first dictation may be slow")
        }
    } catch {
        log("recognition is UNAVAILABLE -- \(error)")
    }
}
warmUp.name = "dev.personal.dicta.warmup"
warmUp.start()

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
