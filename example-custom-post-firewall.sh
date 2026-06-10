# =============================================================================
# example-custom-post-firewall.sh — EXAMPLE custom %post snippet (firewall rules)
# =============================================================================
# Pass this to the build with:  --custom-post example-custom-post-firewall.sh
# (or pick it at the make-golden-iso.sh "Custom %post" prompt). Its contents are
# inserted VERBATIM into the appliance install's chroot %post, after the kit's
# unattended block. UNSUPPORTED / at your own risk.
#
# ---- READ THIS FIRST --------------------------------------------------------
# * This runs at INSTALL time, where **firewalld is NOT running**. So use
#   `firewall-offline-cmd` (it edits the permanent config directly) — NOT
#   `firewall-cmd`, which needs the live daemon and will fail here.
# * The stock Veeam kickstart already sets the **default zone to `drop`** (all
#   traffic blocked unless explicitly allowed). Your rules ADD to that; they do
#   not change the drop default. Add ports/services to the zone that's active on
#   the appliance's interface (with a `drop` default, that's the `drop` zone
#   unless you assign the interface elsewhere).
# * Do NOT use this to set the network / domain / password policy / encryption —
#   the appliance manages those itself, so changing them here will conflict.
#   Firewall rules are fair game.
# * Ports VARY by role, Veeam version, and your environment — there is no safe
#   universal list, so the lines below are PLACEHOLDERS. Fill them from:
#     - VBR / VSA :  https://helpcenter.veeam.com/docs/vbr/vsphere/used_ports.html?ver=13
#     - VB Ent.Mgr:  https://helpcenter.veeam.com/docs/vbr/em/used_ports.html?ver=13
#   (or your Veeam account/security team). The VIA / hardened repo should be the
#   most restrictive: only the ports VBR needs, sourced from the VBR subnet.
#
# As shipped, every rule below is COMMENTED OUT — this snippet is a no-op until
# you edit it. Copy it, uncomment, and replace the PLACEHOLDER values.
# -----------------------------------------------------------------------------

log "Custom %post: applying customer firewall rules (firewall-offline-cmd)"

# --- pick the zone your rules go into (default-zone is 'drop'; see notes above)
# ZONE=drop

# --- open individual TCP/UDP ports (replace PLACEHOLDER_PORT) -----------------
# firewall-offline-cmd --zone="$ZONE" --add-port=PLACEHOLDER_PORT/tcp
# firewall-offline-cmd --zone="$ZONE" --add-port=PLACEHOLDER_PORT/udp

# --- open a port range --------------------------------------------------------
# firewall-offline-cmd --zone="$ZONE" --add-port=PLACEHOLDER_START-PLACEHOLDER_END/tcp

# --- (optional) restrict a zone to the VBR server subnet (recommended for VIA) -
# firewall-offline-cmd --new-zone=veeam 2>/dev/null || true
# firewall-offline-cmd --zone=veeam --add-source=PLACEHOLDER_VBR_SUBNET/24
# firewall-offline-cmd --zone=veeam --add-port=PLACEHOLDER_PORT/tcp

# --- (optional) add a predefined service instead of raw ports -----------------
# firewall-offline-cmd --zone="$ZONE" --add-service=ssh
