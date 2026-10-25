# UX decisions

## Look

Native macOS. Standard SwiftUI controls, system fonts and SF Symbols, and
the system accent colour. Follows light and dark mode. The chosen mock is
the dark native version (Scope tab `irudd-voice-ui-mocks-dark`).

## The mic stays open while the switch is on

The app ends a thought when the mic's mute button makes the audio go
silent (see [hardware/boya-by-gm18cu.md](hardware/boya-by-gm18cu.md)).
To notice that, it has to keep listening. So while the switch in the panel
is on, the mic stream is open and macOS shows its orange mic dot the whole
time. Nothing is saved until you unmute and talk.

Switching the app off closes the mic stream. The orange dot goes away, and
nothing is recorded until you switch it on again.

## Menu-bar states

| State | Icon | Meaning |
| --- | --- | --- |
| Off | `mic.slash` | Switched off; mic closed |
| Ready | `mic` | Listening, waiting for you to unmute |
| Hearing you | `mic.fill` | Recording a thought |
| Cleaning up | `sparkles` | Turning the thought into clean text |
| Text waiting | `text.badge.plus` | Text is ready but you moved away; go back to paste it |
| Mic missing | `mic.badge.xmark` | The pinned mic isn't connected; the app waits |

Off wins over everything, then Mic missing, then the current activity.

## Preview while talking

Three choices in the panel and Settings: **Off** (nothing on screen),
**Dot** (a small dot while hearing you; the default) and **Transcript**
(the live transcript, mostly for testing).

## Rules the app never breaks

- It never switches to another mic. If the pinned mic is unplugged, it
  shows Mic missing and waits.
- It never presses Enter or submits anything. You review and send.
- It never loses a thought. Audio is saved before recognition, cleanup or
  pasting can fail.

## Deleting data

Everything is kept forever by default. Nothing is deleted automatically.
Settings → Data has **Delete all**, which asks for confirmation first.
