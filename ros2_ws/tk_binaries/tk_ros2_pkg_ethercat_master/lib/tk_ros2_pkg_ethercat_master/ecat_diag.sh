#!/bin/bash
#
# ecat_diag.sh — two-phase EtherCAT RT host diagnostic
#
# Phase A (daemon DOWN): validates setup + records idle baseline
# Phase B (daemon UP):   validates RT state + computes deltas
#
# Between phases the script pauses and polls for ecat_rt_daemon — you
# start the daemon in another terminal (ecat_daemon_start.sh), and as
# soon as this sees the PID, it continues to Phase B.
#
# The goal is a clear green/yellow/red per check, so you can tell at
# a glance whether a host is healthy and, if not, exactly which piece
# of the RT story is missing.
#
# Usage:
#   ecat_diag.sh                            # default config, auto-detect RT_CPU
#   ecat_diag.sh --config /path/to/cfg.yaml
#   ecat_diag.sh --rt-cpu 2 --window 10
#   ecat_diag.sh --phase a                  # only Phase A
#   ecat_diag.sh --phase b                  # only Phase B (daemon already running)
#   ecat_diag.sh --report                   # one-shot snapshot for maintainer copy-paste
#                                           # (plain text, no two-phase wait, works daemon-up or daemon-down)
#
# Exit codes:
#   0 = all PASS
#   1 = at least one FAIL
#   2 = WARNs but no FAILs

set -uo pipefail

# =========================================================================
# Colors
# =========================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1;34m'; D='\033[1m'; N='\033[0m'
else
    R=''; G=''; Y=''; B=''; D=''; N=''
fi

# =========================================================================
# Counters + helpers
# =========================================================================
PASS=0; WARN=0; FAIL=0
FIX_LIST=()

pass()    { PASS=$((PASS+1)); printf "  ${G}[PASS]${N} %s\n" "$*"; }
warn()    { WARN=$((WARN+1)); printf "  ${Y}[WARN]${N} %s\n" "$*"; }
fail()    { FAIL=$((FAIL+1)); printf "  ${R}[FAIL]${N} %s\n" "$*"; }
info()    { printf "  ${B}[INFO]${N} %s\n" "$*"; }
fix()     { FIX_LIST+=("$1"); }
section() { printf "\n${D}=== %s ===${N}\n" "$*"; }
header()  { printf "\n${B}${D}##### %s #####${N}\n\n" "$*"; }

# =========================================================================
# Args
# =========================================================================
CONFIG_PATH=""
RT_CPU_OVERRIDE=""
WINDOW_S=10
PHASE="both"
WAIT_TIMEOUT=180

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \?//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --config)       CONFIG_PATH="$2"; shift 2 ;;
        --rt-cpu)       RT_CPU_OVERRIDE="$2"; shift 2 ;;
        --window)       WINDOW_S="$2"; shift 2 ;;
        --phase)        PHASE="$2"; shift 2 ;;
        --report)       PHASE=report; shift ;;
        --nic)          PHASE=nic; shift ;;
        --wait-timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

case "$PHASE" in a|A) PHASE=a ;; b|B) PHASE=b ;; both|BOTH) PHASE=both ;; report|REPORT) PHASE=report ;; nic) PHASE=nic ;; *) echo "--phase must be a|b|both|report"; exit 1 ;; esac

# =========================================================================
# Config resolution (read rt_cpu, rt_priority, cycle_us from ecat_bus.yaml)
# =========================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$CONFIG_PATH" ]; then
    for cand in \
        "$SCRIPT_DIR/../share/tk_ros2_pkg_ethercat_master/configs/ecat_bus.yaml" \
        "$SCRIPT_DIR/../../configs/ecat_bus.yaml" \
        "$SCRIPT_DIR/../configs/ecat_bus.yaml"; do
        [ -f "$cand" ] && { CONFIG_PATH="$cand"; break; }
    done
fi

RT_CPU=""
RT_PRIO=""
CYCLE_US=""
if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    RT_CPU=$(awk   '/^[[:space:]]*rt_cpu:/      {print $2; exit}' "$CONFIG_PATH")
    RT_PRIO=$(awk  '/^[[:space:]]*rt_priority:/ {print $2; exit}' "$CONFIG_PATH")
    CYCLE_US=$(awk '/^[[:space:]]*cycle_us:/    {print $2; exit}' "$CONFIG_PATH")
fi
[ -n "$RT_CPU_OVERRIDE" ] && RT_CPU="$RT_CPU_OVERRIDE"
RT_CPU=${RT_CPU:-2}
RT_PRIO=${RT_PRIO:-90}
CYCLE_US=${CYCLE_US:-1000}

# SCHED_FIFO internal kernel prio = 99 - userspace rtprio
EXPECTED_INT_PRIO=$((99 - RT_PRIO))

STATE_DIR="/tmp/ecat_diag.state"
mkdir -p "$STATE_DIR"

# Parameterizable roots for the NIC status view (--nic). Default to the real
# system; the fixture test (scripts/tests/test_nic_status.sh) overrides them to
# point at a fabricated sysfs tree so the three-state classification can be
# verified without EtherCAT hardware.
NIC_SYS_BUS_PCI="${ECAT_DIAG_SYS_BUS_PCI:-/sys/bus/pci}"
NIC_SYS_CLASS_NET="${ECAT_DIAG_SYS_CLASS_NET:-/sys/class/net}"
NIC_STATE_DIR="${ECAT_DIAG_STATE_DIR:-/var/lib/ecat}"
NIC_DEV_ETHERCAT="${ECAT_DIAG_DEV_ETHERCAT:-/dev/EtherCAT0}"
NIC_MODPARAM="${ECAT_DIAG_MODPARAM:-/sys/module/ec_master/parameters/main_devices}"
# Intel PCI device ids that have a native IgH driver (kept minimal + local; the
# canonical lists live in ecat_setup.sh — no shared lib by design).
NIC_I210_IDS="1531 1533 1536 1537 1538 1539 157b 157c 15f6 15f7 15f8"
NIC_I226_IDS="125b 125c 125d"

# =========================================================================
# Low-level helpers
# =========================================================================
nic_detect() {
    # Three-tier resolution. The alphabetical scan that used to be the
    # only path picks the wrong NIC on multi-NIC hosts (e.g. eno1 sorts
    # before enp133s0), so Phase B checks would land on the wrong port
    # and miss IRQs the EtherCAT NIC was actually emitting on the RT CPU.
    # Trust the live ec_master module first, then setup's persisted MAC,
    # then fall back to the old scan for hosts that never ran setup.
    local target_mac=""

    if [ -r /sys/module/ec_master/parameters/main_devices ]; then
        target_mac=$(tr -d '\n' </sys/module/ec_master/parameters/main_devices \
                     | tr 'A-F' 'a-f')
    fi

    if [ -z "$target_mac" ] || [ "$target_mac" = "00:00:00:00:00:00" ]; then
        if [ -r /var/lib/ecat/main_devices ]; then
            target_mac=$(tr -d '\n' </var/lib/ecat/main_devices \
                         | tr 'A-F' 'a-f')
        fi
    fi

    if [ -n "$target_mac" ] && [ "$target_mac" != "00:00:00:00:00:00" ]; then
        for a in /sys/class/net/*/address; do
            if [ "$(tr 'A-F' 'a-f' <"$a" 2>/dev/null)" = "$target_mac" ]; then
                basename "$(dirname "$a")"
                return
            fi
        done
    fi

    for i in $(ls /sys/class/net); do
        case "$i" in lo|wl*|docker*|veth*|br-*|virbr*) continue ;; esac
        [ -d "/sys/class/net/$i/device" ] || continue
        echo "$i"; return
    done
}

# List IRQ numbers whose effective affinity is *exactly* the RT CPU.
irqs_on_rt_cpu() {
    for n in $(ls /proc/irq/ 2>/dev/null | grep -E '^[0-9]+$'); do
        local eff
        eff=$(cat /proc/irq/$n/effective_affinity_list 2>/dev/null)
        [ "$eff" = "$RT_CPU" ] && echo "$n"
    done
}

irq_name() {
    awk -v n="$1" '$1==n":"{ $1=""; sub(/^ +/,""); print }' /proc/interrupts | awk '{print $NF}'
}

# Heuristic managed-IRQ classifier: returns "managed" or "unmanaged".
# Managed IRQs (IRQF_MANAGED | IRQF_NO_BALANCING) cannot be moved at runtime —
# kernel rejects or ignores writes to /proc/irq/<N>/smp_affinity. Common
# sources: NVMe queue IRQs, virtio request queues, modern NICs with one queue
# per CPU. We match by IRQ name since it's cheap and non-destructive; the
# cgroup helper's write-probe is the ground truth at runtime.
irq_class() {
    local n="$1"
    local name; name=$(irq_name "$n")
    case "$name" in
        nvme*q*|*-nvme*q*)    echo managed; return ;;
        virtio*-req*|virtio*-output*|virtio*-input*) echo managed; return ;;
        *-TxRx-*|*-rx-*|*-tx-*|*-Tx-*|*-Rx-*) echo managed; return ;;
        *-perf|*_perf|perf-*) echo managed; return ;;     # per-CPU perf-event IRQs (dmar0-perf etc.)
        *)                    echo unmanaged; return ;;
    esac
}

# IRQ counter for a specific CPU column. CPU N is field (N+2) in /proc/interrupts.
irq_cpu_count() {
    local n=$1 cpu=$2
    local col=$((cpu + 2))
    awk -v n="$n" -v c="$col" '$1==n":"{print $c}' /proc/interrupts
}

# =========================================================================
# PHASE A — setup validation + idle baseline
# =========================================================================
phase_a() {
    header "PHASE A — setup validation + idle baseline"
    echo "Config:  ${CONFIG_PATH:-<none found>}"
    echo "RT CPU:  $RT_CPU"
    echo "RT prio: $RT_PRIO  (expected kernel internal prio = $EXPECTED_INT_PRIO)"
    echo "Cycle:   ${CYCLE_US} us"

    # -------- Host info (reference only, no verdict) --------
    section "Host info"
    info "host: $(hostname)"
    info "kernel: $(uname -r)"
    info "preempt: $(uname -v | grep -oE 'PREEMPT(_RT|_DYNAMIC)?' | head -1)"
    info "cmdline: $(cat /proc/cmdline)"

    # -------- Validate RT CPU exists --------
    section "RT CPU"
    local nproc; nproc=$(nproc)
    if [ "$RT_CPU" -ge "$nproc" ]; then
        fail "RT_CPU=$RT_CPU but host only has $nproc cores (0..$((nproc-1)))"
        fix "Re-run ecat_setup.sh --ecat-cpu <valid-core> or adjust rt_cpu in ecat_bus.yaml"
        return
    else
        pass "RT_CPU=$RT_CPU is a valid core on this $nproc-core host"
    fi
    local sibling
    sibling=$(cat /sys/devices/system/cpu/cpu${RT_CPU}/topology/thread_siblings_list 2>/dev/null)
    if [ "$sibling" = "$RT_CPU" ]; then
        info "CPU $RT_CPU has no SMT sibling"
    else
        warn "CPU $RT_CPU has SMT sibling(s): $sibling — consider isolating or disabling SMT"
        fix "Add SMT sibling ($sibling) to isolation, or disable SMT globally (echo off > /sys/devices/system/cpu/smt/control)"
    fi

    # -------- GRUB isolation mode --------
    if grep -qE '\b(isolcpus|nohz_full|rcu_nocbs)=' /proc/cmdline; then
        if grep -q 'isolcpus=managed_irq' /proc/cmdline; then
            pass "strict GRUB isolation active (CPU $RT_CPU carved out at boot via isolcpus/nohz_full/rcu_nocbs)"
        else
            warn "legacy isolcpus/nohz_full/rcu_nocbs on /proc/cmdline — not from this setup"
            fix "sudo ecat_setup.sh               (strips them, writes the strict managed_irq token set)"
        fi
    else
        warn "no isolcpus in /proc/cmdline — strict isolation is mandatory"
        fix "sudo ecat_setup.sh && sudo reboot    (writes the strict token set + reboots to apply)"
    fi

    # -------- cgroups v2 + cpuset --------
    section "Cgroups v2 + cpuset"
    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        fail "cgroups v2 not mounted at /sys/fs/cgroup"
        fix "Need a unified-hierarchy system (Ubuntu 22.04+ by default)"
    else
        pass "cgroups v2 unified hierarchy present"
    fi
    if grep -qw cpuset /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
        pass "cpuset controller available at cgroup root"
    else
        fail "cpuset controller NOT available at cgroup root (need Linux >= 5.6)"
        fix "Upgrade kernel / distro"
    fi

    # -------- Setup artifacts --------
    section "Setup artifacts (from ecat_setup.sh)"
    local a_ok=true
    for f in /usr/local/sbin/ecat-cgroup \
             /etc/sudoers.d/ecat \
             /etc/systemd/system/ethercat.service \
             /etc/udev/rules.d/99-ethercat.rules \
             /etc/security/limits.d/99-ethercat.conf; do
        if [ -e "$f" ]; then
            pass "$f exists"
        else
            fail "$f missing"
            a_ok=false
        fi
    done
    $a_ok || fix "sudo ecat_setup.sh --ecat-cpu $RT_CPU (re-run setup)"

    # -------- Group membership --------
    section "Group 'ecat'"
    if getent group ecat >/dev/null; then
        pass "group 'ecat' exists"
    else
        fail "group 'ecat' does not exist"
        fix "sudo ecat_setup.sh"
    fi
    local user=${SUDO_USER:-$(id -un)}
    if id -nG "$user" | grep -qw ecat; then
        pass "user '$user' is in group 'ecat'"
    else
        fail "user '$user' is NOT in group 'ecat'"
        fix "sudo usermod -aG ecat $user && log out/in"
    fi
    if id -nG | grep -qw ecat; then
        pass "current shell has 'ecat' group picked up"
    else
        warn "current shell does NOT have 'ecat' group — log out/in or 'newgrp ecat'"
        fix "Log out and back in, or run 'newgrp ecat'"
    fi

    # -------- irqbalance --------
    section "irqbalance"
    local ib
    ib=$(systemctl is-active irqbalance 2>/dev/null) || true
    ib=${ib:-unknown}
    if [ "$ib" = "active" ]; then
        fail "irqbalance is ACTIVE — will fight manual IRQ pinning"
        fix "sudo systemctl disable --now irqbalance"
    else
        pass "irqbalance is $ib"
    fi

    # -------- IgH module --------
    section "IgH EtherCAT master kernel module"
    local modver
    modver=$(modinfo -F vermagic ec_master 2>/dev/null | awk '{print $1}')
    if [ -z "$modver" ]; then
        fail "ec_master module not installed"
        fix "sudo ecat_setup.sh"
    elif [ "$modver" != "$(uname -r)" ]; then
        fail "ec_master built for $modver but running $(uname -r)"
        fix "sudo ecat_setup.sh (will rebuild for current kernel)"
    else
        pass "ec_master vermagic matches kernel ($modver)"
    fi

    # -------- Daemon binary + caps --------
    section "Daemon binary + capabilities"
    local daemon_bin=""
    local candidates=()
    [ -n "$(command -v ecat_rt_daemon 2>/dev/null || true)" ] && candidates+=("$(command -v ecat_rt_daemon)")
    for p in $SCRIPT_DIR/ecat_rt_daemon \
             /home/*/*/ros2_ws/install/tk_ros2_pkg_ethercat_master/lib/tk_ros2_pkg_ethercat_master/ecat_rt_daemon \
             /home/*/*/ros2_ws/build/tk_ros2_pkg_ethercat_master/ecat_rt_daemon; do
        [ -x "$p" ] && candidates+=("$p")
    done
    for c in "${candidates[@]}"; do
        [ -x "$c" ] || continue
        daemon_bin="$(readlink -f "$c")"
        break
    done
    if [ -z "$daemon_bin" ]; then
        fail "ecat_rt_daemon binary not found"
        fix "Run 'tk build' in the ros2_ws, or install from tk_binaries"
    else
        pass "daemon binary: $daemon_bin"
        local caps; caps=$(getcap "$daemon_bin" 2>/dev/null | awk '{print $NF}')
        if echo "$caps" | grep -q cap_sys_nice && echo "$caps" | grep -q cap_ipc_lock; then
            pass "file caps present: $caps"
        else
            warn "no cap_sys_nice/cap_ipc_lock on binary — will fall back to PAM rlimits"
            fix "sudo setcap cap_sys_nice,cap_ipc_lock,cap_net_admin+ep $daemon_bin   (or re-run ecat_setup.sh)"
        fi
    fi

    # -------- PAM limits (fallback if caps missing) --------
    section "PAM limits (rtprio + memlock)"
    local rtpr; rtpr=$(ulimit -r 2>/dev/null)
    local mem;  mem=$(ulimit -l 2>/dev/null)
    if [ "${rtpr:-0}" -ge "$RT_PRIO" ] 2>/dev/null; then
        pass "rtprio limit: $rtpr (>= $RT_PRIO)"
    else
        warn "rtprio limit: $rtpr (< $RT_PRIO)  — caps on binary will still work if present"
        fix "Log out and back in (limits.d PAM reload), or ensure file caps on daemon"
    fi
    if [ "$mem" = "unlimited" ]; then
        pass "memlock limit: unlimited"
    elif [ "${mem:-0}" -ge 1048576 ] 2>/dev/null; then
        pass "memlock limit: $mem KB (>= 1 GB)"
    else
        warn "memlock limit: $mem  — caps on binary will still work if present"
    fi

    # -------- Partition state (must be DOWN in Phase A) --------
    section "Partition state (expected: DOWN)"
    if [ -d /sys/fs/cgroup/ethercat_rt ]; then
        warn "partition is UP in Phase A — a daemon may already be running"
        /usr/local/sbin/ecat-cgroup status 2>/dev/null | sed 's/^/    /'
    else
        pass "partition is down (CPU $RT_CPU fully in general scheduler)"
    fi

    # -------- NIC auto-detect --------
    section "Ethernet interface"
    local iface; iface=$(nic_detect)
    if [ -z "$iface" ]; then
        fail "could not detect any physical ethernet interface"
        fix "Pass --interface IFACE to ecat_setup.sh"
    else
        pass "detected interface: $iface"
        echo "$iface" > "$STATE_DIR/iface"
        local irqs; irqs=$(grep -E "$iface" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ' | tr '\n' ' ')
        if [ -z "$irqs" ]; then
            warn "no IRQ lines found for $iface (driver loaded? link up?)"
        else
            info "$iface IRQ(s): $irqs"
            for n in $irqs; do
                local eff; eff=$(cat /proc/irq/$n/effective_affinity_list 2>/dev/null)
                if [ "$eff" = "$RT_CPU" ]; then
                    fail "NIC IRQ $n ($(irq_name $n)) effective affinity = RT CPU $RT_CPU — WILL cause jitter"
                    fix "Pin NIC IRQ off CPU $RT_CPU: echo <mask-without-$RT_CPU> > /proc/irq/$n/smp_affinity"
                else
                    pass "NIC IRQ $n currently on CPU $eff (not on RT CPU $RT_CPU)"
                fi
            done
        fi
    fi

    # -------- NetworkManager + avahi quarantine (issue #20) --------
    # NM cycling DHCP on the EtherCAT NIC and avahi multicasting mDNS on the
    # same NIC are silent jitter sources on default-config Ubuntu/Fedora
    # desktops. ecat_setup.sh installs a NM keyfile (unmanaged-devices) and
    # an avahi deny-interfaces line for the NIC. Verify both are present and
    # reference the detected NIC.
    section "NetworkManager + avahi quarantine"
    if [ -z "$iface" ]; then
        warn "no NIC detected — skipping NM/avahi quarantine check"
    else
        # NetworkManager keyfile.
        if command -v nmcli >/dev/null 2>&1 || [ -d /etc/NetworkManager ]; then
            local nmkey="/etc/NetworkManager/conf.d/99-tk-ethercat.conf"
            if [ ! -f "$nmkey" ]; then
                fail "$nmkey missing — NM will retry DHCP on $iface every ~45s"
                fix "sudo ecat_setup.sh   (writes NM keyfile + avahi deny-interfaces)"
            elif ! grep -qE "^unmanaged-devices=.*interface-name:${iface}(\$|;)" "$nmkey" 2>/dev/null; then
                fail "$nmkey exists but doesn't mark $iface as unmanaged"
                fix "sudo ecat_setup.sh --interface $iface   (rewrites the keyfile)"
            else
                pass "$nmkey marks $iface as unmanaged"
                # Live state cross-check via nmcli.
                if command -v nmcli >/dev/null 2>&1; then
                    local nm_state
                    nm_state=$(nmcli -t -g GENERAL.STATE dev show "$iface" 2>/dev/null | head -1)
                    case "$nm_state" in
                        *unmanaged*) pass "nmcli reports $iface state: $nm_state" ;;
                        "")          info "nmcli has no record of $iface (NM may not be running)" ;;
                        *)           warn "nmcli reports $iface state: $nm_state — keyfile present but NM hasn't reloaded?"
                                     fix "sudo nmcli general reload   (or restart NetworkManager)" ;;
                    esac
                fi
            fi
        else
            info "NetworkManager not installed — keyfile check skipped"
        fi

        # avahi deny-interfaces.
        if [ -f /etc/avahi/avahi-daemon.conf ]; then
            local deny_line
            deny_line=$(awk '/^\[server\]/ {in_s=1; next} /^\[/ {in_s=0} in_s && /^[[:space:]]*deny-interfaces[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, "", $0); print; exit}' /etc/avahi/avahi-daemon.conf)
            if [ -z "$deny_line" ]; then
                fail "no deny-interfaces= line in /etc/avahi/avahi-daemon.conf [server] — avahi will multicast mDNS on $iface"
                fix "sudo ecat_setup.sh   (adds the deny-interfaces line + backs up original)"
            else
                case ",$deny_line," in
                    *",$iface,"*) pass "avahi deny-interfaces covers $iface" ;;
                    *)            fail "avahi deny-interfaces missing $iface"
                                  fix "sudo ecat_setup.sh   (rewrites avahi deny-interfaces)" ;;
                esac
            fi
        else
            info "avahi-daemon.conf not present — avahi not installed (no mDNS source on this host)"
        fi
    fi

    # -------- IRQs currently on RT CPU (idle baseline) --------
    section "IRQs currently routed to RT CPU $RT_CPU (baseline)"
    : > "$STATE_DIR/irqs_on_rt_cpu_A.txt"
    local any_irq=false
    local any_managed=false
    for n in $(irqs_on_rt_cpu); do
        any_irq=true
        local count; count=$(irq_cpu_count "$n" "$RT_CPU")
        local cls; cls=$(irq_class "$n")
        echo "$n $count $cls" >> "$STATE_DIR/irqs_on_rt_cpu_A.txt"
        if [ "$cls" = "managed" ]; then
            any_managed=true
            warn "irq $n -> CPU $RT_CPU  ($(irq_name $n))  [count=$count, MANAGED]"
        else
            warn "irq $n -> CPU $RT_CPU  ($(irq_name $n))  [count=$count, unmanaged]"
            fix "Repin irq $n off CPU $RT_CPU: ecat-cgroup up will do this automatically, or echo <mask> > /proc/irq/$n/smp_affinity"
        fi
    done
    $any_irq || pass "no IRQs currently routed to CPU $RT_CPU"
    if $any_managed; then
        fix "Managed IRQs above cannot be moved at runtime. Re-apply strict isolation: sudo ecat_setup.sh && sudo reboot"
    fi

    # -------- C-states on RT CPU --------
    section "C-states on CPU $RT_CPU (deep states harm worst-case latency)"
    : > "$STATE_DIR/cstates_A.txt"
    for s in /sys/devices/system/cpu/cpu${RT_CPU}/cpuidle/state*; do
        [ -e "$s" ] || continue
        local name lat dis usage
        name=$(cat "$s/name"); lat=$(cat "$s/latency"); dis=$(cat "$s/disable"); usage=$(cat "$s/usage")
        echo "$(basename $s) $usage" >> "$STATE_DIR/cstates_A.txt"
        if [ "$lat" -gt 100 ] 2>/dev/null; then
            if [ "$dis" = "1" ]; then
                pass "$(basename $s) $name latency=${lat}us disabled"
            else
                warn "$(basename $s) $name latency=${lat}us ENABLED — parks CPU $RT_CPU for ${lat}us during idle gaps"
                fix "Disable deep C-state on CPU $RT_CPU: echo 1 > $s/disable (or boot with intel_idle.max_cstate=1)"
            fi
        else
            pass "$(basename $s) $name latency=${lat}us  (negligible)"
        fi
    done

    # -------- Governor on RT CPU --------
    section "CPU frequency governor on CPU $RT_CPU"
    local gov cur mn mx
    gov=$(cat /sys/devices/system/cpu/cpu${RT_CPU}/cpufreq/scaling_governor 2>/dev/null || echo "?")
    cur=$(cat /sys/devices/system/cpu/cpu${RT_CPU}/cpufreq/scaling_cur_freq 2>/dev/null || echo "?")
    mn=$(cat  /sys/devices/system/cpu/cpu${RT_CPU}/cpufreq/scaling_min_freq 2>/dev/null || echo "?")
    mx=$(cat  /sys/devices/system/cpu/cpu${RT_CPU}/cpufreq/scaling_max_freq 2>/dev/null || echo "?")
    info "governor=$gov  cur=$cur Hz  min=$mn Hz  max=$mx Hz"
    echo "$gov $cur $mn $mx" > "$STATE_DIR/cpufreq_A.txt"
    if [ "$gov" = "performance" ]; then
        pass "governor is 'performance'"
    else
        warn "governor is '$gov' — P-state transitions add jitter on CPU $RT_CPU"
        fix "sudo cpupower -c $RT_CPU frequency-set -g performance   (or echo performance > .../scaling_governor)"
    fi

    echo
    echo "Phase A baseline saved to $STATE_DIR"
}

# =========================================================================
# Wait for daemon
# =========================================================================
wait_for_daemon() {
    section "Waiting for ecat_rt_daemon"
    echo "Start the daemon now in another terminal:"
    echo "    ecat_daemon_start.sh [${CONFIG_PATH:-<config>}]"
    echo ""
    echo "Polling for 'ecat_rt_daemon' every 1 s (timeout: ${WAIT_TIMEOUT}s)…"
    local elapsed=0
    local pid=""
    while [ "$elapsed" -lt "$WAIT_TIMEOUT" ]; do
        pid=$(pgrep -x ecat_rt_daemon | head -1)
        if [ -n "$pid" ]; then
            echo ""
            pass "daemon detected: PID $pid"
            echo "Letting it stabilize for 3 s…"
            sleep 3
            echo "$pid" > "$STATE_DIR/daemon_pid"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed+1))
        printf "\r  (waited %ds)" "$elapsed"
    done
    echo ""
    fail "daemon did not appear within ${WAIT_TIMEOUT}s — aborting Phase B"
    return 1
}

# =========================================================================
# PHASE B — runtime validation + deltas
# =========================================================================
phase_b() {
    header "PHASE B — runtime validation"

    local pid=""
    if [ -f "$STATE_DIR/daemon_pid" ]; then
        pid=$(cat "$STATE_DIR/daemon_pid")
    fi
    # If running Phase B standalone, detect now.
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        pid=$(pgrep -x ecat_rt_daemon | head -1)
    fi
    if [ -z "$pid" ]; then
        fail "ecat_rt_daemon not running — cannot run Phase B"
        fix "Start it: ecat_daemon_start.sh ${CONFIG_PATH:-<config>}"
        return
    fi
    info "daemon PID: $pid"

    # -------- Partition --------
    section "Partition state"
    if [ ! -d /sys/fs/cgroup/ethercat_rt ]; then
        fail "partition is DOWN even though daemon is running"
        fix "ecat_daemon_start.sh brings the partition up; was the daemon launched via that script?"
        return
    fi
    local part cpus members
    part=$(cat /sys/fs/cgroup/ethercat_rt/cpuset.cpus.partition 2>/dev/null)
    cpus=$(cat /sys/fs/cgroup/ethercat_rt/cpuset.cpus 2>/dev/null)
    members=$(cat /sys/fs/cgroup/ethercat_rt/cgroup.procs 2>/dev/null | tr '\n' ' ')
    if [ "$part" = "isolated" ]; then pass "cpuset.cpus.partition = isolated"; else fail "partition state = '$part' (expected 'isolated')"; fi
    if [ "$cpus" = "$RT_CPU" ];   then pass "cpuset.cpus = $cpus";            else fail "cpuset.cpus = '$cpus' (expected '$RT_CPU')"; fi

    # Members must include daemon PID
    if echo "$members" | tr ' ' '\n' | grep -qw "$pid"; then
        pass "daemon PID $pid is inside the partition"
    else
        fail "daemon PID $pid is NOT in the partition (members: $members)"
        fix "ecat-cgroup add $pid   (or re-launch via ecat_daemon_start.sh)"
    fi
    local member_count; member_count=$(echo "$members" | wc -w)
    if [ "$member_count" = "1" ]; then
        pass "partition has exactly 1 member (the daemon)"
    else
        warn "partition has $member_count members: $members"
    fi

    # -------- Daemon scheduler/affinity/mlock --------
    section "Daemon RT attributes"
    local cpus_allowed vmlck
    cpus_allowed=$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/$pid/status 2>/dev/null)
    vmlck=$(awk '/^VmLck:/ {print $2}' /proc/$pid/status 2>/dev/null)
    if [ "$cpus_allowed" = "$RT_CPU" ]; then
        pass "Cpus_allowed_list = $cpus_allowed"
    else
        fail "Cpus_allowed_list = '$cpus_allowed' (expected '$RT_CPU')"
    fi
    if [ -n "$vmlck" ] && [ "$vmlck" -gt 0 ] 2>/dev/null; then
        pass "VmLck = ${vmlck} kB (mlockall active)"
    else
        fail "VmLck = '$vmlck' — mlockall not active"
        fix "Check cap_ipc_lock on daemon binary, or PAM memlock=unlimited"
    fi

    # -------- Per-thread policy --------
    section "Thread scheduler policies"
    local found_fifo=false
    for t in /proc/$pid/task/*; do
        local tid comm pol prio aff
        tid=$(basename "$t")
        comm=$(cat "$t/comm" 2>/dev/null)
        pol=$(awk '/^policy/{print $3}' "$t/sched" 2>/dev/null)
        prio=$(awk '/^prio/{print $3; exit}' "$t/sched" 2>/dev/null)
        aff=$(awk '/^Cpus_allowed_list:/ {print $2}' "$t/status" 2>/dev/null)
        # policy: 0=OTHER 1=FIFO 2=RR 6=DEADLINE
        local polname
        case "$pol" in 0) polname=OTHER;; 1) polname=FIFO;; 2) polname=RR;; 6) polname=DEADLINE;; *) polname="?($pol)";; esac
        if [ "$pol" = "1" ]; then
            found_fifo=true
            if [ "$prio" = "$EXPECTED_INT_PRIO" ]; then
                pass "tid=$tid $comm  SCHED_FIFO internal prio=$prio (= rtprio $RT_PRIO)  cpus=$aff"
            else
                warn "tid=$tid $comm  SCHED_FIFO internal prio=$prio (expected $EXPECTED_INT_PRIO for rtprio $RT_PRIO) cpus=$aff"
                fix "Check rt_priority in $CONFIG_PATH matches daemon start"
            fi
        else
            info "tid=$tid $comm  policy=$polname prio=$prio cpus=$aff"
        fi
    done
    $found_fifo || { fail "no SCHED_FIFO thread found in daemon"; fix "Check cap_sys_nice / PAM rtprio"; }

    # -------- IRQs on RT CPU — delta over window --------
    section "IRQs on CPU $RT_CPU — $WINDOW_S s observation"
    declare -A irq_before
    local irq_list; irq_list=$(irqs_on_rt_cpu)
    for n in $irq_list; do irq_before[$n]=$(irq_cpu_count "$n" "$RT_CPU"); done
    # Also track NIC IRQs explicitly (even if not currently on RT_CPU)
    local iface; iface=$(cat "$STATE_DIR/iface" 2>/dev/null || nic_detect)
    local nic_irqs; nic_irqs=$(grep -E "$iface" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ' | tr '\n' ' ')
    declare -A nic_before
    for n in $nic_irqs; do nic_before[$n]=$(irq_cpu_count "$n" "$RT_CPU"); done

    info "sampling for ${WINDOW_S}s …"
    sleep "$WINDOW_S"

    local any_bad=false
    local any_managed=false
    for n in $irq_list; do
        local before=${irq_before[$n]}
        local now; now=$(irq_cpu_count "$n" "$RT_CPU")
        local delta=$((now - before))
        local rate=$((delta / (WINDOW_S > 0 ? WINDOW_S : 1)))
        if [ "$delta" -gt 0 ]; then
            local cls; cls=$(irq_class "$n")
            if [ "$cls" = "managed" ]; then
                any_managed=true
                fail "irq $n ($(irq_name $n)) [MANAGED] fired $delta times on CPU $RT_CPU in ${WINDOW_S}s (~${rate}/s)"
            else
                warn "irq $n ($(irq_name $n)) [unmanaged] fired $delta times on CPU $RT_CPU in ${WINDOW_S}s (~${rate}/s)"
                fix "Repin irq $n off CPU $RT_CPU: sudo ecat-cgroup up (via ecat_daemon_start.sh) should have done this — is the daemon still running?"
            fi
            any_bad=true
        fi
    done
    $any_bad || pass "no IRQ activity observed on CPU $RT_CPU during the window"
    if $any_managed; then
        fix "Managed IRQs cannot be moved at runtime. Re-apply strict isolation: sudo ecat_setup.sh && sudo reboot"
    fi

    # NIC-specific — this is the critical one for EtherCAT
    section "NIC IRQs ($iface) — must NOT hit RT CPU"
    for n in $nic_irqs; do
        local before=${nic_before[$n]}
        local now; now=$(irq_cpu_count "$n" "$RT_CPU")
        local delta=$((now - before))
        local eff; eff=$(cat /proc/irq/$n/effective_affinity_list 2>/dev/null)
        if [ "$delta" -gt 0 ] || [ "$eff" = "$RT_CPU" ]; then
            fail "NIC irq $n ($(irq_name $n)): effective=$eff, fired ${delta}x on CPU $RT_CPU in ${WINDOW_S}s"
            fix "Pin NIC IRQ off CPU $RT_CPU: echo <mask-without-$RT_CPU> > /proc/irq/$n/smp_affinity"
        else
            pass "NIC irq $n ($(irq_name $n)): effective=$eff, 0 hits on CPU $RT_CPU"
        fi
    done

    # -------- C-states delta --------
    section "C-state deltas on CPU $RT_CPU over ${WINDOW_S}s"
    while read -r state_dir before; do
        local s=/sys/devices/system/cpu/cpu${RT_CPU}/cpuidle/$state_dir
        [ -e "$s" ] || continue
        local name lat now delta
        name=$(cat "$s/name")
        lat=$(cat "$s/latency")
        now=$(cat "$s/usage")
        delta=$((now - before))
        if [ "$lat" -gt 100 ] 2>/dev/null; then
            if [ "$delta" -gt 0 ]; then
                warn "$state_dir $name latency=${lat}us  entries=$delta  (CPU was parked — each exit costs ~${lat}us)"
                fix "Disable $name on CPU $RT_CPU: echo 1 > $s/disable"
            else
                pass "$state_dir $name latency=${lat}us  entries=0"
            fi
        else
            info "$state_dir $name latency=${lat}us  entries=$delta  (negligible)"
        fi
    done < "$STATE_DIR/cstates_A.txt"

    # -------- Frequency samples --------
    section "CPU $RT_CPU frequency under load (10 samples, 200ms apart)"
    local min=999999999 max=0
    for i in $(seq 1 10); do
        local cur; cur=$(cat /sys/devices/system/cpu/cpu${RT_CPU}/cpufreq/scaling_cur_freq 2>/dev/null)
        [ "$cur" -lt "$min" ] 2>/dev/null && min=$cur
        [ "$cur" -gt "$max" ] 2>/dev/null && max=$cur
        sleep 0.2
    done
    local min_freq; min_freq=$(cat /sys/devices/system/cpu/cpu${RT_CPU}/cpufreq/scaling_min_freq)
    info "observed freq range: $min .. $max Hz  (host min=$min_freq Hz)"
    if [ "$min" -le $((min_freq + 100000)) ] 2>/dev/null; then
        warn "CPU $RT_CPU dropped near scaling_min_freq while daemon was running — P-state transitions are happening"
        fix "sudo cpupower -c $RT_CPU frequency-set -g performance"
    else
        pass "CPU $RT_CPU stayed above idle freq"
    fi

    # -------- Liveness check --------
    section "Daemon liveness"
    if kill -0 "$pid" 2>/dev/null; then
        pass "daemon PID $pid still alive at end of Phase B"
    else
        fail "daemon PID $pid died during Phase B"
        fix "Check daemon stdout/stderr for aborts"
    fi
}

# =========================================================================
# Summary
# =========================================================================
summary() {
    header "SUMMARY"
    printf "  ${G}PASS${N}: %d\n" "$PASS"
    printf "  ${Y}WARN${N}: %d\n" "$WARN"
    printf "  ${R}FAIL${N}: %d\n" "$FAIL"
    echo
    if [ "${#FIX_LIST[@]}" -gt 0 ]; then
        echo "Suggested fixes (in order of importance):"
        local i=1
        for f in "${FIX_LIST[@]}"; do
            printf "  ${D}%d)${N} %s\n" "$i" "$f"
            i=$((i+1))
        done
        echo
    fi
    if [ "$FAIL" -gt 0 ]; then
        printf "${R}${D}VERDICT: NOT READY — address FAIL items above.${N}\n"
        exit 1
    elif [ "$WARN" -gt 0 ]; then
        printf "${Y}${D}VERDICT: MOSTLY OK — WARN items may explain residual jitter.${N}\n"
        exit 2
    else
        printf "${G}${D}VERDICT: ALL CLEAR.${N}\n"
        exit 0
    fi
}

# =========================================================================
# Phase report — one-shot snapshot for maintainer copy-paste.
# =========================================================================
# Why this exists: when a host misbehaves, the maintainer needs the same
# 15-20 facts every time (kernel, modules, cmdline, cgroup, NIC, service,
# daemon, journal). Asking the operator to gather them by hand is slow
# and error-prone. This dumps them all in one block. Output is plain
# text (no ANSI) so it pastes cleanly into chat / issue tracker even if
# the terminal had colour enabled. The launcher (ecat_daemon_start.sh)
# invokes this automatically on every pre-flight failure, so the failing
# host emits the report unprompted.
phase_report() {
    # Force-disable colour for this mode regardless of TTY. Re-enabling
    # for `phase_a`/`phase_b` would require resetting these — but those
    # phases are not reachable in --report mode (single dispatch below).
    R=''; G=''; Y=''; B=''; D=''; N=''
    local kver iface mac link speed
    kver=$(uname -r)
    iface=$(grep -oP '(?<=ip link set dev )\S+' /etc/systemd/system/ethercat.service 2>/dev/null | head -1)
    iface=${iface:-unknown}
    mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || echo "?")
    link=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "?")
    speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo "?")

    echo "================ ECAT REPORT $(date -Iseconds) ================"
    local up_s=$(awk '{print int($1)}' /proc/uptime)
    echo "Host:        $(id -un)@$(hostname)   uptime=${up_s}s"
    echo "Kernel:      $kver"
    echo "NIC:         $iface ($mac) link=$link speed=${speed}M"
    local iv=$(cat /var/lib/ecat/installed_version 2>/dev/null || echo "NONE")
    local strict=$(grep -q 'isolcpus=managed_irq' /proc/cmdline && echo "YES" || echo "no")
    echo "Helper:      installed_version=$iv  strict_isolation=$strict"
    echo "Cmdline:     $(cat /proc/cmdline | tr -s ' ')"
    echo ""

    # Modules: ec_master is always required. The device driver is whichever
    # of ec_generic / ec_igb / ec_igc / ec_r8169 the setup script chose at
    # install time, persisted in the systemd unit's ExecStartPost. Hardcoding
    # would mislead readers on native-driver hosts. Fall back to ec_generic
    # if the unit is missing/unreadable so the report still surfaces something.
    local drv=$(awk '/^ExecStartPost=.*modprobe[[:space:]]+ec_/ {for(i=1;i<=NF;i++) if($i ~ /^ec_/){print $i; exit}}' /etc/systemd/system/ethercat.service 2>/dev/null)
    drv=${drv:-ec_generic}
    echo "Modules (built for kernel $kver, NIC driver=$drv):"
    local master_ko="/lib/modules/$kver/ethercat/master/ec_master.ko"
    local master_loaded=$(lsmod | awk '$1=="ec_master"{print "LOADED"; exit}')
    master_loaded=${master_loaded:-NOT-LOADED}
    local master_disk=$([ -f "$master_ko" ] && echo "present" || echo "MISSING")
    printf "  %-14s %-60s %s/%s\n" "ec_master" "$master_ko" "$master_disk" "$master_loaded"
    local drv_ko=$(find "/lib/modules/$kver/ethercat/devices" -name "${drv}.ko" 2>/dev/null | head -1)
    drv_ko=${drv_ko:-/lib/modules/$kver/ethercat/devices/${drv}.ko}
    local drv_loaded=$(lsmod | awk -v m="$drv" '$1==m{print "LOADED"; exit}')
    drv_loaded=${drv_loaded:-NOT-LOADED}
    local drv_disk=$([ -f "$drv_ko" ] && echo "present" || echo "MISSING")
    printf "  %-14s %-60s %s/%s\n" "$drv" "$drv_ko" "$drv_disk" "$drv_loaded"
    echo ""

    echo "Service:"
    local svc=$(systemctl is-active ethercat.service 2>/dev/null; true)
    echo "  ethercat.service:        ${svc:-unknown}"
    if [ -e /dev/EtherCAT0 ]; then
        echo "  /dev/EtherCAT0:          present ($(stat -c '%G:%U %a' /dev/EtherCAT0 2>/dev/null))"
    else
        echo "  /dev/EtherCAT0:          ABSENT"
    fi
    echo ""

    local rtcpu="${RT_CPU:-2}"
    echo "CPU $rtcpu (RT CPU):"
    if [ -d /sys/fs/cgroup/ethercat_rt ]; then
        echo "  cgroup partition:        $(cat /sys/fs/cgroup/ethercat_rt/cpuset.cpus.partition 2>/dev/null)"
        echo "  cgroup members:          $(tr '\n' ' ' < /sys/fs/cgroup/ethercat_rt/cgroup.procs 2>/dev/null)"
    else
        echo "  cgroup partition:        DOWN"
    fi
    local cstates=""
    for s in /sys/devices/system/cpu/cpu${rtcpu}/cpuidle/state*/disable; do
        [ -e "$s" ] && cstates="${cstates}$(cat $s) "
    done
    echo "  C-states (state0..N):    ${cstates}(1=disabled,0=enabled)"
    echo "  no_turbo:                $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo ?)"
    echo "  governor:                $(cat /sys/devices/system/cpu/cpu${rtcpu}/cpufreq/scaling_governor 2>/dev/null || echo ?)"
    echo "  scaling_cur_freq:        $(cat /sys/devices/system/cpu/cpu${rtcpu}/cpufreq/scaling_cur_freq 2>/dev/null || echo ?) kHz"
    if [ -s /var/lib/ecat/cpu_dma_latency.pid ]; then
        local hpid=$(cat /var/lib/ecat/cpu_dma_latency.pid 2>/dev/null)
        if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
            echo "  cpu_dma_latency holder:  alive (pid $hpid)"
        else
            echo "  cpu_dma_latency holder:  STALE pidfile (pid $hpid not running)"
        fi
    else
        echo "  cpu_dma_latency holder:  none (no pidfile)"
    fi
    echo ""

    echo "IRQs:"
    local still=""
    for n in $(ls /proc/irq/ 2>/dev/null | grep -E '^[0-9]+$'); do
        local eff=$(cat "/proc/irq/$n/effective_affinity_list" 2>/dev/null || echo "")
        if [ "$eff" = "$rtcpu" ]; then
            local nm=$(awk -v m="$n" '$1==m":"{ for(i=NF;i>=2;i--) if($i !~ /^[0-9]+$/){print $i; exit} }' /proc/interrupts 2>/dev/null)
            still="$still $n:${nm:-?}"
        fi
    done
    [ -z "$still" ] && still=" (none)"
    echo "  still on CPU $rtcpu:        $still"
    if [ -s /var/lib/ecat/irq_snapshot.tsv ]; then
        echo "  pinned-off (snapshot):   $(wc -l < /var/lib/ecat/irq_snapshot.tsv) IRQs"
    fi
    echo ""

    echo "Daemon process:"
    local dpids=$(pgrep -af ecat_rt_daemon 2>/dev/null | grep -v "pgrep\|grep" || true)
    if [ -n "$dpids" ]; then
        echo "$dpids" | sed 's/^/  /'
        local dp1=$(pgrep -f ecat_rt_daemon -n 2>/dev/null | head -1)
        if [ -n "$dp1" ]; then
            # The main thread of ecat_rt_daemon is intentionally SCHED_OTHER
            # — it drops itself after spawning the RT cycle thread. Reading
            # only the main /proc/<pid>/stat would always show 0/0 and look
            # like the daemon is misconfigured. Walk every kernel task under
            # /proc/<pid>/task/ and pick the one with the highest rt_priority
            # — that's the cycle thread that actually drives the bus.
            #
            # Use chrt(1) so we don't have to count /proc/.../stat fields
            # (comm can contain spaces/parens, brittle to parse by hand;
            # chrt reads the policy via syscalls).
            local rt_tid="" rt_pri=0 rt_pol="SCHED_OTHER"
            for task_dir in /proc/$dp1/task/*/; do
                local tid=$(basename "$task_dir")
                local line=$(chrt -p "$tid" 2>/dev/null | tr '\n' ' ')
                # chrt prints two lines: "...policy: NAME" then "...priority: N"
                local pol=$(echo "$line" | sed -n 's/.*policy: \([A-Z_]*\).*/\1/p')
                local pri=$(echo "$line" | sed -n 's/.*priority: \([0-9]*\).*/\1/p')
                if [ "${pri:-0}" -gt "$rt_pri" ] 2>/dev/null; then
                    rt_pri=$pri
                    rt_pol=$pol
                    rt_tid=$tid
                fi
            done
            echo "  RT thread (max prio):    tid=${rt_tid:-?} policy=${rt_pol} rt_priority=${rt_pri}"
            # /proc/<pid>/cgroup line in cgroups v2 is "0::/path". awk -F:
            # splits to $1="0", $2="" (empty between two colons), $3="/path".
            # The previous comparison ($2=="0") therefore never matched.
            local cg=$(awk -F: '$1=="0"{print $NF}' /proc/$dp1/cgroup 2>/dev/null)
            echo "  cgroup (v2 path):        ${cg:-?}"
        fi
    else
        echo "  (no ecat_rt_daemon running)"
    fi
    echo ""

    echo "Last 8 lines of journalctl -u ethercat.service:"
    journalctl -u ethercat.service --no-pager -n 8 2>/dev/null | sed 's/^/  /' || echo "  (journal access denied — run with sudo for log)"
    echo "================================================================="
}

# =========================================================================
# NIC status (--nic) — show the EtherCAT NIC and its current driver in ANY
# state, keyed off the PCI BDF so it works even when the card has no netdev
# (native ec_igb/ec_igc owns it). This is the "ip link for EtherCAT": ip link
# cannot show an ec_igb-owned card, this can. Three states are distinguished:
#   1) running native   : driver = ec_igb/ec_igc, no netdev (by design)
#   2) reserved/orphan  : no driver bound, driver_override still = ec_igb
#   3) restored/ordinary: stock igb/igc bound, netdev present
# =========================================================================
nic_chipset_for_bdf() {   # BDF -> "Intel I210" | "Intel I226" | "" (best-effort)
    local bdf="$1"
    local vf="$NIC_SYS_BUS_PCI/devices/$bdf/vendor" df="$NIC_SYS_BUS_PCI/devices/$bdf/device"
    [ -r "$vf" ] && [ -r "$df" ] || return 0
    local v d
    v=$(sed 's/^0x//' "$vf" 2>/dev/null | tr 'A-F' 'a-f')
    d=$(sed 's/^0x//' "$df" 2>/dev/null | tr 'A-F' 'a-f')
    [ "$v" = "8086" ] || return 0
    case " $NIC_I210_IDS " in *" $d "*) echo "Intel I210"; return 0 ;; esac
    case " $NIC_I226_IDS " in *" $d "*) echo "Intel I226"; return 0 ;; esac
}

nic_driver_of_bdf() {     # BDF -> bound driver name | "none"
    local l="$NIC_SYS_BUS_PCI/devices/$1/driver"
    if [ -e "$l" ]; then basename "$(readlink -f "$l" 2>/dev/null)"; else echo "none"; fi
}

nic_netdev_of_bdf() {     # BDF -> netdev name (empty if none)
    local d="$NIC_SYS_BUS_PCI/devices/$1/net" n
    [ -d "$d" ] || return 0
    for n in "$d"/*; do [ -e "$n" ] && { basename "$n"; return 0; }; done
}

nic_target_mac() {        # recorded EtherCAT MAC (module param, then persisted)
    local m=""
    [ -r "$NIC_MODPARAM" ] && m=$(tr -d '[:space:]' < "$NIC_MODPARAM" 2>/dev/null | tr 'A-F' 'a-f')
    if [ -z "$m" ] || [ "$m" = "00:00:00:00:00:00" ]; then
        [ -r "$NIC_STATE_DIR/main_devices" ] && \
            m=$(tr -d '[:space:]' < "$NIC_STATE_DIR/main_devices" 2>/dev/null | tr 'A-F' 'a-f')
    fi
    echo "$m"
}

# Resolve the EtherCAT NIC -> sets NIC_BDF + NIC_IFACE. Order: (1) a netdev
# whose MAC matches the recorded one, (2) a slot bound to ec_igb/ec_igc,
# (3) a slot reserved via driver_override with no driver bound.
nic_resolve() {
    NIC_BDF=""; NIC_IFACE=""
    local mac; mac=$(nic_target_mac)
    if [ -n "$mac" ]; then
        local a
        for a in "$NIC_SYS_CLASS_NET"/*/address; do
            [ -r "$a" ] || continue
            if [ "$(tr 'A-F' 'a-f' < "$a" 2>/dev/null)" = "$mac" ]; then
                NIC_IFACE=$(basename "$(dirname "$a")")
                NIC_BDF=$(basename "$(readlink -f "$NIC_SYS_CLASS_NET/$NIC_IFACE/device" 2>/dev/null)" 2>/dev/null)
                return 0
            fi
        done
    fi
    local drv link
    for drv in ec_igb ec_igc; do
        [ -d "$NIC_SYS_BUS_PCI/drivers/$drv" ] || continue
        for link in "$NIC_SYS_BUS_PCI/drivers/$drv"/0000:*; do
            [ -e "$link" ] || continue
            NIC_BDF=$(basename "$link"); return 0
        done
    done
    local ov o bdf
    for ov in "$NIC_SYS_BUS_PCI"/devices/*/driver_override; do
        [ -r "$ov" ] || continue
        o=$(cat "$ov" 2>/dev/null)
        case "$o" in
            ec_igb|ec_igc)
                bdf=$(basename "$(dirname "$ov")")
                [ -e "$NIC_SYS_BUS_PCI/devices/$bdf/driver" ] || { NIC_BDF="$bdf"; return 0; }
                ;;
        esac
    done
    return 1
}

nic_status() {
    if ! nic_resolve; then
        echo "EtherCAT NIC"
        echo "  (none found — no netdev matches the recorded MAC, and no slot is"
        echo "   bound to or reserved for ec_igb/ec_igc)"
        return 0
    fi
    local bdf="$NIC_BDF" iface="$NIC_IFACE" drv override netdev chip mac macsrc
    drv=$(nic_driver_of_bdf "$bdf")
    override=$(cat "$NIC_SYS_BUS_PCI/devices/$bdf/driver_override" 2>/dev/null)
    [ "$override" = "(null)" ] && override=""
    if [ -n "$iface" ]; then netdev="$iface"; else netdev=$(nic_netdev_of_bdf "$bdf"); fi
    chip=$(nic_chipset_for_bdf "$bdf")

    if [ -r "$NIC_MODPARAM" ] && [ -n "$(tr -d '[:space:]' < "$NIC_MODPARAM" 2>/dev/null)" ]; then
        mac=$(tr -d '[:space:]' < "$NIC_MODPARAM"); macsrc="live ec_master module"
    elif [ -r "$NIC_STATE_DIR/main_devices" ]; then
        mac=$(tr -d '[:space:]' < "$NIC_STATE_DIR/main_devices"); macsrc="$NIC_STATE_DIR/main_devices"
    else
        mac="?"; macsrc="unknown"
    fi

    local drvline
    case "$drv" in
        ec_igb|ec_igc) drvline="$drv  → EtherCAT-owned (no kernel netdev — expected while master runs)" ;;
        ec_generic)    drvline="ec_generic  → EtherCAT via kernel net stack (netdev stays present)" ;;
        none)
            case "$override" in
                ec_igb|ec_igc) drvline="none  → slot reserved for EtherCAT (driver_override=$override; stock driver blocked)" ;;
                *)             drvline="none  → unbound (no driver, no reservation)" ;;
            esac ;;
        *)             drvline="$drv  → ordinary NIC" ;;
    esac

    local netline
    if [ -n "${netdev:-}" ]; then
        local link speed
        link=$(cat "$NIC_SYS_CLASS_NET/$netdev/operstate" 2>/dev/null || echo "?")
        speed=$(cat "$NIC_SYS_CLASS_NET/$netdev/speed" 2>/dev/null || echo "?")
        netline="$netdev   link $link   ${speed}M"
    elif [ "$override" = ec_igb ] || [ "$override" = ec_igc ]; then
        netline="none  (returns as a netdev after ecat_teardown.sh)"
    else
        netline="none"
    fi

    local masterline
    if [ -e "$NIC_DEV_ETHERCAT" ]; then
        masterline="$NIC_DEV_ETHERCAT present"
        if command -v ethercat >/dev/null 2>&1; then
            local ph
            ph=$(ethercat master 2>/dev/null | sed -n 's/.*Phase:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -1)
            [ -n "$ph" ] && masterline="$masterline · Phase = $ph"
        fi
    else
        masterline="$NIC_DEV_ETHERCAT absent (daemon not running)"
    fi

    echo "EtherCAT NIC"
    printf "  %-8s : %s\n" "PCI slot" "$bdf${chip:+   ($chip)}"
    printf "  %-8s : %s\n" "MAC"      "$mac   (source: $macsrc)"
    printf "  %-8s : %s\n" "driver"   "$drvline"
    printf "  %-8s : %s\n" "netdev"   "$netline"
    printf "  %-8s : %s\n" "master"   "$masterline"
    return 0
}

# =========================================================================
# Main
# =========================================================================
case "$PHASE" in
    nic)    nic_status; exit $? ;;
    a)      phase_a ;;
    b)      phase_b ;;
    both)   phase_a; wait_for_daemon && phase_b ;;
    report) phase_report; exit 0 ;;
esac
summary
