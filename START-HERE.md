# START HERE — Veeam Appliance Golden ISO (validation quickstart)

> **Not a Veeam product** — independent courtesy tooling, provided as-is, without
> warranty or Veeam support. See DISCLAIMER.md and LICENSE.

This kit builds an **unattended** Veeam appliance ISO that pre-defines the
`veeamadmin` and `veeamso` logins so many identical appliances can be deployed from
one golden ISO. You pick the **role** at build time:
- **proxy** — VIA generic backup proxy (NBD/HotAdd)
- **vmware-proxy** — VIA VMware proxy with iSCSI & NVMe/TCP storage connectivity
- **hardened-repo** — VIA Veeam Hardened Repository
- **vsa** — Veeam Backup & Replication server (Veeam Software Appliance)
- **vbem** — Veeam Backup Enterprise Manager (Veeam Software Appliance)

proxy/vmware-proxy/hardened-repo build from the **VIA** ISO; vsa/vbem build from
the **VSA** ISO.

This page is the 60-second quickstart. Deeper detail is in **README.md**; the
credentials/keys reference is in **CREDENTIALS.md**.

---

## 1. What you need

- **Linux, or WSL2 on Windows.** The build uses `xorriso`; macOS and native
  Windows can't repack this bootable ISO (see README "Build environment").
  - Rocky / RHEL:  `sudo dnf install -y epel-release && sudo dnf install -y xorriso`
  - Ubuntu / Debian:  `sudo apt update && sudo apt install -y xorriso`
  - **Root/sudo** — the build loop-mounts the UEFI boot image to patch it, so it
    runs `sudo mount` (you'll be prompted; or run `sudo -v` first). No extra
    package needed. If you can't use root, install `mtools` and it'll use that.
- `python3` — already present on most Linux distros.
- The matching Veeam ISO — the **VIA** ISO for proxy/hardened-repo, the **VSA** ISO
  for vsa. Drop it in this folder (auto-detected per role) or pass its path.

## 2. Build the golden ISO (guided)

```bash
chmod +x *.sh          # if the execute bit didn't survive transfer
./make-golden-iso.sh   # auto-detects the matching ISO in this folder for the chosen role
```

It prompts for the **role** (proxy / vmware-proxy / hardened-repo / vsa / vbem), a **hostname prefix**
(each VM becomes `<prefix>-<unique-hash>`; default per role), the **veeamadmin**
password, whether to **enforce veeamadmin MFA** (auto-forced for hardened-repo),
whether to **enable the veeamso account**, the **veeamso** password (when enabled;
must differ), whether to **supply your own MFA keys/token** (else auto-generate),
and the **NTP server** — then fills the unattended block, extracts the role's stock
kickstart from your ISO, inserts the block, and builds the ISO.

**Write down the three values it prints** — especially `veeamso.recoveryToken`
(it cannot be recovered later).

If it can't auto-detect the ISO, pass the path explicitly:
```bash
./make-golden-iso.sh ./VeeamInfrastructureAppliance_<version>.iso   # or the VSA ISO for vsa
```
(Use your actual ISO filename — the version/build in it may differ from any examples
in these docs.)

Output: the source ISO's own name with a role suffix, e.g.
`VeeamInfrastructureAppliance_<version>_PROXY_UNATTENDED.iso` /
`..._HARDENEDREPO_UNATTENDED.iso` (VIA) or
`VeeamSoftwareAppliance_<version>_VSA_UNATTENDED.iso` (vsa) — so the output always
carries the same build as the ISO you fed in.

## 3. Boot-test it

Create an **empty VM**, attach the built ISO, and power it on. Three requirements:

- **UEFI firmware** — the ISO is UEFI-only; it will not boot in legacy BIOS.
- A **DHCP** network (used at install and first boot).
- If your platform has guest customization (e.g. **VMware Cloud Director**),
  **disable it** for this VM so it doesn't fight the appliance's first-boot init.

It auto-installs (no prompts), reboots and ejects the media, and applies the
credentials on first boot. Then log in as `veeamadmin` / `veeamso` and verify per
the README "Verify on a sample appliance" section. **veeamso** (and **veeamadmin**
if its MFA was enabled) will prompt for a TOTP code immediately — add the
generated key(s) to an authenticator before logging in.

---

## Notes for testers

- **This is a flat bundle**, so any README mention of `baseline-stock/` or an
  `../ISO Archive/` sibling doesn't apply here — everything needed is in this one
  folder.
- Re-running `make-golden-iso.sh` regenerates the secrets and keeps a timestamped
  backup of the unattended block it fills.
- Please report, per role tested: did the build complete? did the VM install fully
  unattended? did first-boot login work for both accounts (and the MFA prompt
  appear for veeamso — and veeamadmin if you enabled its MFA / chose hardened-repo)?
