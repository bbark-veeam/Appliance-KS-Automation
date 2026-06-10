# =============================================================================
# example-custom-post-license.sh — EXAMPLE custom %post snippet (install a Veeam
#                                   license on the vsa / VBR server at first boot)
# =============================================================================
# Pass this to the build with:  --custom-post example-custom-post-license.sh
# (or pick it at the make-golden-iso.sh "Custom %post" prompt). Its contents are
# inserted VERBATIM into the appliance install's chroot %post, after the kit's
# unattended block. Intended for the **vsa** role only. UNSUPPORTED / at your own risk.
#
# ---- READ THIS FIRST --------------------------------------------------------
# * SCOPE: this is for the **vsa (Veeam Backup & Replication server)** role only.
#   Proxies and the hardened repo are not licensed; Enterprise Manager (vbem) has
#   APIs but no license install. Don't use this snippet with those roles.
# * This runs at INSTALL time, in the chroot, where **VBR is NOT running and there
#   is no network**. You cannot install a license here. The pattern is:
#     (A) STAGE the .lic file onto the appliance now (inline, base64), then
#     (B) a FIRST-BOOT one-shot waits for VBR to come up and installs it —
#         mirroring the stock `start-iscsid-once.service` pattern.
# * AUTH IS THE HARD PART — and the placeholder you must solve. The license call
#   itself is simple, but it needs an authenticated VBR session. With **veeamadmin
#   MFA enabled** the token flow hits an MFA challenge that an unattended script
#   can't clear. Two options:
#     - SIMPLEST: deploy with **veeamadmin MFA disabled** (the builder's MFA prompt
#       -> No), let this install the license, then enroll/enable MFA afterwards.
#     - Or have the one-shot compute the current TOTP from the baked-in MFA secret
#       (e.g. with oathtool) and complete the MFA token exchange.
#   (The build guard warns/prompts if it sees an API call here with MFA enabled.)
# * CONFIRM ON THE APPLIANCE before relying on this: the local REST port/base URL
#   (typically 9419), the `x-api-version` value for your build, and whether the
#   Veeam PowerShell module is present (the `Install-VBRLicense -Path <file>`
#   cmdlet is the alternative to the REST call below).
# * The license is deployment-specific, so the value below is a PLACEHOLDER.
#
# Reference: REST `POST /api/v1/license/install` (body: base64 of the .lic);
#            PowerShell `Install-VBRLicense`.
#
# As shipped, every line below is COMMENTED OUT — this snippet is a no-op until
# you edit it. Copy it, uncomment, and replace the PLACEHOLDER values.
# -----------------------------------------------------------------------------

log "Custom %post: staging Veeam license for first-boot install (vsa / VBR server)"

# --- (A) stage the .lic on the appliance (base64 it: `base64 -w0 your.lic`) ---
# install -d -m 700 /opt/veeam-firstboot
# base64 -d > /opt/veeam-firstboot/license.lic <<'LICB64'
# PLACEHOLDER_BASE64_OF_YOUR_LICENSE_FILE
# LICB64

# --- (B) first-boot one-shot: install the license once VBR is up -------------
# Needs veeamadmin MFA DISABLED (see notes) so the token call needs no MFA code.
# cat > /etc/systemd/system/veeam-license-install-once.service <<'UNIT'
# [Unit]
# Description=Install Veeam license once on first boot
# After=network-online.target
# Wants=network-online.target
#
# [Service]
# Type=oneshot
# RemainAfterExit=true
# ExecStart=/opt/veeam-firstboot/install-license.sh
# ExecStartPost=/bin/systemctl disable veeam-license-install-once.service
#
# [Install]
# WantedBy=multi-user.target
# UNIT
#
# cat > /opt/veeam-firstboot/install-license.sh <<'RUN'
# #!/usr/bin/env bash
# set -euo pipefail
# API="https://localhost:PLACEHOLDER_PORT/api"      # confirm port (typically 9419)
# APIVER="PLACEHOLDER_X_API_VERSION"                 # e.g. 1.3-rev1 for your build
# # wait for the REST API to answer
# for i in $(seq 1 60); do curl -sk "$API/v1/serverInfo" -H "x-api-version: $APIVER" >/dev/null && break; sleep 10; done
# # authenticate (password grant; works only with veeamadmin MFA DISABLED)
# TOKEN=$(curl -sk -X POST "$API/oauth2/token" -H "x-api-version: $APIVER" \
#   -H "Content-Type: application/x-www-form-urlencoded" \
#   --data-urlencode "grant_type=password" \
#   --data-urlencode "username=veeamadmin" \
#   --data-urlencode "password=PLACEHOLDER_VEEAMADMIN_PASSWORD" \
#   | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
# [ -n "$TOKEN" ] || { echo "auth failed (MFA enabled? wrong creds?)" >&2; exit 1; }
# # install the license (base64 of the staged .lic)
# B64=$(base64 -w0 /opt/veeam-firstboot/license.lic)
# curl -sk -X POST "$API/v1/license/install" -H "x-api-version: $APIVER" \
#   -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
#   -d "{\"license\":\"$B64\"}"
# # tidy up the staged secret material
# shred -u /opt/veeam-firstboot/license.lic 2>/dev/null || rm -f /opt/veeam-firstboot/license.lic
# RUN
# chmod 700 /opt/veeam-firstboot/install-license.sh
# systemctl enable veeam-license-install-once.service
