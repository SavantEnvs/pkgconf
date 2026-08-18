#!/usr/bin/env bash
#
# pkgconf/mayhem/build.sh — build the three upstream libFuzzer harnesses
# (fuzzer/{parser,solver,spdxtool}-fuzzer.c) as sanitized Mayhem targets, plus a
# standalone (non-fuzzer) reproducer for each, plus a SEPARATE normal-flags build of
# the CLI tools + upstream's own meson test suite for mayhem/test.sh.
#
# Fuzzed surface: libpkgconf's .pc parser (Requires/Conflicts/Provides, ${var}
# interpolation, version comparisons) and its dependency-graph solver, driven through
# upstream's own harnesses. Each harness also drives fuzzer/alloc-inject.c, which
# --wrap's malloc/calloc/realloc/reallocarray/strdup/strndup so the harness can
# exhaustively replay the input with each allocation site failing in turn (OOM-path
# coverage) — see the header comments in fuzzer/*-fuzzer.c. We build EXACTLY upstream's
# fuzzer/meson.build wiring (`-Dfuzzing=true`), just with two edits done from build.sh
# rather than by editing any upstream file (SPEC: never modify upstream files):
#   1. thread $SANITIZER_FLAGS/$DEBUG_FLAGS through CFLAGS/LDFLAGS at `meson setup`
#      time (upstream's own -Dfuzzing=true only adds -fsanitize=fuzzer-no-link; it does
#      not know about our ASan/UBSan/DWARF contract), and
#   2. -Ddefault_library=static, so each fuzzer binary is self-contained (no .so to
#      carry alongside it into /mayhem).
#
# TWO independent meson build directories, per SPEC §6.2 item 10 / §6.3:
#   build-fuzz/  sanitized (ASan+UBSan halting) + DWARF<=3 — libpkgconf + the 3 harnesses.
#                This is what gets fuzzed; the harnesses write only under /tmp (mkstemps/
#                mkdtemp — never an absolute image-dir path, so SPEC §6.2 item 13 is
#                satisfied unmodified).
#   build-test/  NORMAL flags, default_library=shared (meson's default) — the CLI tools
#                (pkgconf/spdxtool/bomtool/pccritic) + upstream's meson test() suite. Kept
#                separate so a benign UB flagged by the sanitized build never false-fails
#                the functional oracle, and so the oracle binaries are DYNAMICALLY linked
#                (libpkgconf.so) and therefore reachable by verify-repo's LD_PRELOAD
#                sabotage check — see mayhem/test.sh for why `meson test`'s own pass/fail
#                is NOT used as that oracle (it is exit-code-only and reward-hackable).
#
# pkgconf is dependency-free for our purposes: no meson subprojects/wraps (no
# subprojects/ dir, no *.wrap files — verified), so there is nothing to vendor for the
# air-gapped re-run (§6.2 item 9 / §6.5) beyond the apt-installed meson/ninja/clang
# already baked into the image by the Dockerfile.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

FUZZ_BUILD="$SRC/build-fuzz"
TEST_BUILD="$SRC/build-test"

# ── 1) Sanitized build: libpkgconf + the 3 harnesses, DWARF<=3, static-linked ─────────
# --wipe so a re-run (offline PATCH tier, §6.2 item 9) reconfigures cleanly if a previous
# partial build-fuzz exists; `meson setup` itself is otherwise idempotent (rejects a
# second `setup` on an already-configured dir without --reconfigure/--wipe).
if [ -d "$FUZZ_BUILD" ]; then
  CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS" \
    meson setup --wipe "$FUZZ_BUILD" -Dfuzzing=true -Ddefault_library=static \
      || { cat "$FUZZ_BUILD/meson-logs/meson-log.txt" 2>/dev/null; exit 1; }
else
  CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS" \
    meson setup "$FUZZ_BUILD" -Dfuzzing=true -Ddefault_library=static \
      || { cat "$FUZZ_BUILD/meson-logs/meson-log.txt" 2>/dev/null; exit 1; }
fi
ninja -C "$FUZZ_BUILD" -j"$MAYHEM_JOBS" \
  fuzzer/parser-fuzzer fuzzer/solver-fuzzer fuzzer/spdxtool-fuzzer libpkgconf.a
echo "built sanitized libpkgconf.a + 3 harnesses (build-fuzz/)"

for t in parser-fuzzer solver-fuzzer spdxtool-fuzzer; do
  cp -f "$FUZZ_BUILD/fuzzer/$t" "/mayhem/$t"
  echo "installed /mayhem/$t"
done

# ── 2) Standalone (non-fuzzer) reproducers ────────────────────────────────────────────
# Recompile each harness's own sources (never a meson-internal .o — those are ninja's
# private object dirs, not a stable link surface) against the SAME sanitized static
# libpkgconf.a from build-fuzz, replacing $LIB_FUZZING_ENGINE with $STANDALONE_FUZZ_MAIN
# (LLVM's run-once driver: reads one input file per argv, calls LLVMFuzzerTestOneInput
# once, no libFuzzer runtime — a natural-crash reproducer). All three harnesses need
# alloc-inject.c; spdxtool-fuzzer additionally needs the spdxtool sources it drives.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

build_standalone() {
  local target="$1"; shift
  local extra_srcs=("$@")
  echo "=== building /mayhem/$target-standalone ==="
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS \
      -I"$SRC" -I"$SRC/cli/spdxtool" \
      -c "$SRC/fuzzer/$target.c" -o "/tmp/$target.o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS \
      -I"$SRC" -I"$SRC/cli/spdxtool" \
      -c "$SRC/fuzzer/alloc-inject.c" -o /tmp/alloc-inject.o
  local extra_objs=()
  for s in "${extra_srcs[@]}"; do
    local o; o="/tmp/$(basename "${s%.c}").o"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -I"$SRC" -I"$SRC/cli/spdxtool" -c "$s" -o "$o"
    extra_objs+=("$o")
  done
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS \
      -Wl,--wrap=malloc -Wl,--wrap=calloc -Wl,--wrap=realloc -Wl,--wrap=reallocarray \
      -Wl,--wrap=strdup -Wl,--wrap=strndup \
      "/tmp/$target.o" /tmp/alloc-inject.o "${extra_objs[@]}" /tmp/standalone_main.o \
      "$FUZZ_BUILD/libpkgconf.a" -o "/mayhem/$target-standalone"
  echo "built /mayhem/$target-standalone"
}

build_standalone parser-fuzzer
build_standalone solver-fuzzer
build_standalone spdxtool-fuzzer \
  "$SRC/cli/spdxtool/core.c" "$SRC/cli/spdxtool/software.c" "$SRC/cli/spdxtool/serialize.c" \
  "$SRC/cli/spdxtool/simplelicensing.c" "$SRC/cli/spdxtool/util.c" "$SRC/cli/spdxtool/generate.c"

# ── 3) Per-target dictionaries ────────────────────────────────────────────────────────
# The Mayhemfiles reference /mayhem/<target>.dict; a referenced-but-absent dict makes
# libFuzzer exit 1 at 0 edges, so copy every one that exists.
for t in parser-fuzzer solver-fuzzer spdxtool-fuzzer; do
  d="mayhem/$t/$t.dict"
  if [ -f "$d" ]; then
    cp -f "$d" "/mayhem/$t.dict"
    echo "copied dictionary /mayhem/$t.dict"
  fi
done

# ── 4) NORMAL-flags build: the CLI tools + upstream's own meson test suite ────────────
# Independent build dir, NO $SANITIZER_FLAGS/$DEBUG_FLAGS — a clean functional-oracle
# build (default_library=shared, meson's default), so pkgconf/spdxtool/bomtool/pccritic/
# test-runner are DYNAMICALLY linked against libpkgconf.so (needed for the sabotage
# check; see mayhem/test.sh). `meson test` builds any not-yet-built test executables
# itself, but do it explicitly here so build.sh is what does the compiling (test.sh only
# RUNS).
if [ -d "$TEST_BUILD" ]; then
  meson setup --wipe "$TEST_BUILD" || { cat "$TEST_BUILD/meson-logs/meson-log.txt" 2>/dev/null; exit 1; }
else
  meson setup "$TEST_BUILD" || { cat "$TEST_BUILD/meson-logs/meson-log.txt" 2>/dev/null; exit 1; }
fi
ninja -C "$TEST_BUILD" -j"$MAYHEM_JOBS"
echo "built normal-flags pkgconf/spdxtool/bomtool/pccritic/test-runner + test suite (build-test/)"

echo "build.sh complete:"
ls -la /mayhem/parser-fuzzer /mayhem/solver-fuzzer /mayhem/spdxtool-fuzzer \
       /mayhem/parser-fuzzer-standalone /mayhem/solver-fuzzer-standalone /mayhem/spdxtool-fuzzer-standalone
