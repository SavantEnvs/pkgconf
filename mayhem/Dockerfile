# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base). The base already provides debian + clang-19/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV; this only adds meson/ninja
# (pkgconf's build system; ninja/pkg-config ship in the base, meson does not) and runs
# the per-commit build.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t pkgconf-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); an empty value breaks clang, so it is
# never baked as ENV. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declare it WITHOUT a default (no '=') so an unset arg lets the base ENV flow through to
# build.sh, and an explicit --build-arg overrides it.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# pkgconf builds with meson+ninja and is otherwise dependency-free (no meson subprojects/wraps
# to pre-fetch — verified: no subprojects/ dir, no .wrap files, `dependency()` calls are all
# internal). ninja/pkg-config/clang/git already ship in the base; only meson is missing.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true; \
    apt-get update && apt-get install -yq --no-install-recommends meson \
 && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run pkgconf's own meson test suite (426 t/ CLI fixtures + API/OOM/fuzz-replay unit tests) at
# build time — a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
