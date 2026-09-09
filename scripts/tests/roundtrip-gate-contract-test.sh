#!/bin/bash
# Make recipe selection contract. No Rust execution, models, accounts or audio.
# Run only after the W2 embargo closes: bash scripts/tests/roundtrip-gate-contract-test.sh
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/codescribe-roundtrip-gate.XXXXXX")
# Every command below is foreground and finite. Make waits for recipe shells;
# bash waits for both cargo/tee pipeline children. No watchdog/sleep to orphan.
cleanup() {
    rm -rf -- "$fixture"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$fixture/bin"

cat > "$fixture/bin/cargo" <<'CARGO'
#!/bin/bash
set -euo pipefail
printf '%s|%s\n' "${CODESCRIBE_E2E_ROUNDTRIP-<unset>}" "$*" >> "$ROUNDTRIP_CALLS"
call_count=$(wc -l < "$ROUNDTRIP_CALLS")
printf 'fake-cargo-call=%s\n' "${call_count// /}"
if [[ $call_count -eq $ROUNDTRIP_FAIL_AT ]]; then
    exit "$ROUNDTRIP_FAIL_RC"
fi
CARGO

# GNU make itself maps recipe failures to exit 2. Record the ACTUAL recipe
# shell status as well to prove the original cargo code survived tee unchanged.
cat > "$fixture/bin/recipe-shell" <<'SHELL'
#!/bin/bash
/bin/bash "$@"
recipe_rc=$?
printf '%s\n' "$recipe_rc" >> "$ROUNDTRIP_SHELL_CODES"
exit "$recipe_rc"
SHELL
chmod +x "$fixture/bin/cargo" "$fixture/bin/recipe-shell"

fail() {
    printf 'roundtrip-gate-contract: %s\n' "$*" >&2
    exit 1
}

run_case() {
    local target=$1 opt_in=$2 fail_at=$3 fail_rc=$4
    local case_root="$fixture/$target-$opt_in-$fail_at-$fail_rc"
    local make_rc=0
    local -a opt_in_env=("ROUNDTRIP_CASE_OPT_IN=$opt_in")
    mkdir -p "$case_root"
    : > "$case_root/calls"
    : > "$case_root/shell-codes"
    if [[ $opt_in != missing ]]; then
        opt_in_env+=("CODESCRIBE_E2E_ROUNDTRIP=$opt_in")
    fi
    # Consume the real repository Makefile, not an extracted/copied recipe.
    # Override only host setup and eager discovery; keep recipe selection,
    # opt-in assignments, cargo commands, tee and failure handling intact.
    # A clean child environment prevents caller MAKEFLAGS/.env from changing it.
    env -i PATH="$fixture/bin:/usr/bin:/bin" \
        ROUNDTRIP_CALLS="$case_root/calls" \
        ROUNDTRIP_SHELL_CODES="$case_root/shell-codes" \
        ROUNDTRIP_FAIL_AT="$fail_at" ROUNDTRIP_FAIL_RC="$fail_rc" \
        "${opt_in_env[@]}" \
        /usr/bin/make --no-print-directory -rR -C "$fixture" -f "$repo_root/Makefile" \
        "SHELL=$fixture/bin/recipe-shell" \
        'CODESCRIBE_APPLE_DEVELOPMENT_IDENTITY=' \
        'CODESCRIBE_DEVELOPER_ID_IDENTITY=' \
        'CODESCRIBE_LICENSE_PUBLIC_KEY_FILE=' 'CODESCRIBE_SPARKLE_PUBLIC_KEY_FILE=' \
        "DATA_ASSETS_DIR=$fixture/absent-corpus" \
        'ENV_LOAD=:' 'TEST_SETUP=LOG="$(TEST_LOG)"' \
        "TEST_LOG=$case_root/test.log" "$target" \
        > "$case_root/make.log" 2>&1 || make_rc=$?

    local expected_rc=0 expected_make_rc=0
    if [[ $fail_at -ne 0 ]]; then
        expected_rc=$fail_rc
        expected_make_rc=2
    fi
    [[ $make_rc -eq $expected_make_rc ]] || fail "$target make exit=$make_rc, expected=$expected_make_rc"
    printf '%s\n' "$expected_rc" > "$case_root/expected-codes"
    cmp -s "$case_root/expected-codes" "$case_root/shell-codes" || fail "$target lost exact recipe exit $expected_rc"

    if [[ $target == test-e2e-roundtrip ]]; then
        printf '%s\n' '1|test --test e2e_vad_flow -- --ignored --nocapture' > "$case_root/expected-calls"
        if [[ $fail_at -ne 1 ]]; then
            printf '%s\n' '1|test --test e2e_round_trip -- --ignored --nocapture' >> "$case_root/expected-calls"
        fi
    else
        local expected_opt_in=$opt_in
        if [[ $opt_in == missing ]]; then expected_opt_in='<unset>'; fi
        printf '%s|%s\n' "$expected_opt_in" 'test --workspace --all-targets -- --nocapture' > "$case_root/expected-calls"
        if [[ $fail_at -eq 0 ]]; then
            grep -q 'Heavy round-trip NOT RUN' "$case_root/test.log" || fail "$target concealed unrun heavy tests"
        fi
    fi
    cmp -s "$case_root/expected-calls" "$case_root/calls" || fail "$target selected unexpected cargo commands or opt-in"
    grep -q 'fake-cargo-call=1' "$case_root/test.log" || fail "$target did not tee cargo output"
    if [[ $fail_at -ne 0 ]] && grep -q 'Done. Log:' "$case_root/test.log"; then
        fail "$target announced completion after cargo failed"
    fi
}

for opt_in in missing 0 yes 1 true; do
    for target in test test-all; do
        run_case "$target" "$opt_in" 0 0
        run_case "$target" "$opt_in" 1 37
    done
    # Explicit target is itself consent; both existing heavy suites get opt-in.
    run_case test-e2e-roundtrip "$opt_in" 0 0
    run_case test-e2e-roundtrip "$opt_in" 1 23
    run_case test-e2e-roundtrip "$opt_in" 2 37
done
printf 'roundtrip-gate-contract: PASS (fake cargo only; no heavy-test evidence)\n'
