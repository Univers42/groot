#!/usr/bin/env bash
# certs-export.sh SRC DEST — copy the local CA out for a browser on ANOTHER machine
# (stack in a VM, browser on the host). Prints the SHA-256 fingerprint and the exact
# host-side import commands; touches no trust store and needs no sudo.
# Every `make certs` on a fresh tree mints a NEW CA, so the host must re-import
# after each VM rebuild — hence delete-then-add in the commands below. Old copies are
# matched by subject, not nickname: a CA imported through a browser's settings carries
# a nickname of the browser's choosing.
# Ponytail: only the three store paths in step 3 are searched (not snap Chromium or
# flatpak Firefox; born2root's `make groot` covers those), and nicknames come from
# `certutil -L`'s padded columns, so one ending in spaces is trimmed, then not found
# and not offered (under-reports).
set -eu

src=${1:?usage: certs-export.sh SRC DEST}
dest=${2:?usage: certs-export.sh SRC DEST}
[ -f "$src" ] || {
  echo "[certs-export] no CA at $src; run make certs first" >&2
  exit 1
}
cp "$src" "$dest"
fp=$(openssl x509 -in "$dest" -noout -fingerprint -sha256 | cut -d= -f2)
subject=$(openssl x509 -in "$dest" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
name=$(basename "$dest")

cat <<EOF
[certs-export] CA copied to $dest
[certs-export] SHA-256 fingerprint: $fp
[certs-export] subject: $subject

On the HOST (where the browser runs), as your user, no sudo:

  # 1. fetch it (born2root VM: SSH on port 4242)
  scp -P 4242 <vm-user>@127.0.0.1:$(realpath "$dest") ./$name

  # 2. the fingerprint must match the one above
  openssl x509 -in $name -noout -fingerprint -sha256

  ca=./$name
  subject='$subject'
EOF
# Quoted heredoc: everything below runs on the host, so nothing is expanded here.
cat <<'EOF'

  # 3. every NSS store Chrome / Chromium and Firefox read (certutil is in libnss3-tools):
  #    offer to drop each cert with this subject, whatever nickname it was imported
  #    under (a browser's own import names it after the CN), then import the new one
  for db in $HOME/.pki/nssdb $HOME/.mozilla/firefox/*.default* $HOME/snap/firefox/common/.mozilla/firefox/*.default*; do
    [ -f "$db/cert9.db" ] || continue
    certutil -d "sql:$db" -L | tail -n +5 | sed -E 's/[[:space:]]+[^[:space:]]*,[^[:space:]]*,[^[:space:]]*[[:space:]]*$//' |
      while IFS= read -r n; do
        s=$(certutil -d "sql:$db" -L -n "$n" -a | openssl x509 -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
        [ "$s" = "$subject" ] || continue
        printf 'remove "%s" from %s? [y/N] ' "$n" "$db"
        read -r answer </dev/tty
        [ "$answer" = y ] || continue
        while certutil -d "sql:$db" -D -n "$n" 2>/dev/null; do :; done
      done
    certutil -d "sql:$db" -A -t 'C,,' -n 'Track Binocle Local CA' -i "$ca"
  done

  # 4. verify what the browser now trusts, then restart the browser
  certutil -d sql:$HOME/.pki/nssdb -L -n 'Track Binocle Local CA' -a | openssl x509 -noout -fingerprint -sha256
EOF
