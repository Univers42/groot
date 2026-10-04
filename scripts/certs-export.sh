#!/usr/bin/env bash
# certs-export.sh SRC DEST — copy the local CA out for a browser on ANOTHER machine
# (stack in a VM, browser on the host). Prints the SHA-256 fingerprint and the exact
# host-side import commands; touches no trust store and needs no sudo.
# Every `make certs` on a fresh tree mints a NEW CA, so the host must re-import
# after each VM rebuild — hence delete-then-add in the commands below.
set -eu

src=${1:?usage: certs-export.sh SRC DEST}
dest=${2:?usage: certs-export.sh SRC DEST}
[ -f "$src" ] || {
  echo "[certs-export] no CA at $src; run make certs first" >&2
  exit 1
}
cp "$src" "$dest"
fp=$(openssl x509 -in "$dest" -noout -fingerprint -sha256 | cut -d= -f2)
name=$(basename "$dest")

cat <<EOF
[certs-export] CA copied to $dest
[certs-export] SHA-256 fingerprint: $fp

On the HOST (where the browser runs), as your user, no sudo:

  # 1. fetch it (born2root VM: SSH on port 4242)
  scp -P 4242 <vm-user>@127.0.0.1:$(realpath "$dest") ./$name

  # 2. the fingerprint must match the one above
  openssl x509 -in $name -noout -fingerprint -sha256

  # 3. Chrome / Chromium (NSS db; certutil is in libnss3-tools): drop old Track Binocle CAs, import
  for n in 'Track Binocle Local CA' 'Track Binocle Local Development CA'; do
    while certutil -d sql:\$HOME/.pki/nssdb -D -n "\$n" 2>/dev/null; do :; done
  done
  certutil -d sql:\$HOME/.pki/nssdb -A -t 'C,,' -n 'Track Binocle Local CA' -i $name

  # 4. Firefox: the same per profile
  for db in \$HOME/.mozilla/firefox/*.default* \$HOME/snap/firefox/common/.mozilla/firefox/*.default*; do
    [ -d "\$db" ] || continue
    for n in 'Track Binocle Local CA' 'Track Binocle Local Development CA'; do
      while certutil -d sql:\$db -D -n "\$n" 2>/dev/null; do :; done
    done
    certutil -d sql:\$db -A -t 'C,,' -n 'Track Binocle Local CA' -i $name
  done

  # 5. verify what the browser now trusts, then restart the browser
  certutil -d sql:\$HOME/.pki/nssdb -L -n 'Track Binocle Local CA' -a | openssl x509 -noout -fingerprint -sha256
EOF
