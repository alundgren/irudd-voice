#!/usr/bin/env bash
# Checks scripts/create-signing-certificate.sh against a throwaway keychain,
# then signs a small binary with the new certificate. Your login keychain
# isn't touched. The throwaway keychain is on the keychain search list only
# while the test runs.

set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
keychain="$work/test.keychain-db"
password=$(/usr/bin/openssl rand -hex 16)
name="irudd-voice Test Signing $$"

original_list=()
while IFS= read -r line; do
  line=${line#"${line%%[![:space:]]*}"}
  line=${line#\"}
  line=${line%\"}
  [[ -n "$line" ]] && original_list+=("$line")
done < <(security list-keychains -d user)

cleanup() {
  security list-keychains -d user -s "${original_list[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain" # no auto-lock during the test
security unlock-keychain -p "$password" "$keychain"
security list-keychains -d user -s "$keychain" "${original_list[@]}"

fail() { echo "FAIL: $*" >&2; exit 1; }

out=$(IRUDD_VOICE_CERT_NAME="$name" IRUDD_VOICE_KEYCHAIN="$keychain" \
  IRUDD_VOICE_KEYCHAIN_PASSWORD="$password" "$REPO_DIR/scripts/create-signing-certificate.sh")
sha1=$(sed -n 's/^  SHA-1: *//p' <<<"$out")
[[ "$sha1" =~ ^[0-9A-F]{40}$ ]] || fail "no SHA-1 printed: $out"
grep -q "Expires:.*20[0-9][0-9]" <<<"$out" || fail "no expiry printed"

expires_year=$(sed -n 's/^  Expires: .* \(20[0-9][0-9]\) GMT$/\1/p' <<<"$out")
(( expires_year >= $(date +%Y) + 9 )) || fail "certificate should last about 10 years, expires $expires_year"

security find-identity -p codesigning "$keychain" | grep -q "$sha1 \"$name\"" ||
  fail "identity not found in the keychain"

again=$(IRUDD_VOICE_CERT_NAME="$name" IRUDD_VOICE_KEYCHAIN="$keychain" \
  IRUDD_VOICE_KEYCHAIN_PASSWORD="$password" "$REPO_DIR/scripts/create-signing-certificate.sh")
grep -q "already in the keychain" <<<"$again" || fail "second run should reuse the certificate"
grep -q "SHA-1: *$sha1" <<<"$again" || fail "second run should print the same SHA-1"
count=$(security find-identity -p codesigning "$keychain" | grep -c "\"$name\"")
(( count == 1 )) || fail "second run created another certificate"

cp /usr/bin/true "$work/sample"
codesign --force --sign "$sha1" --keychain "$keychain" --timestamp=none "$work/sample" 2>/dev/null ||
  fail "codesign couldn't use the new certificate"
codesign -d -r- "$work/sample" 2>&1 | grep -qi "H\"$sha1\"" ||
  fail "designated requirement doesn't name the certificate"

echo "PASS signing certificate ($sha1)"
