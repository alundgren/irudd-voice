#!/usr/bin/env bash
# Run every local check. None of them open the app or show windows.
set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_DIR"

echo "== Logic tests"
swift test --package-path Packages/IruddVoiceKit

echo "== CLI tests (with the app's database code)"
swift build --product voice-db-tool --package-path Packages/IruddVoiceKit
VOICE_DB_TOOL="$REPO_DIR/Packages/IruddVoiceKit/.build/debug/voice-db-tool" \
  uv run --project cli --quiet pytest -q cli/tests

if [[ -n "${IRUDD_VOICE_SLOW:-}" ]]; then
  # Loads a real model and trains a few LoRA steps; takes minutes and a few GB.
  echo "== Slow model tests"
  uv run --project cli --group ml --quiet pytest -q -m slow cli/tests
fi

echo "== Installer tests"
tests/install-test.sh

echo "== Signing certificate test"
tests/signing-certificate-test.sh

echo "== App build"
test_build="${TMPDIR:-/tmp}/irudd-voice-test-build"
xcodebuild -project App/IruddVoice.xcodeproj -scheme IruddVoice -configuration Debug \
  -derivedDataPath "$test_build" CODE_SIGN_IDENTITY=- -destination 'platform=macOS,arch=arm64' build -quiet
# Xcode registers built apps with Launch Services; unregister this one so
# Spotlight only finds the installed app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$test_build/Build/Products/Debug/irudd-voice.app" 2>/dev/null || true

echo "== Model tool build"
# Packages/CleanupModel links MLX, whose Metal shaders only build with xcodebuild.
tool_build="${TMPDIR:-/tmp}/irudd-voice-model-tool-build"
(cd Packages/CleanupModel && xcodebuild -scheme voice-model-tool -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$tool_build" build -quiet)
tool="$tool_build/Build/Products/Release/voice-model-tool"

# Slow: loads real models. IRUDD_VOICE_PARITY_DIR is a folder of Python
# parity references (<model-id>.json, from `irudd-voice parity-reference`);
# each one with a model folder in the models folder is checked, then the
# XPC helper's code runs against the first model over an in-process listener.
if [[ -n "${IRUDD_VOICE_PARITY_DIR:-}" ]]; then
  echo "== Model parity and helper check (real models)"
  models="$HOME/Library/Application Support/irudd-voice/models"
  pairs=()
  for reference in "$IRUDD_VOICE_PARITY_DIR"/*.json; do
    id=$(basename "$reference" .json)
    [[ -d "$models/$id" ]] && pairs+=("$models/$id" "$reference")
  done
  (( ${#pairs[@]} )) || { echo "no references with model folders in $IRUDD_VOICE_PARITY_DIR" >&2; exit 1; }
  VOICE_MODEL_TOOL="$tool" tests/model-parity.sh "${pairs[@]}"
  "$tool" xpc-check --model "${pairs[0]}"
fi

echo "== Probe build"
swift build -c release --package-path tools/boya-probe

echo "All checks passed."
