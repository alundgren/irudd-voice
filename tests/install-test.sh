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
# Never register the test's fake apps with the real Launch Services.
fake lsregister <<'EOF2'
#!/bin/bash
echo "$*" >>"$FAKE_STATE/registered"
EOF2

passed=0
fail() { echo "FAIL [$case_name]: $*" >&2; echo "--- output ---" >&2; cat "$work/out" >&2; exit 1; }

# run NAME EXPECTED_EXIT EXPECTED_TEXT [VAR=value…] [-- install.sh arguments…]
run() {
  case_name=$1 expected_exit=$2 expected_text=$3
  shift 3
  local vars=() opts=() seen_separator=0 arg
  for arg in "$@"; do
    if (( seen_separator )); then opts+=("$arg")
    elif [[ "$arg" == -- ]]; then seen_separator=1
    else vars+=("$arg"); fi
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
    IRUDD_VOICE_LSREGISTER="$fakes/lsregister" \
    IRUDD_VOICE_STATE_DIR="$work/$case_name/state-dir" \
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

run metal-download 0 "Metal toolchain: installed" FAKE_METAL=downloadable -- --no-open
grep -q new "$last_apps/irudd-voice.app/Contents/MacOS/irudd-voice" || fail "app not replaced"

run install 0 "Certificate SHA-1: $SHA1"
grep -q new "$last_apps/irudd-voice.app/Contents/MacOS/irudd-voice" || fail "app not replaced"
[[ -z "$(ls -A "$last_apps" | grep -v '^irudd-voice.app$')" ]] || fail "leftover files in the apps folder"
grep -q "irudd-voice.app" "$last_state/opened" || fail "app not opened"
grep -q -- "-f .*irudd-voice.app" "$last_state/registered" || fail "app not re-registered for its icon"
install_json="$work/install/state-dir/install.json"
plutil -convert json -o /dev/null "$install_json" 2>/dev/null || fail "install.json isn't valid JSON"
grep -q "\"signingSHA1\": \"$SHA1\"" "$install_json" || fail "install.json is missing the certificate"
grep -q "\"commit\": \"[0-9a-f]\{40\}\"" "$install_json" || fail "install.json is missing the commit"

# ---- Update now: build into a staging folder, then swap -------------------

stage="$work/staged"
run stage 0 "Staged $stage/irudd-voice.app" FAKE_BUILD_ID=staged -- --stage "$stage"
grep -q old "$last_apps/irudd-voice.app/Contents/MacOS/irudd-voice" || fail "staging touched the installed app"
grep -q staged "$stage/irudd-voice.app/Contents/MacOS/irudd-voice" || fail "nothing staged"
plutil -convert json -o /dev/null "$stage/build-info.json" 2>/dev/null || fail "build-info.json isn't valid JSON"

run stage-fails 1 "The build failed" FAKE_BUILD=fail -- --stage "$work/staged-broken"
[[ ! -e "$work/staged-broken/irudd-voice.app" ]] || fail "a failed build left a staged app"

# The app quits itself; --activate waits for it, swaps, records and reopens.
sleep 1 & app_pid=$!
run activate 0 "Installed" -- --activate "$stage" --wait-pid "$app_pid"
grep -q staged "$last_apps/irudd-voice.app/Contents/MacOS/irudd-voice" || fail "staged app not swapped in"
grep -q "irudd-voice.app" "$last_state/opened" || fail "app not reopened"
grep -q '"commit"' "$work/activate/state-dir/install.json" || fail "activate didn't record the install"

run activate-missing 1 "No staged build" -- --activate "$work/nothing-here"

sleep 60 & stuck_pid=$!
disown "$stuck_pid"
run activate-app-wont-quit 1 "didn't quit within 1 seconds" IRUDD_VOICE_QUIT_TIMEOUT=1 -- --activate "$stage" --wait-pid "$stuck_pid"
kill "$stuck_pid" 2>/dev/null || true

run by-sha1 0 "Installed" IRUDD_VOICE_SIGNING_IDENTITY=$SHA1 -- --no-open

echo "PASS install.sh ($passed cases)"
