#!/usr/bin/env bash
# =============================================================================
# make-golden-iso.sh — guided, end-to-end build of a golden Veeam appliance ISO
# =============================================================================
# Interactive "easy button" that runs the whole prepare + build flow:
#   - select role: proxy | vmware-proxy | hardened-repo (VIA ISO) | vsa | vbem (VSA ISO)
#   - prompt for the veeamadmin password (hidden, confirmed, validated)
#   - choose whether veeamadmin MFA is enforced (auto-forced ON for hardened-repo)
#   - choose whether the veeamso (Security Officer) account is enabled
#   - prompt for the veeamso password (when enabled; must differ from veeamadmin)
#   - prompt for the NTP server(s)
#   - generate the MFA keys + SO recovery token, OR let you supply your own
#   - write everything into the role's kickstart
#   - build the golden ISO (delegates to build-appliance-iso.sh --role <role>)
#   - print the secrets summary LAST and write a sensitivity-noted secrets file
#
# Granular scripts remain for non-interactive use:
#   generate-secrets.sh  (keys only)        build-appliance-iso.sh  (build only)
#
# RUN ON LINUX (or WSL). Use --prep-only to do the prepare steps anywhere and
# build later on Linux.
#
# Usage:  ./make-golden-iso.sh [--prep-only] [source-iso] [output-iso]
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build-appliance-iso.sh"
KIT_VERSION="$(tr -d '[:space:]' < "$HERE/VERSION" 2>/dev/null || true)"; KIT_VERSION="${KIT_VERSION:-unknown}"

PREP_ONLY=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --prep-only) PREP_ONLY=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
SRC_ISO="${ARGS[0]:-}"
OUT_ISO="${ARGS[1]:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v python3 >/dev/null || die "python3 is required"
[[ $PREP_ONLY -eq 1 || -f "$BUILD" ]] || die "build-appliance-iso.sh not found next to this script"

echo "============================================================"
echo " Veeam Appliance — Golden ISO Builder   (kit v$KIT_VERSION)"
echo "============================================================"

# ---- role selection ---------------------------------------------------------
echo
echo "Select appliance role:"
echo "   [1] proxy          — VIA: generic backup proxy"
echo "   [2] vmware-proxy   — VIA: VMware proxy with iSCSI & NVMe/TCP storage connectivity"
echo "   [3] hardened-repo  — VIA: Veeam Hardened Repository (forces MFA on BOTH accounts)"
echo "   [4] vsa            — VSA: Veeam Backup & Replication server"
echo "   [5] vbem           — VSA: Veeam Backup Enterprise Manager"
while true; do
  read -rp "  Role [1/2/3/4/5]: " r || die "input ended"
  case "$r" in
    1|proxy)             ROLE=proxy;         ISO_GLOB="VeeamInfrastructureAppliance*.iso"; DEF_PREFIX=vprx; break ;;
    2|vmware-proxy|vmw)  ROLE=vmware-proxy;  ISO_GLOB="VeeamInfrastructureAppliance*.iso"; DEF_PREFIX=vinf; break ;;
    3|hardened-repo|hr)  ROLE=hardened-repo; ISO_GLOB="VeeamInfrastructureAppliance*.iso"; DEF_PREFIX=vlhr; break ;;
    4|vsa)               ROLE=vsa;           ISO_GLOB="VeeamSoftwareAppliance*.iso";        DEF_PREFIX=vbr;  break ;;
    5|vbem|em)           ROLE=vbem;          ISO_GLOB="VeeamSoftwareAppliance*.iso";        DEF_PREFIX=vbem; break ;;
    *) echo "  ✗ enter 1, 2, 3, 4, or 5" >&2 ;;
  esac
done
KSNAME=unattended-block.tmpl
KS="$HERE/$KSNAME"
[[ -f "$KS" ]] || die "$KSNAME not found next to this script"
echo "  -> role: $ROLE  (fills the unattended block; stock kickstart comes from the ISO)"

# Confirm overwrite if the block was already filled (real tokens, not comments).
if ! grep -qE '<<(SET|GENERATE)_[A-Z_]+>>' "$KS"; then
  echo "WARNING: $KSNAME has no placeholders left — it appears already filled."
  read -rp "Re-running overwrites its credentials / NTP / keys. Continue? [Y/N] (Default behavior is No) " ans || exit 1
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ---- helpers ----------------------------------------------------------------
validate_pw() {  # $1=password $2=label -> nonzero (prints reasons) if it fails the policy
  PW="$1" PW_LABEL="$2" python3 - <<'PY'
import os, re, sys
pw = os.environ['PW']; label = os.environ['PW_LABEL']
errs = []
if len(pw) < 15:                        errs.append("15+ characters")
if not re.search(r'[A-Z]', pw):         errs.append("an uppercase letter")
if not re.search(r'[a-z]', pw):         errs.append("a lowercase letter")
if not re.search(r'[0-9]', pw):         errs.append("a digit")
if not re.search(r'[^A-Za-z0-9]', pw):  errs.append("a special character")
# DISA RHEL8 STIG (what the appliance enforces): max 4 consecutive of the same
# class (maxclassrepeat=4) AND max 3 consecutive identical chars (maxrepeat=3).
# Classes: Upper / Lower / Digit / Special.
cls = lambda c: 'U' if c.isupper() else 'L' if c.islower() else 'D' if c.isdigit() else 'S'
class_run = ident_run = 1
for i in range(1, len(pw)):
    class_run = class_run + 1 if cls(pw[i]) == cls(pw[i-1]) else 1
    ident_run = ident_run + 1 if pw[i] == pw[i-1] else 1
    if class_run > 4:
        errs.append("no more than 4 of the same class (upper/lower/digit/special) in a row")
        break
    if ident_run > 3:
        errs.append("no more than 3 identical characters in a row")
        break
if errs:
    sys.stderr.write("  ✗ %s password needs: %s\n" % (label, "; ".join(errs)))
    sys.exit(1)
PY
}
prompt_password() {  # $1=label $2=output-var
  local label="$1" __out="$2" pw pw2
  while true; do
    read -rsp "  Enter $label password: " pw || die "input ended"; echo
    validate_pw "$pw" "$label" || continue
    read -rsp "  Confirm $label password: " pw2 || die "input ended"; echo
    [ "$pw" = "$pw2" ] || { echo "  ✗ passwords do not match — try again" >&2; continue; }
    printf -v "$__out" '%s' "$pw"; break
  done
}
is_b32()  { [[ "$1" =~ ^[A-Z2-7]{16}$ ]]; }                                                   # 16-char Base32
is_guid() { [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; }
prompt_optional() {  # $1=label $2=validator-fn $3=output-var ; blank => leave empty (auto-generate)
  local label="$1" vfn="$2" __out="$3" val
  while true; do
    read -rp "  $label (blank = auto-generate): " val || die "input ended"
    [ -z "$val" ] && { printf -v "$__out" '%s' ""; return 0; }
    if "$vfn" "$val"; then printf -v "$__out" '%s' "$val"; return 0; fi
    echo "  ✗ invalid format — try again, or leave blank to auto-generate" >&2
  done
}

# ---- hostname prefix --------------------------------------------------------
echo
echo "Hostname prefix — each appliance becomes <prefix>-<unique-hash> (e.g. ${DEF_PREFIX}-a1b2c3d4)."
echo "(For true sequential names, assign them post-boot via your IPAM / vSphere customization.)"
while true; do
  read -rp "  Hostname prefix [default: $DEF_PREFIX]: " HOSTPREFIX || die "input ended"
  HOSTPREFIX="${HOSTPREFIX:-$DEF_PREFIX}"
  [[ "$HOSTPREFIX" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,48}[A-Za-z0-9])?$ ]] && break
  echo "  ✗ letters/digits/hyphens only, no leading/trailing hyphen, ≤50 chars" >&2
done

# ---- 1. veeamadmin password + MFA choice ------------------------------------
echo
echo "Step 1 — veeamadmin password (15+ chars; upper, lower, digit, special; no dictionary words)"
prompt_password "veeamadmin" ADMIN_PW
if [ "$ROLE" = hardened-repo ]; then
  ADMIN_MFA_ENABLED=true
  echo "  Hardened repository: MFA will be ENFORCED for veeamadmin (and veeamso)."
else
  read -rp "  Enforce MFA on the veeamadmin account? [Y/N] (Default behavior is No) " m || die "input ended"
  [[ "$m" =~ ^[Yy]$ ]] && ADMIN_MFA_ENABLED=true || ADMIN_MFA_ENABLED=false
fi

# ---- 2. veeamso account: enabled? + password --------------------------------
echo
read -rp "Step 2 — Enable the veeamso (Security Officer) account? [Y/N] (Default behavior is Yes) " s || die "input ended"
if [[ "$s" =~ ^[Nn]$ ]]; then SO_ENABLED=false; else SO_ENABLED=true; fi
if [ "$SO_ENABLED" = true ]; then
  echo "  veeamso password (same rules; must differ from veeamadmin)"
  while true; do
    prompt_password "veeamso" SO_PW
    [ "$SO_PW" != "$ADMIN_PW" ] && break
    echo "  ✗ veeamso password must differ from veeamadmin — try again" >&2
  done
else
  echo "  veeamso will be DISABLED (veeamso.isEnabled=false); skipping its password."
  SO_PW=""   # python fills a throwaway compliant value so the answer file stays valid
fi

# ---- 3. NTP -----------------------------------------------------------------
echo
echo "Step 3 — NTP server(s), comma-separated (e.g. ntp1.corp.local,ntp2.corp.local)"
while true; do
  read -rp "  NTP server(s): " NTP || die "input ended"
  [ -n "$NTP" ] && break
  echo "  ✗ NTP server cannot be empty" >&2
done
# Optional: skip the forced NTP time-sync at first boot. For networks where NTP
# isn't reachable at first boot (e.g. Azure VMware Solution / restricted segments)
# the blocking sync step fails and the unattended config drops to the manual wizard.
# The VM still gets time from the hypervisor, so MFA/TOTP keeps working; the NTP
# server above stays configured (chrony syncs once reachable).
read -rp "  Skip the NTP time-sync at first boot (for AVS / NTP-unreachable networks)? [Y/N] (Default behavior is No) " ntpoff || die "input ended"
if [[ "$ntpoff" =~ ^[Yy]$ ]]; then NTP_RUNSYNC=false; else NTP_RUNSYNC=true; fi

# ---- 4. secret keys: generate, or supply your own ---------------------------
echo
ADMIN_MFA=""; SO_MFA=""; TOKEN=""
read -rp "Step 4 — Supply your own MFA keys / recovery token? [Y/N] (Default behavior is No, auto-generate) " own || die "input ended"
if [[ "$own" =~ ^[Yy]$ ]]; then
  prompt_optional "veeamadmin MFA secret — 16-char Base32 (A-Z,2-7)" is_b32 ADMIN_MFA
  if [ "$SO_ENABLED" = true ]; then
    prompt_optional "veeamso MFA secret — 16-char Base32 (A-Z,2-7)" is_b32 SO_MFA
    prompt_optional "veeamso recovery token — GUID (8-4-4-4-12 hex)" is_guid TOKEN
  fi
fi

# ---- 4b. optional custom %post (firewall rules, agents, etc.) ----------------
echo
echo "Step 4b — Custom %post (OPTIONAL): a shell snippet inserted into the install's"
echo "  %post — e.g. firewalld rules (see example-custom-post-firewall.sh), an agent,"
echo "  an SSH key. Runs at install time (firewalld NOT running → use firewall-offline-cmd)."
echo "  UNSUPPORTED / at your own risk. NOT for network/domain/password-policy/encryption."
CUSTOM_POST=""
while true; do
  read -rp "  Path to a custom %post file (blank = none): " CUSTOM_POST || die "input ended"
  [ -z "$CUSTOM_POST" ] && break
  [ -f "$CUSTOM_POST" ] && break
  echo "  ✗ file not found: $CUSTOM_POST — try again, or blank for none" >&2
done
CPOPT=(); [ -n "$CUSTOM_POST" ] && CPOPT=(--custom-post "$CUSTOM_POST")

# ---- 5. generate (as needed) + write the kickstart --------------------------
echo
echo "Step 5 — writing $KSNAME"
cp -p "$KS" "$KS.bak.$(date +%Y%m%d%H%M%S)"   # single backup of the original

SUMMARY="$(mktemp)"
KS="$KS" ADMIN_PW="$ADMIN_PW" SO_PW="$SO_PW" NTP="$NTP" NTP_RUNSYNC="$NTP_RUNSYNC" HOSTPREFIX="$HOSTPREFIX" \
ADMIN_MFA_ENABLED="$ADMIN_MFA_ENABLED" SO_ENABLED="$SO_ENABLED" \
ADMIN_MFA="$ADMIN_MFA" SO_MFA="$SO_MFA" TOKEN="$TOKEN" SUMMARY="$SUMMARY" python3 - <<'PY'
import os, re, secrets, base64, uuid, string
ks = os.environ['KS']
b32 = lambda: base64.b32encode(secrets.token_bytes(10)).decode()   # 80 bits -> 16 chars
def gen_pw():
    pool = string.ascii_letters + string.digits + "!@#$%^&*-_=+"
    cls = lambda c: 'U' if c.isupper() else 'L' if c.islower() else 'D' if c.isdigit() else 'S'
    while True:
        pw = ''.join(secrets.choice(pool) for _ in range(20))
        if not (any(c.isupper() for c in pw) and any(c.islower() for c in pw)
                and any(c.isdigit() for c in pw) and any(not c.isalnum() for c in pw)):
            continue
        run, ok = 1, True
        for i in range(1, len(pw)):
            run = run + 1 if cls(pw[i]) == cls(pw[i-1]) else 1
            if run > 3:
                ok = False; break
        if ok:
            return pw

admin_mfa = os.environ.get('ADMIN_MFA') or b32()
so_mfa    = os.environ.get('SO_MFA')    or b32()
token     = os.environ.get('TOKEN')     or str(uuid.uuid4()).upper()
admin_pw  = os.environ['ADMIN_PW']
so_pw     = os.environ.get('SO_PW') or gen_pw()   # disabled veeamso => throwaway compliant pw

subs = {
    r'^(veeamadmin\.password=).*$':      admin_pw,
    r'^(veeamadmin\.mfaSecretKey=).*$':  admin_mfa,
    r'^(veeamadmin\.isMfaEnabled=).*$':  os.environ['ADMIN_MFA_ENABLED'],
    r'^(veeamso\.password=).*$':         so_pw,
    r'^(veeamso\.mfaSecretKey=).*$':     so_mfa,
    r'^(veeamso\.recoveryToken=).*$':    token,
    r'^(veeamso\.isMfaEnabled=).*$':     os.environ['SO_ENABLED'],
    r'^(veeamso\.isEnabled=).*$':        os.environ['SO_ENABLED'],
    r'^(ntp\.servers=).*$':              os.environ['NTP'],
    r'^(ntp\.runSync=).*$':              os.environ['NTP_RUNSYNC'],
}
text = open(ks).read()
for pat, val in subs.items():
    # function replacement => value inserted literally (handles \, &, $ in passwords)
    text, n = re.subn(pat, lambda m, v=val: m.group(1) + v, text, flags=re.M)
    if n != 1:
        raise SystemExit(f"ERROR: expected exactly 1 match for {pat!r}, found {n}")
# NOTE: the hostname prefix is NOT baked into the block — it is applied to the
# stock %pre line at build time (build-appliance-iso.sh --hostname-prefix), since
# that line is extracted from the source ISO, not shipped here.
open(ks, 'w').write(text)
open(os.environ['SUMMARY'], 'w').write(f"{admin_mfa}\n{so_mfa}\n{token}\n")
PY

unset ADMIN_PW SO_PW   # drop plaintext passwords from the environment
{ read -r ADMIN_MFA; read -r SO_MFA; read -r TOKEN; } < "$SUMMARY"
rm -f "$SUMMARY"

if [ "$ADMIN_MFA_ENABLED" = true ]; then
  admin_note="(MFA ENFORCED — veeamadmin must enroll this in an authenticator too)"
else
  admin_note="(MFA not enforced; key baked in for optional later use)"
fi

# Reusable secrets summary — printed LAST (after the build log) so it's easy to find.
print_secrets() {
  echo "------------------------------------------------------------"
  echo " GENERATED SECRETS — record/keep these   (role: $ROLE)"
  echo "------------------------------------------------------------"
  echo "   veeamadmin.mfaSecretKey = $ADMIN_MFA   $admin_note"
  if [ "$SO_ENABLED" = true ]; then
    echo "   veeamso.mfaSecretKey    = $SO_MFA   (veeamso must enroll this in an authenticator)"
    echo "   veeamso.recoveryToken   = $TOKEN   (STORE SECURELY — unrecoverable)"
  else
    echo "   veeamso account         = DISABLED (veeamso.isEnabled=false; its keys are inert)"
  fi
  echo "------------------------------------------------------------"
}

# Drop the secrets to a sensitivity-noted text file for easy retrieval later.
SECRETS_FILE="$HERE/veeam-${ROLE}-secrets-$(date +%Y%m%d%H%M%S).txt"
{
  echo "============================================================"
  echo " Veeam Golden ISO — GENERATED SECRETS      *** SENSITIVE ***"
  echo "============================================================"
  echo " Kit version:     $KIT_VERSION"
  echo " Role:            $ROLE"
  echo " Kickstart:       $KSNAME"
  echo " Hostname prefix: $HOSTPREFIX  (each VM: $HOSTPREFIX-<unique-hash>)"
  echo " NTP server:      $NTP   (first-boot time-sync: $([ "$NTP_RUNSYNC" = false ] && echo "SKIPPED — relies on hypervisor time" || echo "enabled"))"
  echo " Generated (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo " veeamadmin.mfaSecretKey = $ADMIN_MFA"
  echo "     (veeamadmin MFA enforced: $ADMIN_MFA_ENABLED)"
  if [ "$SO_ENABLED" = true ]; then
    echo " veeamso.mfaSecretKey    = $SO_MFA"
    echo " veeamso.recoveryToken   = $TOKEN"
  else
    echo " veeamso account         = DISABLED (veeamso.isEnabled=false)"
  fi
  echo
  echo " SENSITIVITY — handle as a secret:"
  echo "  - Live first-login secrets for EVERY appliance built from this ISO."
  echo "  - Enroll the MFA key(s) in a TOTP authenticator BEFORE first login"
  echo "    (veeamso when enabled; veeamadmin when its MFA is enforced)."
  echo "  - The recovery token cannot be regenerated — keep it safe."
  echo "  - Store securely, restrict access, and DELETE this file and the golden ISO"
  echo "    once the fleet rollout is complete."
  echo "============================================================"
} > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

if [ $PREP_ONLY -eq 1 ]; then
  echo
  echo "$KSNAME is prepared (--prep-only set; build skipped)."
  echo "Build later on Linux:  ./build-appliance-iso.sh --role $ROLE --hostname-prefix $HOSTPREFIX ${CUSTOM_POST:+--custom-post $CUSTOM_POST }<source-iso>"
  echo
  print_secrets
  echo "Secrets also saved to: $SECRETS_FILE"
  exit 0
fi

echo
echo "Building the golden ISO (role: $ROLE)..."
if [ -n "$SRC_ISO" ]; then
  "$BUILD" --role "$ROLE" --hostname-prefix "$HOSTPREFIX" "${CPOPT[@]}" "$SRC_ISO" ${OUT_ISO:+"$OUT_ISO"}
else
  # Auto-detect the matching source ISO (role-specific) in this folder or ../ISO Archive.
  shopt -s nullglob
  isos=( "$HERE"/$ISO_GLOB "$HERE/../ISO Archive"/$ISO_GLOB )
  shopt -u nullglob
  if [ ${#isos[@]} -eq 1 ]; then
    echo "Using detected source ISO: ${isos[0]}"
    "$BUILD" --role "$ROLE" --hostname-prefix "$HOSTPREFIX" "${CPOPT[@]}" "${isos[0]}"
  elif [ ${#isos[@]} -gt 1 ]; then
    echo "  Multiple matching ISOs detected:"; printf '    %s\n' "${isos[@]}"
    read -rp "  Path to source ISO: " SRC_ISO || die "input ended"
    "$BUILD" --role "$ROLE" --hostname-prefix "$HOSTPREFIX" "${CPOPT[@]}" "$SRC_ISO"
  else
    read -rp "  Path to source ISO ($ISO_GLOB): " SRC_ISO || die "input ended"
    "$BUILD" --role "$ROLE" --hostname-prefix "$HOSTPREFIX" "${CPOPT[@]}" "$SRC_ISO"
  fi
fi

# Final output: secrets summary LAST, so it's easy to find after the build log.
echo
echo "============================================================"
echo " BUILD COMPLETE — role: $ROLE"
echo "============================================================"
print_secrets
echo "Secrets also saved to: $SECRETS_FILE"
echo "(Sensitive — store securely; delete it and the golden ISO after rollout.)"
