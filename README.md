# Veeam Appliance Kickstart

> **Not a Veeam product.** Independent, community/courtesy tooling — not developed,
> endorsed, or supported by Veeam Software, and provided **as-is, without warranty
> or support**. See [DISCLAIMER.md](DISCLAIMER.md) and [LICENSE](LICENSE).

A ready-to-use unattended block + tooling that pre-defines the `veeamadmin` and
`veeamso` logins (passwords + MFA secret keys + SO recovery token) so Veeam
appliances can be rolled out unattended at scale. **Version-agnostic:** at build
time the tool extracts the stock kickstart from *your* Veeam ISO and inserts the
unattended settings into it — nothing build-specific is shipped.

For **large-scale (mass) deployment** — one golden ISO provisions many identical
appliances. You pick the **role** at build time (which stock kickstart is pulled
from the ISO):
- **proxy** — VIA generic backup proxy ("Veeam Infrastructure Appliance",
  `VARIANT_ID=vbproxy`); uses the **VIA** ISO's `proxy-ks.cfg`.
- **vmware-proxy** — VIA VMware backup proxy with **iSCSI & NVMe/TCP** storage
  connectivity (the "Veeam Infrastructure Appliance (with iSCSI & NVMe/TCP)"
  variant); uses the **VIA** ISO's `vmware-proxy-ks.cfg`.
- **hardened-repo** — VIA Veeam Hardened Repository (`VARIANT_ID=veeam-lhr`); uses
  the **VIA** ISO's `hardened-repo-ks.cfg`. **Forces MFA on BOTH veeamadmin and veeamso.**
- **vsa** — Veeam Backup & Replication server ("Veeam Software Appliance",
  `VARIANT_ID=vbr`); uses the **VSA** ISO's `vbr-ks.cfg`.
- **vbem** — Veeam Backup Enterprise Manager; uses the **VSA** ISO's `vbem-ks.cfg`.

`make-golden-iso.sh` prompts for the role; the standalone scripts take
`--role proxy|vmware-proxy|hardened-repo|vsa|vbem`. Each role uses its matching
**source ISO** (the Veeam Infrastructure Appliance ISO for
proxy/vmware-proxy/hardened-repo, the Veeam Software Appliance ISO for vsa/vbem).
Two further options apply to any role: you can **supply
your own MFA keys / SO recovery token** (instead of auto-generating), and you can
**enable or disable the veeamso account** (`veeamso.isEnabled`).

> The VSA ISO also carries `vbem-ks.cfg` (Enterprise Manager) behind a "Veeam
> Backup Enterprise Manager" submenu — a possible future role.

## ⚠️ Build environment — Linux is REQUIRED

**The ISO must be built on a Linux box. Windows and macOS are not supported for
the build, and this is not a preference — it's a hard technical constraint.**

The build (`build-appliance-iso.sh`) repacks the golden ISO with
`xorriso -boot_image any replay`, which clones the source ISO's exact El Torito +
UEFI boot structure while swapping in the kickstart and a patched grub.cfg. **No
native Windows or macOS tool reliably reproduces that boot structure** for a
RHEL/anaconda hybrid ISO:
- Windows `oscdimg.exe` (ADK) is built for Windows boot media and can silently
  break the appliance's UEFI boot — the ISO assembles but won't boot.
- macOS has no `xorriso` and cannot repack the hybrid ISO at all.

Use one of:
- A **Linux host / VM** with `xorriso` (`dnf install xorriso` or `apt install xorriso`), and run the build with **sudo** — recommended. (The build loop-mounts the UEFI boot image to patch it; root avoids any extra package. If you can't use root, `install mtools` and it uses that instead.)
- **WSL2** or a **Linux Docker container** on a Windows machine — these *are* Linux,
  so the existing `.sh` scripts run unchanged and produce a correct, bootable ISO.

Do **not** attempt a native PowerShell/Windows reimplementation of the build —
the boot fidelity cannot be guaranteed. (`generate-secrets.sh` could run anywhere,
but keep the whole workflow on the Linux box for simplicity.)

### Building on Windows via WSL

WSL (Windows Subsystem for Linux) is a genuine Linux environment that runs on
Windows, so it satisfies the Linux requirement above — the `.sh` scripts run
unchanged and use the real `xorriso`, producing a correct, bootable ISO. This is
the supported way to build on a Windows workstation without a separate Linux VM.

One-time setup (Windows 10 2004+ / Windows 11, run in an elevated PowerShell):
```powershell
wsl --install                 # installs WSL2 + Ubuntu (reboot if prompted)
```
Then, inside the Ubuntu shell:
```bash
sudo apt update && sudo apt install -y xorriso zip
```

Build (all inside the Ubuntu/WSL shell — **not** PowerShell):
```bash
# Windows drives are mounted under /mnt — cd to wherever you extracted the kit, e.g.:
cd "/mnt/c/Users/you/Downloads/VIA-Kickstart-Kit"
sudo ./make-golden-iso.sh   # prompts for role, credentials, NTP; then builds
```

Notes specific to WSL:
- **Use Linux-style paths** inside WSL: `C:\foo` is `/mnt/c/foo`, `E:\foo` is
  `/mnt/e/foo`. `wslpath -u 'E:\path\file.iso'` converts a Windows path for you.
- **Run the scripts from the WSL shell**, not by prefixing `wsl` in PowerShell —
  the whole build is already scripted in bash, so there's nothing to wrap.
- **The ISO on `/mnt/c` is slower** to read/write across the Windows boundary;
  it works, just expect the repack to take a bit longer than on native Linux.

### Building on Windows via a remote Linux host (`make-golden-remote.ps1`)

If you have a **separate Linux build host** (with `xorriso` + `python3`) reachable over
SSH, you can drive the whole build from a Windows box without WSL. From the kit folder
in PowerShell:
```powershell
.\make-golden-remote.ps1 -BuildHost root@10.0.0.50 -IsoPath .\VeeamInfrastructureAppliance_<version>.iso
```
It uploads the kit + your ISO to the host, runs `make-golden-iso.sh` there **interactively**
(you answer the role/password/NTP prompts right in that window — passwords are entered on the
Linux side, never stored by the script), downloads the built ISO (and the secrets file) back,
and then **deletes the remote copies** (they hold cleartext credentials). The build still runs
on Linux/`xorriso` — this is just an orchestrator, not a Windows reimplementation. The build
host's login user must be **root or able to `sudo`** (the build loop-mounts the UEFI image).

## Configuration model
- **Role:** `proxy` | `vmware-proxy` | `hardened-repo` | `vsa` | `vbem`, chosen at
  build time (see top of this doc).
- **Secret keys (MFA + SO recovery token):** generated per deployment by default,
  via `generate-secrets.sh` (or `make-golden-iso.sh`) — the kit ships placeholders,
  not preset keys. **Or supply your own:** `make-golden-iso.sh` offers it
  interactively; `generate-secrets.sh` takes `VEEAMADMIN_MFA` / `VEEAMSO_MFA` /
  `VEEAMSO_TOKEN` env vars (validated; any omitted are generated). Supplying the
  same values across builds gives one shared MFA registration fleet-wide.
- **Passwords:** you supply the two account passwords (must differ; STIG-compliant).
- **Scope:** one golden ISO, shared credentials across all appliances in a deployment.
- **MFA:**
  - `veeamso` — enforced when the account is enabled (Veeam default).
  - `veeamadmin` — enforced **always** for `hardened-repo`; a Y/N choice for
    `proxy`/`vsa` (default off). Its key is generated either way so MFA can be
    turned on later if left off.
- **veeamso account:** enabled by default; `make-golden-iso.sh` can **disable** it
  (`veeamso.isEnabled=false`) — mirrors the GUI's "enable Security Officer" choice.
- **Hostname:** you choose a prefix; each appliance gets `<prefix>-<unique-hash>`
  (default prefix per role: `vprx` / `vlhr` / `vbr`). One golden ISO still yields a
  unique name per VM. True sequential numbering (`name-0,1,…`) isn't possible from a
  single shared ISO — assign that post-boot via IPAM / vSphere customization.

## Files

Everything below ships in the kit — this is the complete contents of the customer zip.

**Build tools**
| File | Purpose |
|------|---------|
| [make-golden-iso.sh](make-golden-iso.sh) | **Guided one-shot (start here):** prompts for role, credentials, veeamadmin-MFA + veeamso-enable choices, supply-your-own-keys, hostname prefix, NTP (and skip-NTP-sync), and an optional custom `%post`; fills the unattended block and builds the ISO. Run on Linux. |
| [build-appliance-iso.sh](build-appliance-iso.sh) | Standalone build: extracts the role's stock kickstart from the source ISO, inserts the unattended block, and repacks the golden ISO (`--role proxy\|vmware-proxy\|hardened-repo\|vsa\|vbem`). Run on Linux. Derives + patches grub.cfg from the same ISO. |
| [generate-secrets.sh](generate-secrets.sh) | Standalone: writes MFA keys + SO recovery token into `unattended-block.tmpl` (`./generate-secrets.sh`); supply-your-own via env vars. |
| [check-credentials.sh](check-credentials.sh) | Read-only verifier: checks the veeamadmin/veeamso passwords + keys against the appliance policy (DISA STIG-aligned). Run it on `unattended-block.tmpl` before building, or on a mounted built ISO's derived `…-ks.cfg` to diagnose a "dropped to manual config" boot. |
| [make-golden-remote.ps1](make-golden-remote.ps1) | **Windows helper:** from a Windows box, uploads the kit + your ISO to a Linux build host over SSH, runs the build there interactively, and pulls the finished ISO back. (The build still runs on Linux — see "Building on Windows via a remote Linux host".) |

**Config you provide**
| File | Purpose |
|------|---------|
| [unattended-block.tmpl](unattended-block.tmpl) | The role-agnostic unattended block (the veeamadmin/veeamso settings) with `<<...>>` placeholders. The build inserts it into the stock kickstart it extracts from your source ISO. The **only** config file you fill. |
| [example-custom-post-firewall.sh](example-custom-post-firewall.sh) | Starter template for the `--custom-post` hook — firewalld rules with placeholder ports (see "Custom %post"). Optional; copy + edit. |

**Docs & metadata**
| File | Purpose |
|------|---------|
| [README.md](README.md) | This file. |
| [CREDENTIALS.md](CREDENTIALS.md) | What to set + what the generator produces. **Sensitive.** |
| [WHATS-NEW.md](WHATS-NEW.md) | Change log (newest first). |
| `VERSION` | Current kit version (shown when scripts run; recorded in the generated secrets file). |
| [LICENSE](LICENSE) / [DISCLAIMER.md](DISCLAIMER.md) | Free-use license + the "not a Veeam product, as-is" disclaimer. |

> Neither the **kickstart** nor **grub.cfg** is a shipped file — `build-appliance-iso.sh`
> extracts both from the source ISO at build time (and patches grub / inserts the
> unattended block) for the chosen role, so the kit always matches your ISO's build.

## How it works
At first boot the appliance runs `veeam-init.service`, which calls
`veeamhostmanager --apply_init_config /etc/veeam/vbr_init.cfg` to set both
accounts, then deletes the plaintext answer file and disables itself. The
interactive setup wizard is suppressed via `cockpit_auto_test_disable_init`.
Mechanism verified against Veeam documentation (validated on the 13.0.2.29 and
13.0.1.2067 ISOs).

> **ISO version / compatibility.** The build is **version-agnostic**: it extracts
> both the stock kickstart and grub.cfg from whatever ISO you feed it, inserts the
> unattended block / patches grub, and names the output after that same source
> build. So the package list, disk layout, and build ID always match your ISO —
> there is no baked-in version. The injector relies on two stable points in the
> stock kickstart (the `# post end` marker that closes the chroot `%post`, and the
> `%pre` hostname line); if a future Veeam build changes those, the build **stops
> with a clear error** instead of emitting a questionable ISO — that's the signal
> to update the injector. (Validated identical across 13.0.1.2067 → 13.0.2.29,
> where only the build ID differed.)

---

## Deployment process (end-to-end runbook)

Steps 1–4 prepare and build one golden ISO. Steps 5–7 deploy each appliance from
it. **Steps 1–4 run on a Linux box** (or WSL2 / a Linux container) — see the
**Build environment** section above for why this is a hard requirement.

> ### Quick path (guided one-shot)
> On Linux/WSL, run a single script that performs steps 1–4 interactively. It prompts for:
> the **role**, a **hostname prefix**, both passwords (hidden, validated), the
> **veeamadmin-MFA** choice, whether to **enable veeamso**, the **NTP server** (and whether
> to **skip the first-boot NTP sync**), whether to **supply your own MFA keys/token**, and an
> optional **custom `%post`** — then generates the keys, fills the unattended block, and builds:
> ```bash
> ./make-golden-iso.sh
> ```
> Add `--prep-only` to do the prepare steps + key generation without building (e.g. prepare on
> one machine, build on Linux later). On a **Windows** box with a separate Linux build host,
> **`make-golden-remote.ps1`** drives this whole flow remotely (see "Building on Windows via a
> remote Linux host"). The numbered steps below document exactly what the guided script does —
> follow them manually (with `--role proxy|vmware-proxy|hardened-repo|vsa|vbem` on the standalone scripts) if you
> prefer granular control or an automated pipeline.

> You fill **one** file for every role — `unattended-block.tmpl`. The build pulls
> the matching stock kickstart from the ISO based on `--role`; the examples below
> use `--role proxy`.

### 1. Generate per-deployment secret keys
```bash
./generate-secrets.sh                        # fills unattended-block.tmpl
```
This writes fresh, random values into the unattended block:
- `veeamadmin.mfaSecretKey` — 16-char Base32
- `veeamso.mfaSecretKey` — 16-char Base32 (veeamso **must enroll this** in an
  authenticator before first login, when the SO account is enabled)
- `veeamso.recoveryToken` — GUID; **store it securely, it cannot be recovered later**

To **supply your own** instead of generating, set any of `VEEAMADMIN_MFA`,
`VEEAMSO_MFA`, `VEEAMSO_TOKEN` (validated; omitted ones are generated):
```bash
VEEAMADMIN_MFA=XXXX... VEEAMSO_TOKEN=xxxxxxxx-... ./generate-secrets.sh
```
**Record the values it prints.** Run once per organization/deployment so secret
keys aren't reused across organizations (unless you deliberately supply shared ones).

### 2. Set the two account passwords
In `unattended-block.tmpl`, replace `<<SET_VEEAMADMIN_PASSWORD>>` and
`<<SET_VEEAMSO_PASSWORD>>`. Requirements (satisfy both Veeam and the appliance's
DISA STIG profile):
- ≥15 characters; ≥1 uppercase, lowercase, digit, special
- no more than 4 consecutive same-class characters and no more than 3 identical in a row; no dictionary words
- **the two passwords must differ**

(veeamadmin MFA default: the block ships `veeamadmin.isMfaEnabled=false`. The
guided `make-golden-iso.sh` toggles it — forced **on** for `hardened-repo` — and
enables/disables veeamso. To change manually, edit the `veeamadmin.isMfaEnabled` /
`veeamso.isEnabled` lines in `unattended-block.tmpl`.)

### 3. Set the NTP server
Replace `<<SET_NTP_SERVER>>` (comma-separate for multiple, e.g.
`ntp1.corp.local,ntp2.corp.local`).

> **Prefer an IP address for the NTP server.** The appliance installs with no DNS
> (`--nodns`), so a *hostname* only resolves at first boot if the deployment network
> provides **DHCP + DNS**. NTP sets the clock that TOTP/MFA logins depend on, so an
> **IP** is the safest choice (no resolution needed); if you use a hostname, make sure
> DHCP/DNS are available on the network where these are deployed.

> **If NTP can't be reached at first boot** — e.g. **Azure VMware Solution** / restricted
> NSX-T segments, or anywhere the NTP target isn't reachable during the appliance's first
> boot — the forced time-sync fails and the unattended install **drops to the manual wizard**.
> Set `ntp.runSync=false` (the guided builder asks *"Skip the NTP time-sync at first boot?"*).
> The VM still gets its clock from the hypervisor, so MFA keeps working, and the NTP server
> you set still syncs in the background once it's reachable. (Best combined with an **IP** NTP
> server so it can resolve at all.)

> **Optional — verify the credentials before building:**
> ```bash
> ./check-credentials.sh                       # checks unattended-block.tmpl against the policy
> ```
> Install `cracklib cracklib-dicts` first so the dictionary-word rule is checked too. This
> catches a non-compliant password the appliance would otherwise reject at first boot.

### 4. Build the golden ISO  *(Linux, needs `xorriso`; run with sudo)*
```bash
sudo ./build-appliance-iso.sh --role proxy /path/to/VeeamInfrastructureAppliance_<version>.iso
# vsa: sudo ./build-appliance-iso.sh --role vsa /path/to/VeeamSoftwareAppliance_<version>.iso
```
(Use your actual ISO filename — the version/build may differ from any examples in
these docs. Tip: drop the matching ISO in this folder and `make-golden-iso.sh`
auto-detects it per role, so you can skip the explicit path.)
Output: the source ISO's own name with a role suffix —
`..._PROXY_UNATTENDED.iso` / `..._HARDENEDREPO_UNATTENDED.iso` (VIA ISO) or
`VeeamSoftwareAppliance_<version>_VSA_UNATTENDED.iso` (VSA ISO), so the output
always carries the same build as the input. The script **extracts the role's stock
kickstart from the source ISO and inserts the unattended block**, **derives
grub.cfg from the same ISO and patches it for the role** (into both
`/EFI/BOOT/grub.cfg` and the copy inside `images/efiboot.img` — the one UEFI
firmware actually reads), and **refuses to build while any `<<...>>` placeholder
remains** — so it catches a skipped step 1, 2, or 3. Add `--hostname-prefix NAME`
to override the stock per-role prefix, and `--custom-post FILE` to inject your own
install-time `%post` steps (see "Custom %post") — `make-golden-iso.sh` prompts for both.

> ⚠️ **The golden ISO is a sensitive artifact.** It embeds the kickstart, which
> contains the veeamadmin/veeamso **passwords, MFA secret keys, and the SO recovery
> token in cleartext**. Restrict who can access the ISO, store it securely, and
> **delete the golden ISO once the fleet rollout is complete.** (On each deployed
> appliance the plaintext answer file is auto-deleted after first boot — but the
> ISO itself always retains the secrets.)

### 5. Deploy each appliance
- Distribute the golden ISO (e.g. vSphere Content Library) and attach it as boot
  media to each (empty) VM. **Boot UEFI** — the ISO is UEFI-only, it will not boot
  legacy BIOS.
- This is a **destructive fresh install** (wipes the target disk). It needs
  **network/DHCP** at install and first boot. (On **NSX-T / Azure VMware Solution**,
  DHCP isn't automatic — make sure a DHCP server/relay is configured on the segment, or
  the appliance comes up with no IP and first-boot config can't complete.)
- The installer runs unattended, then **auto-reboots and ejects** the media. On
  first boot, `veeam-init.service` applies the credentials and deletes the
  plaintext answer file. Each VM gets a unique auto hostname (`vprx-<hash>` for
  proxy, `vinf-<hash>` for vmware-proxy, `vlhr-<hash>` for hardened repo,
  `vbr-<hash>` for vsa, `vbem-<hash>` for vbem).

### 6. Bring each appliance into service
- **proxy / vmware-proxy / hardened-repo (VIA):** these don't run VBR themselves —
  add each one to your VBR server as a **backup proxy** (NBD/HotAdd; vmware-proxy
  also brings iSCSI & NVMe/TCP storage connectivity for Direct SAN / storage
  access) or a **hardened repository** (console, or scripted via PowerShell/REST).
- **vsa:** the appliance **is** the Veeam Backup & Replication server — nothing to
  register it *into*; log in and configure it (or attach it to Enterprise
  Manager / VSPC if you use them).
- **vbem:** the appliance **is** the Veeam Backup Enterprise Manager server — log
  in and connect it to your VBR server(s).

### 7. Verify on a sample appliance
```bash
systemctl status veeam-init.service   # inactive (one-shot, disabled itself after running)
ls /etc/veeam/vbr_init.cfg            # gone (deleted after credentials applied)
# then log in as veeamadmin / veeamso with the passwords from step 2
```
Login expectations (confirmed by test):
- **veeamso** (when enabled) prompts for a **TOTP code immediately** (MFA pre-enabled/
  enforced) — add the generated `veeamso.mfaSecretKey` to an authenticator *before*
  logging in. If you disabled veeamso, the account won't be present.
- **veeamadmin** prompts for a TOTP code too **if its MFA was enabled** (always on
  for hardened-repo; per your choice for proxy/vsa) — enroll its key the same way.
- **Neither account is forced to change its password** at first login.

## Custom %post (advanced, optional)

Need the appliance to do something the kit doesn't cover — e.g. **firewall rules**,
install a monitoring/AV agent, drop an SSH key, register with a CMDB? Pass a shell
snippet and it's inserted into the install's `%post`, right after the kit's unattended
block:
```bash
sudo ./build-appliance-iso.sh --role proxy --custom-post ./my-firewall.sh /path/to/ISO
```
`make-golden-iso.sh` also prompts for it (Step 4b). A starter template is included:
**`example-custom-post-firewall.sh`** (firewalld rules, placeholder ports).

> ⚠️ **Unsupported / at your own risk**, and additive only. Key points:
> - It runs at **install time, where firewalld isn't running** — use
>   **`firewall-offline-cmd`** (not `firewall-cmd`). The stock kickstart already sets
>   the default zone to **`drop`**, so you're *adding* allowed ports on top.
> - **Don't** use it for **network / domain / password-policy / encryption** — the
>   appliance manages those itself, so changing them here will conflict.
> - **If a build or install fails, reproduce WITHOUT `--custom-post` first** to confirm
>   it's your snippet vs. the kit.

## Notes / scope
- **Secrets in the golden ISO:** the built ISO embeds the kickstart with the
  account passwords, MFA keys, and SO recovery token in cleartext. Treat it as a
  secret, restrict access, and **delete it after the fleet rollout.** Record the
  generated keys/recovery token first; rotate passwords post-rollout if required.
- **Generated secrets file:** `make-golden-iso.sh` prints the MFA keys + recovery
  token at the end of its run **and** writes them to a `veeam-<role>-secrets-*.txt`
  file (mode 600) for easy retrieval. It's equally sensitive — store it securely
  and **delete it after rollout** (it is never included in a handoff bundle).
- **Firewall:** left stock. The kit adds **no** firewall configuration. The only
  firewall operation in the kickstart is Veeam's own stock hardening, which sets
  the default firewalld zone to `drop`. Required ports (reachable from the VBR
  server) are handled out-of-band per the role's needs.
- **Identity:** hostname/IP are per-host (DHCP at install; `%pre` derives a unique
  `<prefix>-<hash>` hostname — prefix is your choice, default `vprx`/`vlhr`/`vbr`
  per role). Assign final identity (static IP, sequential names) post-boot via
  IPAM / vSphere customization.
- **UEFI only** — these appliances do not boot in legacy BIOS mode.
