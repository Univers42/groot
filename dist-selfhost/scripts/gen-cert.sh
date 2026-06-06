#!/usr/bin/env sh
# ===========================================================================
# gen-cert.sh — generate a local HTTPS CA + localhost server certificate into
# ./certs for the self-hosted Track-Binocle stack's TLS proxy.
#
# Unlike the monorepo's generate-localhost-cert.sh, this NEVER touches the host
# trust store (no system/Firefox CA install) — a downloaded product must not
# mutate a stranger's machine. The browser shows a one-time "not trusted"
# warning per origin; click through (Advanced -> Proceed), or run the optional
# install.sh --trust-cert to opt in. Idempotent: regenerates only if missing or
# expiring. Requires openssl.
# ===========================================================================
set -eu

CERT_DIR=${TRACK_BINOCLE_CERT_DIR:-"$(pwd)/certs"}
CA_NAME="Track Binocle Local Development CA"
CA_KEY="$CERT_DIR/track-binocle-local-ca-key.pem"
CA_CERT="$CERT_DIR/track-binocle-local-ca.pem"
SERVER_KEY="$CERT_DIR/localhost-key.pem"
SERVER_CSR="$CERT_DIR/localhost.csr"
SERVER_CERT="$CERT_DIR/localhost.pem"
OPENSSL_CONFIG="$CERT_DIR/localhost-openssl.cnf"
SERVER_EXT="$CERT_DIR/localhost-ext.cnf"

command -v openssl >/dev/null 2>&1 || { echo "FATAL: openssl is required to generate local certs." >&2; exit 1; }
mkdir -p "$CERT_DIR"

cat > "$OPENSSL_CONFIG" <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
[dn]
CN = localhost
[req_ext]
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = host.docker.internal
DNS.3 = local-https-proxy
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

cat > "$SERVER_EXT" <<'EOF'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = host.docker.internal
DNS.3 = local-https-proxy
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

ca_regenerated=0
if [ ! -s "$CA_KEY" ] || [ ! -s "$CA_CERT" ]; then
  rm -f "$CA_KEY" "$CA_CERT"
  openssl genrsa -out "$CA_KEY" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
    -subj "/CN=$CA_NAME" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$CA_CERT" >/dev/null 2>&1
  ca_regenerated=1
fi

server_needs_regen=1
if [ "$ca_regenerated" -eq 0 ] && [ -s "$SERVER_KEY" ] && [ -s "$SERVER_CERT" ]; then
  if openssl verify -CAfile "$CA_CERT" "$SERVER_CERT" >/dev/null 2>&1 \
    && openssl x509 -checkend 2592000 -noout -in "$SERVER_CERT" >/dev/null 2>&1; then
    server_needs_regen=0
  fi
fi

if [ "$server_needs_regen" -eq 1 ]; then
  rm -f "$SERVER_KEY" "$SERVER_CSR" "$SERVER_CERT"
  openssl genrsa -out "$SERVER_KEY" 2048 >/dev/null 2>&1
  openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -config "$OPENSSL_CONFIG" >/dev/null 2>&1
  openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$SERVER_CERT" -days 397 -sha256 -extfile "$SERVER_EXT" >/dev/null 2>&1
  echo "[gen-cert] generated localhost certificate chain in $CERT_DIR"
else
  echo "[gen-cert] reusing existing valid localhost certificate in $CERT_DIR"
fi

chmod 600 "$CA_KEY" "$SERVER_KEY"
chmod 644 "$CA_CERT" "$SERVER_CERT"
rm -f "$SERVER_CSR" "$OPENSSL_CONFIG" "$SERVER_EXT"
