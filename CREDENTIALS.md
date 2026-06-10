# Veeam Appliance Golden ISO — Credentials Sheet

> **SENSITIVE.** The values below get baked into the golden ISO that deploys
> every appliance in a deployment. Treat the ISO and any record of these values as
> secrets. Rotate the passwords after the appliances are in production.

## What goes into the unattended block (`unattended-block.tmpl`)

You fill **one** file, `unattended-block.tmpl`, for any role — the build inserts it
into the stock kickstart it extracts from your source ISO. It ships with `<<...>>`
placeholders. There are two kinds:

### A. Secret keys — generate, OR supply your own
```bash
./generate-secrets.sh          # fills unattended-block.tmpl
```
This fills the three `<<GENERATE_...>>` tokens with fresh random values and
prints them. **Run it once per organization/deployment** so keys aren't reused
across organizations. To **supply your own** instead (e.g. a deliberately shared
fleet-wide key), set `VEEAMADMIN_MFA` / `VEEAMSO_MFA` / `VEEAMSO_TOKEN` env vars
(validated; omitted ones are generated), or use the prompts in `make-golden-iso.sh`.
Record what it prints:

| Field | Format | Notes |
|-------|--------|-------|
| `veeamadmin.mfaSecretKey` | 16-char Base32 | Enforced at first boot **if veeamadmin MFA is enabled** (always for hardened-repo; optional for proxy). Enroll it then. |
| `veeamso.mfaSecretKey` | 16-char Base32 | MFA **always enforced** at first boot — the SO must enroll this on first login. |
| `veeamso.recoveryToken` | GUID (hex) | SO account recovery. **Store securely — it cannot be recovered later.** |

### B. Passwords + NTP + hostname — you set these (`<<SET_...>>` tokens)

| Token | What to set | Rules |
|-------|-------------|-------|
| `<<SET_VEEAMADMIN_PASSWORD>>` | veeamadmin account password | 15+ chars; ≥1 upper, lower, digit, special; no more than 4 same-class / 3 identical in a row; no dictionary words |
| `<<SET_VEEAMSO_PASSWORD>>` | veeamso (Security Officer) password | same rules; **must differ from veeamadmin** |
| `<<SET_NTP_SERVER>>` | NTP server (comma-separate for several) | **Prefer an IP** — the appliance has no DNS at install, so a hostname only resolves if the deploy network has DHCP+DNS. NTP drives the clock TOTP/MFA needs. |
| `<<SET_HOSTNAME_PREFIX>>` | hostname prefix; each VM becomes `<prefix>-<unique-hash>` | letters/digits/hyphens, ≤50 chars. Default role prefix: `vprx` / `vlhr` / `vbr`. For sequential names, assign post-boot via IPAM / vSphere. |

Avoid leading/trailing spaces in passwords (the answer file is parsed as `key=value`).
The build script refuses to build while any `<<...>>` placeholder remains.

## MFA for veeamso (PRE-ENABLED and ENFORCED — no enrollment wizard)
Because we set both `veeamso.mfaSecretKey` and `isMfaEnabled=true`, MFA is already
registered server-side. On first login the appliance goes **straight to a TOTP
code prompt** — there is no QR/enrollment screen. So the secret must be added to a
TOTP authenticator **before** that first login.

Add the generated `veeamso.mfaSecretKey` to an authenticator — either enter the
16-char Base32 key manually (time-based / TOTP), or encode this URI as a QR
(substitute your generated key for `SECRETKEY`):

```
otpauth://totp/Veeam:veeamso?secret=SECRETKEY&issuer=Veeam
```

Because the secret is the same across every appliance built from one golden ISO,
**a single authenticator entry produces valid codes for the whole fleet.** TOTP is
time-based, so keep the appliance NTP-synced.

## veeamadmin MFA (role / toggle dependent)
- **hardened-repo:** veeamadmin MFA is **enforced** — like veeamso, it prompts for
  a TOTP code at first login, so enroll its `veeamadmin.mfaSecretKey` first too.
- **proxy / vsa:** veeamadmin MFA is **off by default**; `make-golden-iso.sh` offers
  a Y/N to enforce it. If off, the key is still baked in to enable MFA later.

## veeamso account enable/disable
`make-golden-iso.sh` can disable the Security Officer account (`veeamso.isEnabled=false`,
mirroring the GUI's "enable Security Officer" choice). When disabled, you aren't
prompted for an SO password (a throwaway is filled so the answer file stays valid),
and the veeamso MFA key / recovery token are inert. Enabled is the default.

## First-login behavior (confirmed by test, 2026-06-03)
- **Neither `veeamadmin` nor `veeamso` is forced to change its password at first
  login** — the passwords set here are the working passwords.
- `veeamso` requires the TOTP code immediately; `veeamadmin` does too when its MFA
  is enabled (see above).

## Security reminders
- One golden ISO = same credentials on every appliance in that deployment.
  Generate distinct keys/passwords per organization, and rotate after rollout.
- The kickstart writes `/etc/veeam/vbr_init.cfg` in plaintext on the appliance,
  but `veeam-init.sh` deletes it immediately after applying (an added hardening step).
- The **built golden ISO embeds these credentials in cleartext** (in the derived
  kickstart). Restrict who can access it, store it securely, and **delete the golden
  ISO once the fleet rollout is complete** (record the generated keys/recovery token
  first). The filled `unattended-block.tmpl` is equally sensitive.
- `generate-secrets.sh` keeps a timestamped backup of `unattended-block.tmpl` each
  run; clean those up if they would contain old secrets you don't want retained.
