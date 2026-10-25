# BOYA BY-GM18CU: what the mute button does

Tested 2026-10-25 on an Apple silicon MacBook Air (M5), macOS 27.0.1
(build 26A434), over USB, with `tools/boya-probe`. The terminal had microphone permission, so the zeros
below come from the mic, not from macOS blocking access.

## Result

**The mute button turns the audio into exact zeros. Nothing else changes.**

| Signal | Seen? |
| --- | --- |
| Exact-zero samples while muted | Yes, every time (4 of 4 mutes across two runs) |
| CoreAudio mute or volume property change | No. `mute[input,0]` stays 0, volume stays 1.000 |
| Device disappears or reappears | No |
| HID button press from the mic | No |

Details:

- **Muted:** every sample is exactly `0.0` (peak `-inf dBFS`, 100% zeros)
  until the button is pressed again. Unmuting brings audio back within one
  0.5 s log window.
- **Speaking:** about 0.1–1% of samples are exactly zero, but they never
  form a run of 20 ms or more.
- **Right before each mute:** a 32–33 ms zero run, then a little audio,
  then the long zero run. The button causes this short blip.
- **Stream start:** the first ~600 ms after the audio unit starts are exact
  zeros, even when the mic is not muted.
- **HID:** the BOYA's HID interface describes only consumer keys (volume
  up/down, play/pause, voice command, next/previous track) and two vendor
  reports. During the first runs, the probe's HID filter let the Mac's own
  sensors through (usage page `0x20`, a steady once-a-second pattern that
  ignored the mute presses). The BOYA's descriptor cannot send page `0x20`.
  The probe now filters by device.
- The device also lists a 2-channel output. It has no output jack, so the
  app ignores it.

## What the app uses

- **End of thought:** the mic counts as muted after **250 ms of
  continuous exact-zero samples**. Speech never came close to that (no run
  ≥ 20 ms), and the 33 ms button blip is ignored. A press ends the thought
  about a quarter of a second after the button.
- **Start of thought:** the first non-zero sample after a muted period.
  The 2 s pre-roll still applies.
- **Stream start:** ignore zeros for the first 1 s after the stream opens,
  so the ~600 ms of startup zeros don't look like a mute.
- **Permission first:** check microphone permission before treating zeros
  as muted, because a denied permission also gives all zeros.
- **Fallback:** the 5 s silence rule from the plan stays for mics that
  don't produce exact zeros.

## Device

```
Name:      BY-GM18CU
UID:       AppleUSBAudioEngine:JIAYZ:BY-GM18CU:<USB serial>:1
           (the serial part can differ between units; bind to the full UID)
Model UID: BY-GM18CU:0002:0005
Format:    1 channel, 48000 Hz, 32-bit float
USB vendor 0x0002, product 0x0005, manufacturer "JIAYZ"
HID report descriptor:
050c0901a1018501150025017501950209e909ea8102950409cd09cf09b609b58102950281010601ff854b7508950a09008103950a0900910285547508950a09008103950a09009102c0
```

## Probe log (90 s run, level lines and the Mac's sensor events removed)

```
[  0.090] property mute[input,0]: 0
[  0.090] property volume[input,0]: 1.000
[  0.090] property mute[input,1]: not present
[  0.090] property volume[input,1]: not present
[  0.090] property data source: not present
[  0.090] property is alive: 1
[  0.166] listening for 90 s.
[  1.171] EVENT zero run ended: 598 ms of exact zeros     <- stream start
[ 12.668] EVENT zero run ended: 33 ms of exact zeros      <- button blip
[ 25.168] EVENT zero run ended: 12800 ms of exact zeros   <- muted 12.3–25.1 s
[ 42.668] EVENT zero run ended: 32 ms of exact zeros      <- button blip
[ 57.168] EVENT zero run ended: 14759 ms of exact zeros   <- muted 42.2–57.0 s
[ 90.171] ---- summary ----
[ 90.171]   at 71.0 s: 19178 ms                           <- muted until the end
[ 90.172] CoreAudio property changes: 0
```

A 10 s run before it showed the same pattern: muted 3.4–6.2 s
(2783 ms of zeros, after a 33 ms blip), muted again from 8.9 s, no
property changes and no HID events.
