#!/bin/bash
#
# ecat_daemon_start.sh - Start the EtherCAT RT daemon
#
# Prerequisites: run 'sudo ecat_setup.sh' once and reboot.
#
# Usage:
#   ecat_daemon_start.sh [config.yaml]
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# =========================================================================
# Config resolution
# =========================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_PREFIX="$(dirname "$(dirname "$SCRIPT_DIR")")"
PKG_SHARE="$PKG_PREFIX/share/tk_ros2_pkg_ethercat_master"

ARG="${1:-}"
if [ -n "$ARG" ]; then
    CONFIG_PATH="$ARG"
elif [ -f "$PKG_SHARE/configs/ecat_bus.yaml" ]; then
    CONFIG_PATH="$PKG_SHARE/configs/ecat_bus.yaml"
elif [ -f "$SCRIPT_DIR/../../configs/ecat_bus.yaml" ]; then
    CONFIG_PATH="$SCRIPT_DIR/../../configs/ecat_bus.yaml"
else
    echo -e "${RED}ERROR:${NC} No ecat_bus.yaml found. Pass path as first argument."
    exit 1
fi

RT_CPU=$(grep 'rt_cpu:' "$CONFIG_PATH" | awk '{print $2}')
RT_CPU=${RT_CPU:-2}

echo "Config: $CONFIG_PATH"
echo "RT CPU: $RT_CPU"

# =========================================================================
# On-demand: load EtherCAT modules + create isolated cpuset partition
# =========================================================================
# The setup script installs everything in on-demand mode:
#   * ethercat.service is NOT enabled at boot — port stays normal Ethernet
#   * the cpuset partition does NOT exist at boot — CPU $RT_CPU stays usable
# Both are brought up here, and torn down in cleanup() on exit. Track
# whether *we* were the ones to set up each, so we only tear down what we
# created (avoids interfering with a manual 'ethercat slaves' session etc.).
CGROUP_HELPER="/usr/local/sbin/ecat-cgroup"
WE_STARTED_SERVICE=false
WE_STARTED_CPUSET=false

# Verify /dev/EtherCAT0 is actually open()-able for read+write, not just
# present as an inode. The IgH driver creates the chrdev node during
# module init, but the underlying ec_master may not be ready until the
# NIC is fully claimed (~100-500 ms after the node appears). A plain
# [ -e /dev/EtherCAT0 ] check is satisfied during that race window —
# the daemon's ecrt_request_master() then opens the node, hits ENOENT,
# and reports "Failed to open /dev/EtherCAT0: No such file or directory".
# This polls the same syscall the daemon would issue (open() RW) so
# success here means the daemon will succeed too.
# Default budget: 100 ticks × 100 ms = 10 s.
wait_for_ecat_master_ready() {
    local budget="${1:-100}"
    for _ in $(seq 1 "$budget"); do
        if ( : 3<> /dev/EtherCAT0 ) 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Cycle ethercat.service to drain kernel-module state. Used:
#   - Up-front by the default FORCE_RELOAD path (per-launch preventative)
#   - Recovery-time, when attempt-1 of the daemon hits master-EBUSY
#     (IgH module still holding master 0 from a prior abnormal exit;
#     pkill won't drain that, only rmmod+modprobe via service cycle will).
# Stop is idempotent (no-op if already stopped). The udev wait + 1.5 s
# settle + start + readiness probe + 3 s slave-enumeration sleep are the
# minimum sequence both call sites need; without it the new modprobe can
# land on a partially-released NIC and ecrt_master_get_slave() returns
# "Invalid argument" for every slave, or the daemon catches slave CoE
# mailboxes mid-init and re-introduces the SII fallback.
cycle_ethercat_service() {
    sudo -n systemctl stop ethercat.service 2>/dev/null || \
        sudo systemctl stop ethercat.service 2>/dev/null || true
    for _ in $(seq 1 20); do
        [ ! -e /dev/EtherCAT0 ] && break
        sleep 0.1
    done
    sleep 1.5
    sudo -n systemctl start ethercat.service 2>/dev/null || \
        sudo systemctl start ethercat.service
    if ! wait_for_ecat_master_ready 100; then
        echo -e "  ${YELLOW}WARN:${NC} /dev/EtherCAT0 not openable after 10s — daemon may fail"
    fi
    sleep 3
    WE_STARTED_SERVICE=true
}

# (0) Verify load-bearing /etc/* artifacts are still installed. Catches
# the silent-staleness class (someone deleted /etc/sudoers.d/ecat etc.)
# before it shows up as cryptic downstream errors. Helper prints the
# specific drift items + their consequences; we add a banner so a panel
# or systemd unit watching exit codes can tell this is a setup issue,
# not a daemon crash.
if [ ! -x "$CGROUP_HELPER" ]; then
    echo ""
    echo "============================================"
    echo "  First-time setup needed (one sudo, ever)"
    echo "============================================"
    echo ""
    echo "The EtherCAT helper at $CGROUP_HELPER isn't installed yet."
    echo "Run this once:"
    echo ""
    echo "    sudo ecat_setup.sh"
    echo ""
    echo "After that, the daemon launches with no sudo: it creates the isolated"
    echo "partition fresh ('ecat-cgroup up', strict) and re-applies file caps."
    echo "You won't need to re-run setup again — even after 'tk build'."
    echo ""
    exit 1
fi

# Per-session cache for verify-install. The helper itself is fast (<10ms
# of greps), but the sudo round-trip adds ~30-50ms to every launch. Cache
# the OK result in $XDG_RUNTIME_DIR/ecat (tmpfs, cleared on logout AND
# reboot) so the second-and-subsequent launches in a session skip it.
# The cache is intentionally pessimistic: on first launch, on cache miss,
# on any drift detection, we still pay the full check.
ECAT_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/ecat"
VERIFY_OK_CACHE="$ECAT_RUNTIME_DIR/verify-install.ok"

if [ ! -f "$VERIFY_OK_CACHE" ]; then
    set +e
    sudo -n "$CGROUP_HELPER" verify-install
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        # Helper already printed the drift items + remediation. Add a single
        # banner so the failure mode is unambiguous when seen out of context,
        # then dump ecat_diag.sh --report so the operator can copy-paste the
        # full host snapshot to the maintainer without gathering uname,
        # lsmod, cmdline, journalctl, etc. by hand.
        echo -e "${RED}>>> ECAT PRE-FLIGHT FAILED — NOT A DAEMON CRASH <<<${NC}"
        echo "    Setup drift detected (see above). Run the fix command, then retry."
        echo ""
        if [ -x "$SCRIPT_DIR/ecat_diag.sh" ]; then
            echo "----- Full host report follows (copy-paste this whole block to the maintainer) -----"
            "$SCRIPT_DIR/ecat_diag.sh" --report 2>/dev/null || true
        fi
        exit 1
    fi
    # Mark the OK result so we can skip the helper next time. Failures here
    # (no XDG_RUNTIME_DIR, ENOSPC, etc.) are non-fatal — we just lose the
    # speed-up, never break correctness.
    mkdir -p "$ECAT_RUNTIME_DIR" 2>/dev/null && touch "$VERIFY_OK_CACHE" 2>/dev/null || true
fi

# =========================================================================
# Cleanup on exit — installed BEFORE any system-mutating call below.
# =========================================================================
# 'ecat-cgroup up' (next block) creates the partition + applies RT-PM knobs.
# The ethercat.service cycle (after that) can
# legitimately fail (kernel-module drift, NIC missing, etc.) and abort
# the script under `set -e`. If the trap were installed only just before
# the daemon spawn — as it used to be — that abort path would leave the
# host with C-states off, freq pinned, and partition up but no daemon.
# Installing the trap here guarantees `ecat-cgroup down` runs on every
# exit path past this point, regardless of which sudo/systemctl/modprobe
# call inside the bring-up sequence is the one that fails.
DAEMON_PID=""
DAEMON_LOG=""
CLEANED_UP=false
cleanup() {
    # Guard: trap fires on both signals and EXIT, so we may be called twice.
    [ "$CLEANED_UP" = true ] && return
    CLEANED_UP=true
    echo ""
    echo "=== Shutting down daemon ==="
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    wait 2>/dev/null
    echo "=== Daemon stopped ==="
    # Tear down only what we ourselves brought up. If the service or
    # cpuset was already in place (e.g. a manual 'ethercat slaves'
    # session left modules loaded), leave it alone.
    if [ "$WE_STARTED_SERVICE" = true ]; then
        echo "=== Releasing port (stopping ethercat.service) ==="
        if ! sudo -n systemctl stop ethercat.service 2>/dev/null; then
            sudo systemctl stop ethercat.service 2>/dev/null || true
        fi
        echo "=== Port released to NetworkManager ==="
    fi
    if [ "$WE_STARTED_CPUSET" = true ]; then
        echo "=== Releasing CPU $RT_CPU back to general scheduler ==="
        if ! sudo -n "$CGROUP_HELPER" down 2>/dev/null; then
            sudo "$CGROUP_HELPER" down 2>/dev/null || true
        fi
    fi
    [ -n "$DAEMON_LOG" ] && rm -f "$DAEMON_LOG"
}
trap cleanup EXIT SIGINT SIGTERM

# (1) Create the isolated cpuset partition. 'ecat-cgroup up' is STRICT: it
# creates the partition fresh and errors out if one already exists (a stale
# partition from a crashed daemon, or a manual experiment) instead of
# reconciling. The operator then runs 'ecat-cgroup down' and retries. There
# is no self-heal — unexpected state is surfaced, not papered over.
#
# WE_STARTED_CPUSET tracks whether the partition was absent at our entry,
# so cleanup() only tears it down if we were the ones who created it.
[ ! -d /sys/fs/cgroup/ethercat_rt ] && WE_STARTED_CPUSET=true

# Group check first so we don't waste a sudo attempt and don't suppress
# the helper's stderr (which carries managed-IRQ remediation on exit 3).
if ! id -nG | grep -qw ecat; then
    echo -e "${RED}ERROR:${NC} Your current session does not have the 'ecat' group."
    echo "  Your user is in the group, but Linux only picks up new groups on login."
    echo ""
    echo "  Fix (pick one):"
    echo "    1. Log out and back in (recommended)"
    echo "    2. Run 'newgrp ecat' in this terminal, then re-run this script"
    exit 1
fi

# Run with stderr visible. Propagate exit 3 (managed-IRQ hard-fail) directly;
# fall back to interactive sudo if the NOPASSWD grant got revoked somehow.
set +e
sudo -n "$CGROUP_HELPER" up
rc=$?
set -e
if [ "$rc" -eq 3 ]; then
    exit 3
fi
if [ "$rc" -ne 0 ]; then
    echo "Password-less helper failed (rc=$rc); trying interactive sudo..."
    sudo "$CGROUP_HELPER" up
fi

# (1b) Contract: a user of this package never has to touch
# `systemctl ... ethercat.service`. The script owns the service. Today
# we honour that by cycling stop→start before every daemon launch — that
# also rmmod+modprobe's the kernel module, which cycles the NIC link and
# resets every slave's CoE mailbox state, sidestepping the stale-mailbox
# pathology that used to push users to manual `systemctl restart`.
# The mechanism may change (smarter retries, fault-driven cycle, etc.)
# but the contract must not. Power users can opt out of *this specific*
# cycle via ECAT_FORCE_RELOAD=0 (e.g. tight loops of `ethercat slaves`
# where the ~2s tax dominates) — the rest of the script still handles
# service state on their behalf.
if [ "${ECAT_FORCE_RELOAD:-1}" != "0" ]; then
    echo "=== Cycling ethercat.service so you don't have to (set ECAT_FORCE_RELOAD=0 to skip) ==="
    cycle_ethercat_service
fi

# (2) Load EtherCAT kernel modules so /dev/EtherCAT0 appears.
if [ ! -e /dev/EtherCAT0 ]; then
    echo "=== Loading EtherCAT modules (on-demand) ==="
    if ! sudo -n systemctl start ethercat.service 2>/dev/null; then
        if ! id -nG | grep -qw ecat; then
            echo -e "${RED}ERROR:${NC} Your current session does not have the 'ecat' group."
            echo "  Log out and back in, or run 'newgrp ecat' first."
            exit 1
        fi
        echo "Password-less start failed; trying interactive sudo..."
        sudo systemctl start ethercat.service
    fi
    WE_STARTED_SERVICE=true
    # Wait for the master to be actually openable (modprobe is fast but the
    # IgH driver may still be claiming the NIC after udev creates the node;
    # see wait_for_ecat_master_ready preamble above for the failure shape).
    if ! wait_for_ecat_master_ready 100; then
        echo -e "  ${YELLOW}WARN:${NC} /dev/EtherCAT0 not openable after 10s — daemon may fail"
    fi
fi

# (2b) Pin the EtherCAT NIC's MSI-X queue IRQs onto $RT_CPU.
# This must run AFTER ethercat.service has cycled the link up, because
# many NIC drivers (igb included) allocate the MSI-X vectors only when
# the netdev is brought up — at ecat-cgroup up time above, the
# IRQs don't exist yet, so irq_apply's whole-system pass skipped them.
# Under ec_generic the RX path is plain Linux NAPI softirq, which runs on
# the CPU that services the NIC IRQ; off-CPU NIC IRQs on a saturated
# housekeeping core cause multi-ms RX-softirq delays that stall the
# cycle thread waiting on $RT_CPU. Native ec_igb would obviate this
# (data path lives inside the IgH master kernel thread) — see follow-up.
sudo -n "$CGROUP_HELPER" pin-nic 2>&1 || \
    echo -e "  ${YELLOW}WARN:${NC} ecat-cgroup pin-nic failed (non-fatal — daemon may still run with off-CPU NIC IRQs)"

# =========================================================================
# Pre-flight checks
# =========================================================================
echo "=== Pre-flight checks ==="
READY=true

# 'ecat-cgroup up' already guaranteed the partition is up + isolated on the
# helper's compiled-in ECAT_CPU. The only failure shape it can't fix is a genuine
# mismatch between the bus YAML's rt_cpu and the helper's CPU — that needs
# the operator to re-run setup with --ecat-cpu N.
CPUSET_CPUS="/sys/fs/cgroup/ethercat_rt/cpuset.cpus"
HELPER_CPU=$(cat "$CPUSET_CPUS" 2>/dev/null)
if [ "$HELPER_CPU" != "$RT_CPU" ]; then
    echo -e "  ${RED}[FAIL]${NC} bus YAML says rt_cpu=$RT_CPU, helper compiled with CPU=$HELPER_CPU"
    echo "    Fix: sudo ecat_setup.sh --ecat-cpu $RT_CPU   (rebuilds the helper)"
    READY=false
else
    echo -e "  ${GREEN}[OK]${NC} cgroup partition isolated on CPU $RT_CPU"
fi

# Strict CPU isolation (mandatory) writes isolcpus=managed_irq. Anything
# carrying plain isolcpus/nohz_full/rcu_nocbs WITHOUT the managed_irq flavour
# is a legacy leftover from an older setup, not from this one.
if grep -qE '\b(isolcpus|nohz_full|rcu_nocbs)=' /proc/cmdline 2>/dev/null; then
    if grep -q 'isolcpus=managed_irq' /proc/cmdline 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} strict GRUB isolation active (CPU $RT_CPU carved out at boot)"
    else
        echo -e "  ${YELLOW}[WARN]${NC} legacy isolcpus/nohz_full/rcu_nocbs in /proc/cmdline — not from this setup"
        echo "    Run: sudo ecat_setup.sh (strips them and writes the strict managed_irq token set)"
    fi
fi

# IRQ status check: report how many IRQs the cgroup helper pinned off the RT
# CPU, and flag any that are STILL on it (typically managed IRQs the operator
# hasn't yet remediated). Non-blocking — the hard-fail is inside ecat-cgroup up,
# which set -e'd out before we got here if there were unresolved managed IRQs.
if [ -f /var/lib/ecat/irq_snapshot.tsv ]; then
    moved_n=$(wc -l < /var/lib/ecat/irq_snapshot.tsv 2>/dev/null)
    echo -e "  ${GREEN}[OK]${NC} $moved_n IRQ(s) pinned off CPU $RT_CPU by ecat-cgroup up"
fi
expected_iface_list=()
for ifdir in /sys/class/net/*; do
    [ -d "$ifdir/device" ] || continue
    expected_iface_list+=("$(basename "$ifdir")")
done

still_unexpected=0
unexpected_list=()
expected_pins=0
expected_list=()
for n in $(ls /proc/irq/ 2>/dev/null | grep -E '^[0-9]+$'); do
    eff=$(cat /proc/irq/$n/effective_affinity_list 2>/dev/null)
    if [ "$eff" = "$RT_CPU" ]; then
        name=$(awk -v m="$n" '$1==m":"{ for(i=NF;i>=2;i--) if($i !~ /^[0-9]+$/){print $i; exit} }' /proc/interrupts 2>/dev/null)
        is_nic_pin=false
        for iface in "${expected_iface_list[@]}"; do
            case "$name" in
                "$iface"|"$iface"-TxRx-*|"$iface"-Tx-*|"$iface"-Rx-*) is_nic_pin=true; break ;;
            esac
        done
        if [ "$is_nic_pin" = true ]; then
            expected_pins=$((expected_pins+1))
            expected_list+=("$n:$name")
        else
            still_unexpected=$((still_unexpected+1))
            unexpected_list+=("$n:$name")
        fi
    fi
done
if [ "$expected_pins" -gt 0 ]; then
    echo -e "  ${GREEN}[OK]${NC} $expected_pins NIC IRQ(s) pinned to CPU $RT_CPU by ecat-cgroup pin-nic:"
    for s in "${expected_list[@]}"; do echo "    - $s"; done
fi
if [ "$still_unexpected" -gt 0 ]; then
    echo -e "  ${YELLOW}[WARN]${NC} $still_unexpected IRQ(s) still on CPU $RT_CPU (managed or hotplug):"
    for s in "${unexpected_list[@]}"; do echo "    - $s"; done
    echo "    Managed/hotplug IRQs the kernel won't relocate at runtime — remediate at the host level."
fi

# EtherCAT device
if [ -r /dev/EtherCAT0 ]; then
    echo -e "  ${GREEN}[OK]${NC} /dev/EtherCAT0 readable"
elif [ -e /dev/EtherCAT0 ]; then
    echo -e "  ${RED}[FAIL]${NC} /dev/EtherCAT0 exists but not readable (permission issue)"
    echo ""
    echo "  Diagnostics:"
    echo "    Device: $(ls -l /dev/EtherCAT0 2>/dev/null)"
    echo "    Your groups: $(id -nG)"
    echo ""
    echo "  Fix: ensure your user is in the 'ecat' group, then log out and back in:"
    echo "    sudo usermod -aG ecat \$USER && newgrp ecat"
    READY=false
else
    echo -e "  ${RED}[FAIL]${NC} /dev/EtherCAT0 not found"
    echo ""
    echo "  Diagnosing..."

    # Check if ethercat.service exists
    if ! systemctl cat ethercat.service &>/dev/null; then
        echo -e "    ${RED}✗${NC} ethercat.service not installed. Run: sudo ecat_setup.sh"
    else
        # Check service status
        SVC_STATE=$(systemctl is-active ethercat.service 2>/dev/null || true)
        SVC_ENABLED=$(systemctl is-enabled ethercat.service 2>/dev/null || true)
        echo "    Service state: $SVC_STATE (enabled: $SVC_ENABLED)"

        if [ "$SVC_STATE" = "failed" ]; then
            echo ""
            echo "    ethercat.service failed on boot. Journal:"
            echo "    ─────────────────────────────────────────"
            journalctl -u ethercat.service -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
            echo "    ─────────────────────────────────────────"
            echo ""

            # Check specific failure causes
            # 1. Kernel module mismatch
            if modinfo ec_master &>/dev/null; then
                MOD_VER=$(modinfo -F vermagic ec_master 2>/dev/null | awk '{print $1}')
                KERN_VER=$(uname -r)
                if [ "$MOD_VER" != "$KERN_VER" ]; then
                    echo -e "    ${RED}✗${NC} Kernel module mismatch: ec_master built for $MOD_VER, running $KERN_VER"
                    echo "      Fix: sudo ecat_setup.sh   (will rebuild module for current kernel)"
                fi
            else
                echo -e "    ${RED}✗${NC} ec_master kernel module not found"
                echo "      Fix: sudo ecat_setup.sh   (will install IgH EtherCAT Master)"
            fi

            # 2. Network interface missing
            SVC_IFACE=$(systemctl cat ethercat.service 2>/dev/null | grep -oP '(?<=ip link set dev )\S+' || true)
            if [ -n "$SVC_IFACE" ] && [ ! -d "/sys/class/net/$SVC_IFACE" ]; then
                echo -e "    ${RED}✗${NC} Interface '$SVC_IFACE' does not exist"
                echo "      Available interfaces: $(ls /sys/class/net/ | grep -v lo | tr '\n' ' ')"
                echo "      Fix: sudo ecat_setup.sh --interface <correct_interface>"
            fi

        elif [ "$SVC_STATE" = "inactive" ]; then
            echo ""
            echo "    Service exists but never started. Attempting to start..."
            if sudo systemctl start ethercat.service 2>&1; then
                sleep 1
                if [ -r /dev/EtherCAT0 ]; then
                    echo -e "    ${GREEN}[OK]${NC} /dev/EtherCAT0 appeared after starting service"
                    # Re-check so we don't abort
                    READY=true
                else
                    echo -e "    ${RED}✗${NC} Service started but /dev/EtherCAT0 still missing"
                    journalctl -u ethercat.service -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
                fi
            else
                echo -e "    ${RED}✗${NC} Failed to start ethercat.service"
                journalctl -u ethercat.service -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
            fi
        fi
    fi
    [ "$READY" != "true" ] && READY=false
fi

# RT scheduling + memlock capability.
# Prefer file capabilities on the daemon binary (set by ecat_setup.sh):
# they make the PAM rlimits irrelevant and survive across shells. Fall
# back to limits.d (PAM) only when the binary lacks caps — typical right
# after a fresh `tk build` that wiped them.
DAEMON_BIN=""
# Prefer this workspace's build tree over whatever `ros2 pkg prefix`
# resolves — a developer machine commonly has older install trees higher
# in AMENT_PREFIX_PATH, and we want to launch the binary that corresponds
# to the sources sitting next to this script. Use string-only `dirname`
# (not `..` traversal) because tk_ros2_pkg_ethercat_master is typically
# a symlink, and kernel-level `..` resolution walks through the link
# target instead of the logical workspace path.
WS_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"
LOCAL_WS_BIN="$WS_ROOT/build/tk_ros2_pkg_ethercat_master/ecat_rt_daemon"
if [ -x "$LOCAL_WS_BIN" ]; then
    DAEMON_BIN="$LOCAL_WS_BIN"
fi

# Same rationale for plugin .so resolution: the daemon uses ament_index
# to look up device plugins (e.g. libdevice_servo.so) by package name at
# runtime, and picks whichever install tree shows up first in
# AMENT_PREFIX_PATH. On dev machines with older workspaces sourced, that
# often resolves to a stale plugin whose ABI may no longer match the
# daemon — silently breaking device bring-up (servo stuck in PREOP with
# no AL error). Prepend every install subdir of THIS workspace so the
# plugin the user just built wins over archived siblings.
if [ -d "$WS_ROOT/install" ]; then
    for pkg_prefix in "$WS_ROOT/install"/*/; do
        if [ -d "${pkg_prefix}share/ament_index/resource_index/packages" ]; then
            AMENT_PREFIX_PATH="${pkg_prefix%/}:${AMENT_PREFIX_PATH:-}"
        fi
    done
    export AMENT_PREFIX_PATH
fi
if [ -z "$DAEMON_BIN" ]; then
    PKG_PREFIX_RUN=$(ros2 pkg prefix tk_ros2_pkg_ethercat_master 2>/dev/null || true)
    if [ -n "$PKG_PREFIX_RUN" ] && [ -e "$PKG_PREFIX_RUN/lib/tk_ros2_pkg_ethercat_master/ecat_rt_daemon" ]; then
        # Follow symlinks: ros2 install/lib often symlinks to the build dir,
        # and getcap does not dereference by default while the kernel does.
        DAEMON_BIN="$(readlink -f "$PKG_PREFIX_RUN/lib/tk_ros2_pkg_ethercat_master/ecat_rt_daemon")"
    fi
fi

# File caps on the daemon binary. Wiped by every 'tk build' (binary
# relink). When missing, auto-restore via the helper's setcap-daemon
# subcommand (root-trusted via NOPASSWD) — the user never sees a sudo
# prompt and never has to re-run setup. Helper validates the path
# (basename, workspace tree, ownership) before applying caps.
if [ -z "$DAEMON_BIN" ]; then
    echo -e "  ${RED}[FAIL]${NC} ecat_rt_daemon binary not found"
    echo "    Did you run 'tk build' in the workspace?"
    READY=false
else
    DAEMON_CAPS=$(getcap "$DAEMON_BIN" 2>/dev/null | awk '{print $NF}')
    if ! echo "$DAEMON_CAPS" | grep -q cap_sys_nice || \
       ! echo "$DAEMON_CAPS" | grep -q cap_ipc_lock; then
        echo "  applying file caps to $DAEMON_BIN (likely just rebuilt)..."
        set +e
        sudo -n "$CGROUP_HELPER" setcap-daemon "$DAEMON_BIN"
        rc=$?
        set -e
        if [ "$rc" -ne 0 ]; then
            echo "Password-less helper failed (rc=$rc); trying interactive sudo..."
            sudo "$CGROUP_HELPER" setcap-daemon "$DAEMON_BIN" || {
                echo -e "  ${RED}[FAIL]${NC} could not apply file caps"
                echo "    Fix: sudo ecat_setup.sh"
                READY=false
            }
        fi
        DAEMON_CAPS=$(getcap "$DAEMON_BIN" 2>/dev/null | awk '{print $NF}')
    fi
    if echo "$DAEMON_CAPS" | grep -q cap_sys_nice && \
       echo "$DAEMON_CAPS" | grep -q cap_ipc_lock; then
        echo -e "  ${GREEN}[OK]${NC} file caps on $DAEMON_BIN ($DAEMON_CAPS)"
    else
        echo -e "  ${RED}[FAIL]${NC} file caps still missing on $DAEMON_BIN after setcap-daemon"
        READY=false
    fi
fi

echo ""

if [ "$READY" = false ]; then
    echo "System not configured. Run:  sudo ecat_setup.sh"
    echo "Then reboot."
    echo ""
    if [ -x "$SCRIPT_DIR/ecat_diag.sh" ]; then
        echo "----- Full host report follows (copy-paste this whole block to the maintainer) -----"
        "$SCRIPT_DIR/ecat_diag.sh" --report 2>/dev/null || true
    fi
    exit 1
fi

# =========================================================================
# Kill previous daemon if running
# =========================================================================
pkill -f "ecat_rt_daemon" 2>/dev/null || true
sleep 0.5

# =========================================================================
# Start daemon  (with one auto-retry on bringup failure)
# =========================================================================
# The daemon exits with code 1 when discovery fails (passthrough plugin throws
# on 0-PDO total-discovery, or the OP watchdog fires after 5 s in PREOP). A
# second attempt almost always succeeds because the slave's CoE state has
# settled by then. We retry once and only on exit code 1; signal-driven
# exits (130 SIGINT, 143 SIGTERM) and clean exits propagate as-is.
#
# Two distinct failure classes can land at attempt 1 → exit 1:
#
#   (a) Slave-state wedge — stuck-PREOP, mailbox mid-init, EX600 sub-bus
#       wedged. On a cold/freshly-link-up bus the slaves' CoE/FSoE mailbox
#       state has not settled, and a bare respawn against the SAME master
#       lands the daemon back in PREOP (or crawls to SAFEOP and wedges there
#       alive). A `sleep 1` retry — what this used to do — does NOT fix it;
#       observed 2026-06-17, every cold start burned ~2.5 min churning the
#       inner sleep-retry + the outer 120 s wrapper deadline before the
#       systemd-restart boundary finally cycled the master and unwedged the
#       slaves. The effective recovery is a fresh master release+request
#       (rmmod+modprobe via ethercat.service), so attempt-2 now does exactly
#       that for this class too — same mechanism as (b). For the truly
#       hardware-stuck slave it's harmless (software can't fix that anyway);
#       for the common cold-bus case it makes attempt 2 succeed in ~15 s.
#
#   (b) Master-state wedge — IgH module still holding master 0 from a
#       prior abnormal exit. Daemon prints "Failed to reserve master:
#       Device or resource busy" from ecrt_request_master(). pkill+sleep
#       cannot drain this; only a service cycle (rmmod+modprobe via
#       ethercat.service) drops the kernel-side reservation. Triggered
#       when the default ECAT_FORCE_RELOAD=1 upfront cycle was skipped
#       (operator set =0 for panel tight loops) or, rarely, didn't fully
#       drain.
#
# Both classes now take the same recovery (cycle the service). We still
# tee daemon stdout/stderr to $DAEMON_LOG and grep the EBUSY signature
# between attempts purely to log WHICH class fired — the action is the
# same, but the distinction is worth keeping visible in the journal.
#
# What we still don't escalate to: a slave that stays stuck-PREOP even
# after the master cycle (genuine slave-side hardware wedge). Those need a
# power cycle of the affected slave — software cannot fix them, only add
# operator-visible latency. When per-slave power-cycle hooks land, this is
# where they'd plug in.
#
# Disable -e for the retry block: the daemon-related commands (sudo helper,
# kill -0, sleep, wait) all return non-zero in normal control flow, and
# blanket -e would abort the script before we can inspect the exit codes.
set +e
DAEMON_RC=0
DAEMON_LOG=$(mktemp /tmp/ecat_daemon_log.XXXXXX)
for ATTEMPT in 1 2; do
    if [ "$ATTEMPT" -gt 1 ]; then
        echo ""
        # Branch on attempt-1's failure signature (see comment block above).
        if grep -q "Device or resource busy" "$DAEMON_LOG" 2>/dev/null; then
            echo -e "${YELLOW}=== Attempt 1 hit master-EBUSY; cycling ethercat.service to drain kernel state ===${NC}"
            cycle_ethercat_service
        else
            # Slave-state wedge (stuck-PREOP — the daemon's "failed to reach OP"
            # FATAL). Observed on every cold start (2026-06-17): on a freshly
            # link-up bus the slaves' CoE/FSoE mailbox state has not settled,
            # and a bare respawn against the SAME master just lands the daemon
            # back in PREOP — or crawls to SAFEOP and wedges there alive,
            # defeating this fast retry and forcing the outer 120 s wrapper
            # deadline + a systemd restart before the first effective recovery
            # (a fresh master release+request) ever runs. The thing that
            # actually unwedges the slaves is exactly that master cycle
            # (rmmod+modprobe via ethercat.service), so do it HERE on attempt 2
            # instead of waiting for the systemd boundary. Same mechanism the
            # EBUSY branch uses; it also re-settles the bus on the way up.
            echo -e "${YELLOW}=== Bringup failed on attempt 1 (slave stuck-PREOP); cycling ethercat.service for a fresh master before retry ===${NC}"
            cycle_ethercat_service
        fi
    fi
    echo "=== Starting ECAT Daemon (attempt $ATTEMPT/2) ==="

    # Final openability gate before each spawn. The FORCE_RELOAD block at
    # the top of the script and the attempt-3+ service cycle above already
    # call wait_for_ecat_master_ready, but observed failure: on attempts 1
    # and 2 the daemon sometimes reports "Failed to open /dev/EtherCAT0:
    # No such file or directory" even though pre-flight saw the inode. The
    # IgH master can transition from openable back to ENOENT during NIC
    # claim/release if anything (a setcap-driven binary rebuild) churns
    # the kernel state between pre-flight and spawn. Polling
    # open() inside the loop costs ~one syscall when the device is already
    # ready and rescues the otherwise-wasted attempt when it isn't.
    if ! wait_for_ecat_master_ready 50; then
        echo -e "  ${YELLOW}WARN:${NC} /dev/EtherCAT0 not openable after 5s — spawning anyway"
    fi

    # Spawn the daemon binary directly (not via 'ros2 run') so $! is the PID
    # of ecat_rt_daemon itself, not of a wrapper. The cgroup helper
    # validates that the PID's comm is 'ecat_rt_daemon' before migrating
    # it. $DAEMON_BIN was resolved during pre-flight.
    #
    # Tee stdout+stderr to $DAEMON_LOG (overwritten per attempt) so the
    # attempt-2 pre-step can grep for the EBUSY signature without disturbing
    # the operator's terminal view. Process substitution is not tracked by
    # $!, so $! remains the daemon's PID — required for the cgroup migration
    # below and for `wait $DAEMON_PID` at the bottom of the loop.
    "$DAEMON_BIN" "$CONFIG_PATH" > >(tee "$DAEMON_LOG") 2>&1 &
    DAEMON_PID=$!

    # Migrate the daemon into the isolated partition. cgroups v2 requires
    # a privileged actor for cross-subtree migration. Race note: the
    # daemon's pthread_setaffinity_np(CPU $RT_CPU) may run before the
    # migration lands and EINVAL silently — harmless, the cgroup
    # constraint pins it to CPU $RT_CPU anyway.
    if sudo -n "$CGROUP_HELPER" add "$DAEMON_PID" 2>/dev/null; then
        echo -e "${GREEN}[OK]${NC} Daemon (pid $DAEMON_PID) migrated into isolated cpuset (CPU $RT_CPU)"
    else
        echo -e "${YELLOW}WARNING:${NC} '$CGROUP_HELPER add $DAEMON_PID' failed"
        echo "         Continuing — daemon will run wherever the kernel schedules it."
    fi

    # No knob-drift watchdog: the global RT-PM knobs it used to re-assert
    # (no_turbo, min_perf_pct, netdev_budget, the cpu_dma_latency holder) have
    # been removed. The remaining per-CPU knobs are set once by 'ecat-cgroup up'.
    # If something external fights them, fix that root cause — don't reconcile
    # in a loop.

    # Wait for SHM to appear
    echo "Waiting for SHM /ecat_shm..."
    for _ in $(seq 1 30); do
        if [ -f /dev/shm/ecat_shm ]; then
            echo "SHM ready."
            break
        fi
        if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
            echo -e "${RED}ERROR:${NC} ecat_rt_daemon exited before creating SHM."
            break
        fi
        sleep 1
    done

    # Keep running until daemon exits, then capture exit status.
    # Tunnel through set -e: 'wait' returning non-zero (exit code 1 from
    # the bringup-watchdog FATAL) would otherwise abort the script before
    # we can react. The if-form lets us read $? without tripping -e.
    if wait "$DAEMON_PID"; then
        DAEMON_RC=0
    else
        DAEMON_RC=$?
    fi
    # Null the PID so cleanup() and a potential attempt 2 below don't operate
    # on a stale PID.
    DAEMON_PID=""

    # Exit code 1 = bringup-watchdog FATAL → eligible for retry.
    # Anything else (0 clean, 130 SIGINT, 143 SIGTERM, …) propagates immediately.
    if [ "$DAEMON_RC" -ne 1 ]; then
        break
    fi
done

exit "$DAEMON_RC"
