#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    jdtls-launch.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# jdtls-launch — wrapper that starts Eclipse JDT Language Server on stdio.
# The bridge invokes this via /api/ide/lsp?lang=java. Must emit nothing on
# stdout before the exec (stdout IS the LSP stream).
#
# J2: raise oom_score_adj so the kernel picks jdtls first under memory pressure.
# J3: config/data under /workspace/.osio/jdtls (rootfs is read-only).
# J3: heap limited by JDTLS_XMX (default 448m) so jdtls + baseline ≤ 900 MiB.
# Ponytail: plain javac projects only — Maven/Gradle dependency resolution fails
# (the egress allowlist has no Maven Central) and ~/.m2 would sit on a 64m tmpfs.

set -eu

# J2: raise OOM score adjustment FIRST (no privilege needed). If it fails,
# print one line to stderr and exit 1 — a jdtls the kernel would not pick
# first must not start next to the user's terminal and fs-agent.
if ! printf '1000' > /proc/self/oom_score_adj 2>/dev/null; then
  printf 'jdtls-launch: failed to write /proc/self/oom_score_adj\n' >&2
  exit 1
fi

# J3: configuration area (rootfs is read-only). Copy the Linux default config
# on first run (when config.ini is absent).
CFG_DIR="/workspace/.osio/jdtls/config"
DATA_DIR="/workspace/.osio/jdtls/data"
TMP_DIR="/workspace/.osio/jdtls/tmp"

mkdir -p "$CFG_DIR" "$DATA_DIR" "$TMP_DIR"

if [ ! -f "$CFG_DIR/config.ini" ]; then
  cp -R /opt/jdtls/config_linux/. "$CFG_DIR/"
fi

# J3: exec the JDT LS. Heap is JDTLS_XMX (default 448m, a budget until the J3
# measurement replaces it).
# stdout is the LSP stream — nothing before this exec.
exec /opt/jre21/bin/java \
  -Xmx"${JDTLS_XMX:-448m}" \
  -XX:+UseSerialGC \
  -Xss1m \
  -XX:MaxMetaspaceSize=192m \
  -Djava.io.tmpdir="$TMP_DIR" \
  -Declipse.application=org.eclipse.jdt.ls.core.id1 \
  -Dosgi.bundles.defaultStartLevel=4 \
  -Declipse.product=org.eclipse.jdt.ls.core.product \
  -Dlog.level=WARNING \
  --add-modules=ALL-SYSTEM \
  --add-opens=java.base/java.util=ALL-UNNAMED \
  --add-opens=java.base/java.lang=ALL-UNNAMED \
  -jar /opt/jdtls/launcher.jar \
  -configuration "$CFG_DIR" \
  -data "$DATA_DIR"