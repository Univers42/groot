#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    STORAGE-dlesieur42.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/09/19 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/09/19 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Storage reshuffle for the VM `dlesieur42` (KVM, 44 G disk, LUKS + LVM, volume
# group fully allocated). Run as root in a terminal WITH a tty:
#     sudo sh infrastructure/docker/osionos/ide-sandbox/STORAGE-dlesieur42.sh
#
# Measured 2026-09-19: /var (docker data-root) 19.4 G LV, 4.4 G free; the
# browser-test image build needs ~5 G and failed twice on ENOSPC. / is an 11 G LV
# with 8.2 G free; swap is a 1.9 G LV with 1.6 G IN USE; /opt is a 1.9 G LV with
# 204 M used (nvim, kulala, excalidraw).
#
#   PART A — no reboot, ~3.3 G moves to /var:
#     swap LV  → a 3 G swapfile on /   (more swap than today; the LV is freed)
#     /opt LV  → 512 M                  (ext4 shrinks unmounted; /opt is idle)
#     freed extents → /var              (online ext4 grow)
#     The root LV's spare 8 G cannot be reclaimed online (ext4 never shrinks
#     mounted, and / is always mounted), so it hosts the swapfile instead.
#
#   PART B — only after the disk was grown in the hypervisor (the durable fix the
#     IDE sandbox plane needs: a 12 G data-root for docker-ide, the rest to /var):
#       host:  virsh blockresize <vm> <disk> 90G      (or: qemu-img resize <disk> +46G, VM off)
#     The script detects the bigger disk and extends sda3 (extended) → sda5 (LUKS)
#     → PV → new LV docker-ide → /var.
set -eu
VG=LVMGroup
SWAPFILE=/swapfile
SWAP_MB=3072
DISK_SECTORS_AT_44G=92274688

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
say() { printf '\n== %s\n' "$1"; }

say "before"
vgs "$VG"; lvs -o lv_name,lv_size "$VG"; df -h / /opt /var | tail -3; free -m | sed -n 2,3p

# ── PART A ────────────────────────────────────────────────────────────────────
say "A1. swap: LV → $SWAPFILE on / (dd, not fallocate: swapon refuses unwritten extents)"
if [ ! -f "$SWAPFILE" ]; then
  dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_MB" status=progress
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
fi
swapon "$SWAPFILE" 2>/dev/null || true
grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
if [ -e "/dev/$VG/swap" ]; then
  # 1.6 G was swapped out when measured; swapoff pages it back in (4.5 G was available).
  swapoff "/dev/$VG/swap"
  sed -i.bak '\|/dev/mapper/LVMGroup-swap|d' /etc/fstab
  # the initramfs may otherwise wait at boot for this LV as a hibernation resume device
  [ -d /etc/initramfs-tools/conf.d ] && echo 'RESUME=none' > /etc/initramfs-tools/conf.d/resume
  lvremove -f "$VG/swap"
  update-initramfs -u
fi
swapon --show

say "A2. /opt: 1.9 G → 512 M (fails loudly if something runs from /opt, e.g. nvim — close it and rerun)"
if [ "$(lvs --noheadings -o lv_size --units m "$VG/opt" | tr -d ' mM' | cut -d. -f1)" -gt 600 ]; then
  umount /opt
  e2fsck -f -y "/dev/$VG/opt"
  resize2fs "/dev/$VG/opt" 480M
  lvreduce -f -L 512M "$VG/opt"
  resize2fs "/dev/$VG/opt"
  mount /opt
fi

say "A3. freed extents → /var"
lvextend -r -l +100%FREE "/dev/$VG/var"

# ── PART B ────────────────────────────────────────────────────────────────────
if [ "$(cat /sys/block/sda/size)" -gt "$DISK_SECTORS_AT_44G" ]; then
  say "B. the disk grew — extend sda3 (extended) → sda5 (LUKS) → PV → LVs"
  echo 1 > /sys/class/block/sda/device/rescan || true
  parted ---pretend-input-tty /dev/sda resizepart 3 100%
  parted ---pretend-input-tty /dev/sda resizepart 5 100%
  partprobe /dev/sda
  cryptsetup resize sda5_crypt
  pvresize /dev/mapper/sda5_crypt
  if ! lvs "$VG/docker-ide" >/dev/null 2>&1; then
    lvcreate -L 12G -n docker-ide "$VG"
    mkfs.ext4 -q -O quota -E quotatype=prjquota "/dev/$VG/docker-ide"
    echo "created /dev/$VG/docker-ide (12 G, prjquota) — ACTIVATE-dlesieur42.sh uses it as DATAROOT_DEV"
  fi
  lvextend -r -l +100%FREE "/dev/$VG/var"
else
  say "B. skipped: disk still 44 G — grow it in the hypervisor first (needed for the sandbox plane only)"
fi

say "after"
vgs "$VG"; lvs -o lv_name,lv_size "$VG"; df -h / /opt /var | tail -3; free -m | sed -n 2,3p
