#!/usr/bin/env bash
# Model parity: the app's Swift model code (Packages/CleanupModel) must give
# exactly the tokens Python mlx-lm gives, greedy, for the inputs in
# evals/parity.jsonl. Prints OK, or the first differing token (index, both
# IDs, decoded text) for each input that differs.
#
#   tests/model-parity.sh MODEL_DIR REFERENCE.json [MODEL_DIR REFERENCE.json ...]
#
# REFERENCE.json comes from `irudd-voice parity-reference` (format:
# docs/models/parity-format.md). Loads real models: hold the heavy-job lock
# when running it on a shared Mac. Set VOICE_MODEL_TOOL to skip the build.
set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INPUTS=${PARITY_INPUTS:-$REPO_DIR/evals/parity.jsonl}

if [ $# -lt 2 ] || [ $(($# % 2)) -ne 0 ]; then
  echo "usage: $0 MODEL_DIR REFERENCE.json [MODEL_DIR REFERENCE.json ...]" >&2
  exit 2
fi

tool=${VOICE_MODEL_TOOL:-}
if [ -z "$tool" ]; then
  # MLX's Metal shaders only build with xcodebuild, not `swift build`.
  build="${TMPDIR:-/tmp}/irudd-voice-model-tool-build"
  (cd "$REPO_DIR/Packages/CleanupModel" && xcodebuild -scheme voice-model-tool -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$build" build -quiet) >&2
  tool="$build/Build/Products/Release/voice-model-tool"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
while [ $# -gt 0 ]; do
  model=$1 reference=$2
  shift 2
  name=$(basename "$model")
  max_tokens=$(plutil -extract max_new_tokens raw -o - "$reference")
  echo "== $name"
  if ! "$tool" generate --model "$model" --inputs "$INPUTS" --max-tokens "$max_tokens" \
      --out "$work/$name.json" 2>"$work/$name.log"; then
    cat "$work/$name.log" >&2
    failed=1
    continue
  fi
  "$tool" compare --reference "$reference" --swift "$work/$name.json" --model "$model" || failed=1
done
exit $failed
