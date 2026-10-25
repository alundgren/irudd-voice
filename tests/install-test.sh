#!/usr/bin/env bash
# Runs install.sh against fake system tools: one case per missing
# prerequisite, plus a full install and a reinstall. Checks the exit code,
# the message, and that the apps folder is left alone when a check fails.
# Nothing real is built, signed, quit or opened.

set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

SHA1=1111111111111111111111111111111111111111
fakes="$work/bin"
mkdir -p "$fakes"

fake() { cat >"$fakes/$1"; chmod +x "$fakes/$1"; }

fake uname <<'EOF2'
#!/bin/bash
echo "${FAKE_ARCH:-arm64}"
EOF2
fake sw_vers <<'EOF2'
#!/bin/bash
echo "${FAKE_MACOS:-27.0.1}"
EOF2
fake xcodebuild <<'EOF2'
#!/bin/bash
[[ "${FAKE_XCODE:-27.1}" == none ]] && exit 1
case "$1" in
  -version) echo "Xcode ${FAKE_XCODE:-27.1}"; echo "Build version 27A0000" ;;
  -showComponent)
    if [[ "${FAKE_METAL:-installed}" == installed || -e "$FAKE_STATE/metal-downloaded" ]]; then
      echo "Status: installed"
    else
      echo "Status: uninstalled"
    fi ;;
  -downloadComponent)
    [[ "${FAKE_METAL:-installed}" == downloadable ]] || exit 1
    touch "$FAKE_STATE/metal-downloaded" ;;
  *)
    [[ "${FAKE_BUILD:-ok}" == ok ]] || { echo "main.swift:1: error: boom"; exit 65; }
    while (( $# )); do [[ "$1" == -derivedDataPath ]] && dd=$2; shift; done
    app="$dd/Build/Products/Release/irudd-voice.app"
    mkdir -p "$app/Contents/MacOS"
    echo "${FAKE_BUILD_ID:-new}" >"$app/Contents/MacOS/irudd-voice" ;;
esac
EOF2
fake security <<'EOF2'
#!/bin/bash
case "$1" in
  find-identity)
    echo "Policy: Code Signing"
    case "${FAKE_IDENTITY:-present}" in
      present) echo "  1) $FAKE_SHA1 \"irudd-voice Local Signing\" (CSSMERR_TP_NOT_TRUSTED)" ;;
      duplicate)
        echo "  1) $FAKE_SHA1 \"irudd-voice Local Signing\" (CSSMERR_TP_NOT_TRUSTED)"
        echo "  2) 2222222222222222222222222222222222222222 \"irudd-voice Local Signing\" (CSSMERR_TP_NOT_TRUSTED)" ;;
    esac ;;
  show-keychain-info) [[ "${FAKE_KEYCHAIN:-unlocked}" == unlocked ]] ;;
esac
EOF2
fake codesign <<'EOF2'
#!/bin/bash
[[ "$1" == --verify ]] && exit 0
echo "designated => identifier \"io.github.alundgren.irudd-voice\" and certificate root = H\"${FAKE_SIGNED_SHA1:-$FAKE_SHA1}\""
EOF2
fake pgrep <<'EOF2'
#!/bin/bash
exit 1
EOF2
fake open <<'EOF2'
#!/bin/bash
echo "$*" >>"$FAKE_STATE/opened"
EOF2
fake osascript <<'EOF2'
#!/bin/bash
exit 0
EOF2

passed=0
fail() { echo "FAIL [$case_name]: $*" >&2; echo "--- output ---" >&2; cat "$work/out" >&2; exit 1; }

# run NAME EXPECTED_EXIT EXPECTED_TEXT [VAR=value…] [--install-option…]
run() {
  case_name=$1 expected_exit=$2 expected_text=$3
  shift 3
  local vars=() opts=() arg
  for arg in "$@"; do
    if [[ "$arg" == --* ]]; then opts+=("$arg"); else vars+=("$arg"); fi
  done
  local apps="$work/$case_name/Applications" state="$work/$case_name/state"
  mkdir -p "$apps/irudd-voice.app/Contents/MacOS" "$state"
  echo old >"$apps/irudd-voice.app/Contents/MacOS/irudd-voice"
  local before
  before=$(cd "$apps" && find . -print0 | sort -z | xargs -0 ls -ld | shasum)

  set +e
  env -i HOME="$work/$case_name/home" PATH="$fakes:/usr/bin:/bin" \
    FAKE_STATE="$state" FAKE_SHA1="$SHA1" \
    IRUDD_VOICE_APPS_DIR="$apps" IRUDD_VOICE_BUILD_DIR="$work/$case_name/build" \
    ${vars[@]+"${vars[@]}"} bash "$REPO_DIR/install.sh" ${opts[@]+"${opts[@]}"} >"$work/out" 2>&1
  local code=$?
  set -e

  (( code == expected_exit )) || fail "exit code $code, expected $expected_exit"
  grep -qF -- "$expected_text" "$work/out" || fail "missing text: $expected_text"
  if (( expected_exit != 0 )); then
    local after
    after=$(cd "$apps" && find . -print0 | sort -z | xargs -0 ls -ld | shasum)
    [[ "$before" == "$after" ]] || fail "apps folder changed"
    grep -qF "Nothing was changed in" "$work/out" || fail "missing 'Nothing was changed'"
  fi
  last_apps=$apps last_state=$state
  passed=$((passed + 1))
  echo "ok - $case_name"
}

run intel 1 "needs a Mac with Apple silicon" FAKE_ARCH=x86_64
run old-macos 1 "needs macOS 27 or newer. This Mac has 26.6.2" FAKE_MACOS=26.6.2
run no-xcode 1 "Xcode 27 or newer is needed" FAKE_XCODE=none
run old-xcode 1 "Xcode 27 or newer is needed (found: Xcode 26.4)" FAKE_XCODE=26.4
run metal-missing 1 "Metal toolchain is missing and the download failed" FAKE_METAL=missing
run no-identity 1 "No signing certificate \"irudd-voice Local Signing\" was found" FAKE_IDENTITY=none
run duplicate-identity 1 "More than one signing certificate" FAKE_IDENTITY=duplicate
run locked-keychain 1 "login keychain is locked" FAKE_KEYCHAIN=locked
run build-fails 1 "The build failed" FAKE_BUILD=fail
run wrong-signer 1 "isn't signed with certificate" FAKE_SIGNED_SHA1=3333333333333333333333333333333333333333

run metal-download 0 "Metal toolchain: installed" FAKE_METAL=downloadable --no-open
grep -q new "$last_apps/irudd-voice.app/Contents/MacOS/irudd-voice" || fail "app not replaced"

run install 0 "Certificate SHA-1: $SHA1"
grep -q new "$last_apps/irudd-voice.app/Contents/MacOS/irudd-voice" || fail "app not replaced"
[[ -z "$(ls -A "$last_apps" | grep -v '^irudd-voice.app$')" ]] || fail "leftover files in the apps folder"
grep -q "irudd-voice.app" "$last_state/opened" || fail "app not opened"

run by-sha1 0 "Installed" IRUDD_VOICE_SIGNING_IDENTITY=$SHA1 --no-open

echo "PASS install.sh ($passed cases)"
