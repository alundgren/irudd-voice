# Database

One SQLite file holds everything the app records:
`~/Library/Application Support/irudd-voice/voice.sqlite`.

## Rules

- **The app owns the schema.** Only the Swift app creates tables or
  migrates (`PRAGMA user_version`, in
  `Packages/IruddVoiceKit/Sources/IruddVoiceKit/Schema.swift`). It refuses
  to open a database from a newer version.
- **The CLI never migrates.** It refuses to write when `user_version`
  isn't the version it knows, and says why (`cli/src/irudd_voice/db.py`).
- Both sides use WAL and a 10 s busy timeout, and take the write lock up
  front (`BEGIN IMMEDIATE`), so app and CLI can write at the same time.
- **Nothing stays pending.** Recognition gets 20 s plus the thought's
  length. After that the row is marked `error` with the reason, and the
  audio is kept. Rows left pending by a quit are recognised again from their
  audio at the next launch.
- **Audio is saved first.** When a thought ends, its audio is written as a
  `pending` row before recognition runs. The row then becomes `transcribed`
  or `error`. Audio stays in the database, nothing is deleted
  automatically, and Settings → Data → Delete All Recordings is the only
  way to remove it.

## Schema version 1

| Table | What it holds |
| --- | --- |
| `chunks` | One row per thought: audio, Apple's text, times, mic, target app, and later the cleaned and pasted text |
| `labels` | What a teacher model said a chunk should have been, accepted or rejected |
| `dataset_days` | Which split (train, selection, test) each recording day belongs to; test days never move |
| `models` | Trained cleanup models and their manifests and eval reports |
| `active_model` | The one active model and the previous one, for rollback |
| `events` | The app's log: saves, recognition results and timings, failures, mic changes. `irudd-voice events` prints it |
| `app_state` | Small key/value settings shared by app and CLI |

### `chunks`

| Column | Meaning |
| --- | --- |
| `status` | `pending` → `transcribed` or `error`; `discarded` when thrown away |
| `error` | Why recognition failed, in plain words |
| `started_at`, `signal_at`, `ended_at` | UTC ISO 8601 with milliseconds: first sample (pre-roll included), the start signal, the end |
| `local_day`, `utc_offset_minutes` | The local recording date (used for dataset splits) and the offset then |
| `duration_ms` | Length of the stored audio |
| `start_reason`, `end_reason` | `unmute`/`hotkey`; `muteButton`, `hotkey`, `silence`, `micLost`, `micChanged`, `switchedOff` |
| `mic_uid`, `mic_name`, `mic_model_uid` | The exact mic used |
| `audio`, `audio_format`, `audio_sample_rate`, `audio_bytes` | The whole recording as a FLAC file (16 kHz, 16-bit mono). If FLAC encoding ever fails, raw little-endian floats (`pcm_f32le`) at the mic's rate |
| `target_app_bundle_id`, `target_app_name` | The app in front when the thought ended |
| `raw_text`, `recognizer`, `transcribed_at` | Apple's text and which engine produced it |
| `cleaned_text`, `cleanup_*`, `pasted_text`, `paste_*` | Filled in by later versions |
| `schema_version`, `app_version`, `prompt_version` | What wrote the row |

### `models` and `active_model`

| Column | Meaning |
| --- | --- |
| `models.id` | The model folder's name in `models/`, also `manifest.json`'s `id` |
| `models.manifest_json` | The folder's manifest; `training` holds how it was trained |
| `models.dataset_hash`, `trained_chunks`, `trained_at` | Copied from the manifest's `training` block; null for base models |
| `models.eval_report_json` | The latest `irudd-voice eval-compare` report for this model (fields in `shared/app-state.md`) |
| `active_model.model_id` | The model the app uses; null means the default (`gemma-4-e2b-base-q4`) |
| `active_model.previous_model_id` | What was active before; `irudd-voice rollback` swaps the two |

`promote` and `rollback` change `active_model` in one transaction and log an
`events` row (category `model`) in the same transaction.
