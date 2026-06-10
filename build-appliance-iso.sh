#!/usr/bin/env bash
# =============================================================================
# build-appliance-iso.sh — bake a ready-to-use unattended kickstart into a
#                          golden Veeam appliance ISO
# =============================================================================
# Produces ONE golden ISO for large-scale deployment (shared creds across all
# appliances provisioned from it). Supports five roles:
#   --role proxy           -> generic backup proxy        (VIA ISO, proxy-ks.cfg)
#   --role vmware-proxy    -> VMware proxy, iSCSI/NVMe-TCP (VIA ISO, vmware-proxy-ks.cfg)
#   --role hardened-repo   -> Veeam Hardened Repository    (VIA ISO, hardened-repo-ks.cfg)
#   --role vsa             -> Veeam Backup & Replication   (VSA ISO, vbr-ks.cfg)
#   --role vbem            -> Enterprise Manager           (VSA ISO, vbem-ks.cfg)
#
# Pass the matching SOURCE ISO: the Veeam Infrastructure Appliance ISO for
# proxy/vmware-proxy/hardened-repo, or the Veeam Software Appliance ISO for
# vsa/vbem.
#
# VERSION-AGNOSTIC BY DESIGN. Nothing build-specific is shipped. At build time
# this script, for the chosen role:
#   1. EXTRACTS the role's stock kickstart FROM the source ISO (so it always
#      matches that ISO's build — package list, disk layout, BUILD_ID, etc.),
#   2. INSERTS the unattended block (unattended-block.tmpl) at the end of the
#      stock chroot %post, just before its "# post end" marker,
#   3. optionally rewrites the stock %pre hostname prefix (--hostname-prefix),
#   4. DERIVES + patches grub.cfg from the same ISO (default entry + timeout=10 +
#      inst.assumeyes) into BOTH /EFI/BOOT/grub.cfg and the copy inside
#      images/efiboot.img (the one UEFI firmware actually reads),
#   5. repacks the ISO with the derived kickstart + patched grub.
#
# If the stock layout it depends on isn't found (the "# post end" anchor or the
# hostname line), it FAILS LOUD rather than emitting a broken ISO — that signals
# the stock kickstart changed (e.g. a new major build) and the injector needs a
# look. The kit ships NO pinned kickstart (a stale one on a different build would
# re-introduce a version mismatch); baseline-stock/ keeps pristine extracts only
# for diffing.
#
# REQUIREMENTS: run on Linux. macOS can't repack this hybrid ISO.
#   - xorriso, python3
#   - To patch efiboot.img: run as root/sudo (loop-mount, no extra package) OR
#     install mtools. Recommended: run the build with sudo and skip mtools.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_VERSION="$(tr -d '[:space:]' < "$HERE/VERSION" 2>/dev/null || true)"; KIT_VERSION="${KIT_VERSION:-unknown}"

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- arguments --------------------------------------------------------------
ROLE="proxy"
BLOCK_FILE="$HERE/unattended-block.tmpl"   # the (filled) unattended block to insert
HOST_PREFIX=""                             # empty => keep the stock per-role hostname prefix
EMIT_KS=""                                 # optional path to also write the derived ks (SENSITIVE)
CUSTOM_POST=""                             # optional customer %post snippet to append (additive)
ARGS=()
NEXT=""
for a in "$@"; do
  if [ -n "$NEXT" ]; then
    case "$NEXT" in
      role)   ROLE="$a" ;;
      block)  BLOCK_FILE="$a" ;;
      prefix) HOST_PREFIX="$a" ;;
      emit)   EMIT_KS="$a" ;;
      cpost)  CUSTOM_POST="$a" ;;
    esac
    NEXT=""; continue
  fi
  case "$a" in
    --role)              NEXT=role ;;
    --role=*)            ROLE="${a#*=}" ;;
    --block)             NEXT=block ;;
    --block=*)           BLOCK_FILE="${a#*=}" ;;
    --hostname-prefix)   NEXT=prefix ;;
    --hostname-prefix=*) HOST_PREFIX="${a#*=}" ;;
    --emit-ks)           NEXT=emit ;;
    --emit-ks=*)         EMIT_KS="${a#*=}" ;;
    --custom-post)       NEXT=cpost ;;
    --custom-post=*)     CUSTOM_POST="${a#*=}" ;;
    *) ARGS+=("$a") ;;
  esac
done
SRC_ISO="${ARGS[0]:-}"
OUT_ISO="${ARGS[1]:-}"

# ---- role-specific settings -------------------------------------------------
# INSTALL_ENTRY is the grub "fresh install" menu-entry text. It is identical for
# every role EXCEPT vbem, whose entry omits the "(including local backups)" suffix
# (Enterprise Manager keeps no local backups). The grub default is built as
# "<submenu>><entry>", so a wrong entry string points the default at a missing
# menu node — hence it is tracked per role.
INSTALL_ENTRY="Install - fresh install, wipes everything (including local backups)"
case "$ROLE" in
  proxy)
    STOCK_KS="proxy-ks.cfg"
    GRUB_SUBMENU="Veeam Infrastructure Appliance"
    ROLE_TAG="PROXY" ;;
  vmware-proxy)
    # VIA VMware backup proxy with iSCSI & NVMe/TCP storage connectivity.
    STOCK_KS="vmware-proxy-ks.cfg"
    GRUB_SUBMENU="Veeam Infrastructure Appliance (with iSCSI & NVMe/TCP)"
    ROLE_TAG="VMWAREPROXY" ;;
  hardened-repo)
    STOCK_KS="hardened-repo-ks.cfg"
    GRUB_SUBMENU="Veeam Hardened Repository"
    ROLE_TAG="HARDENEDREPO" ;;
  vsa)
    STOCK_KS="vbr-ks.cfg"
    GRUB_SUBMENU="Veeam Backup & Replication"
    ROLE_TAG="VSA" ;;
  vbem)
    # VSA Veeam Backup Enterprise Manager — distinct install-entry text (no suffix).
    STOCK_KS="vbem-ks.cfg"
    GRUB_SUBMENU="Veeam Backup Enterprise Manager"
    INSTALL_ENTRY="Install - fresh install, wipes everything"
    ROLE_TAG="VBEM" ;;
  *) die "unknown --role '$ROLE' (use: proxy | vmware-proxy | hardened-repo | vsa | vbem)" ;;
esac
KS_ISO_PATH="/$STOCK_KS"          # path of the stock kickstart inside the ISO
GRUB_DEFAULT="${GRUB_SUBMENU}>${INSTALL_ENTRY}"

[[ -n "$SRC_ISO" ]] || die "usage: $0 [--role proxy|vmware-proxy|hardened-repo|vsa|vbem] [--hostname-prefix P] [--block FILE] [--custom-post FILE] [--emit-ks FILE] <source-iso> [output-iso]"
[[ -f "$SRC_ISO" ]] || die "source ISO not found: $SRC_ISO"
[[ -f "$BLOCK_FILE" ]] || die "unattended block template not found: $BLOCK_FILE"
[[ -z "$CUSTOM_POST" || -f "$CUSTOM_POST" ]] || die "custom %post file not found: $CUSTOM_POST"

# Output name derives from the SOURCE ISO (so it carries the actual build/version,
# whatever it is) + the role tag — version-agnostic and accurate.
OUT_ISO="${OUT_ISO:-$HERE/$(basename "$SRC_ISO" .iso)_${ROLE_TAG}_UNATTENDED.iso}"
command -v xorriso >/dev/null || die "xorriso not installed (dnf/apt install xorriso)"
command -v python3 >/dev/null || die "python3 not installed"
if ! { [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null || command -v mcopy >/dev/null; }; then
  die "to patch efiboot.img, run this as root (loop-mount), or install mtools (dnf/apt install mtools)"
fi

# ---- validate the FILLED block template (fast-fail before touching the ISO) --
# Refuse to build while real placeholder tokens remain (<<SET_FOO>>/<<GENERATE_FOO>>),
# ignoring the instructional comments that mention <<SET_...>>/<<GENERATE_...>>.
if grep -qE '<<(SET|GENERATE)_[A-Z_]+>>' "$BLOCK_FILE"; then
  echo "Unreplaced placeholders still present in $(basename "$BLOCK_FILE"):" >&2
  grep -nE '<<(SET|GENERATE)_[A-Z_]+>>' "$BLOCK_FILE" >&2
  die "run ./generate-secrets.sh (or ./make-golden-iso.sh) and set passwords/NTP before building"
fi

# Validate the embedded account passwords against the appliance policy, so even a
# hand-filled (standalone-path) block can't ship an ISO the appliance rejects at
# first boot: 15+ chars, all 4 classes, no >4 same-class / no >3 identical in a row, and
# veeamadmin != veeamso. (veeamso checked only when its account is enabled.)
python3 - "$BLOCK_FILE" <<'PY' || die "credentials fail the appliance password policy — fix the block and rebuild"
import sys, re
ks = open(sys.argv[1]).read()
def get(k):
    m = re.search(r'^%s=(.*)$' % re.escape(k), ks, re.M)
    return m.group(1) if m else None
cls = lambda c: 'U' if c.isupper() else 'L' if c.islower() else 'D' if c.isdigit() else 'S'
def check(pw, label):
    if pw is None: return ["%s: password line not found" % label]
    e = []
    if len(pw) < 15: e.append("15+ chars")
    if not re.search(r'[A-Z]', pw): e.append("uppercase")
    if not re.search(r'[a-z]', pw): e.append("lowercase")
    if not re.search(r'[0-9]', pw): e.append("digit")
    if not re.search(r'[^A-Za-z0-9]', pw): e.append("special")
    class_run = ident_run = 1
    for i in range(1, len(pw)):
        class_run = class_run + 1 if cls(pw[i]) == cls(pw[i-1]) else 1
        ident_run = ident_run + 1 if pw[i] == pw[i-1] else 1
        if class_run > 4: e.append("no >4 of the same class in a row"); break
        if ident_run > 3: e.append("no >3 identical chars in a row"); break
    return ["%s: %s" % (label, x) for x in e]
admin = get("veeamadmin.password"); so = get("veeamso.password")
problems = check(admin, "veeamadmin")
if get("veeamso.isEnabled") == "true":
    problems += check(so, "veeamso")
    if admin is not None and so == admin:
        problems.append("veeamadmin and veeamso passwords must differ")
if problems:
    sys.stderr.write("Password policy violations:\n")
    for p in problems: sys.stderr.write("  - %s\n" % p)
    sys.exit(1)
PY

echo "Kit version    : $KIT_VERSION"
echo "Role           : $ROLE"
echo "Source ISO     : $SRC_ISO"
echo "Output ISO     : $OUT_ISO"
echo "Hostname prefix: ${HOST_PREFIX:-<keep stock>}"
[ -n "$CUSTOM_POST" ] && echo "Custom %post   : $CUSTOM_POST  (UNSUPPORTED, inserted verbatim)"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
WORK="$(mktemp -d)"
EBMNT=""
cleanup() { if [ -n "$EBMNT" ] && mountpoint -q "$EBMNT" 2>/dev/null; then $SUDO umount "$EBMNT"; fi; rm -rf "$WORK"; }
trap cleanup EXIT

# ---- derive the kickstart FROM the source ISO -------------------------------
echo "Extracting stock kickstart $KS_ISO_PATH from the ISO and inserting the unattended block"
xorriso -osirrox on -indev "$SRC_ISO" -extract "$KS_ISO_PATH" "$WORK/stock-ks.cfg" >/dev/null 2>&1 \
  || die "could not extract $KS_ISO_PATH from the ISO (is this the right ISO for role '$ROLE'?)"
[ -s "$WORK/stock-ks.cfg" ] || die "extracted stock kickstart is empty: $KS_ISO_PATH"

BLOCK_FILE="$BLOCK_FILE" STOCK="$WORK/stock-ks.cfg" DST="$WORK/derived-ks.cfg" \
HOST_PREFIX="$HOST_PREFIX" CUSTOM_POST="$CUSTOM_POST" python3 - <<'PY'
import os, re
stock = open(os.environ['STOCK']).read()
block = open(os.environ['BLOCK_FILE']).read()
# Our unattended block, optionally followed by the customer's --custom-post snippet
# (inserted verbatim, wrapped in markers — additive, at the customer's own risk).
insert = block.rstrip('\n')
cpost = os.environ.get('CUSTOM_POST', '').strip()
if cpost:
    cp = open(cpost).read().rstrip('\n')
    insert += ("\n\n# === custom %post (customer-supplied via --custom-post) — UNSUPPORTED, at your own risk ===\n"
               + cp +
               "\n# === end custom %post ===")
# Insert at the end of the stock chroot %post — right before its unique "# post end"
# close marker (stable across builds; see PROJECT-NOTES).
cnt = len(re.findall(r'(?m)^# post end$', stock))
if cnt != 1:
    raise SystemExit("ERROR: expected exactly 1 '# post end' anchor in the stock "
                     "kickstart, found %d — stock layout changed; update the injector." % cnt)
stock = re.sub(r'(?m)^# post end$', insert + "\n# post end", stock, count=1)
# Optional custom hostname prefix: rewrite the stock %pre network line in place.
prefix = os.environ.get('HOST_PREFIX', '').strip()
if prefix:
    stock, n = re.subn(r'(--hostname=)[A-Za-z0-9]+(-\$\{MACH_HASH\})',
                       lambda m: m.group(1) + prefix + m.group(2), stock)
    if n != 1:
        raise SystemExit("ERROR: expected exactly 1 '--hostname=<prefix>-${MACH_HASH}' "
                         "line to set the hostname prefix, found %d — stock layout "
                         "changed; update the injector." % n)
open(os.environ['DST'], 'w').write(stock)
PY
DERIVED_KS="$WORK/derived-ks.cfg"
# Safety net: the assembled ks must not contain leftover placeholders.
if grep -qE '<<(SET|GENERATE)_[A-Z_]+>>' "$DERIVED_KS"; then
  die "internal error: derived kickstart still has placeholders"
fi

# ---- derive + patch grub.cfg from the source ISO, per role ------------------
echo "Deriving grub.cfg from the ISO and patching for role '$ROLE'"
xorriso -osirrox on -indev "$SRC_ISO" -extract /EFI/BOOT/grub.cfg "$WORK/grub-stock.cfg" >/dev/null 2>&1

GRUB_DEFAULT="$GRUB_DEFAULT" KS_ISO_PATH="$KS_ISO_PATH" \
SRC="$WORK/grub-stock.cfg" DST="$WORK/grub.cfg" python3 - <<'PY'
import os, re
src, dst = os.environ['SRC'], os.environ['DST']
default, ks = os.environ['GRUB_DEFAULT'], os.environ['KS_ISO_PATH']
t = open(src).read()
t, n = re.subn(r'^set default=.*$', 'set default="%s"' % default, t, count=1, flags=re.M)
assert n == 1, "could not set grub default"
t, n = re.subn(r'^set timeout=.*$', 'set timeout=10', t, count=1, flags=re.M)
assert n == 1, "could not set grub timeout"
# Append inst.assumeyes to the fresh-Install line for this role only.
marker = ":%s quiet" % ks            # e.g. ':/proxy-ks.cfg quiet' — unique to the fresh Install entry
t, n = re.subn(re.escape(marker), ":%s inst.assumeyes quiet" % ks, t)
assert n == 1, "expected exactly 1 fresh-Install line for %s, found %d" % (ks, n)
open(dst, 'w').write(t)
PY
GRUB_CFG="$WORK/grub.cfg"

# ---- patch the grub.cfg embedded inside images/efiboot.img ------------------
# On UEFI boot the firmware reads grub.cfg from this FAT image, not the ISO-root
# copy. Method: loop-mount (base 'mount' + kernel vfat — no extra package; needs
# root) and overwrite grub.cfg; fall back to mtools (mcopy) if not root.
echo "Patching grub.cfg inside images/efiboot.img"
xorriso -osirrox on -indev "$SRC_ISO" -extract /images/efiboot.img "$WORK/efiboot.img" >/dev/null 2>&1
chmod u+w "$WORK/efiboot.img"

patched=0
if [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null; then
  EBMNT="$WORK/ebmnt"; mkdir -p "$EBMNT"
  if $SUDO mount -o loop "$WORK/efiboot.img" "$EBMNT" 2>/dev/null; then
    $SUDO cp "$GRUB_CFG" "$EBMNT/EFI/BOOT/grub.cfg"
    $SUDO umount "$EBMNT"; EBMNT=""
    echo "  (patched via loop-mount — no extra package)"
    patched=1
  else
    EBMNT=""
  fi
fi
if [ "$patched" -eq 0 ] && command -v mcopy >/dev/null; then
  MTOOLS_SKIP_CHECK=1 mcopy -i "$WORK/efiboot.img" -o "$GRUB_CFG" ::/EFI/BOOT/grub.cfg
  echo "  (patched via mtools)"
  patched=1
fi
[ "$patched" -eq 1 ] || die "could not patch efiboot.img: run as root for loop-mount, or install mtools"

# ---- repack the ISO ---------------------------------------------------------
echo "Injecting  : derived kickstart -> $KS_ISO_PATH"
echo "             patched grub.cfg -> /EFI/BOOT/grub.cfg  AND  inside /images/efiboot.img"

xorriso -indev "$SRC_ISO" -outdev "$OUT_ISO" \
  -boot_image any replay \
  -map "$DERIVED_KS"       "$KS_ISO_PATH" \
  -map "$GRUB_CFG"         /EFI/BOOT/grub.cfg \
  -map "$WORK/efiboot.img" /images/efiboot.img \
  -commit

# Optional: re-implant the anaconda media checksum if the tool is available.
if command -v implantisomd5 >/dev/null; then
  echo "Re-implanting ISO MD5 (implantisomd5)"
  implantisomd5 "$OUT_ISO" || echo "WARN: implantisomd5 failed (non-fatal)"
fi

# Optional: also write the derived kickstart out for inspection/audit. It contains
# live credentials, so it's opt-in and written 0600.
if [ -n "$EMIT_KS" ]; then
  cp "$DERIVED_KS" "$EMIT_KS"; chmod 600 "$EMIT_KS"
  echo "Derived kickstart written to: $EMIT_KS  (SENSITIVE — contains credentials)"
fi

echo "Done. Golden Veeam appliance ISO ($ROLE): $OUT_ISO"
echo "Verify injected files:"
xorriso -indev "$OUT_ISO" -find "$KS_ISO_PATH" -o -find /EFI/BOOT/grub.cfg 2>/dev/null || true
