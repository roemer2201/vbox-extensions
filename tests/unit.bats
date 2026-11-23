#!/usr/bin/env bats
#
# Unit tests for bin/vbox-relocate. They source the script (main is not run
# when sourced) and test helper functions, argument parsing and the
# configuration precedence. No VirtualBox installation is needed.

SCRIPT="${BATS_TEST_DIRNAME}/../bin/vbox-relocate"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.config"
    unset VBOX_RELOCATE_TARGET VBOX_RELOCATE_STRATEGY VBOX_RELOCATE_VERIFY \
          VBOX_RELOCATE_KEEP_SOURCE VBOX_RELOCATE_SILENT VBOX_RELOCATE_VERBOSE
}

# Source the script in a subshell and print the resolved settings.
resolve() {
    bash -c '
        . "$0"
        load_config
        apply_env
        parse_args "$@"
        validate_settings
        printf "%s|%s|%s|%s\n" "${TARGET}" "${STRATEGY}" "${VERIFY}" "${KEEP_SOURCE}"
    ' "${SCRIPT}" "$@"
}

@test "mr_quote escapes quotes and backslashes" {
    run bash -c '. "$0"; mr_quote "a\"b\\c"' "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '"a\"b\\c"' ]
}

@test "state_class maps VirtualBox states" {
    run bash -c '. "$0"; for s in poweroff saved aborted-saved running paused saving restoring; do printf "%s " "$(state_class "$s")"; done' "${SCRIPT}"
    [ "${output}" = "offline offline offline live live transient transient " ]
}

@test "is_below distinguishes prefixes" {
    run bash -c '. "$0"; is_below /a/b/c /a/b && ! is_below /a/bc /a/b && ! is_below /a/b /a/b' "${SCRIPT}"
    [ "${status}" -eq 0 ]
}

@test "normalize_bool accepts common spellings" {
    run bash -c '. "$0"; for v in 1 yes TRUE on 0 no false off; do printf "%s" "$(normalize_bool X "$v")"; done' "${SCRIPT}"
    [ "${output}" = "11110000" ]
}

@test "normalize_bool rejects invalid values with status 2" {
    run bash -c '. "$0"; normalize_bool X maybe' "${SCRIPT}"
    [ "${status}" -eq 2 ]
}

@test "--help and --version exit 0" {
    run "${SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: vbox-relocate"* ]]
    run "${SCRIPT}" --version
    [ "${status}" -eq 0 ]
    [[ "${output}" == "vbox-relocate "* ]]
}

@test "usage errors exit with status 2" {
    run "${SCRIPT}"
    [ "${status}" -eq 2 ]
    run "${SCRIPT}" bogus
    [ "${status}" -eq 2 ]
    run "${SCRIPT}" plan somevm
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"needs --target"* ]]
    run "${SCRIPT}" run vm -t /tmp --strategy fast
    [ "${status}" -eq 2 ]
    run "${SCRIPT}" list --silent --verbose
    [ "${status}" -eq 2 ]
    run "${SCRIPT}" plan vm -t
    [ "${status}" -eq 2 ]
}

@test "defaults apply without config, env or CLI" {
    run resolve plan vm1 -t /x
    [ "${output}" = "/x|auto|size|0" ]
}

@test "precedence: default < config < env < CLI" {
    cat > "${HOME}/.config/vbox-relocate.conf" <<'EOF'
TARGET="/from-config"
VERIFY="checksum"
KEEP_SOURCE=yes
EOF
    run resolve plan vm1
    [ "${output}" = "/from-config|auto|checksum|1" ]

    VBOX_RELOCATE_TARGET=/from-env run resolve plan vm1
    [ "${output}" = "/from-env|auto|checksum|1" ]

    VBOX_RELOCATE_TARGET=/from-env run resolve plan vm1 --target /from-cli --verify size
    [ "${output}" = "/from-cli|auto|size|1" ]
}

@test "organisation-specific user config wins over the generic one" {
    if [ -e /etc/org.conf ]; then
        skip "/etc/org.conf exists on this host"
    fi
    mkdir -p "${HOME}/.config/orgdefault"
    printf 'TARGET="/generic"\n' > "${HOME}/.config/vbox-relocate.conf"
    printf 'TARGET="/orgdefault"\n' > "${HOME}/.config/orgdefault/vbox-relocate.conf"
    run resolve plan vm1
    [ "${output}" = "/orgdefault|auto|size|0" ]
}

@test "tree_listing compares type, path, size and link target" {
    mkdir -p "${BATS_TEST_TMPDIR}/a/sub" "${BATS_TEST_TMPDIR}/b/sub"
    printf 'x' > "${BATS_TEST_TMPDIR}/a/sub/f"
    printf 'y' > "${BATS_TEST_TMPDIR}/b/sub/f"
    ln -s /target "${BATS_TEST_TMPDIR}/a/l"
    ln -s /target "${BATS_TEST_TMPDIR}/b/l"
    run bash -c '. "$0"; diff <(tree_listing "$1") <(tree_listing "$2")' "${SCRIPT}" \
        "${BATS_TEST_TMPDIR}/a" "${BATS_TEST_TMPDIR}/b"
    [ "${status}" -eq 0 ]
    printf 'yy' > "${BATS_TEST_TMPDIR}/b/sub/f"
    run bash -c '. "$0"; diff <(tree_listing "$1") <(tree_listing "$2")' "${SCRIPT}" \
        "${BATS_TEST_TMPDIR}/a" "${BATS_TEST_TMPDIR}/b"
    [ "${status}" -ne 0 ]
}

@test "verification fails if both manifest generators fail" {
    run bash -c '. "$0"; STATE_DIR="$1"; verify_copy "$1/missing-a" "$1/missing-b"' "${SCRIPT}" "${BATS_TEST_TMPDIR}"
    [ "${status}" -ne 0 ]
}

@test "cleanup stops when another machine shares the source directory" {
    mkdir -p "${BATS_TEST_TMPDIR}/vm/child"
    touch "${BATS_TEST_TMPDIR}/vm/mine.vbox" "${BATS_TEST_TMPDIR}/vm/child/other.vbox"
    run bash -c '. "$0"; src_is_dedicated "$1/vm" mine.vbox' "${SCRIPT}" "${BATS_TEST_TMPDIR}"
    [ "${status}" -ne 0 ]
}

@test "default and verbose syslog levels keep protocol stdout clean" {
    mkdir "${BATS_TEST_TMPDIR}/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$LOG_CAPTURE"\n' > "${BATS_TEST_TMPDIR}/bin/logger"
    chmod +x "${BATS_TEST_TMPDIR}/bin/logger"
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" LOG_CAPTURE="${BATS_TEST_TMPDIR}/log"
    run bash -c '. "$0"; MACHINE_READABLE=1; step verify Check; verbose Hidden; VERBOSE=1; verbose Details; result ok' "${SCRIPT}"
    [ "${output}" = $'STEP verify Check\nDEBUG Details\nRESULT ok' ]
    grep -F 'user.debug -- Details' "${LOG_CAPTURE}"
    grep -F 'user.notice -- verify: Check' "${LOG_CAPTURE}"
    ! grep -F Hidden "${LOG_CAPTURE}"
}
