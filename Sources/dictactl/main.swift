import DictaCore
import DictaIPC
import Foundation

// The client every chord spawns. It links DictaCore and DictaIPC and nothing else: no AVFoundation,
// no CoreML, no AppKit, and it never opens the microphone (D11, D12, invariant 8). Task 12 asserts
// that at the linker level, because a budget with no check drifts.
//
// Task 1 is scaffolding; Task 4 implements the verbs.

FileHandle.standardError.write(Data(
    "dictactl \(DictaCore.version): not implemented yet (scaffolding only)\n".utf8
))
exit(EXIT_FAILURE)
