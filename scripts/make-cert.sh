#!/bin/bash
# One-time: create a self-signed code-signing identity "Susu Local Signing" in the login keychain.
# Why: macOS remembers permissions (microphone, Accessibility) per signing identity. Ad-hoc signing
# changes on every build and the permissions would reset; a fixed local certificate keeps them.
set -euo pipefail
NAME="Susu Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity \"$NAME\" already exists."; exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/cert.cnf" <<EOF
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
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". Check: security find-identity -p codesigning"
