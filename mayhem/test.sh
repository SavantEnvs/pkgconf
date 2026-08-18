#!/usr/bin/env bash
#
# pkgconf/mayhem/test.sh — RUN upstream's own meson test suite (built by mayhem/build.sh
# in build-test/) PLUS a set of direct known-answer probes, and emit one CTRF summary.
# exit 0 iff nothing failed.
#
# Two layers, and the SECOND is the load-bearing one (verify-repo's anti-reward-hack
# sabotage check proves this — see the header block below):
#
#  1) `meson test -C build-test` — upstream's real suite: 426 t/{basic,cli,link-abi,
#     ordering,parser,personality,sbom,sysroot,tuple,bomtool,spdxtool,pccritic,symlink}
#     fixtures driven by tests/test-runner.c (each asserts an EXACT/partial expected
#     stdout+exit-code for a real .pc fixture, or an in-process libpkgconf Query:
#     assertion), 15 tests/api/test-*.c known-answer unit tests, an OOM fault-injection
#     unit test, and 2 fuzz-replay tests that drive the parser/solver harnesses over
#     their seed corpus. This is a genuine behavioral suite, not "ran without crashing".
#
#  2) Direct KAT probes against the build-test CLI binaries (pkgconf/spdxtool/bomtool/
#     pccritic — dynamically linked against libpkgconf.so). WHY THIS LAYER EXISTS: meson's
#     own test() pass/fail is EXIT-CODE-ONLY. tests/test-runner.c (the process meson
#     actually launches for 14 of the suites above) is itself a plain dynamically-linked
#     executable under /mayhem, so verify-repo's LD_PRELOAD sabotage shim neuters
#     test-runner ITSELF via its constructor, before it reads a single .test fixture or
#     compares any output — `meson test` then sees exit code 0 and reports "OK" for every
#     one of those suites, same as the un-sabotaged run. That is exactly the
#     go/cargo-test-is-a-static-binary trap (SPEC §6.3), just via a different mechanism
#     (a neutered *dynamic* binary that exits before doing any work, rather than a static
#     binary LD_PRELOAD can't touch at all) — so `meson test`'s summary ALONE cannot be
#     the oracle. Layer 2 fixes this: it invokes each CLI tool directly from bash (bash
#     itself is a system binary the sabotage shim spares) and asserts the CAPTURED
#     stdout/exit code against a fixed, hardcoded expected value taken verbatim from a
#     real t/*.test fixture. A neutered pkgconf/spdxtool/bomtool/pccritic then produces
#     empty stdout + exit 0, which bash's own string/exit-code comparison catches as a
#     FAIL — no test-runner process in between to also be neutered.
#
# This script only RUNS things; mayhem/build.sh did the building (both build-fuzz/ for
# the sanitized harnesses and build-test/ for these CLI tools + upstream's suite).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

TEST_BUILD="$SRC/build-test"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$TEST_BUILD" ]; then
  echo "missing $TEST_BUILD — run mayhem/build.sh first" >&2
  emit_ctrf "meson-test+kat" 0 1 0; exit 2
fi
if ! command -v meson >/dev/null 2>&1; then
  echo "meson not available — cannot run the test suite" >&2
  emit_ctrf "meson-test+kat" 0 1 0; exit 2
fi

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) upstream's own meson test suite ───────────────────────────────────────────────
echo "=== running: meson test -C build-test ==="
out="$(meson test -C "$TEST_BUILD" --print-errorlogs 2>&1)"; rc=$?
echo "$out"

MOK=$(printf '%s\n' "$out" | sed -n 's/^Ok:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
MEXPFAIL=$(printf '%s\n' "$out" | sed -n 's/^Expected Fail:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
MFAIL=$(printf '%s\n' "$out" | sed -n 's/^Fail:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
MUNEXP=$(printf '%s\n' "$out" | sed -n 's/^Unexpected Pass:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
MSKIP=$(printf '%s\n' "$out" | sed -n 's/^Skipped:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
MTIMEOUT=$(printf '%s\n' "$out" | sed -n 's/^Timeout:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
: "${MOK:=0}" "${MEXPFAIL:=0}" "${MFAIL:=0}" "${MUNEXP:=0}" "${MSKIP:=0}" "${MTIMEOUT:=0}"

if [ "$(( MOK + MEXPFAIL + MFAIL + MUNEXP + MSKIP + MTIMEOUT ))" -eq 0 ]; then
  echo "FAIL: could not parse a 'meson test' summary (meson exit $rc)" >&2
  PASSED=$(( PASSED )); FAILED=$(( FAILED + 1 ))
else
  PASSED=$(( PASSED + MOK + MEXPFAIL ))
  FAILED=$(( FAILED + MFAIL + MUNEXP + MTIMEOUT ))
  SKIPPED=$(( SKIPPED + MSKIP ))
fi
echo "meson test: ok=$MOK expected-fail=$MEXPFAIL fail=$MFAIL unexpected-pass=$MUNEXP skipped=$MSKIP timeout=$MTIMEOUT"

# ── 2) direct KAT probes (sabotage-detecting; see header) ───────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. Values are
# copied verbatim from real fixtures (t/cli/cflags-libs.test, t/cli/atleast-version-
# fail.test, t/spdxtool/default-time.test, t/bomtool/source-date-epoch.test,
# t/pccritic/unknown-package.test) so this is exactly the assertion upstream's own
# suite makes, just executed where LD_PRELOAD sabotage can't hide behind test-runner.
kat_expect_exact() {
  local label="$1" expected="$2" got="$3" exp_rc="$4" got_rc="$5"
  if [ "$got_rc" = "$exp_rc" ] && [ "$got" = "$expected" ]; then
    echo "KAT PASS: $label"; PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — exit(got=$got_rc want=$exp_rc) stdout(got=[$got] want=[$expected])" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}
kat_expect_contains() {
  local label="$1" needle="$2" got="$3" exp_rc="$4" got_rc="$5"
  if [ "$got_rc" = "$exp_rc" ] && printf '%s' "$got" | grep -qF "$needle"; then
    echo "KAT PASS: $label"; PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — exit(got=$got_rc want=$exp_rc), expected stdout to contain: $needle" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

PKGCONF_BIN="$TEST_BUILD/pkgconf"
SPDXTOOL_BIN="$TEST_BUILD/spdxtool"
BOMTOOL_BIN="$TEST_BUILD/bomtool"
PCCRITIC_BIN="$TEST_BUILD/pccritic"

# KAT 1 (t/cli/cflags-libs.test): a known .pc fixture resolves to an EXACT --cflags --libs line.
out1="$(PKG_CONFIG_PATH="$SRC/tests/lib1" "$PKGCONF_BIN" --cflags --libs foo 2>/dev/null)"; rc1=$?
kat_expect_exact "pkgconf --cflags --libs foo (tests/lib1)" \
  "-fPIC -I/test/include/foo -L/test/lib -lfoo" "$out1" 0 "$rc1"

# KAT 2 (t/cli/atleast-version-fail.test): a version constraint that must FAIL (exit 1, no stdout).
out2="$(PKG_CONFIG_PATH="$SRC/tests/lib1" "$PKGCONF_BIN" --atleast-version=2.0.0 foo 2>/dev/null)"; rc2=$?
kat_expect_exact "pkgconf --atleast-version=2.0.0 foo (must fail: foo is older)" "" "$out2" 1 "$rc2"

# KAT 3 (t/spdxtool/default-time.test, MatchStdout: Partial): SPDX SBOM serialization
# resolves a real dependency graph (tests/lib-sbom) into JSON containing this exact field.
out3="$(PKG_CONFIG_PATH="$SRC/tests/lib-sbom" "$SPDXTOOL_BIN" test3 2>/dev/null)"; rc3=$?
kat_expect_contains 'spdxtool test3 (tests/lib-sbom) contains "type": "software_Package"' \
  '"type": "software_Package"' "$out3" 0 "$rc3"

# KAT 4 (t/bomtool/source-date-epoch.test, MatchStdout: Partial): SOURCE_DATE_EPOCH is
# rendered as an exact RFC3339 timestamp in the bill-of-materials output.
out4="$(PKG_CONFIG_PATH="$SRC/tests/lib-sbom" SOURCE_DATE_EPOCH=1234567890 "$BOMTOOL_BIN" test3 2>/dev/null)"; rc4=$?
kat_expect_contains "bomtool test3 SOURCE_DATE_EPOCH=1234567890 -> Created: 2009-02-13T23:31:30Z" \
  "Created: 2009-02-13T23:31:30Z" "$out4" 0 "$rc4"

# KAT 5 (t/pccritic/unknown-package.test): pccritic must exit nonzero on an unresolvable module.
out5="$("$PCCRITIC_BIN" this-module-does-not-exist 2>/dev/null)"; rc5=$?
kat_expect_exact "pccritic this-module-does-not-exist (must fail)" "" "$out5" 1 "$rc5"

emit_ctrf "meson-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
