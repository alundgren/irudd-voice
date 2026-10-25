# boya-probe

Finds out what a USB mic's mute button does on macOS. It watches one input
device and logs exact-zero audio, CoreAudio mute/volume/device changes, and
HID button presses. It opens no windows. Run it yourself in a terminal that
has microphone permission.

```sh
swift build -c release --package-path tools/boya-probe
tools/boya-probe/.build/release/boya-probe --list
tools/boya-probe/.build/release/boya-probe            # BY-GM18CU, 90 s
tools/boya-probe/.build/release/boya-probe --uid UID --seconds 60
```

The log is written to `boya-probe-<time>.log` in the current folder.
Results for the BOYA BY-GM18CU go in `docs/hardware/boya-by-gm18cu.md`.

The log lists every audio device on the machine, with names and UIDs, so it
can contain personal details. It's gitignored. See `docs/hardware/README.md`
before copying anything from it into the repo.
