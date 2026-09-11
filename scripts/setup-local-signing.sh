#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity="Clipboard Library Local Signing"
if security find-certificate -c "$identity" >/dev/null 2>&1; then
    echo "Local signing certificate already exists. Reuse it; do not regenerate it."
    exit 0
fi
umask 077
signing_tmp=$(mktemp -d)
trap 'rm -f "$signing_tmp/key.pem" "$signing_tmp/cert.pem" "$signing_tmp/identity.p12"; rmdir "$signing_tmp"' EXIT
openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -config scripts/local-signing.cnf -keyout "$signing_tmp/key.pem" -out "$signing_tmp/cert.pem"
openssl pkcs12 -export -inkey "$signing_tmp/key.pem" -in "$signing_tmp/cert.pem" \
    -name "$identity" -out "$signing_tmp/identity.p12" -passout pass:
security import "$signing_tmp/identity.p12" -f pkcs12 -P '' -T /usr/bin/codesign
echo "Installed local signing identity. Keep this certificate and private key for future builds."
