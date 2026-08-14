import DictaCore
import DictaIPC
import DictaRuntime
import Foundation

// The resident daemon. Wiring only — every decision it performs is a pure value in DictaCore and
// every effect goes through a seam in DictaRuntime.
//
// Task 1 is scaffolding: the target exists so the graph is real and `dictactl` can be checked
// against it, but there is no socket server yet. Task 6 makes this an actual daemon.

FileHandle.standardError.write(Data(
    "dicta \(DictaCore.version): the daemon is not implemented yet (scaffolding only)\n".utf8
))
exit(EXIT_FAILURE)
