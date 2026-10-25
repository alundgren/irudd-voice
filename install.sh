#!/usr/bin/env bash
# Build irudd-voice from this checkout and install it into ~/Applications.
#
#   ./install.sh            build, install and open the app
#   ./install.sh --no-open  build and install only
#
# Settings (environment variables):
#   IRUDD_VOICE_SIGNING_IDENTITY  certificate name or SHA-1 (default: "irudd-voice Local Signing")
#   IRUDD_VOICE_APPS_DIR          where the app goes (default: ~/Applications)
#   IRUDD_VOICE_BUILD_DIR         build files (default: ~/Library/Caches/irudd-voice/build)
#
# Every check runs before anything in the apps folder is touched. A failed
# build or signature check leaves the installed app as it was.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP_NAME="irudd-voice.app"
IDENTITY=${IRUDD_VOICE_SIGNING_IDENTITY:-"irudd-voice Local Signing"}
APPS_DIR=${IRUDD_VOICE_APPS_DIR:-"$HOME/Applications"}
BUILD_DIR=${IRUDD_VOICE_BUILD_DIR:-"$HOME/Library/Caches/irudd-voice/build"}
OPEN_APP=1

for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_APP=0 ;;
    -h | --help)
      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
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

say "Checking this Mac…"

[[ "$(uname -m)" == "arm64" ]] || stop "irudd-voice needs a Mac with Apple silicon."

macos=$(sw_vers -productVersion)
[[ "$macos" =~ ^([0-9]+) ]] && (( BASH_REMATCH[1] >= 27 )) || stop "irudd-voice needs macOS 27 or newer. This Mac has $macos." \
  "Update in System Settings → General → Software Update."

command -v xcodebuild >/dev/null 2>&1 || stop "Xcode 27 or newer is needed." \
  "Install Xcode from the App Store, open it once, then run:" \
  "sudo xcode-select -s /Applications/Xcode.app"
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

# ---- Build -------------------------------------------------------------------

say "Building irudd-voice (a few minutes the first time)…"
mkdir -p "$BUILD_DIR"
build_log="$BUILD_DIR/build.log"
if ! xcodebuild \
  -project "$REPO_DIR/App/IruddVoice.xcodeproj" \
  -scheme IruddVoice \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGN_IDENTITY="$sha1" \
  build >"$build_log" 2>&1; then
  grep -E 'error:' "$build_log" | head -n 20 >&2 || true
  stop "The build failed. The full log is in $build_log."
fi
built="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME"
[[ -d "$built" ]] || stop "The build finished but $built is missing. See $build_log."

codesign --verify --strict "$built" 2>/dev/null || stop "The built app's signature doesn't verify."
requirement=$(codesign -d -r- "$built" 2>&1 || true)
grep -qi "$sha1" <<<"$requirement" ||
  stop "The built app isn't signed with certificate $sha1."

# ---- Install -----------------------------------------------------------------

# Copy into the apps folder first, then swap folders, so ~/Applications never
# holds a half-copied app.
mkdir -p "$APPS_DIR"
staged="$APPS_DIR/.$APP_NAME.new"
previous="$APPS_DIR/.$APP_NAME.old"
rm -rf "$staged" "$previous"
ditto "$built" "$staged"

if pgrep -x irudd-voice >/dev/null 2>&1; then
  say "Quitting the running irudd-voice…"
  osascript -e 'tell application id "io.github.alundgren.irudd-voice" to quit' >/dev/null 2>&1 || true
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
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APPS_DIR/$APP_NAME" >/dev/null 2>&1 || true

say "Installed $APPS_DIR/$APP_NAME"
say "Certificate SHA-1: $sha1 (if this changes, macOS will ask for permissions again)"

if (( OPEN_APP )); then
  open "$APPS_DIR/$APP_NAME"
  say "irudd-voice is in the menu bar."
fi
