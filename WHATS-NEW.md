# What's New — Veeam Appliance Kickstart

Current version: see `VERSION`. Newest changes first. Each release is packaged as a
versioned, retained build (see `builds/`).

## New changes — 2026-06-10 (v1.2.0)
- Added two new build **roles**, so the kit now covers all five Veeam appliance kickstarts:
  - **`vmware-proxy`** — VIA VMware backup proxy with **iSCSI & NVMe/TCP** storage connectivity (the "Veeam Infrastructure Appliance (with iSCSI & NVMe/TCP)" variant; builds from the **VIA** ISO's `vmware-proxy-ks.cfg`).
  - **`vbem`** — **Veeam Backup Enterprise Manager** (builds from the **VSA** ISO's `vbem-ks.cfg`).
- The guided builder now lists all five roles (proxy / vmware-proxy / hardened-repo / vsa / vbem), and the standalone `build-appliance-iso.sh` accepts `--role vmware-proxy` and `--role vbem`. Same version-agnostic flow: the stock kickstart and grub are extracted from your ISO at build time.
- Fixed the grub default-entry text per role: Enterprise Manager's install entry omits the "(including local backups)" suffix the other roles use, so its unattended default boot now points at the correct menu entry.

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
