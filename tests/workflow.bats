#!/usr/bin/env bats
# Drive the normal CLI with real rsync and a synthetic VirtualBox registry.
bats_require_minimum_version 1.5.0

setup() {
    base="${BATS_TEST_TMPDIR}"
    script="${BATS_TEST_DIRNAME}/../bin/vbox-relocate"
    export WORKFLOW_DIR="${base}" WORKFLOW_TARGET="${base}/target"
    export VBOX_RELOCATE_STATE_DIR="${base}/journals" VBOX_RELOCATE_VM=VM
    export VBOX_RELOCATE_VBOXMANAGE="${BATS_TEST_DIRNAME}/helpers/workflow-vbox"
    export VBOX_RELOCATE_TARGET="${WORKFLOW_TARGET}" VBOX_RELOCATE_STRATEGY=copy
    export VBOX_RELOCATE_RAM_MODE=off VBOX_RELOCATE_YES=1 VBOX_RELOCATE_MACHINE_READABLE=1
    src="${base}/source/VM"
    mkdir -p "${src}/Snapshots" "${WORKFLOW_TARGET}"
    printf '%s' "${src}/VM.vbox" > "${base}/registered"
    printf '{"state":"running"}' > "${src}/VM.vbox"
    printf base > "${src}/base.vdi"
}

@test "live copy pre-copies immutable files, resumes and merges at target" {
    run --separate-stderr "${script}" run --keep-source --verify checksum
    [ "${status}" = 0 ] || { echo "${output} ${stderr}"; return 1; }
    [ "${lines[-1]}" = 'RESULT ok' ]
    [ "$(cat "${base}/registered")" = "${WORKFLOW_TARGET}/VM/VM.vbox" ]
    [ "$(cat "${WORKFLOW_TARGET}/VM/base.vdi")" = "post-snapshot writes" ]
    [ ! -e "${WORKFLOW_TARGET}/VM/Snapshots/history.sav" ]
    compgen -G "${src}.relocated-*/Snapshots/switch.sav"
}

@test "failed savestate merges the temporary snapshot at the live source" {
    WORKFLOW_FAIL=save run --separate-stderr "${script}" run
    [ "${status}" = 1 ] && [ "${lines[-1]}" = 'RESULT rolled-back' ]
    [ "$(cat "${base}/registered")" = "${src}/VM.vbox" ]
    [ ! -e "${src}/Snapshots/delta.vdi" ] && [ ! -d "${WORKFLOW_TARGET}/VM.relocate-tmp" ]
}

@test "failed target registration restarts and merges at the source" {
    WORKFLOW_FAIL=register run --separate-stderr "${script}" run
    [ "${status}" = 1 ] && [ "${lines[-1]}" = 'RESULT rolled-back' ]
    [ "$(cat "${base}/registered")" = "${src}/VM.vbox" ]
    [ "$(cat "${src}/base.vdi")" = "post-snapshot writes" ]
    [ ! -d "${WORKFLOW_TARGET}/VM" ]
}

@test "recover retries a failed merge on the authoritative target" {
    WORKFLOW_FAIL=merge run --separate-stderr "${script}" run
    [ "${status}" = 1 ] && [ "${lines[-1]}" = 'RESULT failed' ]
    [ "$(cat "${base}/registered")" = "${WORKFLOW_TARGET}/VM/VM.vbox" ]
    [ -d "${src}" ]
    run --separate-stderr "${script}" recover
    [ "${status}" = 0 ] && [ "${lines[-1]}" = 'RESULT ok' ]
    [ ! -d "${src}" ] && [ ! -e "${WORKFLOW_TARGET}/VM/Snapshots/history.sav" ]
}

@test "mandatory RAM preflight refuses insufficient memory before snapshot creation" {
    VBOX_RELOCATE_RAM_RESERVE=999999999 VBOX_RELOCATE_RAM_MODE=require run --separate-stderr "${script}" run
    [ "${status}" = 1 ] && [[ "${stderr}" == *"insufficient RAM"* ]]
    [ ! -e "${src}/Snapshots/delta.vdi" ]
    [ -z "$(ls -A "${WORKFLOW_TARGET}")" ]
}

@test "auto selects live copy across filesystem devices" {
    [ -w /dev/shm ] || skip "no writable tmpfs"
    [ "$(stat -c %d "${src}")" != "$(stat -c %d /dev/shm)" ] || skip "need two different filesystems"
    WORKFLOW_TARGET="$(mktemp -d /dev/shm/vbox-workflow.XXXXXXXX)"
    printf '%s' "${WORKFLOW_TARGET}" > "${base}/test-tmpfs"
    VBOX_RELOCATE_TARGET="${WORKFLOW_TARGET}" VBOX_RELOCATE_STRATEGY=auto run --separate-stderr "${script}" run
    [ "${status}" = 0 ] || { echo "${output} ${stderr}"; return 1; }
    [[ "${output}" == *'PLAN same_filesystem="0"'*'PLAN strategy="copy"'* || "${output}" == *'PLAN strategy="copy"'*'PLAN same_filesystem="0"'* ]]
    [ "$(cat "${WORKFLOW_TARGET}/VM/base.vdi")" = "post-snapshot writes" ]
}

teardown() {
    if [ -f "${BATS_TEST_TMPDIR}/test-tmpfs" ]; then
        target="$(cat "${BATS_TEST_TMPDIR}/test-tmpfs")"
        [[ "${target}" = /dev/shm/vbox-workflow.* ]] && rm -rf -- "${target}"
    fi
}
