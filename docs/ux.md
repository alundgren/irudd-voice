# UX decisions

## Look

Native macOS. Standard SwiftUI controls, system fonts and SF Symbols, and
the system accent colour. Follows light and dark mode. The chosen mock is
the dark native version (Scope tab `irudd-voice-ui-mocks-dark`).

## The mic stays open while the switch is on

The app ends a thought when the mic's mute button makes the audio go
silent (see [hardware/boya-by-gm18cu.md](hardware/boya-by-gm18cu.md)).
To notice that, it has to keep listening. So while the switch in the panel
is on, the mic stream is open and macOS shows its orange microphone
indicator in the menu bar the whole time. Nothing is saved until you unmute and talk.

Switching the app off closes the mic stream. The orange indicator goes away, and
nothing is recorded until you switch it on again.

## Menu-bar states

| State | Icon | Meaning |
| --- | --- | --- |
| Not set up | `mic.badge.plus` | First-run setup isn't finished; the panel shows a Set Up button |
| Off | `mic.slash` | Switched off; mic closed |
| Ready | `mic` | Listening, waiting for you to unmute |
| Hearing you | `mic.fill` | Recording a thought |
| Cleaning up | `sparkles` | Turning the thought into clean text |
| Text waiting | `text.badge.plus` | Text is ready but you moved away; go back to paste it |
| Mic missing | `mic.badge.xmark` | The pinned mic isn't connected; the app waits |

Not set up wins over everything, then Off, then Mic missing, then the
current activity.

## First run

Setup opens in front of other apps when the app starts and setup isn't
finished. If you close it, the panel shows a **Set Up irudd-voice…**
button and the status says Not set up. The on/off switch appears once
setup is done.

## Preview while talking

Three choices in the panel and Settings: **Off** (nothing on screen; the
default), **Dot** (a small dot while hearing you) and **Transcript**
(the live transcript, mostly for testing).

## Picking a mic

The mic list is in the panel and in Settings → General, since that's
where people look first. Picking a mic is the second step of setup. The
pinned mic has a checkmark and a small level bar while the app hears it.
If it's unplugged it stays in the list as "not connected", and the app
waits for that exact mic.

## Starting and ending a thought

- **Mute button** (mics that go silent when muted, like the BOYA):
  unmuting starts a thought, muting ends it. Silence never ends it. A
  silence timeout was tried and felt stressful: you couldn't stop to think
  without your prompt being cut in two.
- **Hotkey** (Settings → Hotkeys, none by default): starts a thought or
  ends the current one. Meant for mics without a mute button, like
  AirPods. A thought started this way also ends after 5 seconds of
  silence.
- Every thought keeps the 2 seconds before it started, so the first word
  isn't cut off.
- Unplugging the mic, switching mics or switching the app off ends the
  thought and keeps what was heard.

## Preview while talking: placement

The preview floats just above the bottom of the screen, centred. It never
takes focus or clicks. In Transcript mode the final text stays for 4
seconds after a thought ends.

## Pasting

- The text goes to the app **and text box** that had focus when the
  thought ended. If you switched app, or switched to another text box or
  conversation in the same app, nothing is pasted anywhere. The icon shows
  **Text waiting**, and the panel offers **Paste Here** (closes the panel
  and pastes where your cursor is), **Copy** and **Throw Away**.
- The text goes through the clipboard and ⌘V. The old clipboard (text,
  images, anything) is put back 1 second later, unless you copied
  something new in the meantime. The dictation is marked concealed and
  transient, so clipboard managers like Raycast skip it.
- The app waits until you let go of held keys before pressing ⌘V, and uses
  the key that types V on your keyboard layout.
- Without "Always allow" clipboard access the old clipboard couldn't be put
  back, so the text waits instead of being pasted. That's why setup asks
  for it.
- Hotkeys (none set by default, Settings → Hotkeys): **Start/stop
  thought**, **Paste last again** (pastes the waiting or last text where
  your cursor is now) and **Throw away current** (ends the thought in
  progress or drops waiting text; the audio is still saved and the row is
  marked discarded).

## Rules the app never breaks

- It never switches to another mic. If the pinned mic is unplugged, it
  shows Mic missing and waits.
- It never presses Enter or submits anything. You review and send.
- It never loses a thought. Audio is saved before recognition, cleanup or
  pasting can fail.

## Deleting data

Everything is kept forever by default. Nothing is deleted automatically.
Settings → Data has **Delete all**, which asks for confirmation first.
