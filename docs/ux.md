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
takes focus or clicks. In Transcript mode, when a thought ends, it shows
what was heard with a ✨ while it's being cleaned. Once the paste is done
it shows what was **heard** above what was **pasted** for 4 seconds. Words
cleanup removed are struck out in the heard line, and words it added or
changed are in the accent colour in the pasted line. If the heard text was
used instead, it's shown once under a plain reason, such as "Pasted as
heard: cleanup changed a number" or "Pasted as heard: training is using the
model". If the text box changed before the paste, it says **Waiting**
instead of Pasted. Off and Dot modes show none of this.

## Cleanup

After Apple's speech recognition, a small model on this Mac tidies the
text before it's pasted: fillers and false starts go, spoken corrections
("fifteen, no, fifty") keep only the correction, and punctuation is fixed.
It never answers or carries out what you said. The icon shows **Cleaning
up** meanwhile; a 50-word thought takes about 1.2 s.

- **The model** runs in a helper process inside the app
  (`IruddVoiceCleanup.xpc`) and stays loaded. The app loads the active
  model (`irudd-voice promote` picks it) or, if none is set, the default
  base model (`gemma-4-e2b-base-q4`, see
  [models/baseline.md](models/baseline.md)). It checks every file's
  checksum before the first load of a folder. A trained model that can't
  be loaded falls back to the default.
- **Your text is safe.** If the helper can't be reached, crashes, takes
  longer than 5 s, sends a reply that's cut off, unreadable or full of
  thinking, or the cleaned text fails a hard check (a number, negation,
  name or identifier changed, words added, the request answered, a question
  turned into a statement), the raw text is pasted instead. The model's text
  is never pasted when it failed a check. The row records why
  (`cleanup_status`).
- **Long thoughts** are cleaned in pieces of at most 120 words, split at
  sentence ends (or after commas and the like, or at the word limit), in
  order, and pasted once. If any piece fails, the whole thought is pasted
  raw, never a mix.
- **Order:** thoughts are pasted in the order they ended. A short thought
  that's ready first waits for a long one before it.
- **Throw away** (the hotkey) follows what the menu-bar icon shows. On
  **Text waiting** it drops the waiting text. On **Cleaning up** it drops
  the newest thought still being transcribed, cleaned or pasted, and only
  that one. It can stop a paste until right before ⌘V: while the app waits
  for held keys, nothing has been pasted yet, and the clipboard is put
  back. The **Throw Away** button next to waiting text always drops that
  text.
- **Switching models** only happens when no thought is in progress. The
  app checks the active model every 10 s when idle and after each thought.
- **Training** asks the app to unload the model while it runs (the
  `cleanup.unload_until` lease in [shared/app-state.md](../shared/app-state.md)).
  Meanwhile thoughts are pasted raw, and the model is loaded again when
  training ends.
- **Settings → Model** shows the active model, whether it's the base or a
  trained one (when, on how many thoughts), the helper's status and memory,
  and the last eval against the previous model. If the active trained
  model couldn't be loaded, it says the default is in use and why. A folder
  the helper refused isn't tried again until its manifest changes. A helper
  that didn't answer gets three tries, then another go 10 minutes later.

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
  thought**, **Paste last again** (pastes the waiting text, or else the
  newest thought's text as it was pasted, where your cursor is now) and
  **Throw away current**. Thrown-away text is never pasted again: if the
  newest thought was thrown away, Paste last again pastes nothing, not an
  older thought. Throw away acts on what
  the icon shows: while **Hearing you** it ends the thought, on **Cleaning
  up** it drops the newest thought still being cleaned (up to the moment
  it's pasted), and on **Text waiting** it drops the waiting text. Nothing
  is pasted; the audio is still saved and the row is marked discarded.

## Rules the app never breaks

- It never switches to another mic. If the pinned mic is unplugged, it
  shows Mic missing and waits.
- It never presses Enter or submits anything. You review and send.
- It never loses a thought. Audio is saved before recognition, cleanup or
  pasting can fail.
- It never pastes the model's text when it failed a check. You get what you
  said instead.

## Deleting data

Everything is kept forever by default. Nothing is deleted automatically.
Settings → Data has **Delete all**, which asks for confirmation first.
