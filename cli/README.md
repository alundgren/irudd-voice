# irudd-voice CLI

Reads the database the irudd-voice app writes
(`~/Library/Application Support/irudd-voice/voice.sqlite`).

```sh
cd cli
uv run irudd-voice stats          # or: uv run irudd-voice stats --json
uv run pytest                      # tests
```

The app owns the schema. The CLI never creates or migrates tables, and it
refuses to write to a database whose schema version it doesn't know.
