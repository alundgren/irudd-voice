# irudd-voice

A macOS menu-bar dictation app for writing prompts to coding agents. Unmute
your mic, talk, mute it again, and clean text is pasted where your cursor
is. Speech recognition and text cleanup run on your Mac. Everything you say
is kept in one SQLite file, so the cleanup model can later be trained on
your own voice and words.

**Status:** early. This version has the menu-bar app, first-run setup, the
installer, mic capture (pick a mic; the mute button or a hotkey starts and
ends a thought), and saving: every thought's audio and Apple's text go into
the database, then Apple's text is pasted where your cursor was. Cleanup
and training come next.

## What you need

- A Mac with Apple silicon and macOS 27 or newer
- Xcode 27 or newer (from the App Store), opened once
- A USB mic. Notes on tested mics are in [docs/hardware](docs/hardware/).
- 16 GB of memory or more, for training the cleanup model later

## Install

```sh
git clone https://github.com/alundgren/irudd-voice.git
cd irudd-voice
./scripts/create-signing-certificate.sh   # once per Mac
./install.sh
```

What to expect:

1. **Certificate script:** creates a signing certificate in your login
   keychain and asks for your Mac login password once, in the terminal.
2. **install.sh:** checks your Mac, downloads Xcode's Metal toolchain the
   first time (several hundred MB), builds the app, and puts it in
   `~/Applications/irudd-voice.app`. It prints the certificate's SHA-1.
3. **First open:** setup asks for Microphone, Speech Recognition,
   Accessibility and Clipboard access (choose "Always allow"), and
   downloads Apple's English speech files.

If a check fails, install.sh says what's missing and leaves any installed
app as it was. To update, run `git pull` and `./install.sh` again.

## Signing certificate

macOS remembers permissions like Microphone and Accessibility per signing
certificate. If every build is signed with the same certificate, you grant
them once. If the certificate changes, macOS asks again. That's why
install.sh prints the SHA-1: if it's different from last time, expect the
permission prompts.

`scripts/create-signing-certificate.sh` makes a self-signed certificate
named **irudd-voice Local Signing** that's valid for 10 years, and lets
`codesign` use it without asking on every build. It isn't an Apple
Developer ID and isn't trusted by other Macs. It's only for building on
your own Mac.

To make it by hand instead:

1. Open **Keychain Access** and select **login**.
2. Choose **Keychain Access → Certificate Assistant → Create a
   Certificate…**
3. Name: `irudd-voice Local Signing`. Identity Type: **Self Signed Root**.
   Certificate Type: **Code Signing**. Tick **Let me override defaults**.
4. Set **Validity Period** to `3650` days. Accept the defaults for the
   remaining pages.

The first build after a manual setup shows a keychain dialog. Choose
**Always Allow**.

To use a different certificate, pass its name or SHA-1:

```sh
IRUDD_VOICE_SIGNING_IDENTITY="My Cert" ./install.sh
```

## Privacy

- Audio (16 kHz FLAC) and text are stored in
  `~/Library/Application Support/irudd-voice/voice.sqlite`. Nothing is
  deleted automatically. You can delete everything from Settings → Data.
  See [docs/database.md](docs/database.md).
- Speech recognition uses Apple's on-device engine. Cleanup uses a local
  model.
- **Labeling for training sends text to a cloud model.** When you start a
  training run, the transcripts (text only, never audio) go to Claude Code
  (Anthropic) or Codex (OpenAI) through your own subscription, so it can
  write what each one should have said. Nothing is sent at any other time.

## Licences

irudd-voice is MIT licensed (see [LICENSE](LICENSE)). It contains no code
from GPL projects.

Third-party parts used in later versions:

| Part | Licence | Used for |
| --- | --- | --- |
| [mlx-swift](https://github.com/ml-explore/mlx-swift), [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | MIT | Running the cleanup model |
| [mlx-lm](https://github.com/ml-explore/mlx-lm) | MIT | Training the cleanup model |
| Qwen3.5 (2B, 4B), Gemma 4 E2B | Apache-2.0 | Cleanup model weights, downloaded separately |

## Command line

The `irudd-voice` command reads the same database. It needs
[uv](https://docs.astral.sh/uv/).

```sh
cd cli
uv run irudd-voice stats
```

## Development

Everything runs locally. There's no CI.

```sh
./scripts/test.sh
```

This runs the logic tests (`swift test` in `Packages/IruddVoiceKit`), the
CLI tests against the app's real database code, the installer tests with
fake system tools, the signing-certificate test with a throwaway keychain,
and a build of the app. None of them open the app.
Checks that need the real app are done by hand.

| Folder | What's there |
| --- | --- |
| `App/` | The SwiftUI menu-bar app (Xcode project) |
| `Packages/IruddVoiceKit/` | App logic with no UI, tested headless |
| `cli/` | The `irudd-voice` command (Python, uv) |
| `tools/boya-probe/` | Command-line tool that finds out what a mic's mute button does |
| `docs/` | UX decisions and hardware notes |
| `tests/` | Installer and signing tests |
