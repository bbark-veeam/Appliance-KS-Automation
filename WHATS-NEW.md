# What's New — Veeam Appliance Kickstart

Current version: see `VERSION`. Newest changes first. Each release is packaged as a
versioned, retained build (see `builds/`).

## New changes — 2026-06-26 (v2.0.7)
- The GUI window no longer runs past the bottom of the screen when **Advanced** is expanded. It's now capped to the screen's working area and **scrolls** when the content is taller, so it stays usable on smaller or non-full-screen RDP sessions (not just full-screen 1080p). If it would still run off the bottom, it nudges itself up to stay on-screen.

## New changes — 2026-06-26 (v2.0.6)
- Fixed a layout bug in the GUI's **Advanced** section: the bottom field (**veeamso recovery token**) was clipped and overlapped the **Build ISO** button. The Advanced panel is now sized to fit all its fields, and the window grows/shrinks as you open or close Advanced — so nothing overlaps and there's no dead space.

## New changes — 2026-06-25 (v2.0.5)
- Added **Confirm password** fields for both veeamadmin and veeamso in the GUI. Because the password boxes are masked, a typo would otherwise only surface when the appliance rejected it after a multi-minute build; the form now checks the two entries match (live) and keeps **Build** disabled until they do — alongside the existing policy and "must differ from veeamadmin" checks.

## New changes — 2026-06-25 (v2.0.4)
- Fixed the GUI throwing an *"Unhandled exception … the running command stopped because ErrorActionPreference … is set to Stop"* error during the SSH host-key check (and which would also have hit the build itself) on Windows PowerShell 5.1. The SSH tools print normal status messages to the error channel, and 5.1 — unlike PowerShell 7 — treats that as fatal when the error preference is "Stop". The SSH/transport steps now tolerate that benign output and rely on explicit exit-code checks, so the host-key dialog and the build proceed normally on 5.1.

## New changes — 2026-06-25 (v2.0.3)
- Fixed the GUI failing to start via **`Launch-GUI.cmd`** on Windows PowerShell 5.1 — it threw a cascade of "Unexpected token" parse errors. The PowerShell scripts contained em-dash characters but were saved without a UTF-8 byte-order mark, so Windows PowerShell 5.1 (which the launcher uses) misread them. The scripts are now plain ASCII, so they load correctly under both Windows PowerShell 5.1 and PowerShell 7. (Running directly under PowerShell 7 already worked, which is why it launched in-session but not from the launcher.)

## New changes — 2026-06-25 (v2.0.2)
- Fixed a noisy warning after a successful build on Windows (*"Could not restrict permissions … Value cannot be null (Parameter 'rule')"*): the step that locks the downloaded ISO + secrets file down to your user account could pass a null value to the permission API when the file had no existing entries to clear. The lockdown now applies cleanly. The build itself always completed regardless — this step is best-effort and only warns — but your built artifacts are now permission-restricted as intended.

## New changes — 2026-06-25 (v2.0.1)
- Fixed the **`Launch-GUI.cmd`** double-click launcher not starting on Windows: the file had macOS-style line endings (and a non-ASCII dash) that `cmd.exe` mis-parses. Rewrote it as plain ASCII, added a pause so any launch error stays readable instead of the window vanishing, and added a `.gitattributes` so batch files are always checked out with Windows (CRLF) line endings while the Linux build scripts stay LF. The GUI itself was unaffected — this was only the double-click convenience wrapper (you can always run `make-golden-gui.ps1 -Gui` directly).

## New changes — 2026-06-25 (v2.0.0)
- Added a **single-window graphical builder for Windows** — double-click **`Launch-GUI.cmd`** and fill in one form (Linux build host + SSH key, ISO type/role, source ISO, hostname prefix, NTP, and the veeamadmin / veeamso passwords), then click **Build ISO**. No command line, no install. The form drives the very same remote build the command-line helper uses (upload kit + ISO to a Linux host, build there, pull the ISO + logs back, clean up).
  - **Passwords stay protected.** They're held as a SecureString and sent to the build host **only over the encrypted SSH channel via stdin** — never on a command line, environment variable, or shell history — and the cleartext is cleared from memory right after. The remote build files are deleted when the run finishes.
  - **Bad passwords are caught before the build, not after.** The form checks each password against the appliance's policy as you type (15+ chars; upper/lower/digit/special; no long same-class or repeated-character runs; veeamadmin must differ from veeamso) and keeps **Build** disabled until both pass — so you don't wait several minutes only to have the appliance reject a weak password at first boot.
  - **Sensible rules built in:** choosing the **Hardened Repository** role locks MFA on for both accounts (as the kit has always done); turning the Security Officer account off greys its fields; and an **Advanced** section keeps power-user options (post-install %post script, bring-your-own MFA keys / recovery token, skip-NTP-sync, keep-remote-on-failure) out of the way for the common case.
  - **First-connection safety:** the first time you build against a host, the form shows that host's SSH fingerprint and makes you **verify it** — either paste the expected SHA256, or type the word `ACCEPT` — before any credentials are sent (Reject is the default; a changed key is refused outright as a possible man-in-the-middle).
  - **Live progress:** the build runs in the background so the window never freezes, the steps stream into a log pane, and you get a clear success/failure result plus a pointer to where the ISO and logs were saved.
- The command-line remote helper (`make-golden-remote.ps1`) is unchanged and still available for scripted/CLI use; the GUI is an addition, not a replacement.

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
