#!/bin/bash
#
# ecat_teardown.sh - Remove all configuration created by ecat_setup.sh
#
# Removes: ethercat.service, ethercat-cpuset.service (legacy),
# /usr/local/sbin/ecat-cgroup helper, IgH sysconfig, leftover GRUB
# isolation params, udev rule, scheduling limits, sudoers drop-in,
# ldconfig entry, file capabilities on the daemon binary.
# Does NOT remove IgH itself (kernel modules, library, headers) or the
# 'ecat' group/user membership.
#
# Run as root. The EtherCAT NIC is rebound to its stock driver here, so its
# netdev returns live; a reboot is only needed if that rebind fails or if
# legacy GRUB params were removed.
#
# Usage:
#   sudo ecat_teardown.sh
#

set -euo pipefail

INSTALL_PREFIX="/usr/local"
GRUB_FILE="/etc/default/grub"

ECAT_SERVICE="/etc/systemd/system/ethercat.service"
CPUSET_SERVICE="/etc/systemd/system/ethercat-cpuset.service"   # legacy
CPUSET_DIR="/sys/fs/cgroup/ethercat_rt"
CGROUP_HELPER="/usr/local/sbin/ecat-cgroup"
ECAT_STATE_DIR="/var/lib/ecat"
IGH_SYSCONFIG="$INSTALL_PREFIX/etc/sysconfig/ethercat"
LDCONFIG_CONF="/etc/ld.so.conf.d/ethercat.conf"
UDEV_RULE="/etc/udev/rules.d/99-ethercat.rules"
LIMITS_FILE="/etc/security/limits.d/99-ethercat.conf"
SUDOERS_FILE="/etc/sudoers.d/ecat"
NM_KEYFILE="/etc/NetworkManager/conf.d/99-tk-ethercat.conf"
AVAHI_CONF="/etc/avahi/avahi-daemon.conf"
AVAHI_BACKUP="/etc/avahi/avahi-daemon.conf.tk-backup"
NATIVE_MODPROBE_CONF_IGB="/etc/modprobe.d/tk-ethercat-ec_igb.conf"
NATIVE_MODPROBE_CONF_IGC="/etc/modprobe.d/tk-ethercat-ec_igc.conf"

# Also clean up old file names from previous versions
OLD_UDEV_RULE="/etc/udev/rules.d/99-ethercat-rt.rules"
OLD_LIMITS_FILE="/etc/security/limits.d/99-ethercat-rt.conf"

# =========================================================================
# 0. Root check
# =========================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)."
    exit 1
fi

echo "=== EtherCAT System Teardown ==="
echo ""

# =========================================================================
# 1. Stop and remove ethercat.service
# =========================================================================
echo "--- [1/6] ethercat.service ---"
if systemctl list-unit-files 2>/dev/null | grep -q "ethercat.service"; then
    systemctl stop ethercat.service 2>/dev/null || true
    systemctl disable ethercat.service --quiet 2>/dev/null || true
    echo "  Stopped and disabled ethercat.service"
fi
if [ -f "$ECAT_SERVICE" ]; then
    rm "$ECAT_SERVICE"
    systemctl daemon-reload
    echo "  Removed $ECAT_SERVICE"
else
    echo "  Not present"
fi

# Remove native-driver PCI pin: modprobe.d install rule + driver_override.
# Setup wrote /etc/modprobe.d/tk-ethercat-ec_<igb|igc>.conf to make stock
# $DRIVER skip the EtherCAT NIC's PCI slot, and set driver_override on
# that BDF. Without removing the override, the slot stays unbindable to
# stock $DRIVER even after teardown (cosmetic on EtherCAT-only hosts,
# breaks the NIC if the operator wants to reuse it for plain LAN later).
NEED_INITRAMFS_REBUILD=false
for conf in "$NATIVE_MODPROBE_CONF_IGB" "$NATIVE_MODPROBE_CONF_IGC"; do
    if [ -f "$conf" ]; then
        rm "$conf"
        echo "  Removed $conf"
        NEED_INITRAMFS_REBUILD=true
    fi
done
# Restore each native-bound EtherCAT NIC to its stock driver so the netdev
# returns LIVE (no reboot needed). Clearing driver_override alone is NOT
# enough: the kernel only consults the override on the next probe, so an
# orphaned slot stays driverless — no netdev — until a reboot. We therefore,
# per BDF: unbind the native driver if still attached, clear the override,
# load the stock driver, and trigger a re-probe. Iterate all PCI devices so
# we don't depend on the original BDF (which lived in the modprobe.d file we
# just deleted). If a netdev doesn't come back, flag a reboot.
NIC_REBOOT_NEEDED=false
STORED_MAC=$(tr -d '[:space:]' < "$ECAT_STATE_DIR/main_devices" 2>/dev/null || true)
for dev in /sys/bus/pci/devices/*/driver_override; do
    [ -r "$dev" ] || continue
    cur=$(cat "$dev" 2>/dev/null || true)
    case "$cur" in
        ec_igb|ec_igc) ;;
        *) continue ;;
    esac
    bdf=$(basename "$(dirname "$dev")")
    stock=${cur#ec_}                         # ec_igb -> igb, ec_igc -> igc
    echo "  EtherCAT NIC $bdf${STORED_MAC:+ (MAC $STORED_MAC)} — driver $cur, restoring to $stock"

    # Free the slot if the native driver is still bound to it.
    boundnow=$(basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null)" 2>/dev/null || true)
    if [ "$boundnow" = "ec_igb" ] || [ "$boundnow" = "ec_igc" ]; then
        echo "$bdf" > "/sys/bus/pci/drivers/$boundnow/unbind" 2>/dev/null || true
    fi
    # Clear the reservation, then load + re-probe the stock driver so the
    # netdev is published again right now.
    : > "$dev" 2>/dev/null || true
    modprobe "$stock" 2>/dev/null || true
    echo "$bdf" > /sys/bus/pci/drivers_probe 2>/dev/null || true

    # Verify a netdev reappeared under the slot.
    newnet=""
    if [ -d "/sys/bus/pci/devices/$bdf/net" ]; then
        for n in "/sys/bus/pci/devices/$bdf/net"/*; do
            [ -e "$n" ] && { newnet=$(basename "$n"); break; }
        done
    fi
    if [ -n "$newnet" ]; then
        echo "    -> restored to $stock ($newnet back — visible in 'ip link')"
    else
        echo "    -> could not rebind live; reboot to restore the netdev"
        NIC_REBOOT_NEEDED=true
    fi
done
if [ "$NEED_INITRAMFS_REBUILD" = true ]; then
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u >/dev/null 2>&1 && echo "  initramfs rebuilt (rule no longer applies at next boot)"
    elif command -v dracut >/dev/null 2>&1; then
        dracut --force >/dev/null 2>&1 && echo "  initramfs (dracut) rebuilt"
    fi
fi

# Remove IgH runtime config + ldconfig
for f in "$IGH_SYSCONFIG" "$LDCONFIG_CONF"; do
    if [ -f "$f" ]; then
        rm "$f"
        echo "  Removed $f"
    fi
done
ldconfig 2>/dev/null || true

# =========================================================================
# 2. NetworkManager + avahi quarantine — restore host networking userspace
# =========================================================================
echo "--- [2/6] NetworkManager + avahi quarantine ---"

# Drop the NM keyfile that marked the EtherCAT NIC + eoe* as unmanaged.
if [ -f "$NM_KEYFILE" ]; then
    rm "$NM_KEYFILE"
    echo "  Removed $NM_KEYFILE"
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        nmcli general reload 2>/dev/null || true
    fi
else
    echo "  $NM_KEYFILE not present"
fi

# Restore avahi-daemon.conf from the pre-setup backup (if we made one).
# If no backup exists, the file was never touched by setup — leave alone.
if [ -f "$AVAHI_BACKUP" ]; then
    if [ -f "$AVAHI_CONF" ] && ! cmp -s "$AVAHI_BACKUP" "$AVAHI_CONF"; then
        install -m 0644 -o root -g root "$AVAHI_BACKUP" "$AVAHI_CONF"
        echo "  Restored $AVAHI_CONF from $AVAHI_BACKUP"
        if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
            systemctl reload-or-restart avahi-daemon 2>/dev/null || true
        fi
    else
        echo "  $AVAHI_CONF already matches backup (no restore needed)"
    fi
    rm -f "$AVAHI_BACKUP"
    echo "  Removed $AVAHI_BACKUP"
else
    echo "  No avahi backup at $AVAHI_BACKUP (avahi config never modified)"
fi

# =========================================================================
# 3. cgroup helper + legacy cpuset service + GRUB legacy cleanup
# =========================================================================
echo "--- [3/6] cgroup helper + legacy cpuset + GRUB ---"

GRUB_REBOOT_NEEDED=false

# Remove the on-demand helper script.
if [ -f "$CGROUP_HELPER" ]; then
    rm "$CGROUP_HELPER"
    echo "  Removed $CGROUP_HELPER"
fi

# Legacy: prior versions installed an always-on ethercat-cpuset.service.
# Stop, disable, and delete it if found.
if systemctl list-unit-files 2>/dev/null | grep -q "ethercat-cpuset.service"; then
    systemctl stop ethercat-cpuset.service 2>/dev/null || true
    systemctl disable ethercat-cpuset.service --quiet 2>/dev/null || true
    echo "  Stopped and disabled legacy ethercat-cpuset.service"
fi
if [ -f "$CPUSET_SERVICE" ]; then
    rm "$CPUSET_SERVICE"
    systemctl daemon-reload
    echo "  Removed legacy $CPUSET_SERVICE"
fi

# If a daemon crashed without calling 'ecat-cgroup down', scaling_min_freq on
# the RT CPU is still pinned to cpuinfo_max_freq. Restore it from snapshot
# before we lose the cpuset (which is how we find out which CPU was pinned).
if [ -f "$ECAT_STATE_DIR/scaling_min_freq.prior" ] && [ -d "$CPUSET_DIR" ]; then
    _rt_cpu=$(cat "$CPUSET_DIR/cpuset.cpus" 2>/dev/null)
    _minf="/sys/devices/system/cpu/cpu${_rt_cpu}/cpufreq/scaling_min_freq"
    if [ -n "$_rt_cpu" ] && [ -w "$_minf" ]; then
        cat "$ECAT_STATE_DIR/scaling_min_freq.prior" > "$_minf" 2>/dev/null || true
        echo "  Restored CPU $_rt_cpu scaling_min_freq from stale snapshot"
    fi
    unset _rt_cpu _minf
fi

# Tear down any leftover partition (whether from helper or legacy service).
if [ -d "$CPUSET_DIR" ]; then
    if [ -s "$CPUSET_DIR/cgroup.procs" ]; then
        while read -r p; do
            [ -n "$p" ] && echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
        done < "$CPUSET_DIR/cgroup.procs"
    fi
    echo member > "$CPUSET_DIR/cpuset.cpus.partition" 2>/dev/null || true
    rmdir "$CPUSET_DIR" 2>/dev/null && echo "  Removed cgroup $CPUSET_DIR" || \
        echo "  Could not rmdir $CPUSET_DIR (still has members?)"
fi

# Clean up helper state dir (IRQ snapshot, irqbalance prior, tuning snapshots).
# If a daemon crashed without calling 'ecat-cgroup down', the snapshot may
# still hold pre-change IRQ affinities. Restore them before deleting the file.
if [ -f "$ECAT_STATE_DIR/irq_snapshot.tsv" ]; then
    while IFS=$'\t' read -r n orig _; do
        [ -n "$n" ] || continue
        echo "$orig" > "/proc/irq/$n/smp_affinity" 2>/dev/null || true
    done < "$ECAT_STATE_DIR/irq_snapshot.tsv"
    echo "  Restored IRQ affinities from stale snapshot"
fi
if [ -f "$ECAT_STATE_DIR/irqbalance.prior" ] && \
   [ "$(cat "$ECAT_STATE_DIR/irqbalance.prior" 2>/dev/null)" = "active" ]; then
    systemctl start irqbalance 2>/dev/null || true
    echo "  Restarted irqbalance (was paused by a prior daemon)"
fi
if [ -d "$ECAT_STATE_DIR" ]; then
    rm -f "$ECAT_STATE_DIR"/*
    rmdir "$ECAT_STATE_DIR" 2>/dev/null || true
    echo "  Removed $ECAT_STATE_DIR"
fi

# Drop file capabilities on any installed daemon binary.
DAEMON_CANDIDATES=()
[ -n "$(command -v ecat_rt_daemon 2>/dev/null || true)" ] && \
    DAEMON_CANDIDATES+=("$(command -v ecat_rt_daemon)")
DAEMON_CANDIDATES+=("/usr/local/bin/ecat_rt_daemon")
for p in /opt/ros/*/lib/tk_ros2_pkg_ethercat_master/ecat_rt_daemon \
         /home/*/*/ros2_ws/install/tk_ros2_pkg_ethercat_master/lib/tk_ros2_pkg_ethercat_master/ecat_rt_daemon; do
    [ -x "$p" ] && DAEMON_CANDIDATES+=("$p")
done
for cand in "${DAEMON_CANDIDATES[@]}"; do
    if [ -x "$cand" ] && getcap "$cand" 2>/dev/null | grep -q cap_; then
        setcap -r "$cand" 2>/dev/null && echo "  setcap removed: $(readlink -f "$cand")"
    fi
done

# Strip the full strict-isolation token set written by ecat_setup.sh
# (isolcpus/irqaffinity/nohz_full/rcu_nocbs/psi) plus the legacy
# nvme.poll_queues from GRUB. Same migration path as ecat_setup.sh — only
# triggers a reboot if anything was found.
if [ -f "$GRUB_FILE" ]; then
    CURRENT=$(grep '^GRUB_CMDLINE_LINUX=' "$GRUB_FILE" | head -1 | sed 's/^GRUB_CMDLINE_LINUX="//' | sed 's/"$//')
    CLEANED=$(echo "$CURRENT" | sed -E 's/\b(isolcpus|irqaffinity|nohz_full|rcu_nocbs|psi|nvme\.poll_queues)=[^ ]*//g' | xargs)

    if [ "$CURRENT" != "$CLEANED" ]; then
        cp "$GRUB_FILE" "${GRUB_FILE}.bak.ecat"
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$CLEANED\"|" "$GRUB_FILE"
        echo "  Removed legacy isolation params from GRUB"
        if command -v update-grub &>/dev/null; then
            update-grub
        elif command -v grub-mkconfig &>/dev/null; then
            grub-mkconfig -o /boot/grub/grub.cfg
        elif command -v grub2-mkconfig &>/dev/null; then
            grub2-mkconfig -o /boot/grub2/grub.cfg
        else
            echo "  WARNING: Could not find grub-mkconfig. Update GRUB manually."
        fi
        GRUB_REBOOT_NEEDED=true
    else
        echo "  No legacy isolation params in GRUB"
    fi
else
    echo "  SKIP: $GRUB_FILE not found"
fi

# =========================================================================
# 4. Udev rule
# =========================================================================
echo "--- [4/6] Udev rule ---"
for f in "$UDEV_RULE" "$OLD_UDEV_RULE"; do
    if [ -f "$f" ]; then
        rm "$f"
        echo "  Removed $f"
    fi
done
udevadm control --reload-rules 2>/dev/null || true

# =========================================================================
# 5. Scheduling limits
# =========================================================================
echo "--- [5/6] Scheduling limits ---"
for f in "$LIMITS_FILE" "$OLD_LIMITS_FILE"; do
    if [ -f "$f" ]; then
        rm "$f"
        echo "  Removed $f"
    fi
done

# =========================================================================
# 6. Sudoers drop-in
# =========================================================================
echo "--- [6/6] Sudoers drop-in ---"
if [ -f "$SUDOERS_FILE" ]; then
    rm "$SUDOERS_FILE"
    echo "  Removed $SUDOERS_FILE"
else
    echo "  Not present"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "============================================"
echo "  Teardown Complete"
echo "============================================"
echo ""
echo "  Removed: ethercat.service, ethercat-cpuset.service, cgroup partition,"
echo "           IgH sysconfig, legacy GRUB isolation, udev rule,"
echo "           NM keyfile + avahi deny-interfaces (restored from backup),"
echo "           scheduling limits, sudoers drop-in, ldconfig, file capabilities"
echo "  Kept:    IgH master (kernel modules, library, headers),"
echo "           'ecat' group and user membership"
echo ""
if [ "$GRUB_REBOOT_NEEDED" = true ]; then
    echo ">>> REBOOT REQUIRED for GRUB changes to take effect. <<<"
    echo ""
fi
if [ "${NIC_REBOOT_NEEDED:-false}" = true ]; then
    echo ">>> A native EtherCAT NIC could not be rebound live — REBOOT to"
    echo "    restore its normal network interface. <<<"
    echo ""
fi
echo "To re-setup, run:  sudo ecat_setup.sh"
