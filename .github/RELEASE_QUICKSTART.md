## Quick start

> **Not a Veeam product** — independent courtesy tooling, provided as-is, with no warranty or Veeam support. See `DISCLAIMER.md` and `LICENSE`.

Builds an **unattended** Veeam appliance golden ISO so many identical appliances deploy from one ISO. Pick a **role** at build time: **proxy**, **hardened-repo** (both from the VIA ISO), or **vsa** (from the VSA ISO).

**You need:** Linux or WSL2 with `xorriso` and `python3`, root/sudo, and the matching Veeam ISO in the folder.

```bash
# Unzip this release, then from inside the folder:
chmod +x *.sh
./make-golden-iso.sh        # guided; auto-detects the matching ISO in the folder
```

The guided builder prompts for role, hostname prefix, passwords, MFA / veeamso options, and NTP, then produces `..._<ROLE>_UNATTENDED.iso`. **Write down the three secrets it prints — especially `veeamso.recoveryToken`, which cannot be recovered later.**

**Boot-test:** attach the built ISO to an empty **UEFI** VM on a **DHCP** network (disable guest customization, e.g. in VMware Cloud Director). It installs fully unattended; then log in as `veeamadmin` / `veeamso` and enroll the MFA key(s) when prompted.

Full detail in `README.md`; credentials and keys reference in `CREDENTIALS.md`.
