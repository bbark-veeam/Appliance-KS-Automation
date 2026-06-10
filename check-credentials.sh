#!/usr/bin/env bash
# =============================================================================
# check-credentials.sh — verify the veeamadmin/veeamso credentials in a kickstart
#                        meet the appliance password policy (DISA STIG-aligned)
# =============================================================================
# READ-ONLY. Run it against the unattended block before building, or against the
# derived kickstart inside a built/mounted ISO to diagnose a "dropped to manual
# configuration" first boot.
#
# Usage:
#   ./check-credentials.sh [file]
#   default file: unattended-block.tmpl   (pre-build, the block you fill)
#   e.g.  ./check-credentials.sh /mnt/proxy-ks.cfg   (derived ks on a mounted ISO)
#
# Checks (passwords): 15+ chars; upper+lower+digit+special; NO MORE THAN 4 of the
# same class (U/L/D/S) in a row (maxclassrepeat=4) and NO MORE THAN 3 identical
# chars in a row (maxrepeat=3); not containing the
# account name; veeamadmin != veeamso. Dictionary-word rule is checked via
# `cracklib-check` if installed (the appliance enforces it regardless).
# Also sanity-checks MFA key / recovery-token formats, isEnabled/isMfaEnabled
# consistency, and leftover <<...>> placeholders.
#
# Exit 0 = compliant, 1 = non-compliant, 2 = usage/error.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KS="${1:-$HERE/unattended-block.tmpl}"
[ -f "$KS" ] || { echo "ERROR: file not found: $KS" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 2; }

KS="$KS" CRACKLIB="$(command -v cracklib-check || true)" python3 - <<'PY'
import os, re, subprocess, sys
ks = open(os.environ['KS']).read()
crack = os.environ.get('CRACKLIB', '')

def get(k):
    m = re.search(r'^%s=(.*)$' % re.escape(k), ks, re.M)
    return m.group(1) if m else None

cls = lambda c: 'U' if c.isupper() else 'L' if c.islower() else 'D' if c.isdigit() else 'S'

def check_pw(pw, label):
    if pw is None:        return ["%s.password: not found in kickstart" % label]
    if '<<' in pw:        return ["%s.password: still an unfilled placeholder" % label]
    issues = []
    if len(pw) < 15:                       issues.append("needs 15+ characters")
    if not re.search(r'[A-Z]', pw):        issues.append("needs an uppercase letter")
    if not re.search(r'[a-z]', pw):        issues.append("needs a lowercase letter")
    if not re.search(r'[0-9]', pw):        issues.append("needs a digit")
    if not re.search(r'[^A-Za-z0-9]', pw): issues.append("needs a special character")
    class_run = ident_run = 1
    for i in range(1, len(pw)):
        class_run = class_run + 1 if cls(pw[i]) == cls(pw[i-1]) else 1
        ident_run = ident_run + 1 if pw[i] == pw[i-1] else 1
        if class_run > 4:
            issues.append("more than 4 of the same class (U/L/D/S) in a row")
            break
        if ident_run > 3:
            issues.append("more than 3 identical characters in a row")
            break
    low = pw.lower()
    for u in ("veeamadmin", "veeamso"):
        if u in low: issues.append("must not contain '%s'" % u)
    if crack:
        try:
            out = subprocess.run([crack], input=pw + "\n", capture_output=True, text=True).stdout.strip()
            verdict = out.rsplit(':', 1)[-1].strip()
            if verdict.lower() != "ok":
                issues.append("cracklib/dictionary: %s" % verdict)
        except Exception:
            pass
    return ["%s.password: %s" % (label, x) for x in issues]

problems = []
admin = get("veeamadmin.password")
so    = get("veeamso.password")
so_enabled = (get("veeamso.isEnabled") == "true")

problems += check_pw(admin, "veeamadmin")
if so_enabled:
    problems += check_pw(so, "veeamso")
    if admin and so and '<<' not in (admin + so) and admin == so:
        problems.append("veeamadmin and veeamso passwords must DIFFER")
else:
    print("note: veeamso.isEnabled=false (SO disabled) — its password is not validated")

def fmt(k, pat, desc):
    v = get(k)
    if v is None or '<<' in v: return
    if not re.fullmatch(pat, v):
        problems.append("%s: bad format (expected %s)" % (k, desc))

fmt("veeamadmin.mfaSecretKey", r'[A-Z2-7]{16}', "16-char Base32")
if so_enabled:
    fmt("veeamso.mfaSecretKey", r'[A-Z2-7]{16}', "16-char Base32")
    fmt("veeamso.recoveryToken", r'[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}', "GUID")

if get("veeamso.isEnabled") == "false" and get("veeamso.isMfaEnabled") == "true":
    problems.append("veeamso.isMfaEnabled=true while isEnabled=false (inconsistent)")
if re.search(r'<<(SET|GENERATE)_[A-Z_]+>>', ks):
    problems.append("kickstart still has unfilled <<...>> placeholders")
if not crack:
    print("note: cracklib-check not installed — dictionary-word rule NOT checked here (the appliance still enforces it)")

print()
if problems:
    print("RESULT: NON-COMPLIANT — %d issue(s):" % len(problems))
    for p in problems:
        print("  ✗ " + p)
    sys.exit(1)
print("RESULT: COMPLIANT — veeamadmin/veeamso credentials meet the policy.")
PY
