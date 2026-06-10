# =============================================================================
# example-custom-post-storage.sh — EXAMPLE custom %post snippet (vmware-proxy
#                  Direct SAN access prep: iSCSI / NVMe-TCP / multipath)
# =============================================================================
# Pass this to the build with:  --custom-post example-custom-post-storage.sh
# (or pick it at the make-golden-iso.sh "Custom %post" prompt). Its contents are
# inserted VERBATIM into the appliance install's chroot %post, after the kit's
# unattended block. Intended for the **vmware-proxy** role (the VIA "with iSCSI &
# NVMe/TCP" variant). UNSUPPORTED / at your own risk.
#
# ---- READ THIS FIRST --------------------------------------------------------
# * This runs at INSTALL time, in the chroot, where **iscsid / multipathd are NOT
#   running and there is NO network yet**. So do NOT run live connection commands
#   here (`iscsiadm --login`, `nvme connect`, `multipath`) — they need the running
#   daemons and reachable targets and WILL fail at install. Two safe approaches:
#     (A) write PERSISTENT CONFIG that the daemons read at boot
#         (initiator name, host NQN, multipath.conf, iscsid.conf), and/or
#     (B) drop a FIRST-BOOT one-shot service that performs discovery + login once
#         networking is up — mirroring the stock `start-iscsid-once.service`.
#   The vmware-proxy stock %post already enables iscsid, loads the `nvme-tcp`
#   module, and enables multipathd; this snippet only ADDS your connection config.
# * Headline use case: **Direct SAN access** — the proxy reads VM data straight
#   from the production SAN LUNs over iSCSI / NVMe-TCP. That mode has **no VBR-side
#   configuration**: VBR auto-selects "Direct storage access" once the proxy's OS
#   can see the LUNs, so the whole job is OS-level connectivity — exactly what this
#   snippet stages. (**Backup from Storage Snapshots (BfSS)** can also have OS-level
#   connection requirements — e.g. reaching the snapshot LUNs the array presents to
#   the proxy — but its array integration is configured IN VBR, not here.)
# * Do NOT use this to set the network / domain / password policy / encryption —
#   the appliance manages those itself. Storage initiator config is fair game.
# * Portals, IQNs/NQNs, and CHAP creds are DEPLOYMENT-SPECIFIC — there is no safe
#   universal value, so everything below is a PLACEHOLDER. Get the real values
#   from your storage team. Reference tooling: open-iscsi (`iscsiadm`,
#   `initiatorname.iscsi`, `iscsid.conf`), nvme-cli (`nvme connect`, `hostnqn`),
#   and device-mapper-multipath (`multipath.conf`).
#
# As shipped, every line below is COMMENTED OUT — this snippet is a no-op until
# you edit it. Copy it, uncomment, and replace the PLACEHOLDER values.
# -----------------------------------------------------------------------------

log "Custom %post: staging vmware-proxy Direct SAN access config (iSCSI / NVMe-TCP / multipath)"

# --- (A) iSCSI initiator name — persistent, read by iscsid at boot ------------
# echo "InitiatorName=PLACEHOLDER_INITIATOR_IQN" > /etc/iscsi/initiatorname.iscsi

# --- (A) iSCSI CHAP auth (optional) — set in iscsid.conf ----------------------
# sed -i 's/^#\?node.session.auth.authmethod.*/node.session.auth.authmethod = CHAP/' /etc/iscsi/iscsid.conf
# sed -i 's/^#\?node.session.auth.username.*/node.session.auth.username = PLACEHOLDER_CHAP_USER/' /etc/iscsi/iscsid.conf
# sed -i 's/^#\?node.session.auth.password.*/node.session.auth.password = PLACEHOLDER_CHAP_SECRET/' /etc/iscsi/iscsid.conf

# --- (A) NVMe/TCP host NQN — persistent, read by nvme at boot -----------------
# echo "PLACEHOLDER_HOST_NQN" > /etc/nvme/hostnqn

# --- (A) multipath tuning (optional) — your array's recommended settings ------
# cat > /etc/multipath.conf <<'MPATH'
# defaults {
#     user_friendly_names yes
#     find_multipaths yes
# }
# # devices { device { vendor "PLACEHOLDER_VENDOR" product "PLACEHOLDER_PRODUCT" } }
# MPATH

# --- (B) first-boot one-shot: discover + log in once the network is up --------
# Live iSCSI/NVMe connections can't be made at install time (no daemon/network),
# so stage them in a one-shot that runs on first boot and then disables itself —
# the same pattern the stock kickstart uses for start-iscsid-once.service.
# cat > /etc/systemd/system/veeam-storage-connect-once.service <<'UNIT'
# [Unit]
# Description=Connect proxy storage (iSCSI / NVMe-TCP) once on first boot
# After=network-online.target iscsid.service
# Wants=network-online.target
#
# [Service]
# Type=oneshot
# RemainAfterExit=true
# # iSCSI: discover the portal, then log in to all discovered targets
# ExecStart=/usr/bin/iscsiadm -m discovery -t sendtargets -p PLACEHOLDER_ISCSI_PORTAL_IP
# ExecStart=/usr/bin/iscsiadm -m node --loginall=all
# # NVMe/TCP: connect to the subsystem on the storage target
# ExecStart=/usr/sbin/nvme connect -t tcp -a PLACEHOLDER_NVME_TARGET_IP -s 4420 -n PLACEHOLDER_SUBSYSTEM_NQN
# ExecStartPost=/bin/systemctl disable veeam-storage-connect-once.service
#
# [Install]
# WantedBy=multi-user.target
# UNIT
# systemctl enable veeam-storage-connect-once.service
