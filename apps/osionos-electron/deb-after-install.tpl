#!/bin/bash

if type update-alternatives 2>/dev/null >&1; then
    # Remove previous link if it doesn't use update-alternatives
    if [ -L '/usr/bin/${executable}' -a -e '/usr/bin/${executable}' -a "`readlink '/usr/bin/${executable}'`" != '/etc/alternatives/${executable}' ]; then
        rm -f '/usr/bin/${executable}'
    fi
    update-alternatives --install '/usr/bin/${executable}' '${executable}' '/opt/${sanitizedProductName}/${executable}' 100 || ln -sf '/opt/${sanitizedProductName}/${executable}' '/usr/bin/${executable}'
else
    ln -sf '/opt/${sanitizedProductName}/${executable}' '/usr/bin/${executable}'
fi

# electron-builder's stock test runs `unshare --user` as root, which passes even where Ubuntu 24.04's
# AppArmor restricts user namespaces for unprivileged users: the helper was left 0755 and the app
# aborted at launch ("The SUID sandbox helper binary was found, but is not configured correctly").
# Caveat: reads the kernel switches, not AppArmor profiles — a host whose profile grants this binary
# userns still gets the setuid helper, which Chromium supports; it never falls back to no sandbox.
userns_restricted() {
    [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ] ||
    [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" = 0 ] ||
    [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)" = 0 ] ||
    ! { [[ -L /proc/self/ns/user ]] && unshare --user true; }
}
if userns_restricted; then
    chown root:root '/opt/${sanitizedProductName}/chrome-sandbox' || true
    chmod 4755 '/opt/${sanitizedProductName}/chrome-sandbox' || true
else
    chmod 0755 '/opt/${sanitizedProductName}/chrome-sandbox' || true
fi

if hash update-mime-database 2>/dev/null; then
    update-mime-database /usr/share/mime || true
fi

if hash update-desktop-database 2>/dev/null; then
    update-desktop-database /usr/share/applications || true
fi
