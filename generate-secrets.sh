#!/usr/bin/env bash
# =============================================================================
# generate-secrets.sh — generate fresh, per-deployment secret keys
# =============================================================================
# Fills the <<GENERATE_...>> tokens in the target kickstart with cryptographically
# random values:
#   - veeamadmin.mfaSecretKey     16-char Base32 (TOTP secret)
#   - veeamso.mfaSecretKey        16-char Base32 (TOTP secret)
#   - veeamso.recoveryToken       GUID (hex)
#
# RUN THIS ONCE PER ORGANIZATION / DEPLOYMENT. The kit ships with placeholders,
# not preset keys, so no two organizations ever build an ISO with the same
# secret keys. Re-running generates new values (a timestamped backup is kept).
#
# This fills the role-agnostic unattended block (unattended-block.tmpl), which the
# build then inserts into the stock kickstart it extracts from your source ISO.
# One block serves all roles, so there is no per-role argument.
#
# Usage:  ./generate-secrets.sh [block-file]
#   default block-file: unattended-block.tmpl
#
# SUPPLY YOUR OWN values (instead of generating) via env vars — any you set are
# validated and used as-is; any you omit are auto-generated:
#   VEEAMADMIN_MFA=<16-char Base32>  VEEAMSO_MFA=<16-char Base32>  VEEAMSO_TOKEN=<GUID>
#   e.g.  VEEAMSO_TOKEN=... VEEAMADMIN_MFA=... ./generate-secrets.sh
#
# Requires: python3 (present on macOS and Linux).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KS="${1:-$HERE/unattended-block.tmpl}"

command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 1; }
[[ -f "$KS" ]] || { echo "ERROR: kickstart not found: $KS" >&2; exit 1; }

BACKUP="$KS.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$KS" "$BACKUP"

KS="$KS" python3 - <<'PY'
import os, re, secrets, base64, uuid

ks = os.environ['KS']
b32 = lambda: base64.b32encode(secrets.token_bytes(10)).decode()   # 80 bits -> 16 chars

def take(env, validate, gen, label):
    v = os.environ.get(env, '').strip()
    if not v:
        return gen()
    if not validate(v):
        raise SystemExit(f"ERROR: {env} has an invalid format ({label})")
    return v

is_b32  = lambda s: re.fullmatch(r'[A-Z2-7]{16}', s) is not None
is_guid = lambda s: re.fullmatch(r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}', s) is not None

admin_mfa = take('VEEAMADMIN_MFA', is_b32,  b32,                              '16-char Base32')
so_mfa    = take('VEEAMSO_MFA',    is_b32,  b32,                              '16-char Base32')
token     = take('VEEAMSO_TOKEN',  is_guid, lambda: str(uuid.uuid4()).upper(), 'GUID 8-4-4-4-12 hex')

text = open(ks).read()
subs = {
    r'^(veeamadmin\.mfaSecretKey=).*$': admin_mfa,
    r'^(veeamso\.mfaSecretKey=).*$':    so_mfa,
    r'^(veeamso\.recoveryToken=).*$':   token,
}
for pat, val in subs.items():
    text, n = re.subn(pat, lambda m, v=val: m.group(1) + v, text, flags=re.M)
    if n != 1:
        raise SystemExit(f"ERROR: expected exactly 1 match for {pat!r}, found {n} — aborting")
open(ks, 'w').write(text)

print("Per-deployment secrets written to:", ks)
print()
print(f"  veeamadmin.mfaSecretKey = {admin_mfa}    (enroll in an authenticator if veeamadmin MFA is enabled)")
print(f"  veeamso.mfaSecretKey    = {so_mfa}    (veeamso enrolls this in an authenticator app)")
print(f"  veeamso.recoveryToken   = {token}    (STORE SECURELY — cannot be recovered later)")
PY

echo
echo "Backup of previous version: $BACKUP"
echo "Record the values above, then set the veeamadmin/veeamso passwords and the"
echo "NTP server (<<SET_...>> tokens) in $KS before building."
