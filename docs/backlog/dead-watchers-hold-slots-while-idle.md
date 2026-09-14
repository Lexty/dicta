---
worth: yes
where: Sources/DictaIPC/ControlSocket.swift:740
added: 2026-09-14
---
# a watcher whose client died keeps its slot for as long as the daemon is idle

`ControlServer.stream(to:watcher:)` reads nothing after the `watch` handshake and discovers a peer
that went away only when a write fails. An idle daemon publishes nothing, so it writes nothing, and a
dead watcher's thread stays parked on its outbox and keeps its entry in `watchers` indefinitely. After
`ControlTimeouts.maxWatchers` (4) such deaths, every new watcher is refused.

Observed on 2026-09-14, driven by `setup-window-constraint-loop-crash`: after a daemon restart the
menu crashed four times in a row, `lsof` showed four accepted connections on `control.sock` in the
daemon with no live process on the other end, and the next menu drew "dicta refused to be watched:
dicta is already serving 4 watchers" with "dicta is not answering". Only a daemon restart freed the
slots. The same happens with any watcher that dies without its socket being written to: a killed
`dictactl watch`, or a menu relaunched by `launchctl kickstart -k` while nothing is dictating.

The refusal is also misdrawn: the header says "dicta is not answering" for a daemon that answered,
which `ControlClient.ClientError.watchRefused` exists to keep apart.

The fix detects the close without waiting for a write, for example by polling the client descriptor
for `POLLHUP`/readable-EOF while the writer waits on the outbox, and removes the watcher then. Test:
a watcher whose client closes while the daemon publishes nothing frees its slot, and a fifth watcher
is then accepted.
