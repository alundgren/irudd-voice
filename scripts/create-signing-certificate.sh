#!/usr/bin/env bash
# Create a self-signed code-signing certificate for building irudd-voice.
# Run once per Mac. It's valid for 10 years.
#
# Why: macOS remembers permissions (microphone, accessibility…) per signing
# certificate. Signing every build with the same certificate means you grant
# them once instead of after every update.
#
#   ./scripts/create-signing-certificate.sh
#
# Settings (environment variables):
#   IRUDD_VOICE_CERT_NAME  certificate name (default: "irudd-voice Local Signing")
#   IRUDD_VOICE_KEYCHAIN   keychain file (default: your login keychain)
#   IRUDD_VOICE_KEYCHAIN_PASSWORD
#                          keychain password; only for tests with a throwaway
#                          keychain. Without it you're asked in the terminal.

set -euo pipefail

NAME=${IRUDD_VOICE_CERT_NAME:-"irudd-voice Local Signing"}
KEYCHAIN=${IRUDD_VOICE_KEYCHAIN:-"$HOME/Library/Keychains/login.keychain-db"}
OPENSSL=/usr/bin/openssl # macOS's own; its .p12 files import cleanly into Keychain

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

create_certificate() {
cat >"$work/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -config "$work/cert.conf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null

# The .p12 only exists to carry the key into the keychain, so a random
# one-time password is enough.
p12_password=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/identity.p12" -passout "pass:$p12_password"

security import "$work/identity.p12" -k "$KEYCHAIN" -P "$p12_password" \
  -T /usr/bin/codesign >/dev/null
}

# A second run skips creating the certificate but still does the codesign
# step below, so a run stopped at the password prompt can be finished.
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$NAME\""; then
  echo "Signing certificate \"$NAME\" is already in the keychain."
  status=Checked
else
  create_certificate
  status=Created
fi

# Let Apple's command-line tools (codesign) use the key without a dialog on
# every build. macOS asks for your keychain password here, once.
# Apple marks the -k option deprecated ("Use of the -k option is insecure.
# Omit it to be prompted." in `security`'s help). Omitting it is the intended
# way, even though the terminal prompt itself is labelled "(deprecated)".
echo "Allowing codesign to use the key. Type your Mac login password at the"
echo "prompt below. It's labelled \"(deprecated)\" by macOS; this is the way Apple recommends."
if [[ -n "${IRUDD_VOICE_KEYCHAIN_PASSWORD:-}" ]]; then
  security set-key-partition-list -S apple-tool:,apple: -s -l "$NAME" \
    -k "$IRUDD_VOICE_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
else
  security set-key-partition-list -S apple-tool:,apple: -s -l "$NAME" "$KEYCHAIN" >/dev/null
fi

security find-certificate -c "$NAME" -p "$KEYCHAIN" >"$work/current.pem"
sha1=$("$OPENSSL" x509 -in "$work/current.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
expires=$("$OPENSSL" x509 -in "$work/current.pem" -noout -enddate | sed 's/notAfter=//')
echo
echo "$status \"$NAME\""
echo "  SHA-1:   $sha1"
echo "  Expires: $expires"
echo
echo "Next: ./install.sh"
