# What's New — Veeam Appliance Kickstart

Current version: see `VERSION`. Newest changes first. Each release is packaged as a
versioned, retained build (see `builds/`).

## New changes — 2026-06-30 (v2.1.1)
- **The graphical builder now masks the bring-your-own MFA keys and recovery token.** Under **Advanced -> "Bring your own MFA keys / recovery token"**, the veeamadmin/veeamso MFA keys and the veeamso recovery token are now hidden as you type or paste them — the same masking the password fields already use. These are secrets (the MFA key is the TOTP seed; the recovery token bypasses MFA), so they should not sit in cleartext on screen (e.g. during a screen-share or demo). Format validation and the after-build field clear are unchanged.

## New changes — 2026-06-30 (v2.1.0)
- **The graphical builder can now build locally in WSL2 — no SSH, no separate Linux host.** When you launch **`Launch-GUI.cmd`** it now asks **where to build** first:
  - **Local (WSL2 + xorriso)** — builds right on your Windows machine using WSL2. Pick your WSL distro from a dropdown (your default distro is pre-selected); the form checks that `xorriso` is installed in it and keeps **Build** disabled, with an install hint, until it is. No SSH, no keys, no second machine.
  - **Remote (Linux host + xorriso)** — the original path: build on a separate Linux host over SSH (host + key + first-connection host-key verification), unchanged.
  - The same form and the **same `xorriso` build engine** run either way — only the *location* of the build differs. If WSL2 isn't installed, the Local option is disabled with a hint and Remote is pre-selected.
- **Default output folder is now `C:\temp`** (was the launch directory), so the built ISO, secrets sheet, and logs land in a predictable place outside the kit folder. It's created automatically if it doesn't exist; the secrets sheet is still permission-locked to you.
- Credential handling is unchanged: passwords are held as a SecureString and fed to the build **via stdin only** (never a command line, environment variable, or history), and the build files are cleaned up when the run finishes.
- The command-line paths (`make-golden-iso.sh`, `make-golden-remote.ps1`) are unchanged.

## New changes — 2026-06-26 (v2.0.0)
- **New: a single-window graphical builder for Windows.** Double-click **`Launch-GUI.cmd`** and fill in one form — Linux build host + SSH key, ISO type/role, source ISO, hostname prefix, NTP, output folder, and the veeamadmin / veeamso passwords — then click **Build ISO**. No command line, no install. It drives the same remote build as the command-line helper: upload the kit + your ISO to a Linux host, build there, pull the ISO + logs back, and clean up.
  - **Credentials stay protected.** Passwords are held as a SecureString and sent to the build host **only over the encrypted SSH channel via stdin** — never on a command line, environment variable, or shell history — and cleared from the form after a successful build. The built ISO and the secrets sheet are permission-locked to the building user when they land on your machine.
  - **Mistakes are caught before the build, not after.** Each password is validated live against the appliance policy (15+ chars; upper/lower/digit/special; no long same-class or repeated runs; veeamadmin must differ from veeamso), with a **Confirm password** field, and **Build** stays disabled until everything passes. NTP, hostname prefix, and bring-your-own MFA keys are validated too.
  - **Sensible rules built in.** The **Hardened Repository** role forces MFA on both accounts; turning off the Security Officer account greys its fields; and an **Advanced** section keeps power-user options (post-install `%post` script, BYO MFA keys / recovery token, skip-NTP-sync, keep-remote-on-failure) out of the way for the common case. The window sizes to your screen and scrolls if it would run off the bottom.
  - **First-connection safety.** The first time you build against a host, the form shows its SSH fingerprint and makes you **verify it** — paste the expected SHA256 or type `ACCEPT` — before any credentials are sent (Reject is the default). A **changed** host key is refused outright as a possible man-in-the-middle.
  - **Live progress.** The build runs in the background so the window never freezes; steps stream into a log pane, and you get a clear success/failure result plus where the ISO and logs were saved.
- **Release integrity + provenance:** every release now ships a **SHA-256 checksum** and a **signed build-provenance attestation** — see **"Verify your download"** in the README to confirm a download is intact and came from this project's pipeline.
- The command-line `make-golden-remote.ps1` path is unchanged and still available for scripted/CLI use; the GUI is an addition, not a replacement.

## New changes — 2026-06-22 (v1.3.0)
- Added **build logging** so every run leaves a record to diagnose a failed build (or a later install) from:
  - The guided builder writes a **job log** of the run, and the build step writes its own **agent log**; the two share a run id and are grouped in one per-run folder under `logs/`. `generate-secrets.sh` and `check-credentials.sh` also log when run on their own.
  - **Always on** — use `--no-log` to disable or `--log <file>` to set the path. The per-run folder is named by role + timestamp (e.g. `proxy-2026-06-22T19-03-10Z-…`) so the run you want is easy to find.
  - The format mirrors the familiar Veeam **job/agent** log style, with headers that clearly mark this as a community tool (not an official Veeam product). **No secrets are ever written to a log** — passwords appear as a fixed mask, and generated MFA keys / the recovery token are never logged (they stay on the console and in the existing secrets file only).
  - The Windows remote helper (`make-golden-remote.ps1`) writes its own transport log and pulls the Linux build logs back alongside the ISO.

## New changes — 2026-06-10 (v1.2.0)
- Added two new build **roles**, so the kit now covers all five Veeam appliance kickstarts:
  - **`vmware-proxy`** — VIA VMware backup proxy with **iSCSI & NVMe/TCP** storage connectivity (the "Veeam Infrastructure Appliance (with iSCSI & NVMe/TCP)" variant; builds from the **VIA** ISO's `vmware-proxy-ks.cfg`).
  - **`vbem`** — **Veeam Backup Enterprise Manager** (builds from the **VSA** ISO's `vbem-ks.cfg`).
- The guided builder now lists all five roles (proxy / vmware-proxy / hardened-repo / vsa / vbem), and the standalone `build-appliance-iso.sh` accepts `--role vmware-proxy` and `--role vbem`. Same version-agnostic flow: the stock kickstart and grub are extracted from your ISO at build time.
- Fixed the grub default-entry text per role: Enterprise Manager's install entry omits the "(including local backups)" suffix the other roles use, so its unattended default boot now points at the correct menu entry.
- Added a second `--custom-post` starter template, **`example-custom-post-storage.sh`** — vmware-proxy **Direct SAN access** prep (OS-level iSCSI / NVMe-TCP / multipath connectivity to the production LUNs; the case with no VBR-side config, unlike Backup from Storage Snapshots; placeholder portals/IQNs/NQNs).
- Added a third `--custom-post` starter template, **`example-custom-post-license.sh`** — **vsa-only**: stages a `.lic` and installs it at first boot via the VBR REST API (`POST /api/v1/license/install`, base64 body). Documents that unattended API auth needs veeamadmin MFA disabled (enroll/enable it after). Like the others, additive, unsupported, and a no-op until you edit it.
- Added a **custom-%post safety guard**: if your snippet looks like it calls the VBR API/cmdlets (`/api/v1/`, `oauth2/token`, `:9419`, `Install-VBRLicense`, `Connect-VBRServer`) **and** veeamadmin MFA is enabled, the guided builder warns that unattended API auth will hit an MFA challenge and **prompts to continue (default: stop)** before generating anything; the standalone `build-appliance-iso.sh` prints a non-blocking warning (it stays scriptable for CI / remote builds). Like the firewall template it's additive, unsupported, and a no-op until you edit it; it writes persistent config and/or a first-boot one-shot (mirroring the stock `start-iscsid-once.service`) rather than running live connection commands at install time.
- Fixed a **cosmetic first-boot issue** where, on slower boots, the appliance's console setup screen could appear briefly **before** the unattended configuration had finished applying — making it look as though the deployment had dropped to manual setup even though it completed successfully. The console login is now ordered to wait for the first-boot configuration to finish, so the unattended flow runs to completion before any setup screen is shown. If the configuration genuinely fails, the setup screen still appears so you can configure manually.

## New changes — 2026-06-08 (v1.1.2)
- Added a **custom %post hook** (`--custom-post`, and a prompt in the guided builder) so you can inject your own install-time steps — **firewall rules**, an agent, an SSH key, CMDB registration, etc. Includes a starter template, `example-custom-post-firewall.sh`. (Additive and unsupported/at-your-own-risk; not for network/domain/password-policy/encryption, which the appliance owns.)
- Made the **Windows remote-build helper** (`make-golden-remote.ps1`) far more robust: it no longer deletes the remote build on a transfer failure (so a mistyped SSH password can't throw away a finished ISO — you can just retry the download), retries network steps, and recommends SSH key auth to avoid repeated password prompts.

## New changes — 2026-06-08 (v1.1.1)
- Corrected the password complexity check, which was **one notch too strict**. It now matches what the appliance actually enforces (DISA STIG): up to **4** consecutive characters of the same class are allowed (was incorrectly capped at 3), and no more than **3** identical characters in a row. This stops the tool from rejecting valid passwords the appliance would have accepted.
- Added a wizard option to **skip the NTP time-sync at first boot** — for environments where NTP isn't reachable when the appliance first boots (e.g. Azure VMware Solution / restricted segments), where the forced time-sync was failing and dropping the unattended install to the manual configuration screen. The VM still gets time from the hypervisor, so MFA keeps working; the NTP server you enter stays configured and syncs once reachable.
- Added a **Windows helper** (`make-golden-remote.ps1`) that builds on a remote Linux host without WSL: from a Windows box it uploads the kit + your ISO to a Linux build host over SSH, runs the build there interactively, downloads the finished ISO back, and cleans up the remote copies. (The build still runs on Linux — this just automates the round-trip.)
- Standardized all yes/no prompts to a consistent `[Y/N]` format with the default behavior spelled out in each prompt.

## New changes — 2026-06-05 (v1.1.0)
- **Now fully version-agnostic.** The kit no longer ships a fixed kickstart. At build time it extracts the stock kickstart from whatever Veeam ISO you provide and inserts the unattended settings into it — so the package list, disk layout, and build ID always match your ISO instead of a baked-in version.
- You now fill **one** unattended block (`unattended-block.tmpl`) instead of three per-role kickstart files; the build inserts it for whichever role you choose.
- If a future Veeam build changes the kickstart layout the tool depends on, the build now **stops with a clear error** instead of producing an ISO that might not install cleanly.
- The hostname prefix is applied to the ISO's own network configuration at build time (no behavior change you'll notice — same `<prefix>-<unique-id>` result).

## New changes — 2026-06-05 (v1.0.1)
- The built ISO is now **named after the ISO you fed in** (plus a role suffix), so the output always carries the same Veeam build/version as the source instead of a fixed version in its name.
- Made the documentation **version-agnostic** — example commands no longer hardcode a specific build, and there's a clear note that your ISO's version may differ and which build the kickstarts were derived from.

## New changes — 2026-06-05 (v1.0.0)
- Added the **Veeam Backup & Replication (VSA) server** as a build target, alongside the proxy and hardened repository options.
- Added the ability to **bring your own MFA secret keys and Security Officer recovery token** instead of auto-generating them.
- Added an option to **enable or disable the veeamso (Security Officer) account**.
- Added a **customizable hostname prefix** — each appliance becomes `<prefix>-<unique-id>`.
- Fixed edge cases where passwords passed the complexity check but were still not DISA STIG compliant.
- Fixed a bug where, if veeamso was disabled, it would improperly leave MFA enabled for it — which could prevent the unattended automation from completing.
- Added a new tool (`check-credentials.sh`) to run password-compliance checks against repacked ISOs, in case an outlier password makes it through or the password is changed by hand in the kickstart.
- Added build/version numbering, with backups of previous builds retained automatically.

## New changes — 2026-06-03
- Fixed the appliance stopping at a manual boot menu instead of installing unattended (the boot configuration is now applied where the firmware actually reads it).
- Secret keys (MFA + recovery token) are now generated fresh per deployment instead of shipped preset, so no two organizations end up with the same keys.
- The generated secrets are now shown at the end of the run and saved to a clearly marked, sensitive file for easy retrieval after the build.
- Added the **hardened repository** role in addition to the proxy role (with MFA enforced on both accounts for that role).
- The build now works with standard tools only — no extra packages needed when run with sudo.
- Added guidance for building on Windows via WSL.

## New changes — 2026-06-02
- Initial release: an unattended Veeam Infrastructure Appliance (proxy) ISO that pre-defines the veeamadmin and veeamso logins with their secret keys, so a fleet of identical appliances can be deployed from a single golden ISO.
