#!/usr/bin/env bash
#
# setup_biber.sh — install a pinned biber binary into the GraphLearning env.
#
# Why this exists:
#   tectonic (our LaTeX compiler) ships its own biblatex (currently 3.16,
#   which writes a .bcf control file at version 3.8) but does NOT ship biber.
#   biblatex 3.16 requires biber 2.17 EXACTLY — a newer biber will reject the
#   .bcf as out-of-date. Conda-forge does not package biber, so we install
#   the official upstream binary from SourceForge into the env's bin dir.
#
# Idempotent: runs and exits cleanly when the correct version is already
# present. Re-run by setting FORCE_REINSTALL=1.
#
# Usage:
#   ./setup_biber.sh                # install if missing/wrong version
#   FORCE_REINSTALL=1 ./setup_biber.sh

set -euo pipefail

# ===== Pinned versions (update both together) =====
# When tectonic upgrades its bundled biblatex, this pair must move in lockstep.
# Compatibility matrix: https://github.com/plk/biblatex/wiki/biblatex-and-biber-compatibility-matrix
BIBER_VERSION="2.17"
EXPECTED_BCF_VERSION="3.8"   # informational; the .bcf version biber 2.17 reads

# ===== Config =====
ENV_NAME="GraphLearning"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
ENV_BIN="$REPO_ROOT/.micromamba/envs/$ENV_NAME/bin"
BIBER_BIN="$ENV_BIN/biber"

# ===== Platform detection =====
UNAME_S=$(uname -s)
UNAME_M=$(uname -m)
case "${UNAME_S}-${UNAME_M}" in
  Linux-x86_64)   PLATFORM_DIR="Linux";   ARCHIVE="biber-linux_x86_64.tar.gz" ;;
  Darwin-x86_64)  PLATFORM_DIR="MacOS";   ARCHIVE="biber-darwin_x86_64.tar.gz" ;;
  Darwin-arm64)   PLATFORM_DIR="MacOS";   ARCHIVE="biber-darwin_x86_64.tar.gz"
                  echo "[biber] ⚠️  No native arm64 build; using x86_64 binary under Rosetta." ;;
  *)
    echo "[biber] ❌ Unsupported platform: $UNAME_S-$UNAME_M"
    echo "          Install biber $BIBER_VERSION manually and place it at $BIBER_BIN"
    exit 1
    ;;
esac

# ===== Sanity checks =====
if [ ! -d "$ENV_BIN" ]; then
  echo "[biber] ❌ Env bin dir not found: $ENV_BIN"
  echo "          Run ./setup.sh first to create the GraphLearning env."
  exit 1
fi

# ===== Skip if already correct version =====
if [ -z "${FORCE_REINSTALL:-}" ] && [ -x "$BIBER_BIN" ]; then
  installed=$("$BIBER_BIN" --version 2>/dev/null | awk '/biber version/ {print $3}' | tr -d '\n')
  if [ "$installed" = "$BIBER_VERSION" ]; then
    echo "[biber] ✅ biber $BIBER_VERSION already installed at $BIBER_BIN"
    exit 0
  else
    echo "[biber] 🔄 Found biber $installed; replacing with pinned $BIBER_VERSION"
  fi
fi

# ===== Download + install =====
DL_URL="https://sourceforge.net/projects/biblatex-biber/files/biblatex-biber/${BIBER_VERSION}/binaries/${PLATFORM_DIR}/${ARCHIVE}/download"
TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

echo "[biber] 📥 Downloading biber $BIBER_VERSION ($PLATFORM_DIR)..."
if ! curl -fsSL "$DL_URL" -o "$TMPDIR_LOCAL/biber.tgz"; then
  echo "[biber] ❌ Download failed from $DL_URL"
  exit 1
fi

echo "[biber] 📦 Extracting..."
tar xzf "$TMPDIR_LOCAL/biber.tgz" -C "$TMPDIR_LOCAL"

if [ ! -f "$TMPDIR_LOCAL/biber" ]; then
  echo "[biber] ❌ Extracted archive has no 'biber' executable at top level."
  ls -la "$TMPDIR_LOCAL"
  exit 1
fi

mv "$TMPDIR_LOCAL/biber" "$BIBER_BIN"
chmod +x "$BIBER_BIN"

# ===== Verify =====
installed=$("$BIBER_BIN" --version 2>/dev/null | awk '/biber version/ {print $3}' | tr -d '\n')
if [ "$installed" != "$BIBER_VERSION" ]; then
  echo "[biber] ❌ Verification failed: expected $BIBER_VERSION, got '$installed'"
  exit 1
fi

echo "[biber] ✅ biber $BIBER_VERSION installed to $BIBER_BIN"
echo "[biber]    (compatible with tectonic's bundled biblatex; .bcf v$EXPECTED_BCF_VERSION)"
