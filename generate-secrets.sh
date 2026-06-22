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
KIT_VERSION="$(tr -d '[:space:]' < "$HERE/VERSION" 2>/dev/null || true)"; KIT_VERSION="${KIT_VERSION:-unknown}"

# Veeam-style logging (worker/agent format). This script PRINTS the generated
# secrets to the console for the operator to record, so its log is written
# FILE-ONLY via arec() (NEVER tee'd) and only ever records masked metadata.
if [ -f "$HERE/kslog.sh" ]; then . "$HERE/kslog.sh"
else alog(){ :; }; kslog_runid(){ printf 'no-runid'; }; kslog_agent_banner(){ :; }; KSLOG_MASK='****************'; fi

NO_LOG=""; LOG_OVERRIDE=""; LOG_FILE=""; KS=""; NEXT=""
for a in "$@"; do
  if [ -n "$NEXT" ]; then case "$NEXT" in logf) LOG_OVERRIDE="$a" ;; esac; NEXT=""; continue; fi
  case "$a" in
    --no-log) NO_LOG=1 ;;
    --log)    NEXT=logf ;;
    --log=*)  LOG_OVERRIDE="${a#*=}" ;;
    *)        [ -z "$KS" ] && KS="$a" ;;
  esac
done
KS="${KS:-$HERE/unattended-block.tmpl}"

arec() { [ -n "$LOG_FILE" ] && alog "$@" >> "$LOG_FILE" || true; }   # file-only (never tee — secrets print to console)
on_exit() {
  local rc=$?
  [ -z "$LOG_FILE" ] && return 0
  if [ "$rc" -eq 0 ]; then arec result "SECRETS RESULT: SUCCESS"
  else arec error "SECRETS RESULT: FAILURE (exit $rc)"; fi
}
trap on_exit EXIT

command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 1; }
[[ -f "$KS" ]] || { echo "ERROR: kickstart not found: $KS" >&2; exit 1; }

if [ -z "$NO_LOG" ]; then
  RUN_ID="$(kslog_runid secrets)"
  LOG_DIR="${KSLOG_DIR:-$HERE/logs/$RUN_ID}"
  mkdir -p "$LOG_DIR" || { echo "ERROR: could not create log dir: $LOG_DIR" >&2; exit 1; }
  LOG_FILE="${LOG_OVERRIDE:-$LOG_DIR/Agent.generate-secrets.log}"
  kslog_agent_banner "generate-secrets.sh" "$HERE/generate-secrets.sh" "$KIT_VERSION" "$RUN_ID" >> "$LOG_FILE"
  echo "  -> log: $LOG_FILE"
  arec init "block file: $KS"
fi

BACKUP="$KS.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$KS" "$BACKUP"
arec init "backup of previous block: $BACKUP"

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

# Masked metadata only — the actual values are printed to the console above, never logged.
arec keygen "veeamadmin.mfaSecretKey: $([ -n "${VEEAMADMIN_MFA:-}" ] && echo supplied || echo generated) = $KSLOG_MASK"
arec keygen "veeamso.mfaSecretKey: $([ -n "${VEEAMSO_MFA:-}" ] && echo supplied || echo generated) = $KSLOG_MASK"
arec keygen "veeamso.recoveryToken: $([ -n "${VEEAMSO_TOKEN:-}" ] && echo supplied || echo generated) = $KSLOG_MASK"
arec keygen "secrets written to $KS (values shown on console for recording; NOT logged)"

echo
echo "Backup of previous version: $BACKUP"
echo "Record the values above, then set the veeamadmin/veeamso passwords and the"
echo "NTP server (<<SET_...>> tokens) in $KS before building."
