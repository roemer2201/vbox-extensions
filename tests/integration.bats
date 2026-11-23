#!/usr/bin/env bats
#
# Integration tests for bin/vbox-relocate against a real VBoxManage.
#
# Requirements: VirtualBox (VBoxManage), bats. Optional: root and
# btrfs-progs for the reflink tests (a btrfs image is loop-mounted).
# VMs cannot be started in a container without the VirtualBox kernel driver,
# so running VMs are simulated by tests/helpers/vboxmanage-sim. A private
# VBOX_USER_HOME keeps the test VMs away from the user's VirtualBox setup.

bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME}/../bin/vbox-relocate"
SIM="${BATS_TEST_DIRNAME}/helpers/vboxmanage-sim"

setup_file() {
    if ! command -v VBoxManage >/dev/null; then
        skip "VBoxManage not installed"
    fi
    if ! VBOX_USER_HOME="${BATS_FILE_TMPDIR}/vbox-home" VBoxManage list vms >/dev/null 2>&1; then
        skip "VBoxSVC cannot open its IPC service on this host"
    fi
    export BASE="${BATS_FILE_TMPDIR}"
    export VBOX_USER_HOME="${BASE}/vbox-home"
    export VBOXSIM_DIR="${BASE}/sim"
    export VBOX_RELOCATE_VBOXMANAGE="${SIM}"
    export VBOX_RELOCATE_STATE_DIR="${BASE}/state"
    mkdir -p "${VBOX_USER_HOME}" "${BASE}/ext" "${BASE}/iso"
    truncate -s 1M "${BASE}/iso/shared.iso"

    # btrfs for the reflink tests (needs root and loop devices).
    export BTRFS=""
    if [ "$(id -u)" -eq 0 ] && command -v mkfs.btrfs >/dev/null; then
        truncate -s 1G "${BASE}/btrfs.img"
        if mkfs.btrfs -q -f "${BASE}/btrfs.img" && mkdir -p "${BASE}/btrfs" && \
           mount -o loop "${BASE}/btrfs.img" "${BASE}/btrfs"; then
            export BTRFS="${BASE}/btrfs"
        fi
    fi
}

teardown_file() {
    local vm
    if [ -n "${BASE:-}" ] && command -v VBoxManage >/dev/null; then
        for vm in $("${SIM}" list vms | sed -n 's/.*{\(.*\)}$/\1/p'); do
            "${SIM}" unregistervm "${vm}" >/dev/null 2>&1 || true
        done
    fi
    if [ -n "${BTRFS:-}" ]; then
        umount "${BTRFS}" || true
    fi
}

setup() {
    unset VBOXSIM_FAIL
    if [ -z "${BASE:-}" ]; then
        skip "setup_file was skipped"
    fi
}

# Create a VM with two disks, an ISO outside the folder and two snapshots.
# Usage: create_vm NAME BASEFOLDER
create_vm() {
    local name="${1}" base="${2}"
    mkdir -p "${base}"
    "${SIM}" createvm --name "${name}" --ostype Ubuntu_64 --register --basefolder "${base}" >/dev/null
    "${SIM}" modifyvm "${name}" --memory 256 --vram 16 >/dev/null
    "${SIM}" storagectl "${name}" --name SATA --add sata --portcount 4 >/dev/null
    "${SIM}" createmedium disk --filename "${base}/${name}/disk1.vdi" --size 32 >/dev/null 2>&1
    "${SIM}" createmedium disk --filename "${base}/${name}/disk2.vmdk" --format VMDK --size 16 >/dev/null 2>&1
    "${SIM}" storageattach "${name}" --storagectl SATA --port 0 --type hdd --medium "${base}/${name}/disk1.vdi"
    "${SIM}" storageattach "${name}" --storagectl SATA --port 1 --type hdd --medium "${base}/${name}/disk2.vmdk"
    "${SIM}" storageattach "${name}" --storagectl SATA --port 2 --type dvddrive --medium "${BASE}/iso/shared.iso"
    "${SIM}" snapshot "${name}" take s1 >/dev/null 2>&1
    "${SIM}" snapshot "${name}" take s2 >/dev/null 2>&1
}

# Print one machine-readable value of a VM (e.g. vm_value NAME CfgFile).
vm_value() {
    "${SIM}" showvminfo "${1}" --machinereadable | sed -n "s/^\"\{0,1\}${2}\"\{0,1\}=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" | head -n 1
}

# Mark a VM as running in the simulator.
set_running() {
    touch "${VBOXSIM_DIR}/$(vm_value "${1}" UUID).running"
}

need_btrfs() {
    if [ -z "${BTRFS}" ]; then
        skip "btrfs loop mount not available (needs root and btrfs-progs)"
    fi
}

@test "plan changes nothing" {
    create_vm t-plan "${BASE}/ext/vms"
    mkdir -p "${BASE}/ext/new-plan"
    run "${SCRIPT}" plan t-plan -t "${BASE}/ext/new-plan"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Strategy:      offline"* ]]
    [ "$(vm_value t-plan CfgFile)" = "${BASE}/ext/vms/t-plan/t-plan.vbox" ]
    [ -z "$(ls -A "${BASE}/ext/new-plan")" ]
}

@test "offline relocation on btrfs uses reflink and keeps snapshots" {
    need_btrfs
    create_vm t-off "${BTRFS}/vms"
    mkdir -p "${BTRFS}/new"
    run "${SCRIPT}" run t-off -t "${BTRFS}/new" --yes --verify checksum
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"reflink: 1"* ]]
    [ "$(vm_value t-off CfgFile)" = "${BTRFS}/new/t-off/t-off.vbox" ]
    [ "$(vm_value t-off SnapshotName-1)" = "s2" ]
    [ "$(vm_value t-off '"SATA-2-0"')" = "${BASE}/iso/shared.iso" ] || \
        "${SIM}" showvminfo t-off --machinereadable | grep -q "shared.iso"
    [ ! -e "${BTRFS}/vms/t-off" ]
    run "${SIM}" list hdds
    [[ "${output}" != *"${BTRFS}/vms/t-off/"* ]]
}

@test "offline relocation to another file system copies with rsync, keeps source, machine-readable" {
    need_btrfs
    create_vm t-rsync "${BTRFS}/vms"
    mkdir -p "${BASE}/ext/new-rsync"
    run "${SCRIPT}" run t-rsync -t "${BASE}/ext/new-rsync" --yes --keep-source --machine-readable
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'PLAN reflink="0"'* ]]
    [[ "${output}" == *"PROGRESS 100 copy"* ]]
    [ "${lines[-1]}" = "RESULT ok" ]
    [ "$(vm_value t-rsync CfgFile)" = "${BASE}/ext/new-rsync/t-rsync/t-rsync.vbox" ]
    ls -d "${BTRFS}/vms/t-rsync.relocated-"*
}

@test "machine-readable STDOUT contains only protocol records" {
    create_vm t-proto "${BASE}/ext/vms"
    mkdir -p "${BASE}/ext/new-proto"
    run --separate-stderr "${SCRIPT}" run t-proto -t "${BASE}/ext/new-proto" --yes --machine-readable
    [ "${status}" -eq 0 ]
    local line
    for line in "${lines[@]}"; do
        [[ "${line}" =~ ^(PLAN|VM|STEP|PROGRESS|DOWNTIME|INFO|DEBUG|WARN|RESULT)\  ]] || {
            echo "unexpected line: ${line}"
            return 1
        }
    done
}

@test "saved VM is relocated offline and stays saved" {
    create_vm t-saved "${BASE}/ext/vms"
    set_running t-saved
    "${SIM}" controlvm t-saved savestate
    [ "$(vm_value t-saved VMState)" = "saved" ]
    mkdir -p "${BASE}/ext/new-saved"
    run "${SCRIPT}" run t-saved -t "${BASE}/ext/new-saved" --yes
    [ "${status}" -eq 0 ]
    [ "$(vm_value t-saved VMState)" = "saved" ]
    [[ "$(vm_value t-saved VMStateFile)" == "${BASE}/ext/new-saved/t-saved/Snapshots/"*.sav ]]
    [ -f "$(vm_value t-saved VMStateFile)" ]
}

@test "running VM on btrfs is relocated with strategy reflink" {
    need_btrfs
    create_vm t-live "${BTRFS}/vms"
    set_running t-live
    mkdir -p "${BTRFS}/new-live"
    run --separate-stderr "${SCRIPT}" run t-live -t "${BTRFS}/new-live" --yes --machine-readable
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'PLAN strategy="reflink"'* ]]
    [[ "${output}" == *"DOWNTIME begin"* ]]
    [[ "${output}" == *"DOWNTIME end"* ]]
    [ "$(vm_value t-live VMState)" = "running" ]
    [ "$(vm_value t-live CfgFile)" = "${BTRFS}/new-live/t-live/t-live.vbox" ]
    [ ! -e "${BTRFS}/vms/t-live" ]
}

@test "live cross-filesystem relocation merges only the temporary snapshot" {
    need_btrfs
    create_vm t-copy "${BTRFS}/vms"
    set_running t-copy
    mkdir -p "${BASE}/ext/new-copy"
    run "${SCRIPT}" run t-copy -t "${BASE}/ext/new-copy" --yes --ram-mode off --machine-readable
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'PLAN strategy="copy"'* ]]
    [ "$(vm_value t-copy VMState)" = running ]
    [ "$(vm_value t-copy SnapshotName-1)" = s2 ]
    [ "$(vm_value t-copy CfgFile)" = "${BASE}/ext/new-copy/t-copy/t-copy.vbox" ]
    [ ! -e "${BTRFS}/vms/t-copy" ]
}

@test "failed registration at the target rolls back to the running source" {
    need_btrfs
    create_vm t-rb "${BTRFS}/vms"
    set_running t-rb
    mkdir -p "${BTRFS}/new-rb"
    rm -f "${VBOXSIM_DIR}/register-failed-once"
    VBOXSIM_FAIL=register-once run --separate-stderr "${SCRIPT}" run t-rb -t "${BTRFS}/new-rb" --yes --machine-readable
    [ "${status}" -eq 1 ]
    [ "${lines[-1]}" = "RESULT rolled-back" ]
    [ "$(vm_value t-rb VMState)" = "running" ]
    [ "$(vm_value t-rb CfgFile)" = "${BTRFS}/vms/t-rb/t-rb.vbox" ]
    [ -z "$(ls -A "${BTRFS}/new-rb")" ]
    [ ! -e "${VBOX_RELOCATE_STATE_DIR}/$(vm_value t-rb UUID).journal" ]
}

@test "failed savestate leaves the VM running and changes nothing" {
    need_btrfs
    create_vm t-sf "${BTRFS}/vms"
    set_running t-sf
    mkdir -p "${BTRFS}/new-sf"
    VBOXSIM_FAIL=savestate run "${SCRIPT}" run t-sf -t "${BTRFS}/new-sf" --yes
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"keeps running at the source"* ]]
    [ "$(vm_value t-sf VMState)" = "running" ]
    [ -z "$(ls -A "${BTRFS}/new-sf")" ]
}

@test "incomplete rollback can be finished with recover" {
    need_btrfs
    create_vm t-rec "${BTRFS}/vms"
    set_running t-rec
    mkdir -p "${BTRFS}/new-rec"
    # Every start fails: the target start and the restart at the source.
    VBOXSIM_FAIL=start run "${SCRIPT}" run t-rec -t "${BTRFS}/new-rec" --yes
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Rollback incomplete"* ]]
    [ "$(vm_value t-rec VMState)" = "saved" ]
    [ "$(vm_value t-rec CfgFile)" = "${BTRFS}/vms/t-rec/t-rec.vbox" ]
    run "${SCRIPT}" recover t-rec --yes
    [ "${status}" -eq 0 ]
    [ "$(vm_value t-rec VMState)" = "running" ]
}

@test "blocking problems are reported and nothing is changed" {
    create_vm t-block "${BASE}/ext/vms"
    run "${SCRIPT}" run t-block -t "${BASE}/ext/does-not-exist" --yes
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Target directory does not exist"* ]]

    mkdir -p "${BASE}/ext/new-block/t-block" "${BASE}/ext/new-block/t-block.relocate-tmp"
    run "${SCRIPT}" run t-block -t "${BASE}/ext/new-block" --yes
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Target folder already exists"* ]]
    [[ "${output}" == *"Leftover temporary folder"* ]]
    [[ "${output}" == *"2 blocking problem(s)"* ]]
    [ "$(vm_value t-block CfgFile)" = "${BASE}/ext/vms/t-block/t-block.vbox" ]

    run "${SCRIPT}" run t-block -t "${BASE}/ext/vms" --yes
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"already located"* ]]
}

@test "VM whose images are used by a linked clone is refused" {
    create_vm t-base "${BASE}/ext/vms"
    "${SIM}" clonevm t-base --snapshot s1 --options link --name t-clone --register \
        --basefolder "${BASE}/ext/clones" >/dev/null 2>&1
    mkdir -p "${BASE}/ext/new-base"
    run "${SCRIPT}" plan t-base -t "${BASE}/ext/new-base"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"linked clone"* ]]
}
