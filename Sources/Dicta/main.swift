import DictaCore
import DictaIPC
import DictaRuntime
import Foundation

// The resident daemon. Thin by design: it wires the seams together and hands the socket to the
// actor. Every decision worth arguing about lives in DictaCore.
//
// Step 1 wires FAKE capture and FAKE transcription. There is no microphone in this build, and so
// no TCC prompt and no model load — the point is to prove the chord → dictactl → daemon → agterm
// path, and to prove the sanitiser holds, before any of that exists. Steps 2 and 3 replace the two
// fakes without touching anything else here.

let daemon = Daemon(
    capture: FakeCapture(),
    transcriber: FakeTranscriber(),
    filter: NoFilter(),
    injector: AgtermInjector()
)

let server = ControlServer { request in
    await daemon.handle(request)
}

do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("dicta: \(error)\n".utf8))
    exit(1)
}

FileHandle.standardError.write(Data("dicta: слушаю \(Paths.socket)\n".utf8))

// Shut down deliberately, so the socket file does not outlive the process and make the next start
// think a live daemon is already there.
var signalSources: [DispatchSourceSignal] = []

for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        server.stop()
        exit(0)
    }
    source.resume()
    // The source must outlive this loop iteration; parking it in a global keeps it alive.
    signalSources.append(source)
}

dispatchMain()
