# App ⇄ CLI coordination (`app_state` table)

The CLI can't talk to the app's cleanup helper directly. They coordinate
through rows in the database's `app_state` table (`key`, `value`,
`updated_at`). Values are strings. Times are UTC ISO 8601 with
milliseconds.

| Key | Written by | Meaning |
| --- | --- | --- |
| `cleanup.unload_until` | CLI (`train`, heavy `eval`) | A lease. While now < this time, the app keeps the cleanup model unloaded and pastes raw text. The CLI refreshes it every 30 s while it works (lease length 120 s) and deletes it when done. If the CLI dies, the lease runs out and the app reloads on its own. |
| `cleanup.loaded_model` | App | The model ID the helper has loaded, or empty when nothing is loaded. |
| `cleanup.status` | App | `loaded`, `loading`, `unloaded`, `unloaded-for-training` or `failed: <reason>`. |
| `cleanup.status_at` | App | When `cleanup.status` last changed. |

**Starting training.** After writing the lease, `train` waits up to 60 s
for `cleanup.status` = `unloaded-for-training`. If `cleanup.status_at` is
older than 2 minutes (the app isn't running), it goes ahead. If the app is
running but doesn't confirm, it stops with a message instead of loading
weights next to the app's model, because 24 GB isn't enough for both.

The active model is the `active_model` row (`slot` = 1). `promote` and
`rollback` change it in one transaction. The app checks it when idle (at
most every 10 s and after each thought), and loads a different model only
when no thought is in progress. `promote` reports success once
`cleanup.loaded_model` equals the new ID, or reports that the app hasn't
picked it up yet.
