#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    ACTIVATE-dlesieur42.sh                             :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/09/19 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/09/19 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# osionos IDE sandbox plane — OWNER activation for the VM `dlesieur42`, run in a
# terminal WITH a tty (sudo refuses the agent's SSH session), from ~/groot.
# Follows README.md "Activation" with the deviations the risk ruling of
# 2026-09-19 required (devil: BLOCK → lifted by conditions 1–9 below, marked [Cn]).
#
# ── Read this first: the disk arithmetic (measured 2026-09-19) ────────────────
#   /var  (docker data-root, 37 live containers)  19 G LV, 2.6 G free after Part C
#   /     8.3 G free · /home 3.8 G · /opt 1.7 G · /tmp 42 M (!) · LVM VG fully allocated
# The sandbox image is ~2.8 G. Activating it costs, at once:
#   • ~3.5 G on /var to BUILD it on the main daemon (the README's step 1), and
#   • ~5.6 G on the docker-ide data-root to LOAD it (bootstrap.sh does
#     `docker save | docker -H docker-ide load`; the overlay2 graphdriver extracts
#     the whole archive into <data-root>/tmp before registering the layers, so the
#     load transiently needs 2× the image), plus room for the sandboxes themselves.
# Neither fits today: the README's 24 G loopback (or even the 6 G the mission
# sized) has no filesystem to live on. So the FIRST step is storage, owner-only:
#
#   Option A (recommended): grow the VM disk by ≥16 G in the hypervisor, then
#     sudo cryptsetup resize sda5_crypt && sudo pvresize /dev/mapper/sda5_crypt
#     sudo lvcreate -L 12G -n docker-ide LVMGroup
#     sudo mkfs.ext4 -q -O quota -E quotatype=prjquota /dev/LVMGroup/docker-ide
#     → set DATAROOT_DEV=/dev/LVMGroup/docker-ide below; a real LV beats a loopback
#       file (no double page-cache, no image file to lose) and satisfies condition 15
#       exactly as a loopback does (separate, size-capped filesystem).
#     Also free ≥1 G on /var for the build (e.g. review the 7 dangling volumes:
#     docker volume ls -qf dangling=true — app_mongodb_data is DATA, the *_node_modules
#     and *_pnpm_store ones are rebuildable caches).
#   Option B: shrink the sandbox image (ide-sandbox/Dockerfile: default-jdk-headless
#     + rustc/cargo are ~1.3 G of the 2.8 G) so 2× image fits a 6 G loopback on `/`.
#   Option C: build the image DIRECTLY on docker-ide (no save|load, no /var cost):
#     docker -H unix:///run/docker-ide.sock build --network host -t osionos-ide-sandbox:latest infrastructure/docker/osionos/ide-sandbox
#     needs bootstrap.sh to skip the seed when docker-ide already holds the image —
#     a 3-line idempotency patch to a plane script; approve it before the agent applies it.
#
set -eu
cd /home/dlesieur/groot
SB=infrastructure/docker/osionos/ide-sandbox
MNT=/var/lib/docker-ide
DATAROOT_DEV="${DATAROOT_DEV:-/dev/LVMGroup/docker-ide}"   # or a loopback file you created (see Option A/B)
VAR_MIN_KB=3670016                                          # [C3] 3.5 G: refuse to build/seed below this

var_free_kb() { df -Pk /var | awk 'NR==2{print $4}'; }
say() { printf '\n== %s\n' "$1"; }

say "[C4] /tmp is a 1.2 G LV at 97%% — point every tool at a filesystem with room"
export TMPDIR=/var/tmp
df -h /tmp /var/tmp | tail -2

say "[C2] images FIRST, on the main daemon, before anything touches the second daemon"
[ "$(var_free_kb)" -ge "$VAR_MIN_KB" ] || { echo "/var has $(( $(var_free_kb) / 1024 )) MiB free (< 3.5 G) — free space first (see header). STOP."; exit 1; }
docker build -t osionos-ide-egress:latest        "$SB/../ide-egress-proxy"
docker build -t osionos-ide-socket-proxy:latest  "$SB/../ide-socket-proxy"
docker build -t osionos-ide-sandbox:latest       "$SB"
docker image inspect osionos-ide-sandbox:latest osionos-ide-egress:latest osionos-ide-socket-proxy:latest --format '{{index .RepoTags 0}} {{.Size}}'
df -h /var | tail -1

say "socket path must be FREE: the running socket-proxy bind-mounted /run/docker-ide.sock before the daemon existed, so Docker created a DIRECTORY there"
docker compose --env-file ./.env.local --profile ide rm -sf osionos-ide-socket-proxy
if [ -d /run/docker-ide.sock ]; then sudo rmdir /run/docker-ide.sock; fi
[ ! -e /run/docker-ide.sock ] || { echo "/run/docker-ide.sock still exists — STOP"; exit 1; }

say "data-root (condition 15: a separate, size-capped filesystem)"
[ -e "$DATAROOT_DEV" ] || { echo "$DATAROOT_DEV does not exist — create the LV / loopback first (header). STOP."; exit 1; }
sudo mkdir -p "$MNT"
grep -qs " $MNT " /etc/fstab || echo "$DATAROOT_DEV $MNT ext4 prjquota,nofail 0 0" | sudo tee -a /etc/fstab >/dev/null
# (a loopback file needs `loop,prjquota,nofail` instead — edit the line above before running)
sudo systemctl daemon-reload
mountpoint -q "$MNT" || sudo mount "$MNT"
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS "$MNT"

say "[C1] mount guard — RequiresMountsFor= silently resolves to var.mount if the fstab line is wrong, and dockerd would then write 2.8 G onto the main daemon's LV"
findmnt --mountpoint "$MNT" >/dev/null || { echo "$MNT is not a mountpoint — STOP"; exit 1; }
findmnt -no OPTIONS "$MNT" | grep -q prjquota || { echo "$MNT mounted without prjquota — STOP"; exit 1; }   # [C6]
sudo cp "$SB/docker-ide.service" /etc/systemd/system/docker-ide.service
sudo systemctl daemon-reload
systemctl show -p RequiresMountsFor docker-ide | grep -q "$MNT" || { echo "unit lacks RequiresMountsFor=$MNT — STOP"; exit 1; }
systemctl show -p Requires docker-ide | grep -q 'var-lib-docker\\x2dide.mount' || { printf 'docker-ide does not Require var-lib-docker\\x2dide.mount — STOP\n'; exit 1; }

say "[C5] bound the daemon: 7.4 G RAM, 366 M free, 1 G swap used when measured — an unbounded second dockerd would OOM-kill a mini-baas database first"
sudo install -d -m 0755 /etc/systemd/system/docker-ide.service.d
printf '[Service]\nMemoryAccounting=yes\nMemoryMax=1536M\nMemorySwapMax=0\n' | sudo tee /etc/systemd/system/docker-ide.service.d/memory.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now docker-ide
sleep 3
systemctl is-active docker-ide
sudo docker -H unix:///run/docker-ide.sock info --format 'docker-ide {{.ServerVersion}} root={{.DockerRootDir}} secopts={{.SecurityOptions}}'

say "[C6] verify, do not assume: the remap user and the data-root actually used"
getent passwd dockremap
grep dockremap /etc/subuid /etc/subgid
sudo docker -H unix:///run/docker-ide.sock info --format '{{.DockerRootDir}}' | grep -q "^$MNT" || { echo "docker-ide root is NOT under $MNT — STOP"; exit 1; }
test -S /run/docker-ide.sock

say "egress NAT (root-owned copy + drop-in, survives reboots)"
sudo sh "$SB/install-egress-nat.sh"

say "[C3] seed into docker-ide (bootstrap removes the main daemon's 2.8 G copy afterwards)"
df -h "$MNT" | tail -1
sudo TMPDIR=/var/tmp sh "$SB/bootstrap.sh"
df -h /var "$MNT" | tail -2

say "[C9] the 16-condition corpus — must print 'RESULT: 16 passed, 0 failed'; anything else: STOP and report which line failed"
sudo sh "$SB/verify.sh"

say "[C8] filter back up — ONLY now that the socket is a socket (bringing it up earlier recreates the directory bug)"
test -S /run/docker-ide.sock || { echo "socket missing — STOP"; exit 1; }
COMPOSE_PROFILES=ide docker compose --env-file ./.env.local up -d osionos-ide-socket-proxy
docker compose --env-file ./.env.local restart osionos-bridge
docker inspect track-binocle-osionos-ide-socket-proxy --format 'socket-proxy: {{.State.Status}}'
echo
echo "[C7] Record in README.md's condition-15 row: data-root ${DATAROOT_DEV} (12 G LV / or the loopback size you chose), ext4 prjquota,"
echo "     no per-sandbox quota on ext4 → all sandboxes share the headroom; one runaway sandbox can fill the plane (not the host)."
echo "done — open a .c page in the IDE, open the terminal, run: gcc --version"
