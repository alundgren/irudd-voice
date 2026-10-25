# Vocabulary file

`~/Library/Application Support/irudd-voice/vocabulary.json` is written by
`irudd-voice vocab`. The app reads it when it loads a model, and training
reads it when building prompts.

```json
{"version": 1, "generated_at": "2026-10-25T10:00:00Z", "terms": ["T3 Code", "SwiftUI", "irudd-voice"]}
```

- An empty `terms` list, or a missing file, means no vocabulary.
- Terms are in the spelling to use, ordered most useful first.
- The prompt and the hard checks both use the first `vocabulary_limit`
  terms (see `cleanup-prompt.json`) in file order.
