---
worth: yes
where: Sources/DictaRuntime/AudioCapture.swift:103
added: 2026-09-12
---
# a Bluetooth headset as the default input breaks capture, and the pre-built engine makes it stick

F10 in `AGENTS.md` describes the failure and three candidate fixes; none is chosen. With AirPods Max
as the default input, `start()` fails with `-10868` because the engine was built while the headset
ran at 48 kHz and the device is at 24 kHz by the time capture opens it. `InputDeviceIdentity` samples
before the flip, so it cannot see it. It repeats rather than passing: one attempt in six succeeds.

Settle it by a **hardware comparison of the candidates**, with a Bluetooth headset selected as the
input, not by reasoning:

1. retry once with a freshly built engine when `start()` fails with a format error;
2. build the converter from the HAL's nominal rate instead of the node's claimed format;
3. pin the current default input on the input unit with `kAudioOutputUnitProperty_CurrentDevice`
   (a probe already started and captured 16 384 frames that way, `AGENTS.md` F10).

Each candidate must be scored on:

- **repeated starts**, including a start after the headset has dropped back to output-only mode;
- **F4's chord budget.** A retry or a pin that costs tens of milliseconds on every chord is a
  regression even if it fixes the headset.

What acta contributes, and what it does not. acta pins its own capture device ("resolve then pin",
`~/dev/acta` `Sources/ActaKit/CaptureMicrophone.swift`, commit `0c531d7`), so an unspecified device
never silently follows a headset. That is a **selection policy**. It is not evidence that pinning
fixes a format mismatch: acta records through ScreenCaptureKit rather than AVAudioEngine and never
met the 48 → 24 kHz flip. Pinning the default can still pick AirPods that fail to start.

If the chosen fix needs HAL property listeners, acta's `AudioHALListening` and
`CoreAudioDeviceDirectory` tests are worth reading first, for the cases they already cover:

- partial registration, and a removal that fails;
- stale callbacks;
- telling an absent device apart from an unreadable one.

A standing device directory in dicta is not justified by this item alone.

Agreed with Codex on 2026-09-12 while reviewing what dicta should inherit from acta's `dev` branch.
