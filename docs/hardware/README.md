# Hardware notes

One file per device model, recording what we measured and what the app does
with it. Write them so they're useful to anyone with the same hardware.

This repo is public. Keep notes about the hardware and the environment
type, not about a particular person or unit:

- Keep: model names, vendor and product IDs, model UIDs, HID report
  descriptors, Mac model class, chip and macOS version, measured behaviour.
- Leave out: other devices on the test machine, device names that contain
  a person's name, serial numbers (replace with `<USB serial>`), USB
  location IDs, hostnames, user names, home-folder paths, network details.
- Raw probe logs list every audio device on the machine. They're
  gitignored (`boya-probe-*.log`). Don't commit them. Copy only the lines
  you need, and clean them first.
