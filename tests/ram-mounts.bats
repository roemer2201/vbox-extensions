#!/usr/bin/env bats
# Opt-in exercise of the installed polkit policy, kernel mounts and capture.
setup() {
    [ "${VBOX_RELOCATE_MOUNT_TEST:-0}" = 1 ] || skip "enable VBOX_RELOCATE_MOUNT_TEST on a test host"
    helper=/usr/libexec/vbox-relocate/vbox-relocate-helper
    [ -x "${helper}" ] && command -v pkexec && [ "${UID}" != 0 ]
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    folder="${BATS_TEST_TMPDIR}/machine"
    snap="${folder}/Snapshots"
    mkdir -p "${snap}"
    printf '<VirtualBox><Machine uuid="{%s}" snapshotFolder="Snapshots"/></VirtualBox>\n' "${uuid}" > "${folder}/test.vbox"
    printf 'disk' > "${snap}/disk.vdi"
}

@test "installed helper mounts, captures, replays and releases a real overlay" {
    pkexec "${helper}" prepare "${uuid}" 32 "${folder}/test.vbox" "${snap}"
    [ "$(findmnt -n -o FSTYPE --target "${snap}")" = overlay ]
    [ "$(cat "${snap}/disk.vdi")" = disk ]
    printf 'saved' > "${snap}/test.sav"
    pkexec "${helper}" capture "${uuid}" test.sav
    pkexec "${helper}" capture "${uuid}" test.sav
    [ ! -e "${snap}/test.sav" ]
    [ "$(cat "/run/vbox-relocate/${UID}/${uuid}/ram/state/test.sav")" = saved ]
    pkexec "${helper}" release "${uuid}"
    [ "$(cat "${snap}/disk.vdi")" = disk ]
}

teardown() {
    if [ -n "${uuid:-}" ] && [ -f "/run/vbox-relocate/${UID}/${uuid}/operation.json" ]; then
        pkexec "${helper}" release "${uuid}"
    fi
}
