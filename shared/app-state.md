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

## Eval reports (`models.eval_report_json`)

`irudd-voice eval-compare <model>` stores its report in the candidate's
`models` row. Settings → Model reads these fields (the rest is per-thought
detail for `promote` and `spot-check`):

| Field | Meaning |
| --- | --- |
| `kind`, `version` | `"eval-compare"`, `1` |
| `candidate.id`, `incumbent.id` | The model scored and the model it was compared with (the active one then) |
| `created_at` | When the report was made, UTC |
| `summary.compared` | Frozen test thoughts both models cleaned |
| `summary.votes` | `win`, `loss` (the candidate's), `tie`, `same` (identical output), `split` (the two orders disagreed), `failed` |
| `summary.decided`, `summary.win_rate` | `win` + `loss`, and `win` / `decided` (null when nothing was decided) |
| `summary.hard_checks` | `candidate_thoughts_failed`, `incumbent_thoughts_failed`, `new_failures` (checks the candidate failed where the incumbent passed) |
| `summary.closeness` | `candidate`, `incumbent`: mean similarity of what each would paste to the label (1.0 = same) |
| `decision.promotable`, `decision.reasons` | Whether `promote` would accept it now, and why not |
| `spot_check` | Optional: `answered`, `agreed`, `agreement` from `irudd-voice spot-check` |

When and on how many thoughts a model was trained are the row's
`trained_at` and `trained_chunks`. A row with no report (base models) has
`eval_report_json` null.
