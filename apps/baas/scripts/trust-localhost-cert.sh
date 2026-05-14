#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CERT_DIR=${TRACK_BINOCLE_CERT_DIR:-"$REPO_DIR/certs"}
CA_CERT="$CERT_DIR/track-binocle-local-ca.pem"
CA_NICKNAME="Track Binocle Local Development CA"
SYSTEM_CA_CERT="/usr/local/share/ca-certificates/track-binocle-local-ca.crt"
INSTALL_SYSTEM=0
VERIFY_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --system)
      INSTALL_SYSTEM=1
      ;;
    --verify)
      VERIFY_ONLY=1
      ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [--system] [--verify]

Imports the Track Binocle local development CA into user browser trust stores.
Use --system to also install it into the Linux system CA store with sudo.
Use --verify to check whether the system CA store has the current CA.
EOF
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

if [ ! -s "$CA_CERT" ]; then
  sh "$SCRIPT_DIR/generate-localhost-cert.sh"
fi

fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^sha256 Fingerprint=//;s/://g'
}

same_certificate() {
  [ -s "$1" ] && [ -s "$2" ] && [ "$(fingerprint "$1")" = "$(fingerprint "$2")" ]
}

verify_system_store() {
  if [ -s "$SYSTEM_CA_CERT" ] && same_certificate "$CA_CERT" "$SYSTEM_CA_CERT"; then
    printf '[certs] Linux system CA store has the current Track Binocle CA.\n'
    return 0
  fi
  if [ -s "$SYSTEM_CA_CERT" ]; then
    printf '[certs] Linux system CA store has a stale Track Binocle CA.\n' >&2
  else
    printf '[certs] Linux system CA store does not have the Track Binocle CA.\n' >&2
  fi
  printf '[certs] VS Code/Electron or system-trust browsers may show ERR_CERT_AUTHORITY_INVALID until you run: make certs-trust-system\n' >&2
  return 1
}

if [ "$VERIFY_ONLY" -eq 1 ]; then
  verify_system_store
  exit $?
fi

ensure_nss_db() {
  db_dir=$1
  mkdir -p "$db_dir"
  if [ ! -f "$db_dir/cert9.db" ]; then
    certutil -N -d "sql:$db_dir" --empty-password >/dev/null 2>&1
  fi
}

trust_nss_db() {
  db_dir=$1
  ensure_nss_db "$db_dir"
  certutil -D -d "sql:$db_dir" -n "$CA_NICKNAME" >/dev/null 2>&1 || true
  certutil -A -d "sql:$db_dir" -n "$CA_NICKNAME" -t "C,," -i "$CA_CERT"
  printf 'Trusted local CA in NSS database: %s\n' "$db_dir"
}

trust_existing_nss_db() {
  db_dir=$1
  [ -f "$db_dir/cert9.db" ] || return 0
  certutil -D -d "sql:$db_dir" -n "$CA_NICKNAME" >/dev/null 2>&1 || true
  certutil -A -d "sql:$db_dir" -n "$CA_NICKNAME" -t "C,," -i "$CA_CERT"
  printf 'Trusted local CA in existing NSS database: %s\n' "$db_dir"
}

if command -v certutil >/dev/null 2>&1; then
  trust_nss_db "$HOME/.pki/nssdb"

  if [ -d "$HOME/.mozilla/firefox" ]; then
    find "$HOME/.mozilla/firefox" -maxdepth 1 -type d \( -name '*.default' -o -name '*.default-release' -o -name '*.default-esr' -o -name '*.dev-edition-default' \) | while IFS= read -r profile_dir; do
      trust_nss_db "$profile_dir"
    done
  fi

  for search_root in \
    "$HOME/snap" \
    "$HOME/.var/app" \
    "$HOME/.config/google-chrome" \
    "$HOME/.config/chromium" \
    "$HOME/.config/BraveSoftware" \
    "$HOME/.config/microsoft-edge" \
    "$HOME/.mozilla"; do
    [ -d "$search_root" ] || continue
    find "$search_root" -type f -name cert9.db -print 2>/dev/null | while IFS= read -r cert_db; do
      trust_existing_nss_db "$(dirname "$cert_db")"
    done
  done
else
  printf '[certs] certutil is required to trust the CA in Chromium/Firefox NSS stores.\n' >&2
  printf '[certs] Install libnss3-tools for browser profile import.\n' >&2
fi

if [ "$INSTALL_SYSTEM" -eq 1 ]; then
  if ! command -v update-ca-certificates >/dev/null 2>&1; then
    printf 'update-ca-certificates is required for --system on this machine.\n' >&2
    exit 1
  fi
  if [ "$(id -u)" -eq 0 ]; then
    cp "$CA_CERT" "$SYSTEM_CA_CERT"
    update-ca-certificates
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp "$CA_CERT" "$SYSTEM_CA_CERT"
    sudo update-ca-certificates
  else
    printf 'sudo is required for --system on this machine.\n' >&2
    exit 1
  fi
  printf 'Trusted local CA in the Linux system CA store.\n'
elif command -v update-ca-certificates >/dev/null 2>&1; then
  verify_system_store || true
fi

printf '\nDone. Fully quit and restart Chrome/Chromium/Firefox, then reopen the Astro dev URL.\n'
