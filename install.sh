#!/usr/bin/env bash
# Build irudd-voice from this checkout and install it into ~/Applications.
#
#   ./install.sh                         build, install and open the app
#   ./install.sh --no-open               build and install only
#   ./install.sh --stage DIR             build into DIR only; leave the installed app alone
#   ./install.sh --activate DIR [--wait-pid PID] [--no-open]
#                                        swap a staged build into place (used by Update now)
#
# Settings (environment variables):
#   IRUDD_VOICE_SIGNING_IDENTITY  certificate name or SHA-1 (default: "irudd-voice Local Signing")
#   IRUDD_VOICE_APPS_DIR          where the app goes (default: ~/Applications)
#   IRUDD_VOICE_BUILD_DIR         build files (default: ~/Library/Caches/irudd-voice/build)
#   IRUDD_VOICE_STATE_DIR         where install.json is kept (default: ~/Library/Application Support/irudd-voice)
#
# Every check runs before anything in the apps folder is touched. A failed
# build or signature check leaves the installed app as it was.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP_NAME="irudd-voice.app"
BUNDLE_ID="io.github.alundgren.irudd-voice"
IDENTITY=${IRUDD_VOICE_SIGNING_IDENTITY:-"irudd-voice Local Signing"}
APPS_DIR=${IRUDD_VOICE_APPS_DIR:-"$HOME/Applications"}
BUILD_DIR=${IRUDD_VOICE_BUILD_DIR:-"$HOME/Library/Caches/irudd-voice/build"}
STATE_DIR=${IRUDD_VOICE_STATE_DIR:-"$HOME/Library/Application Support/irudd-voice"}
LSREGISTER=${IRUDD_VOICE_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}
QUIT_TIMEOUT=${IRUDD_VOICE_QUIT_TIMEOUT:-30}
OPEN_APP=1
MODE=install
STAGE_DIR=""
WAIT_PID=""

while (( $# )); do
  case "$1" in
    --no-open) OPEN_APP=0 ;;
    --stage) MODE=stage; STAGE_DIR=${2:?--stage needs a folder}; shift ;;
    --activate) MODE=activate; STAGE_DIR=${2:?--activate needs a folder}; shift ;;
    --wait-pid) WAIT_PID=${2:?--wait-pid needs a process ID}; shift ;;
    -h | --help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
stop() {
  printf '\nCan'"'"'t install: %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
  printf '\nNothing was changed in %s.\n' "$APPS_DIR" >&2
  exit 1
}

# ---- Preflight ---------------------------------------------------------------

preflight() {
  say "Checking this Mac…"

  [[ "$(uname -m)" == "arm64" ]] || stop "irudd-voice needs a Mac with Apple silicon."

  local macos
  macos=$(sw_vers -productVersion)
  [[ "$macos" =~ ^([0-9]+) ]] && (( BASH_REMATCH[1] >= 27 )) || stop "irudd-voice needs macOS 27 or newer. This Mac has $macos." \
    "Update in System Settings → General → Software Update."

  command -v xcodebuild >/dev/null 2>&1 || stop "Xcode 27 or newer is needed." \
    "Install Xcode from the App Store, open it once, then run:" \
    "sudo xcode-select -s /Applications/Xcode.app"
  local xcode_line xcode_version
  xcode_line=$(xcodebuild -version 2>/dev/null | head -n 1 || true)
  xcode_version=${xcode_line#Xcode }
  if ! [[ "$xcode_line" =~ ^Xcode\ ([0-9]+) ]] || (( BASH_REMATCH[1] < 27 )); then
    stop "Xcode 27 or newer is needed (found: ${xcode_line:-command-line tools only})." \
      "Install Xcode from the App Store, open it once, then run:" \
      "sudo xcode-select -s /Applications/Xcode.app"
  fi
  say "  Xcode: $xcode_version"

  # The cleanup model runs on the GPU through MLX, whose shaders need Apple's
  # Metal toolchain. Xcode downloads it separately, once.
  if ! xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q '^Status: installed'; then
    say "  Metal toolchain: downloading (one time, several hundred MB)…"
    xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true
    xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q '^Status: installed' ||
      stop "Xcode's Metal toolchain is missing and the download failed." \
        "Check your internet connection, then run:" \
        "xcodebuild -downloadComponent MetalToolchain"
  fi
  say "  Metal toolchain: installed"

  # Resolve the signing certificate to its SHA-1. The same certificate on every
  # build keeps macOS permissions (microphone, accessibility…) across updates.
  local identities matches count
  identities=$(security find-identity -p codesigning 2>/dev/null || true)
  if [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    sha1=$(printf '%s\n' "$identities" | awk -v id="$IDENTITY" 'toupper($2) == toupper(id) { print $2; exit }')
  else
    matches=$(printf '%s\n' "$identities" | grep -F "\"$IDENTITY\"" | awk '{ print $2 }' | sort -u || true)
    count=$(printf '%s' "$matches" | grep -c . || true)
    if (( count > 1 )); then
      stop "More than one signing certificate is named \"$IDENTITY\"." \
        "Pick one and pass its SHA-1:" \
        "IRUDD_VOICE_SIGNING_IDENTITY=<sha-1> ./install.sh" \
        "List them with: security find-identity -p codesigning"
    fi
    sha1=$matches
  fi
  [[ -n "${sha1:-}" ]] || stop "No signing certificate \"$IDENTITY\" was found in your keychain." \
    "Create one (once per Mac) with:" \
    "./scripts/create-signing-certificate.sh" \
    "Or see \"Signing certificate\" in README.md."
  say "  Signing certificate: $IDENTITY"
  say "  Certificate SHA-1:   $sha1"

  security show-keychain-info login.keychain >/dev/null 2>&1 ||
    stop "Your login keychain is locked, so the app can't be signed." \
      "Unlock it with: security unlock-keychain login.keychain"
}

# ---- Build -------------------------------------------------------------------

# Builds and verifies the app; sets $built.
build() {
  say "Building irudd-voice (a few minutes the first time)…"
  mkdir -p "$BUILD_DIR"
  local build_log="$BUILD_DIR/build.log"
  if ! xcodebuild \
    -project "$REPO_DIR/App/IruddVoice.xcodeproj" \
    -scheme IruddVoice \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$build_log" 2>&1; then
    grep -E 'error:' "$build_log" | head -n 20 >&2 || true
    stop "The build failed. The full log is in $build_log."
  fi
  built="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME"
  [[ -d "$built" ]] || stop "The build finished but $built is missing. See $build_log."

  # Xcode would also sign the Swift packages' resource bundles (mlx-swift,
  # swift-transformers, swift-crypto) and refuses to do that with a
  # self-signed certificate. So the build is unsigned, and the code is signed
  # here, inside out: the cleanup helper first, then the app around it. The
  # resource bundles hold no code and are sealed by the helper's signature.
  local helper
  for helper in "$built"/Contents/XPCServices/*.xpc; do
    [[ -e "$helper" ]] || continue
    codesign --force --sign "$sha1" --timestamp=none "$helper" >>"$build_log" 2>&1 ||
      stop "Couldn't sign $(basename "$helper"). See $build_log."
  done
  codesign --force --sign "$sha1" --timestamp=none "$built" >>"$build_log" 2>&1 ||
    stop "Couldn't sign the app. See $build_log."

  codesign --verify --strict --deep "$built" 2>/dev/null || stop "The built app's signature doesn't verify."
  local requirement code
  for code in "$built" "$built"/Contents/XPCServices/*.xpc; do
    [[ -e "$code" ]] || continue
    requirement=$(codesign -d -r- "$code" 2>&1 || true)
    grep -qi "$sha1" <<<"$requirement" ||
      stop "$(basename "$code") isn't signed with certificate $sha1."
  done
}

# What was built: written next to a staged app and to install.json, so the
# app knows its commit and where updates come from.
build_info() {
  local commit branch remote upstream dirty=false
  commit=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  upstream=$(git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  branch=${upstream#*/}
  [[ -n "$upstream" ]] || branch=main
  # Update now builds from a detached checkout, so it says which branch.
  branch=${IRUDD_VOICE_BRANCH:-$branch}
  remote=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
  [[ -z "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]] || dirty=true
  printf '{\n  "commit": "%s",\n  "branch": "%s",\n  "remote": "%s",\n  "dirty": %s,\n  "signingSHA1": "%s",\n  "builtAt": "%s"\n}\n' \
    "$commit" "$branch" "$remote" "$dirty" "$sha1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# ---- Install -----------------------------------------------------------------

# Swaps the app at $1 into the apps folder as a whole bundle.
activate() {
  local source=$1
  # Copy into the apps folder first, then swap folders, so ~/Applications
  # never holds a half-copied app.
  mkdir -p "$APPS_DIR"
  local staged="$APPS_DIR/.$APP_NAME.new" previous="$APPS_DIR/.$APP_NAME.old"
  rm -rf "$staged" "$previous"
  ditto "$source" "$staged"

  if [[ -n "$WAIT_PID" ]]; then
    say "Waiting for irudd-voice to quit…"
    for _ in $(seq 1 $((QUIT_TIMEOUT * 2))); do
      kill -0 "$WAIT_PID" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$WAIT_PID" 2>/dev/null; then
      rm -rf "$staged"
      stop "irudd-voice didn't quit within $QUIT_TIMEOUT seconds."
    fi
  elif pgrep -x irudd-voice >/dev/null 2>&1; then
    say "Quitting the running irudd-voice…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x irudd-voice >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi

  if [[ -e "$APPS_DIR/$APP_NAME" ]]; then
    mv "$APPS_DIR/$APP_NAME" "$previous"
  fi
  if ! mv "$staged" "$APPS_DIR/$APP_NAME"; then
    [[ -e "$previous" ]] && mv "$previous" "$APPS_DIR/$APP_NAME"
    rm -rf "$staged"
    stop "Couldn't move the new app into place. The previous version was put back."
  fi
  rm -rf "$previous"

  # A moved-in bundle keeps its old folder date, so Finder and Spotlight can
  # keep showing a cached icon. Touch it and re-register it with Launch Services.
  touch "$APPS_DIR/$APP_NAME"
  "$LSREGISTER" -f "$APPS_DIR/$APP_NAME" >/dev/null 2>&1 || true

  say "Installed $APPS_DIR/$APP_NAME"
}

record_install() {
  local info=$1
  mkdir -p "$STATE_DIR"
  # install.json = the build info plus where it was installed.
  sed '$d' "$info" | sed '$s/$/,/' >"$STATE_DIR/install.json.new"
  printf '  "appsDir": "%s",\n  "installedAt": "%s"\n}\n' "$APPS_DIR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >>"$STATE_DIR/install.json.new"
  mv "$STATE_DIR/install.json.new" "$STATE_DIR/install.json"
}

open_app() {
  if (( OPEN_APP )); then
    open "$APPS_DIR/$APP_NAME"
    say "irudd-voice is in the menu bar."
  fi
}

case "$MODE" in
  install)
    preflight
    build
    info=$(mktemp)
    build_info >"$info"
    activate "$built"
    record_install "$info"
    rm -f "$info"
    say "Certificate SHA-1: $sha1 (if this changes, macOS will ask for permissions again)"
    open_app
    ;;
  stage)
    preflight
    build
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    ditto "$built" "$STAGE_DIR/$APP_NAME"
    build_info >"$STAGE_DIR/build-info.json"
    say "Staged $STAGE_DIR/$APP_NAME"
    ;;
  activate)
    [[ -d "$STAGE_DIR/$APP_NAME" && -f "$STAGE_DIR/build-info.json" ]] ||
      stop "No staged build in $STAGE_DIR."
    activate "$STAGE_DIR/$APP_NAME"
    record_install "$STAGE_DIR/build-info.json"
    open_app
    ;;
esac
