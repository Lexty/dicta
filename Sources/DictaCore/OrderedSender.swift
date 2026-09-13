import Foundation

// The setup window's requests, sent in the order the person made them (D27, D31).
//
// The menu sends every other command on a thread of its own, and must: a `stop` holds its caller
// for the length of a recognition, and an `Abort` queued behind it would wait for the very thing it
// is meant to cut short. The setup window's requests cannot share that rule. Two clicks on a fresh
// screen -- "Set up dictation", then "Use only with agterm" -- would be two threads racing to the
// socket, and the daemon's handler lock orders ARRIVALS, not clicks: a first thread slow to
// connect lets the second choice land first and the first one overwrite it, persisted. So the
// window's requests, its close and its becoming key included, go through one of these, and nothing
// else does.

/// Delivers items one at a time, in the order they were enqueued, off the caller's thread.
///
/// The worker is a real `Thread`, for the reason `MenuWorld.system`'s `offMain` gives (in
/// `DictaMenu`), started when an item arrives with none running and ending when it finds nothing
/// left: nothing waits on an empty queue, and nothing polls. At most one worker exists at a time,
/// which is the whole of the order.
public final class OrderedSender<Item: Sendable>: @unchecked Sendable {
    private let name: String
    private let deliver: @Sendable (Item) -> Void
    private let idle: @Sendable () -> Void
    private let lock = NSLock()
    /// **Guarded by `lock`.**
    private var pending: [Item] = []
    /// **Guarded by `lock`.** Whether a worker is running; set before it starts, cleared by the
    /// worker in the same acquisition in which it finds `pending` empty.
    private var draining = false

    /// `deliver` runs on the worker, once per item, and may block for as long as it needs to: later
    /// items wait behind it, which is the point. `idle` runs as a worker ends, after it has found
    /// nothing left, so a test can tell a drained sender from one still delivering.
    public init(name: String, deliver: @escaping @Sendable (Item) -> Void,
                idle: @escaping @Sendable () -> Void = {}) {
        self.name = name
        self.deliver = deliver
        self.idle = idle
    }

    /// Queues `item` behind everything enqueued before it. Returns at once.
    public func enqueue(_ item: Item) {
        let startsWorker = lock.withLock { () -> Bool in
            pending.append(item)
            guard !draining else { return false }
            draining = true
            return true
        }
        guard startsWorker else { return }
        let worker = Thread { [self] in drain() }
        worker.name = name
        worker.start()
    }

    private func drain() {
        while let next = lock.withLock({ () -> Item? in
            guard !pending.isEmpty else {
                draining = false
                return nil
            }
            return pending.removeFirst()
        }) {
            deliver(next)
        }
        idle()
    }
}
