#!/usr/bin/env bash
# Run every local check. None of them open the app or show windows.
set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_DIR"

echo "== Logic tests"
swift test --package-path Packages/IruddVoiceKit

echo "== Installer tests"
tests/install-test.sh

echo "== Signing certificate test"
tests/signing-certificate-test.sh

echo "== App build"
xcodebuild -project App/IruddVoice.xcodeproj -scheme IruddVoice -configuration Debug \
  -derivedDataPath "${TMPDIR:-/tmp}/irudd-voice-test-build" CODE_SIGN_IDENTITY=- -destination 'platform=macOS,arch=arm64' build -quiet

echo "== Probe build"
swift build -c release --package-path tools/boya-probe

echo "All checks passed."
