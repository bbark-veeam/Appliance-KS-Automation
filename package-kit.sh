#!/usr/bin/env bash
# =============================================================================
# package-kit.sh — package the kit into versioned, retained bundles (INTERNAL)
# =============================================================================
# Reads VERSION and writes, into builds/:
#   Veeam-Appliance-Kickstart-Kit-v<VER>.zip       (customer handoff — allowlist)
#   Veeam-Appliance-Kickstart-scripts-v<VER>.tar.gz (internal/tester — + START-HERE.md)
#
# It NEVER overwrites an existing version, so previous builds in builds/ are kept
# as backups. After making changes: bump VERSION, add a WHATS-NEW.md entry, then
# run this to cut a new build.
#
# Do NOT ship this file or builds/ — internal only.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v zip >/dev/null || { echo "ERROR: zip is required" >&2; exit 1; }

VER="$(tr -d '[:space:]' < "$HERE/VERSION" 2>/dev/null || true)"
[ -n "$VER" ] || { echo "ERROR: VERSION file missing/empty" >&2; exit 1; }

BUILDS="$HERE/builds"; mkdir -p "$BUILDS"
CUST_ZIP="$BUILDS/Veeam-Appliance-Kickstart-Kit-v${VER}.zip"
TEST_TGZ="$BUILDS/Veeam-Appliance-Kickstart-scripts-v${VER}.tar.gz"

if [ -e "$CUST_ZIP" ] || [ -e "$TEST_TGZ" ]; then
  echo "ERROR: build v${VER} already exists in builds/." >&2
  echo "  Bump VERSION (+ add a WHATS-NEW.md entry) before repackaging — old builds are kept as backups." >&2
  exit 1
fi

# Customer-facing allowlist (NO internal/, baseline-stock/, builds/, secrets, *.bak).
CUST="VERSION LICENSE DISCLAIMER.md WHATS-NEW.md README.md CREDENTIALS.md \
unattended-block.tmpl \
make-golden-iso.sh generate-secrets.sh build-appliance-iso.sh check-credentials.sh \
make-golden-remote.ps1 example-custom-post-firewall.sh example-custom-post-storage.sh \
example-custom-post-license.sh"

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT

cdir="$stage/Veeam-Appliance-Kickstart-Kit-v${VER}"; mkdir -p "$cdir"
for f in $CUST; do cp "$HERE/$f" "$cdir/"; done
chmod +x "$cdir"/*.sh
( cd "$stage" && zip -rq "$CUST_ZIP" "Veeam-Appliance-Kickstart-Kit-v${VER}" )

tdir="$stage/Veeam-Appliance-Kickstart-v${VER}"; mkdir -p "$tdir"
for f in $CUST START-HERE.md; do cp "$HERE/$f" "$tdir/"; done
chmod +x "$tdir"/*.sh
tar -czf "$TEST_TGZ" -C "$stage" "Veeam-Appliance-Kickstart-v${VER}"

echo "Packaged kit v${VER}:"
echo "  customer: $CUST_ZIP"
echo "  tester  : $TEST_TGZ"
echo "Previous builds in builds/ are retained as backups."
