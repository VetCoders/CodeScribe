#!/bin/bash
# validate-gates.sh - Validate the Makefile GATE LEDGER against the Makefile and CI
#
# The repo has one rule about verification: a command is authoritative only for
# what it executes, and no surface may cite it as proof of something it does not
# run. That rule is unenforceable while the verification surface is a pile of
# targets nobody classified — which is how `make check` came to print "Quality
# gate passed" having run zero tests, and how `.github/workflows/rust.yml` came
# to call `make check` the "full local gate (incl. real-API / heavy e2e tests)".
#
# This script makes the classification machine-checked, in both directions:
#
#   1. every verification target in the Makefile has a GATE LEDGER entry
#      (an unclassified gate cannot exist);
#   2. every ledger entry names a target that still exists (no stale rows);
#   3. class and ci fields carry legal values;
#   4. the `ci=` claim matches what .github/workflows/ actually invokes —
#      so wiring a target into CI without updating the ledger goes red, and so
#      does claiming CI coverage that no workflow provides.
#
# Known limits of check 4, stated rather than implied. It matches `make <target>`
# literally: it does not follow a target reached transitively through $(MAKE)
# inside another recipe, and it does not see a workflow that runs the same
# underlying script directly (release.yml invokes scripts/verify-dmg-payload.sh
# without going through `make verify-dmg`). Those cases belong in the row's reach
# text; widening the field to "is this check covered somehow" would make it a
# judgement call, and a gate that needs judgement is prose.
#
# Same shape as validate-envs.sh, one level up: that one keeps env vars honest
# against docs/ENV_REGISTRY.toml, this one keeps gates honest against CI.
# `tests/gate_registry.rs` runs it under `cargo test`, which is what puts it in
# front of CI — CI never invokes a Makefile quality target directly.
#
# PORTABILITY: written for bash 3.2, which is what /bin/bash still is on macOS
# (verified 2026-08-08: 3.2.57, no `mapfile`, no `declare -A`). This host has
# bash 5 first on PATH and a runner may not, so no bash-4 construct is used —
# a gate that passes or fails on PATH order is not a gate.
#
# Usage:
#   ./scripts/validate-gates.sh          # validate (exit 1 on drift)
#   ./scripts/validate-gates.sh --list   # print the classified surface
#
# Exit codes:
#   0 - ledger, Makefile and CI agree
#   1 - drift (unclassified target, stale row, bad field, or CI mismatch)
#
# Created by Vetcoders (c)2026

set -eo pipefail

MAKEFILE="Makefile"
WORKFLOW_DIR=".github/workflows"
LIST_MODE=0
ERRORS=0

# Targets whose whole job is to verify something. A target whose name matches
# this and carries no ledger row is the failure this script exists to catch.
VERIFICATION_TARGET_RE='^(check|lint|semgrep|verify|verify-.+|test|test-.+|smoke-.+)$'
LEGAL_CLASSES="static hermetic operator"

usage() {
    cat <<EOF
Usage: $0 [--list]

  --list   Print the classified verification surface and exit 0.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            LIST_MODE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! -f "$MAKEFILE" ]]; then
    echo "validate-gates: $MAKEFILE not found (run from the repo root)" >&2
    exit 2
fi

fail() {
    echo "  ✗ $*" >&2
    ERRORS=$((ERRORS + 1))
}

# The app logger is process-global (`Once`), so test isolation must exist in
# the parent shell before the first cargo/xcodebuild child starts. Keep this
# semantic guard here because this script already runs inside `make verify` via
# tests/gate_registry.rs; a Make dry-run would execute recursive recipes and is
# unsafe for several operator targets.
make_block() {
    local start="$1"
    local end="$2"
    sed -n "/^${start}$/,/^${end}$/p" "$MAKEFILE"
}

make_target_block() {
    local target="$1"
    sed -n "/^${target}:/,/^[a-zA-Z0-9_][a-zA-Z0-9_.-]*:/p" "$MAKEFILE"
}

test_data_setup="$(make_block 'define TEST_DATA_DIR_SETUP' 'endef')"
test_setup="$(make_block 'define TEST_SETUP' 'endef')"
verify_recipe="$(sed -n '/^verify:/,/^[a-zA-Z0-9_][a-zA-Z0-9_.-]*:/p' "$MAKEFILE")"

if [[ "$test_data_setup" != *'mktemp -d'* ]]; then
    fail "TEST_DATA_DIR_SETUP must create a unique directory with mktemp -d"
fi
if [[ "$test_data_setup" != *'export CODESCRIBE_DATA_DIR='* ]]; then
    fail "TEST_DATA_DIR_SETUP must export CODESCRIBE_DATA_DIR to every child process"
fi
if [[ "$test_data_setup" != *'trap cleanup_codescribe_test_data_dir EXIT'* ||
      "$test_data_setup" != *'rm -rf -- "$$CODESCRIBE_TEST_DATA_DIR"'* ]]; then
    fail "TEST_DATA_DIR_SETUP must clean its exact mktemp directory on shell exit"
fi
if [[ "$test_setup" != *'$(TEST_DATA_DIR_SETUP)'* ]]; then
    fail "TEST_SETUP must establish process-wide test data isolation"
fi
if [[ "$verify_recipe" != *'$(TEST_DATA_DIR_SETUP)'* ]]; then
    fail "verify must establish process-wide test data isolation before cargo"
elif [[ "${verify_recipe%%cargo test*}" != *'$(TEST_DATA_DIR_SETUP)'* ]]; then
    fail "verify must export its isolated data directory before the first cargo test"
fi
if ! grep -Fq 'export CODESCRIBE_DATA_DIR="$$CODESCRIBE_TEST_DATA_DIR_GUARD"' "$MAKEFILE"; then
    fail "ENV_LOAD must restore the harness-owned CODESCRIBE_DATA_DIR after sourcing operator dotenv"
fi

# These are the operator targets whose direct cargo children share TEST_SETUP.
# Naming them makes removal of the setup fail closed instead of disappearing
# from a dynamic search together with the protection it was meant to enforce.
for target in test test-quick test-e2e test-e2e-real test-sse test-formatting \
              test-engine-apple-channel test-engine-candle test-all; do
    target_recipe="$(make_target_block "$target")"
    if [[ -z "$target_recipe" ]]; then
        fail "$target is missing while test isolation still expects it"
    elif [[ "${target_recipe%%cargo test*}" != *'$(TEST_SETUP)'* ]]; then
        fail "$target must invoke TEST_SETUP before its first cargo test"
    fi
done

# Closed source contract, not a general Make/shell parser. Python's standard
# library compares complete reviewed productions; it never evaluates Make,
# sources the helper, or executes a target. Bash 3.2 remains the shell contract.
# The standalone test-swift rule must pass the prerequisite bridge as argument 2
# in the SAME shell after TEST_DATA_DIR_SETUP. Duplicate/conditional definitions,
# includes/eval and alternate shell settings are outside this bounded language.
# Helper stages below consume the WHOLE body in order (including the result
# pipeline), so a function, early exit, here-doc, dead branch, alias or swallowed
# failure cannot lend its tokens to a successful path. Only blank/comment lines
# BETWEEN complete stages are ignored; continuation and quoted payload bytes
# inside a stage are exact. Safe equivalent rewrites need a reviewed production
# update plus counterexamples, rather than a permissive token-search fallback.
# Assumptions: ordinary Bash/Make/tool semantics and trusted caller overrides;
# this validates repository source, not arbitrary MAKEFLAGS/BASH_ENV or tools.
if ! python3 - "$MAKEFILE" <<'SWIFT_GATE_CONTRACT'
from pathlib import Path
import re
import sys


def refuse(code, detail):
    print("  ✗ test-swift [" + code + "]: " + detail, file=sys.stderr)
    raise SystemExit(1)


def production(source, label):
    """Read one unconditionally defined Make production, without expansion."""
    lines = source.splitlines()
    found = []
    defines = conditions = 0
    continued = False
    for i, line in enumerate(lines):
        was_continued, continued = continued, line.endswith("\\")
        if line.startswith("\t") or not line.strip() or line.lstrip().startswith("#"):
            continue
        line = line.strip()
        if re.match(r"(?:-?include|sinclude)\s", line) or "$(eval" in line or "${eval" in line:
            refuse("make-shape", "includes/eval are outside the supported Make shape")
        if re.match(r"(?:override\s+|export\s+)?(?:\.RECIPEPREFIX|\.SHELLFLAGS)\s*[:?+!]?=", line) or line.startswith((".ONESHELL:", ".IGNORE:")):
            refuse("make-shape", "alternate recipe execution is unsupported")
        if re.match(r"(?:(?:override|export)\s+)*define\s+.*\$", line):
            refuse("make-shape", "dynamic Make definitions are unsupported")
        assignment = re.match(r"([^=]*?)[?:+!]?=", line)
        if assignment and not defines and not was_continued and "$" in assignment.group(1):
            refuse("make-shape", "dynamic Make assignment names are unsupported")
        if line == label:
            if defines or conditions or was_continued:
                refuse("make-shape", "conditional/nested " + label)
            found.append(i)
        if re.match(r"(?:(?:override|export)\s+)*define\s", line):
            defines += 1
        elif line == "endef":
            defines -= 1
        elif re.match(r"(?:ifeq|ifneq|ifdef|ifndef)\b", line):
            conditions += 1
        elif line == "endif":
            conditions -= 1
    if len(found) != 1:
        refuse("make-shape", "expected exactly one " + label)
    return lines, found[0]


def read_source(path):
    # Universal-newline/splitlines normalization could turn invalid shell bytes
    # into an accepted production (notably CRLF, vertical tab and form feed).
    text = path.read_bytes().decode("utf-8")
    if any((ord(c) < 32 and c not in "\n\t") or c in "\x7f\x85\u2028\u2029" for c in text):
        refuse("source-bytes", "unsupported control/line-ending bytes in " + str(path))
    return text


make = read_source(Path(sys.argv[1]))
# A rule may not be borrowed from a define or disabled Make conditional.
lines, start = production(make, "test-swift: $(ENGINE_BRIDGE)")
headers = [line for line in lines if not line.startswith("\t")
           and re.match(r"[^#:=]*\btest-swift\s*(?:[^:=]*):", line)
           and not line.startswith(".PHONY:")]
if headers != ["test-swift: $(ENGINE_BRIDGE)"]:
    refuse("bridge-prerequisite", "expected one canonical Apple STT bridge prerequisite rule")
end = start + 1
while end < len(lines) and (lines[end].startswith("\t") or not lines[end].strip() or lines[end].startswith("#")):
    end += 1
# Trailing prose is not a recipe, but comments inside a continued recipe ARE
# significant. Stop only after its final noncontinued command.
recipe_lines = lines[start:start + 1]
for line in lines[start + 1:end]:
    if not line.startswith("\t"):
        if recipe_lines[-1].endswith("\\"):
            refuse("invocation", "comment/blank interrupts the helper invocation")
        continue
    recipe_lines.append(line)
expected_recipe = r'''test-swift: $(ENGINE_BRIDGE)
	@$(TEST_DATA_DIR_SETUP); \
	$(SHELL) scripts/test-swift.sh "$(PROFILE)" "$(ENGINE_BRIDGE)" \
	  "$(SWIFT_TEST_CODESIGN_IDENTITY)" "$(SWIFT_TEST_MAX_SECONDS)" \
	  "$(SWIFT_TEST_LOG)" $(SWIFT_TEST_ARGS)'''
if recipe_lines != expected_recipe.splitlines():
    refuse("invocation", "require data-directory setup before the connected scripts/test-swift.sh invocation with canonical bridge argument 2")

# The connected setup cannot be shadowed or replaced by token-bearing dead code.
setup_lines, setup_start = production(make, "define TEST_DATA_DIR_SETUP")
expected_setup = r'''define TEST_DATA_DIR_SETUP
CODESCRIBE_TEST_TMP_ROOT="$${TMPDIR:-/tmp}"; \
CODESCRIBE_TEST_TMP_ROOT="$${CODESCRIBE_TEST_TMP_ROOT%/}"; \
if [[ -z "$$CODESCRIBE_TEST_TMP_ROOT" ]]; then CODESCRIBE_TEST_TMP_ROOT=/tmp; fi; \
CODESCRIBE_TEST_DATA_DIR="$$(mktemp -d "$$CODESCRIBE_TEST_TMP_ROOT/codescribe-test-data.XXXXXX")" || { \
  echo "test-data-dir: mktemp failed under $$CODESCRIBE_TEST_TMP_ROOT" >&2; \
  exit 1; \
}; \
export CODESCRIBE_DATA_DIR="$$CODESCRIBE_TEST_DATA_DIR"; \
cleanup_codescribe_test_data_dir() { \
  isolated_log="$$CODESCRIBE_TEST_DATA_DIR/logs/codescribe.log"; \
  if [[ -f "$$isolated_log" ]]; then \
    isolated_bytes="$$(wc -c < "$$isolated_log" | tr -d ' ')"; \
    echo "test-data-dir: isolated-log=$$isolated_log bytes=$$isolated_bytes"; \
  else \
    echo "test-data-dir: isolated-log=none root=$$CODESCRIBE_TEST_DATA_DIR"; \
  fi; \
  case "$$CODESCRIBE_TEST_DATA_DIR" in \
    "$$CODESCRIBE_TEST_TMP_ROOT"/codescribe-test-data.*) \
      rm -rf -- "$$CODESCRIBE_TEST_DATA_DIR"; \
      echo "test-data-dir: cleaned=$$CODESCRIBE_TEST_DATA_DIR"; \
      ;; \
    *) \
      echo "test-data-dir: refusing unsafe cleanup: $$CODESCRIBE_TEST_DATA_DIR" >&2; \
      return 1; \
      ;; \
  esac; \
}; \
trap cleanup_codescribe_test_data_dir EXIT; \
echo "test-data-dir: created=$$CODESCRIBE_TEST_DATA_DIR"
endef'''
if setup_lines[setup_start:setup_start + len(expected_setup.splitlines())] != expected_setup.splitlines():
    refuse("isolation", "TEST_DATA_DIR_SETUP differs from the reviewed creation/export/cleanup production")
for line in lines:
    line = line.strip()
    if re.match(r"(?:(?:override|export)\s+)?(?:define|undefine)\s+(?:TEST_DATA_DIR_SETUP|SHELL)\b", line) and line != "define TEST_DATA_DIR_SETUP":
        refuse("make-shape", "alternate setup/shell definition is unsupported")
    if re.match(r"(?:override\s+|export\s+)?TEST_DATA_DIR_SETUP\s*[:?+!]?=", line):
        refuse("isolation", "TEST_DATA_DIR_SETUP must not be reassigned")
shell_lines = [line.strip() for line in lines if re.match(r"(?:override\s+|export\s+)?SHELL\s*[:?+!]?=", line.strip())]
if shell_lines != ["SHELL := /bin/bash"]:
    refuse("make-shape", "the connected shell must be /bin/bash")

helper = Path("scripts/test-swift.sh")
try:
    body = read_source(helper).splitlines()
except OSError as error:
    refuse("helper-missing", str(error))

stages = [
    ('bindings', r'''set -uo pipefail
PROFILE="$1"
ENGINE_BRIDGE="$2"
SWIFT_TEST_CODESIGN_IDENTITY="$3"
SWIFT_TEST_MAX_SECONDS="$4"
SWIFT_TEST_LOG="$5"
shift 5'''),
    ('self-test', r'''echo "=== Apple phrase-restart Rust/Swift lockstep self-test ==="
"${ENGINE_BRIDGE}" --phrase-restart-self-test || exit $?'''),
    ('artifact-root', r'''# Match build-app profiles; this test path consumes existing host artifacts.
case "$PROFILE" in
  debug) CONFIG=Debug ;;
  release|local-release) CONFIG=Release ;;
  *) echo "test-swift: unsupported profile: $PROFILE" >&2; exit 2 ;;
esac
# Cargo resolves environment and config-relative paths from the repository root.
# No fallback: an old local target must never stand in for the selected library.
if ! TARGET_ROOT="$(cargo metadata --no-deps --format-version 1 | python3 -c '
import json, sys
value = json.load(sys.stdin)["target_directory"]
if (not isinstance(value, str) or not value.startswith("/")
        or any(ord(c) < 32 or ord(c) == 127 or c in chr(34) + chr(39) + chr(92) + "$`" for c in value)):
    raise SystemExit("invalid Cargo target_directory (expected an absolute usable path)")
print(value)
')"; then
  echo "test-swift: cannot resolve Cargo artifact root via cargo metadata" >&2
  exit 2
fi
TARGET_DIR="${TARGET_ROOT%/}/$PROFILE"
if [ ! -f "$TARGET_DIR/libcodescribe_ffi.dylib" ] || [ ! -r "$TARGET_DIR/libcodescribe_ffi.dylib" ]; then
  echo "test-swift: $TARGET_DIR/libcodescribe_ffi.dylib is missing or unreadable." >&2
  echo "test-swift: run 'make app-bindings' (or 'make app') first; only host artifacts are supported." >&2
  exit 2
fi'''),
    ('generation', r'''if ! command -v xcodegen >/dev/null 2>&1; then
  echo "test-swift: xcodegen is required because the Xcode project is generated, not committed." >&2
  exit 2
fi
echo "=== Regenerating Xcode project from project.yml ==="
( cd macos && xcodegen generate ) || exit $?'''),
    ('XCTest', r'''echo "=== Swift front-end tests (CodescribeTests) ==="
cd macos || exit $?
# Prefer the selected dylib at runtime while retaining bundled framework lookup.
xcodebuild test \
  -scheme Codescribe \
  -configuration "$CONFIG" \
  LIBRARY_SEARCH_PATHS="\"$TARGET_DIR\"" \
  LD_RUNPATH_SEARCH_PATHS="\"$TARGET_DIR\" @executable_path/../Frameworks" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="${SWIFT_TEST_CODESIGN_IDENTITY}" \
  "$@" 2>&1 | tee "${SWIFT_TEST_LOG}" | \
  grep -E "^Test Case .* (failed|error)|Executed [0-9]+ tests|^\*\* TEST|error:"
rc=${PIPESTATUS[0]}
executed=$(grep -oE 'Executed [0-9]+ test' "${SWIFT_TEST_LOG}" | tail -1 | grep -oE '[0-9]+')
if [ "$rc" -eq 0 ] && [ "${executed:-0}" -eq 0 ]; then
  echo "test-swift: xcodebuild said TEST SUCCEEDED but executed 0 tests." >&2
  echo "test-swift: a -only-testing filter that matches nothing exits 0 — that is a" >&2
  echo "test-swift: silent pass, not a green gate. Check SWIFT_TEST_ARGS." >&2
  rc=3
fi
secs=$(sed -nE 's/^.*Executed [0-9]+ tests?,.* in ([0-9.]+) \([0-9.]+\) seconds.*$/\1/p' "${SWIFT_TEST_LOG}" | tail -1)
slowest=$(sed -nE "s/^.*CodescribeTests\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' passed \(([0-9.]+) seconds\)\..*$/\3 \1.\2/p" "${SWIFT_TEST_LOG}" | sort -rn | head -1)
echo "test-swift: full log ${SWIFT_TEST_LOG} (rc=$rc, executed=${executed:-0}, seconds=${secs:-unknown})"
if [ -n "$slowest" ]; then echo "test-swift: slowest test $slowest"; fi
if [ "$rc" -eq 0 ] && [ -n "$secs" ] && \
   awk -v s="$secs" -v m="${SWIFT_TEST_MAX_SECONDS}" 'BEGIN{exit !(s>m)}'; then
  echo "test-swift: suite took $secs s, over the ${SWIFT_TEST_MAX_SECONDS} s budget." >&2
  echo "test-swift: green-but-slow is the shape this gate exists to catch — a 10x swing" >&2
  echo "test-swift: here has meant the core is doing real (blocking) work for a test run," >&2
  echo "test-swift: not that the machine is busy. Check the slowest test above, then" >&2
  echo "test-swift: core/config/keychain.rs::in_xctest_host and macos/CodescribeTests/README.md." >&2
  echo "test-swift: if the host really is loaded: make test-swift SWIFT_TEST_MAX_SECONDS=90" >&2
  rc=4
fi
exit $rc''')
]
cursor = 0
for name, expected in stages:
    while cursor < len(body) and (not body[cursor].strip() or body[cursor].lstrip().startswith("#")):
        cursor += 1
    expected_lines = expected.splitlines()
    # Leading comments in the reviewed stage are documentation, not commands.
    while expected_lines and expected_lines[0].startswith("#"):
        expected_lines.pop(0)
    if body[cursor:cursor + len(expected_lines)] != expected_lines:
        refuse(name, "unsupported or missing ordered helper production at line " + str(cursor + 1)
               + "; self-test and generation must fail-fast before XCTest")
    cursor += len(expected_lines)
if any(line.strip() and not line.lstrip().startswith("#") for line in body[cursor:]):
    refuse("helper-shape", "unexpected executable text after the reviewed helper")
SWIFT_GATE_CONTRACT
then
    fail "test-swift connected Make/helper contract could not be established"
fi

# ---------------------------------------------------------------------------
# Collect: verification targets, ledger rows
# ---------------------------------------------------------------------------

# Target definition lines start at column 0 and are not .PHONY / variable
# assignments. Parallel indexed arrays throughout — bash 3.2 has no `declare -A`.
VERIFICATION_TARGETS=""
while IFS= read -r t; do
    if [[ "$t" =~ $VERIFICATION_TARGET_RE ]]; then
        VERIFICATION_TARGETS="$VERIFICATION_TARGETS $t"
    fi
done < <(sed -nE 's/^([a-zA-Z0-9_][a-zA-Z0-9_.-]*):([^=].*)?$/\1/p' "$MAKEFILE" | sort -u)

is_verification_target() {
    case " $VERIFICATION_TARGETS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

LEDGER_NAMES=""
LEDGER_CLASS_OF=()
LEDGER_CI_OF=()
LEDGER_REACH_OF=()
LEDGER_NAME_OF=()

while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    if [[ ! "$row" =~ ^([a-zA-Z0-9_.-]+)[[:space:]]+class=([a-z]+)[[:space:]]+ci=([a-z]+)[[:space:]]+--[[:space:]]+(.+)$ ]]; then
        fail "malformed ledger row: '# gate: $row'"
        echo "    expected: # gate: <target> class=<${LEGAL_CLASSES// /|}> ci=<yes|no> -- <what it runs>" >&2
        continue
    fi
    name="${BASH_REMATCH[1]}"
    class="${BASH_REMATCH[2]}"
    ci="${BASH_REMATCH[3]}"
    reach="${BASH_REMATCH[4]}"

    case " $LEDGER_NAMES " in
        *" $name "*)
            fail "duplicate ledger row for '$name'"
            continue
            ;;
    esac
    case " $LEGAL_CLASSES " in
        *" $class "*) ;;
        *) fail "'$name' has class=$class; legal classes: $LEGAL_CLASSES" ;;
    esac
    if [[ "$ci" != "yes" && "$ci" != "no" ]]; then
        fail "'$name' has ci=$ci; legal values: yes, no"
    fi

    LEDGER_NAMES="$LEDGER_NAMES $name"
    LEDGER_NAME_OF[${#LEDGER_NAME_OF[@]}]="$name"
    LEDGER_CLASS_OF[${#LEDGER_CLASS_OF[@]}]="$class"
    LEDGER_CI_OF[${#LEDGER_CI_OF[@]}]="$ci"
    LEDGER_REACH_OF[${#LEDGER_REACH_OF[@]}]="$reach"
done < <(sed -nE 's/^# gate: (.*)$/\1/p' "$MAKEFILE")

# What CI actually invokes. Workflows call make by name (`run: make release-dmgs`),
# so a literal word-boundary match on `make <target>` is the ground truth here.
#
# Comment lines are stripped first, on purpose: a workflow that *mentions* a
# target in prose is not a workflow that runs it, and that exact confusion is
# what this script exists to remove — rust.yml carried the sentence "Full local
# gate (incl. real-API / heavy e2e tests) still via: make check" above a job
# that ran cargo directly, pointing every reader at a target that runs no tests.
ci_invokes() {
    local target="$1"
    [[ -d "$WORKFLOW_DIR" ]] || return 1
    find "$WORKFLOW_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) -exec cat {} + 2>/dev/null |
        sed -E 's/^[[:space:]]*#.*$//' |
        grep -Eq "(^|[^A-Za-z0-9_-])make[[:space:]]+${target}([[:space:]]|\$)"
}

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

for t in $VERIFICATION_TARGETS; do
    case " $LEDGER_NAMES " in
        *" $t "*) ;;
        *)
            fail "'$t' is a verification target with no GATE LEDGER row"
            echo "    add to the ledger block in $MAKEFILE:" >&2
            echo "    # gate: $t class=<${LEGAL_CLASSES// /|}> ci=<yes|no> -- <what it runs, what it does not>" >&2
            ;;
    esac
done

i=0
while [[ $i -lt ${#LEDGER_NAME_OF[@]} ]]; do
    name="${LEDGER_NAME_OF[$i]}"
    if ! is_verification_target "$name"; then
        fail "ledger row '$name' names no verification target in $MAKEFILE (stale row, or the target was renamed)"
        i=$((i + 1))
        continue
    fi

    claimed="${LEDGER_CI_OF[$i]}"
    if ci_invokes "$name"; then
        actual="yes"
    else
        actual="no"
    fi
    if [[ "$claimed" != "$actual" ]]; then
        if [[ "$actual" == "yes" ]]; then
            fail "'$name' claims ci=no but $WORKFLOW_DIR invokes 'make $name'"
        else
            fail "'$name' claims ci=yes but no workflow in $WORKFLOW_DIR invokes 'make $name'"
        fi
    fi
    i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

printf '%-28s %-10s %-5s %s\n' "TARGET" "CLASS" "CI" "RUNS"
i=0
while [[ $i -lt ${#LEDGER_NAME_OF[@]} ]]; do
    printf '%-28s %-10s %-5s %s\n' \
        "${LEDGER_NAME_OF[$i]}" "${LEDGER_CLASS_OF[$i]}" "${LEDGER_CI_OF[$i]}" "${LEDGER_REACH_OF[$i]}"
    i=$((i + 1))
done

if [[ "$LIST_MODE" -eq 1 ]]; then
    exit 0
fi

if [[ "$ERRORS" -gt 0 ]]; then
    echo "" >&2
    echo "validate-gates: $ERRORS problem(s). The ledger is the repo's answer to" >&2
    echo "validate-gates: \"what did green mean?\" — fix the row or fix the target." >&2
    exit 1
fi

echo ""
echo "validate-gates: ${#LEDGER_NAME_OF[@]} verification targets classified, ledger matches Makefile and CI"
