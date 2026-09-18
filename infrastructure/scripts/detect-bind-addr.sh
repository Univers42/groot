#!/bin/sh
# Prints the host bind address for browser-facing Docker Compose ports:
# 0.0.0.0 inside a QEMU/VirtualBox NAT VM (guest gateway 10.0.2.2, where the
# host reaches the guest only via a forwarded port, never guest-loopback),
# 127.0.0.1 everywhere else. See archive/wiki-2026-09/host-browser-https-pipeline.md.
set -eu

is_nat_vm() {
	{ [ -r /sys/class/dmi/id/product_name ] \
		&& grep -qi 'VirtualBox' /sys/class/dmi/id/product_name 2>/dev/null; } \
		|| { [ -r /sys/class/dmi/id/sys_vendor ] \
			&& grep -qiE 'QEMU|KVM' /sys/class/dmi/id/sys_vendor 2>/dev/null; }
}

if is_nat_vm && ip route 2>/dev/null | grep -q 'default via 10\.0\.2\.2'; then
	printf '0.0.0.0\n'
else
	printf '127.0.0.1\n'
fi
