#!/bin/bash
# Create/import one local self-signed macOS code-signing identity.
#
# This certificate is for the current Mac only. It is not an Apple Developer ID,
# is not trusted by other Macs, and cannot be used for notarization. Its purpose
# is stable local signing: repeated builds keep one signing identity so TCC
# approvals (Accessibility / Screen Recording) have a chance to survive rebuilds.
set -euo pipefail

NAME="${1:-${LOCAL_CERT_NAME:-macrdp Local Code Signing}}"
DAYS="${LOCAL_CERT_DAYS:-3650}"
KEYCHAIN="${LOCAL_CERT_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macrdp-local-cert.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

if security find-certificate -a -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 \
    && security find-key -l "$NAME" -s -t private "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Local signing identity already exists: $NAME"
    exit 0
fi

# A certificate without its matching private key is not usable for signing.
# Remove only that orphaned certificate so a fresh keypair can be imported.
if security find-certificate -a -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    security delete-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 || true
fi

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
command -v security >/dev/null || { echo "security not found" >&2; exit 1; }
command -v codesign >/dev/null || { echo "codesign not found" >&2; exit 1; }

CONFIG="$TMP_DIR/openssl.cnf"
KEY="$TMP_DIR/identity.key.pem"
CERT="$TMP_DIR/identity.cert.pem"
P12="$TMP_DIR/identity.p12"

cat > "$CONFIG" <<EOF
[ req ]
distinguished_name = distinguished_name
x509_extensions = codesign
prompt = no
[ distinguished_name ]
CN = $NAME
[ codesign ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

umask 077
openssl genrsa -out "$KEY" 2048 >/dev/null 2>&1
openssl req -new -key "$KEY" -subj "/CN=$NAME" -out "$TMP_DIR/identity.csr.pem" >/dev/null 2>&1
openssl x509 -req \
    -in "$TMP_DIR/identity.csr.pem" \
    -signkey "$KEY" \
    -days "$DAYS" \
    -sha256 \
    -extfile "$CONFIG" \
    -extensions codesign \
    -out "$CERT" >/dev/null 2>&1
# OpenSSL 3 defaults to PBES2 algorithms that older macOS security builds may
# reject. -legacy keeps the PKCS#12 portable across macOS releases.
openssl pkcs12 -legacy -export \
    -out "$P12" \
    -inkey "$KEY" \
    -in "$CERT" \
    -passout pass:macrdp-local-import \
    -name "$NAME" >/dev/null 2>&1

# Import certificate + private key as one identity. Temporary files, including
# the private key, are deleted by trap and never enter this repository.
security import "$P12" \
    -k "$KEYCHAIN" \
    -f pkcs12 \
    -P macrdp-local-import \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

# Let codesign use this key without a prompt on each build. If the login
# keychain is locked, codesign/Keychain Access will request its password.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    "$KEYCHAIN" >/dev/null 2>&1 || true

if ! security find-certificate -a -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 \
    || ! security find-key -l "$NAME" -s -t private "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate imported but identity lookup failed: $NAME" >&2
    echo "Open Keychain Access, unlock $KEYCHAIN, and verify certificate + private key." >&2
    exit 1
fi

echo "Created local signing identity: $NAME"
echo "Keychain: $KEYCHAIN"
echo "Valid for this Mac only; not Apple Developer ID; not notarizable."
