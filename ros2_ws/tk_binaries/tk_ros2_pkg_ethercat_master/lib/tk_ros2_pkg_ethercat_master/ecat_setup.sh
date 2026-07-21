#!/bin/bash
#
# ecat_setup.sh — install / refresh the EtherCAT stack
#
# Idempotent. The first invocation is a fresh install; later invocations
# automatically run as a fast refresh — they re-assert /etc/* artifacts,
# the helper, file caps, and the version sentinel without rebuilding the
# kernel module unless the kernel actually changed. Just run this
# whenever the launcher reports drift.
#
# After install, launching the daemon never needs sudo. Drift recovery
# is automatic: 'tk build' wipes the binary's capabilities → restored
# silently; cgroup partition gets stale → reconciled silently; an /etc/*
# file is deleted → the launcher prints one line ('sudo ecat_setup.sh')
# instead of a cryptic error.
#
# Requires PREEMPT-friendly stock Linux ≥ 5.6 (cgroups v2).
#
# Usage:
#   sudo ecat_setup.sh [--ecat-cpu N] [--interface IFACE] [--park-ht-sibling=off]
#   sudo ecat_setup.sh --help
#
# Isolation (mandatory, the only mode):
#   CPU N is carved out of the kernel at boot via GRUB tokens
#   isolcpus=managed_irq,domain,N irqaffinity=<except-N> nohz_full=N
#   rcu_nocbs=N psi=0. Managed IRQs (NVMe etc.) and per-CPU kworker chains
#   (psi_avgs_work, igb_watchdog, pci_pme, ...) are kept off it. The daemon
#   runs on a permanently-isolated core. Reboot required after install.
#
# Undo everything with:    sudo ecat_teardown.sh
#

set -euo pipefail

# =========================================================================
# Constants — all configurable paths in one place
# =========================================================================
IGH_REPO="https://gitlab.com/etherlab.org/ethercat.git"
IGH_BRANCH="stable-1.6"
# /tmp may be mounted noexec on hardened hosts — scripts like ./bootstrap and
# ./configure cannot execute there. Fall back to /var/lib which is always on
# the root filesystem.
if findmnt -n -o OPTIONS --target /tmp 2>/dev/null | grep -qw noexec; then
    BUILD_DIR="/var/lib/igh_ethercat_build"
else
    BUILD_DIR="/tmp/igh_ethercat_build"
fi
INSTALL_PREFIX="/usr/local"

KERNEL_VER="$(uname -r)"
KERNEL_HEADERS="/usr/src/linux-headers-$KERNEL_VER"
GRUB_FILE="/etc/default/grub"

ECAT_GROUP="ecat"
UDEV_RULE="/etc/udev/rules.d/99-ethercat.rules"
SUDOERS_FILE="/etc/sudoers.d/ecat"
CPUSET_SERVICE="/etc/systemd/system/ethercat-cpuset.service"   # legacy, removed if found
CPUSET_DIR="/sys/fs/cgroup/ethercat_rt"
CGROUP_HELPER="/usr/local/sbin/ecat-cgroup"
ECAT_STATE_DIR="/var/lib/ecat"
INSTALL_VERSION_FILE="$ECAT_STATE_DIR/installed_version"   # sentinel — used by 'ecat-cgroup verify-install'

# Bump this when any system-installed artifact (helper, service, udev,
# sudoers, limits, file caps logic) changes shape. The helper embeds it
# at install time as ECAT_HELPER_VERSION; verify-install compares the
# embedded value to the sentinel file written below. Mismatch means the
# helper was hand-edited or the sentinel is stale — either way, re-running
# sudo ecat_setup.sh fixes it. Format: YYYY-MM-DD.N where N increments
# within a day.
ECAT_INSTALL_VERSION="2026-06-25.1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# =========================================================================
# Intel chipset detection for native IgH drivers
# =========================================================================
# Two families are in scope, both have native IgH drivers that replace the
# kernel driver and bypass NAPI/softirq so EtherCAT frames are processed
# inside the IgH master kthread instead of the Linux network stack:
#
#   - I210 family (1 GbE)  -> ec_igb  (mature in IgH 1.6 stable)
#   - I226 family (2.5 GbE) -> ec_igc (newer; check configure support
#                                       on first build, falls back via
#                                       /tmp/igh-configure.log on EINVAL)
#
# We match by PCI vendor:device (not driver name) because the kernel
# 'igb' driver covers I210, I219, I350, 82576, 82580 etc. and 'igc'
# covers I225 and I226 — only I210 and I226 are in scope for this
# script. Extension to other chips is a one-line change to the ID list.
#
# Source: https://pci-ids.ucw.cz/read/PC/8086 — devices flagged as I210
# and I226 in the Intel PCI ID database.
I210_PCI_IDS="1531 1533 1536 1537 1538 1539 157b 157c 15f6 15f7 15f8"
I226_PCI_IDS="125b 125c 125d"

# Returns the friendly chipset name + IgH driver for a NIC, or empty if no
# native driver is in scope, keyed by PCI BDF (e.g. 0000:83:00.0). Keying off
# the BDF (not a netdev name) is deliberate: a NIC already bound to a native
# EtherCAT driver (ec_igb / ec_igc) has NO netdev — /sys/class/net/<iface> is
# gone — but vendor/device still live on the PCI device and survive the bind,
# so we read them straight from the BDF. Used by the menu (default index +
# labels) and the post-selection DRIVER assignment.
chipset_for_bdf() {
    local bdf="$1"
    local vfile="/sys/bus/pci/devices/$bdf/vendor"
    local dfile="/sys/bus/pci/devices/$bdf/device"
    [ -r "$vfile" ] && [ -r "$dfile" ] || return 0
    local vendor device pid
    vendor=$(sed 's/^0x//' "$vfile" | tr 'A-F' 'a-f')
    device=$(sed 's/^0x//' "$dfile" | tr 'A-F' 'a-f')
    [ "$vendor" = "8086" ] || return 0
    for pid in $I210_PCI_IDS; do [ "$device" = "$pid" ] && { echo "I210 igb"; return 0; }; done
    for pid in $I226_PCI_IDS; do [ "$device" = "$pid" ] && { echo "I226 igc"; return 0; }; done
}

# Derive the predictable netdev name (enp<bus>s<slot>[f<func>]) the kernel
# would assign to a PCI BDF. Used to label / quarantine a NIC that currently
# has no netdev because ec_igb / ec_igc claimed its slot: if that slot ever
# fell back to a stock driver the kernel would name it exactly this, so the
# NM/avahi unmanaged marking we write stays correct either way.
ifname_from_bdf() {
    local bdf="$1"            # 0000:83:00.0
    local rest="${bdf#*:}"    # 83:00.0
    local bus="${rest%%:*}"   # 83
    local sf="${rest#*:}"     # 00.0
    local slot="${sf%%.*}"    # 00
    local func="${sf#*.}"     # 0
    local name="enp$((16#$bus))s$((16#$slot))"
    [ "$((16#$func))" -ne 0 ] && name="${name}f$((16#$func))"
    echo "$name"
}

# =========================================================================
# 0. Parse arguments
# =========================================================================
ECAT_CPU=2
INTERFACE=""
DRIVER_FLAG_OVERRIDE=""    # "", "igb", "igc", "generic" — bypasses the menu when set
PARK_HT_SIBLING="on"       # "on" (default) | "off". Park the HT sibling of the RT CPU too.

while [ $# -gt 0 ]; do
    case "$1" in
        --ecat-cpu)               ECAT_CPU="$2"; shift 2 ;;
        --interface)              INTERFACE="$2"; shift 2 ;;
        --driver)                 DRIVER_FLAG_OVERRIDE="$2"; shift 2 ;;
        --driver=*)               DRIVER_FLAG_OVERRIDE="${1#*=}"; shift ;;
        --park-ht-sibling=off)    PARK_HT_SIBLING="off"; shift ;;
        --park-ht-sibling)        PARK_HT_SIBLING="on"; shift ;;
        --park-ht-sibling=on)     PARK_HT_SIBLING="on"; shift ;;
        -h|--help)
            cat <<HELP
Usage: sudo $0 [OPTIONS]

  EtherCAT install. Idempotent — first invocation is a fresh install,
  later invocations are a fast re-install (just refreshes /etc/* artifacts,
  helper, file caps, and the version sentinel; doesn't rebuild the
  kernel module unless the kernel changed). Run this whenever the launcher
  says "install drift detected".

  After install, launching the daemon needs no sudo. The launcher creates
  the isolated partition fresh on each start ('ecat-cgroup up', strict) and
  re-applies file caps; it fails loudly on unexpected state rather than
  auto-repairing.

OPTIONS

  --ecat-cpu N            CPU core to dedicate to EtherCAT (default: 2).
  --interface IFACE       NIC to bind (default: auto-detect physical Ethernet).
                          If multiple NICs are present and one has a
                          native IgH driver in scope (Intel I210 -> ec_igb,
                          Intel I226 -> ec_igc), it is recommended and
                          chosen by default. IgH is then built with the
                          matching --enable-igb / --enable-igc flag and
                          the unit loads the native driver (bypasses
                          NAPI/softirq). Otherwise the script falls back
                          to ec_generic with a WARN.

  --driver DRIVER         Force EtherCAT driver: 'igb' | 'igc' | 'generic'.
                          Default: interactive menu when native is
                          available on this chipset+kernel; otherwise
                          'generic'. Use this in CI / unattended installs
                          to skip the menu.

  (Boot-time CPU isolation is mandatory and unconditional: every install
   carves CPU N out of the kernel via GRUB tokens isolcpus=managed_irq,
   domain,<list> irqaffinity=<except-list> nohz_full=<list> rcu_nocbs=<list>
   psi=0. <list> = N plus its HT sibling unless --park-ht-sibling=off.
   Evicts managed IRQs (NVMe queues, etc.) and per-CPU kworker chains from
   the isolated CPUs. Reboot required after install.)

  --park-ht-sibling=off   Disable HT sibling parking. By default the
                          boot isolation token set isolates BOTH
                          CPU N and its hyperthread sibling — the two
                          logical CPUs share L1+L2 caches on the same
                          physical core, so leaving the sibling
                          schedulable evicts the RT thread's caches
                          under memory pressure. Empirically (validated
                          2026-05-18 on i5-13600KF, 16 GiB DDR5) parking
                          the sibling cuts memory-stress max jitter from
                          537 µs to 253 µs (-53 %) and spike density
                          from 100 to 49 (-51 %) over 3-min phases.
                          Only use --park-ht-sibling=off on hosts where
                          the sibling is needed for other load (uncommon
                          on 4+-core machines).

  -h, --help              Show this message.
HELP
            exit 0
            ;;
        *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
done

if [ -n "$DRIVER_FLAG_OVERRIDE" ]; then
    case "$DRIVER_FLAG_OVERRIDE" in
        igb|igc|generic) ;;
        *) echo "ERROR: --driver must be one of: igb, igc, generic. Got: $DRIVER_FLAG_OVERRIDE" >&2; exit 1 ;;
    esac
fi

# =========================================================================
# 1. Root check
# =========================================================================
if [ "$(id -u)" -ne 0 ]; then
    error "Must run as root (sudo)."
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [ -z "$REAL_USER" ]; then
    error "Could not determine the non-root user. Run with sudo, not as root directly."
fi

# =========================================================================
# 2. Validate EtherCAT CPU
# =========================================================================
NPROC=$(nproc)

if [ "$ECAT_CPU" -ge "$NPROC" ]; then
    error "ecat-cpu=$ECAT_CPU but system only has $NPROC cores (0-$((NPROC-1)))."
fi
if [ "$ECAT_CPU" -eq 0 ]; then
    error "ecat-cpu=0 is not supported — CPU 0 is the kernel's housekeeping core.\n  Pick any other core (2 is the conventional default)."
fi
if [ "$NPROC" -lt 2 ]; then
    error "Single-CPU system detected (nproc=$NPROC). Cannot isolate an RT CPU."
fi

# =========================================================================
# 3. Auto-detect network interface
# =========================================================================
# Selection produces three values, set by every path below:
#   INTERFACE      — netdev name (real, or derived from BDF for a NIC that
#                    has no netdev because a native driver claimed its slot)
#   MAC_ADDR       — the NIC's MAC (for MASTER0_DEVICE / main_devices)
#   SEL_BDF        — the NIC's PCI BDF (source of truth for chipset + the
#                    native driver_override pin in section [native] below)
SEL_BDF=""
SEL_NETDEVLESS=0   # 1 when the chosen NIC currently has no kernel netdev

# Resolve an explicitly-requested interface (--interface / ECAT_INTERFACE).
# Normal case: it still has a netdev -> read MAC + BDF straight from sysfs.
# Re-install case: the NIC is already bound to ec_igb/ec_igc so its netdev
# is gone — match the requested name against the predictable name of each
# native-bound PCI slot and recover the MAC from the persisted main_devices.
resolve_explicit_iface() {
    local pref="$1" drv link bdf
    if [ -d "/sys/class/net/$pref/device" ]; then
        INTERFACE="$pref"
        SEL_BDF=$(basename "$(readlink -f /sys/class/net/$pref/device 2>/dev/null)" 2>/dev/null || echo "")
        MAC_ADDR=$(ip link show "$pref" 2>/dev/null | awk '/ether/ {print $2}')
        SEL_NETDEVLESS=0
        return 0
    fi
    for drv in ec_igb ec_igc; do
        [ -d "/sys/bus/pci/drivers/$drv" ] || continue
        for link in /sys/bus/pci/drivers/$drv/0000:*; do
            [ -e "$link" ] || continue
            bdf=$(basename "$link")
            if [ "$(ifname_from_bdf "$bdf")" = "$pref" ]; then
                INTERFACE="$pref"
                SEL_BDF="$bdf"
                SEL_NETDEVLESS=1
                MAC_ADDR=$(tr -d '[:space:]' < "$ECAT_STATE_DIR/main_devices" 2>/dev/null || echo "")
                return 0
            fi
        done
    done
    return 1
}

EXPLICIT_IFACE="$INTERFACE"
[ -z "$EXPLICIT_IFACE" ] && EXPLICIT_IFACE="${ECAT_INTERFACE:-}"
INTERFACE=""

if [ -n "$EXPLICIT_IFACE" ]; then
    if ! resolve_explicit_iface "$EXPLICIT_IFACE"; then
        error "Interface '$EXPLICIT_IFACE' has no netdev and isn't bound to a native EtherCAT driver.\n  Run 'ip link' (live NICs) or 'ecat_setup.sh' with no --interface to see the full menu."
    fi
else
    # Build the candidate list. Two sources, because a NIC already bound to
    # a native EtherCAT driver (ec_igb/ec_igc) has NO netdev and would
    # otherwise be invisible — which is exactly how the EtherCAT NIC itself
    # silently dropped out of the menu after the first native install.
    CAND_IFACE=(); CAND_BDF=(); CAND_MAC=(); CAND_DRV=(); CAND_NETDEVLESS=()

    # (1) NICs that currently have a kernel netdev.
    while read -r iface; do
        case "$iface" in
            lo|wl*|docker*|veth*|br-*|virbr*) continue ;;
        esac
        [ -d "/sys/class/net/$iface/device" ] || continue
        CAND_IFACE+=("$iface")
        CAND_BDF+=("$(basename "$(readlink -f /sys/class/net/$iface/device 2>/dev/null)" 2>/dev/null || echo "")")
        CAND_MAC+=("$(ip link show "$iface" 2>/dev/null | awk '/ether/ {print $2}')")
        CAND_DRV+=("$(basename "$(readlink -f /sys/class/net/$iface/device/driver 2>/dev/null)" 2>/dev/null || echo "unknown")")
        CAND_NETDEVLESS+=("0")
    done < <(ip -o link show | awk -F': ' '{print $2}')

    # (2) Ethernet NICs with no netdev because ec_igb/ec_igc already owns the
    #     slot. MAC isn't readable while the native driver is bound, so we
    #     recover the one persisted at the last setup (single EtherCAT NIC =
    #     the common case; the menu still lets the operator pick anything).
    STORED_MAC=$(tr -d '[:space:]' < "$ECAT_STATE_DIR/main_devices" 2>/dev/null || echo "")
    for drv in ec_igb ec_igc; do
        [ -d "/sys/bus/pci/drivers/$drv" ] || continue
        for link in /sys/bus/pci/drivers/$drv/0000:*; do
            [ -e "$link" ] || continue
            bdf=$(basename "$link")
            [ -d "/sys/bus/pci/devices/$bdf/net" ] && continue   # has a netdev -> already in (1)
            CAND_IFACE+=("$(ifname_from_bdf "$bdf")")
            CAND_BDF+=("$bdf")
            CAND_MAC+=("$STORED_MAC")
            CAND_DRV+=("$drv")
            CAND_NETDEVLESS+=("1")
        done
    done

    NCAND=${#CAND_IFACE[@]}
    if [ "$NCAND" -eq 0 ]; then
        error "No physical ethernet interfaces found. Use --interface IFACE."
    elif [ "$NCAND" -eq 1 ]; then
        SEL=0
    else
        echo ""
        echo "Ethernet interfaces detected:"
        # Default index preference: (1) the NIC already running EtherCAT
        # (bound to ec_igb/ec_igc) — almost certainly the bus NIC; else
        # (2) the first NIC with a native driver in scope.
        DEFAULT_IDX=""
        NATIVE_IDX=""
        for i in "${!CAND_IFACE[@]}"; do
            chip_drv=$(chipset_for_bdf "${CAND_BDF[$i]}")
            tag=""
            if [ "${CAND_NETDEVLESS[$i]}" = "1" ]; then
                link_status="(sin netdev)"
                tag="  [${chip_drv%% *} — EN USO por EtherCAT (${CAND_DRV[$i]})]"
                [ -z "$DEFAULT_IDX" ] && DEFAULT_IDX="$((i+1))"
            else
                carrier=$(cat "/sys/class/net/${CAND_IFACE[$i]}/carrier" 2>/dev/null || echo "?")
                [ "$carrier" = "1" ] && link_status="link UP" || link_status="link DOWN"
                if [ -n "$chip_drv" ]; then
                    tag="  [${chip_drv%% *} — driver nativo ec_${chip_drv##* } disponible, evita NAPI/softirq]"
                    [ -z "$NATIVE_IDX" ] && NATIVE_IDX="$((i+1))"
                fi
            fi
            echo "  [$((i+1))] ${CAND_IFACE[$i]}  MAC=${CAND_MAC[$i]:-?}  driver=${CAND_DRV[$i]}  $link_status$tag"
        done
        [ -z "$DEFAULT_IDX" ] && DEFAULT_IDX="$NATIVE_IDX"
        echo ""
        warn "The selected port will be dedicated to EtherCAT and marked unmanaged by NetworkManager."
        warn "It will not get an IP address, DHCP, or mDNS — only EtherCAT frames cross it while the daemon runs."
        echo ""
        if [ -n "$DEFAULT_IDX" ]; then
            read -rp "Select interface for EtherCAT [1-$NCAND] (default: $DEFAULT_IDX): " CHOICE
            [ -z "$CHOICE" ] && CHOICE="$DEFAULT_IDX"
        else
            read -rp "Select interface for EtherCAT [1-$NCAND]: " CHOICE
        fi
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$NCAND" ]; then
            SEL=$((CHOICE-1))
        else
            error "Invalid selection. Use --interface IFACE to specify explicitly."
        fi
    fi

    INTERFACE="${CAND_IFACE[$SEL]}"
    MAC_ADDR="${CAND_MAC[$SEL]}"
    SEL_BDF="${CAND_BDF[$SEL]}"
    SEL_NETDEVLESS="${CAND_NETDEVLESS[$SEL]}"
fi

if [ -z "$MAC_ADDR" ]; then
    if [ "$SEL_NETDEVLESS" = "1" ]; then
        error "'$INTERFACE' is bound to a native EtherCAT driver but its MAC couldn't be recovered from $ECAT_STATE_DIR/main_devices.\n  Run a generic setup first (sudo ecat_setup.sh --driver generic) so the MAC is recorded, then re-run."
    fi
    error "Could not get MAC address for interface '$INTERFACE'."
fi

# Pick the IgH driver based on chipset:
#   I210 -> ec_igb (mature, IgH 1.6 stable)
#   I226 -> ec_igc (newer; may need IgH patches on some kernels — the
#                    configure log under /tmp/igh-configure.log surfaces
#                    that case clearly).
# Both replace the kernel driver and process frames inside the master
# kthread (no NAPI/softirq). For any other chipset we fall back to
# ec_generic, which works with the kernel driver in place but goes
# through the regular network stack.
# Chipset is keyed off the PCI BDF (chipset_for_bdf) so it resolves even
# when the NIC has no netdev because ec_igb/ec_igc already owns the slot.
DRIVER_NAME=$(basename "$(readlink -f /sys/bus/pci/devices/$SEL_BDF/driver 2>/dev/null)" 2>/dev/null || echo "unknown")
CHIPSET_FRIENDLY=""
DRIVER_CANDIDATE=""
case "$(chipset_for_bdf "$SEL_BDF")" in
    "I210 igb") DRIVER_CANDIDATE="igb"; CHIPSET_FRIENDLY="Intel I210" ;;
    "I226 igc") DRIVER_CANDIDATE="igc"; CHIPSET_FRIENDLY="Intel I226" ;;
    *)          DRIVER_CANDIDATE="generic"; CHIPSET_FRIENDLY="$DRIVER_NAME" ;;
esac

# Kernel-too-new check for native igb. Upstream IgH stable-1.6 / 1.7 cap
# the bundled igb source at kernel 6.12. On newer kernels the IgH
# configure step fails with 'kernel X not available for igb driver!'.
# The kernel_patches/igh_sittner_igb/ directory ships per-kernel
# patch sets (kernel_<MAJOR.MINOR>/) that forward-port sittner stable-1.6.
# Each subfolder is INDEPENDENTLY validated on its target kernel — applying
# a 6.17 patch on a 6.14 host would break the build, not fix it, because
# the new symbols (timer_container_of, notified arg, non-const cyclecounter)
# don't exist on 6.14 yet. Hence we route operators to the exact folder
# matching their kernel.
version_ge() {
    # version_ge "$1" "$2" -> 0 if $1 >= $2 (semver-ish: NN.NN[.NN])
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Compute whether the native driver path is buildable on this host, and
# stage any patch-set state needed for the build step below.
#   NATIVE_AVAILABLE  — "true" if the menu should offer the native option
#   IGB_PATCH_SET_DIR — absolute path to the vendored patches (igb only)
#   IGB_BASE_KERNEL   — argument for --with-igb-kernel when patches apply
NATIVE_AVAILABLE="false"
IGB_PATCH_SET_DIR=""
IGB_BASE_KERNEL=""
KERNEL_REL=$(uname -r | cut -d- -f1)             # e.g. 6.17.0
KERNEL_XY=$(echo "$KERNEL_REL" | cut -d. -f1-2)  # e.g. 6.17

if [ "$DRIVER_CANDIDATE" = "igb" ] || [ "$DRIVER_CANDIDATE" = "igc" ]; then
    if ! version_ge "$KERNEL_REL" "6.13"; then
        # Upstream sittner stable-1.6 covers igb/igc directly on <6.13.
        NATIVE_AVAILABLE="true"
    elif [ "$DRIVER_CANDIDATE" = "igb" ]; then
        # Validation gate: a kernel folder is hardware-validated iff it
        # contains a 'VALIDATED' sentinel file (with the validation record
        # in its body). Folders without that file are predicted/draft —
        # in those cases we don't offer native in the menu, because the
        # prediction may be wrong and the build would fail outright.
        # Operators on a non-validated kernel who specifically need native
        # should validate locally first and then add the VALIDATED file.
        # Resolve patches root across both deployment layouts:
        #   source tree   : scripts/ecat_setup.sh  + ../kernel_patches/
        #   ament install : lib/<pkg>/ecat_setup.sh + ../../share/<pkg>/kernel_patches/
        # (tk_binaries follows the ament install layout.) First hit wins;
        # if neither exists we log both paths so packaging gaps surface
        # immediately instead of silently routing to ec_generic.
        SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
        PATCHES_CANDIDATES=(
            "$SCRIPT_DIR/../kernel_patches/igh_sittner_igb"
            "$SCRIPT_DIR/../../share/tk_ros2_pkg_ethercat_master/kernel_patches/igh_sittner_igb"
        )
        PATCHES_ROOT=""
        for cand in "${PATCHES_CANDIDATES[@]}"; do
            if [ -d "$cand" ]; then
                PATCHES_ROOT="$cand"
                break
            fi
        done
        if [ -z "$PATCHES_ROOT" ]; then
            warn "Native ec_igb on kernel $KERNEL_REL: kernel_patches/ not shipped with this install."
            warn "  Searched:"
            for cand in "${PATCHES_CANDIDATES[@]}"; do
                warn "    - $cand"
            done
            warn "  Recommending ec_generic. Re-install from a build that ships kernel_patches/"
            warn "  (CMakeLists.txt installs share/<pkg>/kernel_patches/ and auto_compiler"
            warn "  copies it into tk_binaries)."
        fi
        HOST_SET="${PATCHES_ROOT}/kernel_${KERNEL_XY}"
        if [ -n "$PATCHES_ROOT" ] && [ -d "$HOST_SET" ] && [ -f "$HOST_SET/VALIDATED" ]; then
            patch_count=$(find "$HOST_SET" -maxdepth 1 -name '*.patch' 2>/dev/null | wc -l)
            NATIVE_AVAILABLE="true"
            if [ "$patch_count" -gt 0 ]; then
                # sittner stable-1.6 caps the bundled igb at kernel 6.12;
                # the vendored patch sets all forward-port that 6.12 base.
                IGB_PATCH_SET_DIR="$HOST_SET"
                IGB_BASE_KERNEL="6.12"
                info "Native ec_igb path on kernel $KERNEL_REL: VALIDATED."
                info "  Patch set: kernel_patches/igh_sittner_igb/kernel_${KERNEL_XY}/ ($patch_count patches)"
                info "  Apply mode: automatic (this script will git am the patches before configure)"
            else
                info "Native ec_igb path on kernel $KERNEL_REL: VALIDATED."
                info "  No patches required — sittner stable-1.6 builds directly on this kernel."
            fi
        elif [ -n "$PATCHES_ROOT" ]; then
            # PATCHES_ROOT found, but this kernel's folder is missing or
            # unvalidated. (The "kernel_patches/ not shipped at all" case
            # already warned above with the searched paths.)
            warn "Native ec_igb on kernel $KERNEL_REL is NOT VALIDATED in this repo."
            if [ -d "$HOST_SET" ]; then
                warn "  Folder kernel_${KERNEL_XY}/ exists but lacks the VALIDATED sentinel"
                warn "  (its contents are predicted, not hardware-tested)."
            else
                warn "  No kernel_${KERNEL_XY}/ folder exists at all."
            fi
            warn "  Recommending ec_generic. To validate native here yourself, build it"
            warn "  manually then 'touch kernel_patches/igh_sittner_igb/kernel_${KERNEL_XY}/VALIDATED'"
            warn "  and contribute the record back."
        fi
    else
        # DRIVER_CANDIDATE = igc on kernel >= 6.13. No vendored igc patch
        # set is shipped yet; the upstream configure would fail similarly
        # to the igb case. Recommend generic until a kernel_patches/
        # igh_sittner_igc/ tree exists.
        warn "Native ec_igc on kernel $KERNEL_REL is not yet covered by vendored patches."
        warn "  Recommending ec_generic."
    fi
fi

# Driver selection. Always offers ec_generic as a fallback. Native
# (ec_igb / ec_igc) is offered only when the chipset supports it AND
# the kernel has a path to the native build (either upstream covers it
# directly, or our vendored patch set is VALIDATED). Default highlights
# the recommended path but the operator can always override.
# Non-interactive bypass: --driver flag.
if [ -n "$DRIVER_FLAG_OVERRIDE" ]; then
    DRIVER="$DRIVER_FLAG_OVERRIDE"
elif [ "$NATIVE_AVAILABLE" = "true" ]; then
    echo ""
    echo "Driver selection for $CHIPSET_FRIENDLY on kernel $KERNEL_REL:"
    echo "  1) ec_$DRIVER_CANDIDATE  — native (recommended; bypasses NAPI/softirq)"
    echo "  2) ec_generic   — kernel net stack (safe fallback; works on every kernel)"
    while true; do
        read -rp "Select driver [1-2] (default: 1): " CHOICE
        CHOICE="${CHOICE:-1}"
        case "$CHOICE" in
            1) DRIVER="$DRIVER_CANDIDATE"; break ;;
            2) DRIVER="generic"; break ;;
            *) echo "Invalid selection." ;;
        esac
    done
else
    DRIVER="generic"
fi

# If the operator ended up on generic (via menu pick or flag) on a host
# whose candidate was native, drop any igb patch state so the build path
# below doesn't apply patches or pass --with-igb-kernel.
if [ "$DRIVER" = "generic" ]; then
    IGB_PATCH_SET_DIR=""
    IGB_BASE_KERNEL=""
fi

# Persist the chosen MAC so ecat_diag.sh can resolve the EtherCAT NIC even
# when ec_master isn't currently loaded. Without this, diag's nic_detect()
# falls back to an alphabetical scan of /sys/class/net and may report on
# the wrong interface (e.g. eno1 instead of enp133s0) on multi-NIC hosts.
mkdir -p "$ECAT_STATE_DIR"
echo "$MAC_ADDR" > "$ECAT_STATE_DIR/main_devices"

# Detect "this is a re-install vs first install" purely from the sentinel
# the previous run (if any) wrote. Lets banners differ without exposing a
# user-facing flag for it.
IS_REINSTALL=false
[ -f "$INSTALL_VERSION_FILE" ] && IS_REINSTALL=true

echo ""
echo "============================================"
if [ "$IS_REINSTALL" = true ]; then
    echo "  EtherCAT setup — refresh"
else
    echo "  EtherCAT setup — first install"
fi
echo "============================================"
echo ""
echo "  User:      $REAL_USER"
echo "  ECAT CPU:  $ECAT_CPU"
echo "  Interface: $INTERFACE ($MAC_ADDR)"
case "$DRIVER" in
    igb|igc)
        echo "  Chipset:   $CHIPSET_FRIENDLY (kernel driver: $DRIVER_NAME)"
        echo "  Driver:    ec_$DRIVER (native — bypasses NAPI/softirq)"
        ;;
    *)
        if [ "$DRIVER_CANDIDATE" = "igb" ] || [ "$DRIVER_CANDIDATE" = "igc" ]; then
            echo "  Chipset:   $CHIPSET_FRIENDLY (kernel driver: $DRIVER_NAME) — native skipped"
        else
            echo "  Chipset:   $DRIVER_NAME (no native IgH driver in scope)"
        fi
        echo "  Driver:    ec_generic (frames traverse NAPI/softirq)"
        ;;
esac
echo "  Cores:     $NPROC"
echo "  Kernel:    $KERNEL_VER"
if [ "$IS_REINSTALL" = true ]; then
    PRIOR=$(cat "$INSTALL_VERSION_FILE" 2>/dev/null || echo unknown)
    echo "  Prior:     installed version $PRIOR (re-asserting artifacts)"
else
    echo ""
    echo "  This runs once. From now on, just launch the daemon —"
    echo "  the launcher creates the partition fresh ('ecat-cgroup up') and"
    echo "  re-applies caps, without ever asking for sudo."
fi
echo ""

if [ "$DRIVER" = "generic" ]; then
    if [ "$DRIVER_CANDIDATE" = "igb" ] || [ "$DRIVER_CANDIDATE" = "igc" ]; then
        warn "Using ec_generic on $CHIPSET_FRIENDLY (native ec_$DRIVER_CANDIDATE was available but not selected)."
        warn "Frames will traverse Linux NAPI/softirq instead of the master kthread."
        warn "Re-run with --driver $DRIVER_CANDIDATE (or pick option 1 in the menu) to switch to native."
    else
        warn "Chipset '$DRIVER_NAME' on $INTERFACE has no native IgH driver in scope."
        warn "Falling back to ec_generic. EtherCAT frames will traverse Linux NAPI/softirq,"
        warn "which adds a jitter floor that user-space isolation cannot bound. For"
        warn "industrial-grade determinism on production hosts, install an Intel I210"
        warn "(1 GbE) or I226 (2.5 GbE) PCIe NIC (~25-35€) and re-run sudo ecat_setup.sh —"
        warn "it will auto-detect the chipset and switch to ec_igb / ec_igc accordingly."
    fi
    echo ""
fi

# =========================================================================
# 4. IgH EtherCAT Master — check and install if needed [1/4]
# =========================================================================
echo "--- [1/5] IgH EtherCAT Master ---"

IGH_INSTALLED=true
IGH_NEEDS_REBUILD=false

# Check each component
if modinfo ec_master &>/dev/null; then
    MOD_KERNEL=$(modinfo -F vermagic ec_master 2>/dev/null | awk '{print $1}')
    MOD_FILE=$(modinfo -F filename ec_master 2>/dev/null)
    if [ "$MOD_KERNEL" != "$KERNEL_VER" ]; then
        warn "  ec_master built for $MOD_KERNEL, running $KERNEL_VER"
        IGH_NEEDS_REBUILD=true
    elif [ -f "$MOD_FILE" ] && nm --defined-only "$MOD_FILE" 2>/dev/null \
            | grep -qE '\bec_master_eoe_thread\b|\bec_eoe_run\b'; then
        # The kernel EoE thread spawns inside ecrt_request_master()'s bus
        # scan and its probe traffic races slave CoE mailboxes (we observed
        # EX600 SDO walks latching dead at 0x1C00:0). EoE is unused on
        # this stack — no slave needs IP-over-EtherCAT — so we want the
        # module rebuilt without it. Symbol presence is the canonical
        # signal: those two functions only get linked when EC_EOE is
        # defined at configure.
        warn "  ec_master built with EoE enabled — rebuilding with --disable-eoe"
        IGH_NEEDS_REBUILD=true
    else
        info "  Kernel module: OK"
    fi
else
    IGH_INSTALLED=false
fi

[ -f "$INSTALL_PREFIX/lib/libethercat.so" ] || IGH_INSTALLED=false
[ -f "$INSTALL_PREFIX/include/ecrt.h" ]     || IGH_INSTALLED=false
command -v ethercat &>/dev/null              || IGH_INSTALLED=false

# Driver-specific module presence. If the active driver is a native one
# (ec_igb / ec_igc) but the corresponding module isn't installed, the
# currently-installed IgH was built without --enable-igb / --enable-igc —
# rebuild to add it. ec_generic is always built.
if [ "$IGH_INSTALLED" = true ] && [ "$IGH_NEEDS_REBUILD" = false ]; then
    case "$DRIVER" in
        igb|igc)
            if ! modinfo "ec_$DRIVER" &>/dev/null; then
                warn "  ec_$DRIVER module not present — installed IgH was built without --enable-$DRIVER. Rebuilding."
                IGH_NEEDS_REBUILD=true
            fi
            ;;
    esac
fi

if [ "$IGH_INSTALLED" = true ] && [ "$IGH_NEEDS_REBUILD" = false ]; then
    info "  IgH EtherCAT Master already installed and up-to-date."
else
    if [ "$IGH_INSTALLED" = true ]; then
        info "  IgH installed but kernel module needs rebuild."
    else
        info "  IgH EtherCAT Master not found. Installing..."
    fi

    # -- Install build dependencies --
    info "  Installing build dependencies..."
    apt-get update -qq 2>/dev/null
    # linux-headers-<ver> is a thin arch-specific package that depends on the
    # common headers (e.g. linux-hwe-6.17-headers-<ver>). Install both
    # explicitly in case the dependency wasn't pulled in properly.
    COMMON_HEADERS=$(apt-cache depends "linux-headers-$KERNEL_VER" 2>/dev/null \
        | grep -oP 'Depends:\s+\Klinux.*headers.*' || true)
    # Tolerate DKMS post-install hook failures from OTHER kernel-image
    # packages already on the host (e.g. linux-image-6.17.0-20, -22). When
    # apt-get install runs, dpkg triggers DKMS rebuilds for every installed
    # kernel; an unrelated module failing to build for one of those kernels
    # crashes dpkg with exit 100, but the headers we actually need have
    # already been installed and verified below. Suppress the trailing
    # failure so our own install path stays robust.
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        git autoconf automake libtool pkg-config make gcc g++ \
        linux-headers-$KERNEL_VER $COMMON_HEADERS \
        > /dev/null 2>&1 || true

    # Verify the kernel build dir has a Makefile (required for module build)
    if [ ! -f "$KERNEL_HEADERS/Makefile" ]; then
        error "  Kernel headers installed but $KERNEL_HEADERS/Makefile not found.\n  Try: sudo apt install linux-headers-$KERNEL_VER"
    fi
    info "  Build dependencies ready."

    # -- Ensure System.map is visible to kernel build dir --
    # IgH's make modules_install looks for System.map in the headers dir,
    # not /boot/. Without it, module install silently fails.
    if [ ! -f "$KERNEL_HEADERS/System.map" ] && [ -f "/boot/System.map-$KERNEL_VER" ]; then
        ln -sf "/boot/System.map-$KERNEL_VER" "$KERNEL_HEADERS/System.map"
        info "  Symlinked System.map into kernel headers dir."
    fi

    # -- Clone / update source --
    if [ -d "$BUILD_DIR" ]; then
        info "  Updating source..."
        cd "$BUILD_DIR"
        git fetch --all --quiet
        git checkout "$IGH_BRANCH" --quiet
        git pull --quiet
        # Wipe cached build artifacts. Bare configure+make would lean on
        # gcc dependency tracking to spot config.h changes (e.g. flipping
        # --disable-eoe) — reliable in theory, but after enough kernel
        # bumps and abandoned partial builds the tree accumulates stale
        # .o/.cmd files that quietly survive into the new module. Cheap
        # to redo from scratch (~30 s), expensive to debug a half-rebuilt
        # ec_master.ko.
        git clean -fdx --quiet
    else
        info "  Cloning IgH EtherCAT Master ($IGH_BRANCH)..."
        git clone --branch "$IGH_BRANCH" "$IGH_REPO" "$BUILD_DIR" --quiet
        cd "$BUILD_DIR"
    fi

    # -- Apply vendored igb patches (if a VALIDATED set was staged above) --
    # git clean -fdx above already wiped any previous run's patches, so the
    # tree is at a clean sittner HEAD and we re-apply from scratch every time.
    # git am -3 falls back to 3-way merge if sittner has rebased stable-1.6
    # since the patches were generated.
    if [ -n "$IGB_PATCH_SET_DIR" ]; then
        patch_count=$(find "$IGB_PATCH_SET_DIR" -maxdepth 1 -name '*.patch' | wc -l)
        info "  Applying $patch_count vendored igb patch(es) for kernel $KERNEL_XY..."
        # git am needs author identity. Configure locally so we don't touch
        # the operator's global git config.
        git config user.email "ecat-setup@theker.local"
        git config user.name  "ecat-setup wrapper"
        for p in "$IGB_PATCH_SET_DIR"/*.patch; do
            if ! git am -3 "$p" > /tmp/igh-patch.log 2>&1; then
                git am --abort >/dev/null 2>&1 || true
                error "  Failed to apply $(basename "$p"). See /tmp/igh-patch.log\n  Hint: sittner stable-1.6 may have rebased — patches may need refresh."
            fi
        done
    fi

    # -- Bootstrap + Configure + Build --
    info "  Bootstrapping..."
    ./bootstrap > /dev/null 2>&1

    # Dynamic --enable-igb / --enable-igc when the chosen NIC is an
    # I210 / I226 respectively. ec_generic stays enabled in all builds so
    # /etc/sysconfig/ethercat can flip the active driver without a rebuild
    # (e.g. for A/B-testing or as a fallback if the native driver has
    # trouble on the current kernel — surfaced via /tmp/igh-configure.log).
    EXTRA_ENABLE_FLAGS=""
    DRIVER_LIST="generic"
    case "$DRIVER" in
        igb)
            EXTRA_ENABLE_FLAGS="--enable-igb"
            DRIVER_LIST="generic, igb"
            ;;
        igc)
            EXTRA_ENABLE_FLAGS="--enable-igc"
            DRIVER_LIST="generic, igc"
            ;;
    esac

    # When a vendored igb patch set is staged, point IgH at the 6.12 igb
    # source base (the one the patches forward-port). Without this flag,
    # IgH's configure defaults to the running kernel version and aborts
    # with "kernel X not available for igb driver!" on kernels past 6.12.
    EXTRA_IGB_FLAGS=""
    if [ -n "$IGB_BASE_KERNEL" ]; then
        EXTRA_IGB_FLAGS="--with-igb-kernel=$IGB_BASE_KERNEL"
    fi

    info "  Configuring (drivers: $DRIVER_LIST, kernel $KERNEL_VER)..."
    # --disable-eoe: closes the EoE-thread vs CoE-mailbox race that stalls
    # EX600 SDO walks at PREOP. EoE is unused on this bench (no slave needs
    # IP-over-EtherCAT), so disabling it removes the auto-spawned eoe0sN
    # interfaces and the kernel EoE thread entirely.
    # configure output goes to /tmp/igh-configure.log so a failure (e.g.
    # ec_igb patch not applying on a newer kernel) is diagnosable instead
    # of getting swallowed by /dev/null.
    if ! ./configure \
        --prefix="$INSTALL_PREFIX" \
        --with-linux-dir="$KERNEL_HEADERS" \
        --enable-generic \
        $EXTRA_ENABLE_FLAGS \
        $EXTRA_IGB_FLAGS \
        --disable-eoe \
        --disable-8139too \
        --disable-e100 \
        --disable-e1000 \
        --disable-e1000e \
        --disable-r8169 \
        > /tmp/igh-configure.log 2>&1; then
        error "  './configure' failed. See /tmp/igh-configure.log for details:\n  tail -50 /tmp/igh-configure.log"
    fi

    info "  Building userspace with $(nproc) cores..."
    if ! make -j"$(nproc)" > /dev/null 2>&1; then
        error "  'make' failed. Re-run without output suppression to diagnose:\n  cd $BUILD_DIR && make -j$(nproc)"
    fi

    info "  Building kernel modules..."
    if ! make modules -j"$(nproc)" > /dev/null 2>&1; then
        error "  'make modules' failed. Re-run without output suppression to diagnose:\n  cd $BUILD_DIR && make modules -j$(nproc)"
    fi

    # -- Install --
    info "  Installing library + headers..."
    if ! make install > /dev/null 2>&1; then
        error "  'make install' failed. Re-run without output suppression to diagnose:\n  cd $BUILD_DIR && make install"
    fi

    info "  Installing kernel modules..."
    if ! make modules_install 2>&1 | tail -5; then
        error "  'make modules_install' failed."
    fi
    depmod -a || error "  'depmod -a' failed."

    # Verify module was actually installed
    if ! modinfo ec_master &>/dev/null; then
        error "  Build completed but ec_master module not found in /lib/modules/$KERNEL_VER/. Check 'make modules_install' output above."
    fi
    info "  Kernel module verified: $(modinfo -F filename ec_master)"

    # -- ldconfig --
    echo "$INSTALL_PREFIX/lib" > /etc/ld.so.conf.d/ethercat.conf
    ldconfig

    info "  IgH EtherCAT Master installed."
fi

# -- IgH sysconfig (always ensure it's correct for the current interface) --
IGH_SYSCONFIG="$INSTALL_PREFIX/etc/sysconfig/ethercat"
mkdir -p "$(dirname "$IGH_SYSCONFIG")"
cat > "$IGH_SYSCONFIG" <<EOF
# IgH EtherCAT Master configuration
# Generated by ecat_setup.sh on $(date -Iseconds)

MASTER0_DEVICE="$MAC_ADDR"
MASTER0_BACKUP=""
DEVICE_MODULES="$DRIVER"
UPDOWN_INTERFACES="$INTERFACE"
EOF
info "  Config: $IGH_SYSCONFIG ($INTERFACE / $MAC_ADDR / ec_$DRIVER)"

# -- systemd service: on-demand modprobe (NOT enabled at boot) --
# This service is started by ecat_daemon_start.sh when the daemon launches and
# stopped on daemon exit. The NIC is permanently marked unmanaged by
# NetworkManager (see section [2/5] above), so while the daemon is stopped
# the port is administratively idle — no IP, no DHCP, no mDNS. While
# started, the IgH driver binds to the NIC by MAC for EtherCAT frames.
#
# The unit template diverges between ec_generic and native ec_igb / ec_igc:
#   - generic: NIC keeps a kernel netdev ($INTERFACE). EEE / PAUSE /
#     offloads are disabled on it via ethtool before EtherCAT frames flow,
#     and the link is cycled at stop for a clean next bringup.
#   - igb / igc: ec_$DRIVER takes over the PCI slot, so the kernel netdev
#     $INTERFACE ceases to exist once it binds. /sbin/ip / ethtool on the
#     netdev would just error out (used to "work" only because stock igb
#     was incorrectly co-bound — see /etc/modprobe.d/tk-ethercat-ec_*.conf
#     below for the driver_override pin that fixes that). EEE / PAUSE /
#     offload tunings still matter for jitter; in native mode they belong
#     inside ec_$DRIVER itself (each kernel_patches/ port carries them).
if [ "$DRIVER" = "generic" ]; then
    cat > /etc/systemd/system/ethercat.service <<EOF
[Unit]
Description=IgH EtherCAT Master (on-demand)
After=sys-subsystem-net-devices-${INTERFACE}.device
Wants=sys-subsystem-net-devices-${INTERFACE}.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/ip link set dev $INTERFACE up
# NIC link-layer tuning. PAUSE frames can stall Tx for quanta*5.12us (up
# to ~33ms at 100Mb/s) when a slave's MAC emits an 802.3x PAUSE — some
# DS402 drives do this under SDO-burst buffer pressure. EEE LPI entry/exit
# adds ~100us-1ms jitter on the I210 even when the link partner doesn't
# advertise EEE. GRO/GSO/TSO never aggregate L2 EtherCAT frames but their
# NAPI bookkeeping still runs per-frame. VLAN offloads are useless on a
# port that only carries raw EtherCAT EtherType 0x88A4. The "-" prefix
# tolerates drivers that reject specific flags (e.g. I210 firmware revs
# that return EOPNOTSUPP on --set-eee).
ExecStartPre=-/sbin/ethtool -A $INTERFACE autoneg off rx off tx off
ExecStartPre=-/sbin/ethtool --set-eee $INTERFACE eee off
ExecStartPre=-/sbin/ethtool -K $INTERFACE gro off gso off tso off rxvlan off txvlan off
ExecStart=/sbin/modprobe ec_master main_devices=$MAC_ADDR run_on_cpu=$ECAT_CPU
ExecStartPost=/sbin/modprobe ec_$DRIVER
ExecStop=/sbin/rmmod ec_$DRIVER
ExecStop=/sbin/rmmod ec_master
# Cycle the link after rmmod so the NIC is in a clean state for the next
# bringup. NM doesn't reclaim the port (it's marked unmanaged in
# /etc/NetworkManager/conf.d/99-tk-ethercat.conf), so this is purely for
# driver cleanliness. The "-" prefix tolerates failures.
ExecStop=-/sbin/ip link set dev $INTERFACE down
ExecStop=-/sbin/ip link set dev $INTERFACE up
EOF
else
    cat > /etc/systemd/system/ethercat.service <<EOF
[Unit]
Description=IgH EtherCAT Master (on-demand, native ec_$DRIVER)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe ec_master main_devices=$MAC_ADDR run_on_cpu=$ECAT_CPU
ExecStartPost=/sbin/modprobe ec_$DRIVER
# Native driver captures the NIC exclusively, so unloading is the ONLY way to
# release it + reap the [EtherCAT-OP] kthread. After the daemon dies, the IgH
# master/kthread don't drop their module ref instantly — a bare 'rmmod ec_$DRIVER'
# fired immediately races and hits EBUSY ("Module ec_$DRIVER is in use"), which
# under systemd's sequential ExecStop also skips the ec_master rmmod, leaving the
# NIC captured and the kthread orphaned (reboot territory). Retry each rmmod for
# ~5s so the ref has time to drop; best-effort exit 0 so a genuinely-stuck module
# (recovered by the next launch's service cycle) doesn't mark the unit failed.
ExecStop=/bin/sh -c 'for m in ec_$DRIVER ec_master; do for _ in \$(seq 1 50); do /sbin/rmmod \$m 2>/dev/null && break; sleep 0.1; done; done; exit 0'
EOF
fi

systemctl daemon-reload
# Explicitly disable any previous boot-time enablement so the port stays as
# normal Ethernet at boot. Idempotent: harmless if already disabled.
systemctl disable ethercat.service --quiet 2>/dev/null || true
info "  ethercat.service installed (on-demand, NOT enabled at boot)."

# -- Native driver: pin EtherCAT NIC PCI slot to ec_igb / ec_igc ----------
# Without this, the host's stock 'igb' / 'igc' module auto-binds to the
# EtherCAT NIC at boot, blocking ec_$DRIVER from claiming the same PCI
# slot. Symptom: ec_master loads with main_devices=<MAC>, finds no NIC
# bound to ec_$DRIVER, and ecrt_request_master(0) returns ENODEV.
#
# We pin the slot via PCI driver_override = ec_$DRIVER. driver_override
# is consulted on every probe attempt — once set, stock $DRIVER is
# rejected for THIS PCI BDF only (other I210/I226 NICs on the same host
# are unaffected, which a blanket 'blacklist $DRIVER' would break). The
# override survives module unload and reload, so ecat_daemon_start.sh's
# service cycle (stop -> rmmod -> start -> modprobe) no longer races
# against the kernel auto-loading $DRIVER to fill the orphan PCI slot.
#
# Two writes give us both immediate effect and persistence across reboots:
#   1. modprobe.d install rule — fires every time someone modprobes
#      $DRIVER (incl. udev's modalias resolution at boot), setting
#      driver_override on our BDF before the actual module-load happens.
#      update-initramfs -u copies it into the initramfs so the rule
#      applies in early boot before rootfs is mounted (Ubuntu HWE pulls
#      $DRIVER into the initramfs by default).
#   2. Apply driver_override + unbind from current driver right now, so
#      the first daemon launch after setup succeeds without a reboot.
if [ "$DRIVER" = "igb" ] || [ "$DRIVER" = "igc" ]; then
    # PCI BDF of the EtherCAT NIC, e.g. 0000:83:00.0. Already resolved during
    # interface selection (works whether or not the NIC still has a netdev).
    ETHERCAT_BDF="$SEL_BDF"
    if [ -z "$ETHERCAT_BDF" ] || [ ! -d "/sys/bus/pci/devices/$ETHERCAT_BDF" ]; then
        error "Could not resolve PCI BDF for $INTERFACE (got '$ETHERCAT_BDF'). Native ec_$DRIVER setup cannot proceed — re-run with --driver generic."
    fi

    NATIVE_MODPROBE_CONF="/etc/modprobe.d/tk-ethercat-ec_${DRIVER}.conf"
    cat > "$NATIVE_MODPROBE_CONF" <<EOF
# Installed by tk_ros2_pkg_ethercat_master ecat_setup.sh.
# Reserves PCI slot $ETHERCAT_BDF for ec_$DRIVER. Every modprobe of $DRIVER
# (stock kernel driver) is wrapped to first set driver_override=ec_$DRIVER
# on $ETHERCAT_BDF, so $DRIVER's probe skips the EtherCAT NIC. Other
# I210/I226 NICs on this host remain bindable to $DRIVER. Removed by
# ecat_teardown.sh.
#
# modprobe runs 'install' lines via system(3) (sh -c), so shell metachars
# work directly. \$CMDLINE_OPTS is the canonical way to forward args the
# kernel/udev passed to modprobe (e.g. options); it expands to empty for
# the boot-time MODALIAS path, so the no-args case is trivial.
install $DRIVER echo ec_$DRIVER > /sys/bus/pci/devices/$ETHERCAT_BDF/driver_override 2>/dev/null; /sbin/modprobe --ignore-install --quiet $DRIVER \$CMDLINE_OPTS
EOF
    chmod 0644 "$NATIVE_MODPROBE_CONF"
    info "  modprobe rule: $NATIVE_MODPROBE_CONF ($ETHERCAT_BDF pinned to ec_$DRIVER)"

    # Refresh initramfs so the rule applies in early boot. Ubuntu/Debian
    # uses initramfs-tools; Fedora/RHEL uses dracut. If neither is present
    # we warn — the host will still work after the daemon starts (the
    # install rule applies at every modprobe), but kernel auto-load of
    # $DRIVER from initramfs may race the first boot until a manual rebuild.
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u >/dev/null 2>&1 && info "  initramfs rebuilt (rule active at next boot)."
    elif command -v dracut >/dev/null 2>&1; then
        dracut --force >/dev/null 2>&1 && info "  initramfs (dracut) rebuilt (rule active at next boot)."
    else
        warn "  Neither update-initramfs nor dracut found. modprobe rule will only apply post-rootfs-mount; rebuild initramfs manually so it also applies in early boot."
    fi

    # Apply immediately so the next ethercat.service start works without a
    # reboot. driver_override is only consulted on probe, not on already-
    # bound devices, so unbind from $DRIVER first if it's currently bound.
    # After unbind, the slot is unclaimed; ec_$DRIVER will bind on the next
    # modprobe (triggered by ethercat.service ExecStartPost).
    CURRENT_DRV=$(basename "$(readlink -f "/sys/bus/pci/devices/$ETHERCAT_BDF/driver" 2>/dev/null)" 2>/dev/null || echo "")
    echo "ec_$DRIVER" > "/sys/bus/pci/devices/$ETHERCAT_BDF/driver_override"
    if [ "$CURRENT_DRV" = "$DRIVER" ]; then
        echo "$ETHERCAT_BDF" > "/sys/bus/pci/drivers/$DRIVER/unbind" 2>/dev/null || true
        info "  Unbound $ETHERCAT_BDF from $DRIVER; driver_override now ec_$DRIVER."
    else
        info "  driver_override set on $ETHERCAT_BDF (current driver: ${CURRENT_DRV:-none})."
    fi
fi

# =========================================================================
# 4b. Network userspace quarantine — keep NM + avahi off the EtherCAT NIC.
#     [2/5]
# =========================================================================
# Without this, on any default Ubuntu/Fedora desktop, NetworkManager retries
# DHCP on the EtherCAT NIC every ~45 s for the entire daemon lifetime —
# DHCPDISCOVER bursts on the wire add jitter under RT load, and the NIC-RX
# softirq batches occasionally hash onto the RT CPU as multi-millisecond
# outliers. avahi compounds it by multicasting mDNS on the same NIC.
#
# Note: prior versions of this script also quarantined eoe0sN virtual
# interfaces auto-created by IgH for EoE-capable slaves. Since IgH is now
# built with --disable-eoe (see [1/5] above), those netdevs no longer
# exist and the quarantine collapses to the NIC.
# =========================================================================
echo ""
echo "--- [2/5] NetworkManager + avahi quarantine ---"

NM_CONF_DIR="/etc/NetworkManager/conf.d"
NM_KEYFILE="$NM_CONF_DIR/99-tk-ethercat.conf"
AVAHI_CONF="/etc/avahi/avahi-daemon.conf"
AVAHI_BACKUP="/etc/avahi/avahi-daemon.conf.tk-backup"

# --- NetworkManager: mark the EtherCAT NIC as unmanaged. Drop a keyfile
#     rather than mutating runtime state so the setting survives reboots
#     and NM service restarts.
if command -v nmcli &>/dev/null || [ -d /etc/NetworkManager ]; then
    mkdir -p "$NM_CONF_DIR"
    cat > "$NM_KEYFILE" <<EOF
# Installed by tk_ros2_pkg_ethercat_master ecat_setup.sh.
# Removes NetworkManager from the EtherCAT NIC ($INTERFACE). Without
# this, NM injects DHCP / IPv6-LL / mDNS traffic onto the EtherCAT bus,
# causing wkc_drops, jitter excursions, and startup failures.
# Removed by ecat_teardown.sh.
[keyfile]
unmanaged-devices=interface-name:$INTERFACE
EOF
    chmod 0644 "$NM_KEYFILE"
    info "  NM keyfile: $NM_KEYFILE (unmanaged: $INTERFACE)"

    # Delete any auto-generated 'Wired connection N' profile bound to the
    # EtherCAT NIC — NM will recreate one every time the daemon stops if
    # such a profile exists, then keep trying to autoconnect it.
    if command -v nmcli &>/dev/null; then
        while IFS=: read -r uuid devname; do
            [ -z "$uuid" ] && continue
            if [ "$devname" = "$INTERFACE" ]; then
                if nmcli con delete "$uuid" >/dev/null 2>&1; then
                    info "    Deleted stale NM profile uuid=$uuid (device=$devname)"
                fi
            fi
        done < <(nmcli -t -f UUID,DEVICE con show 2>/dev/null || true)

        # Reload NM if it's running so the keyfile takes effect immediately.
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            nmcli general reload 2>/dev/null || true
        fi
    fi
else
    info "  NetworkManager not present — skipping keyfile install"
fi

# --- avahi-daemon: deny-interfaces=$INTERFACE
#     Idempotent in-place edit; back up the original on first run so
#     ecat_teardown.sh can restore it cleanly. Avahi 0.8 does not natively
#     read /etc/avahi/avahi-daemon.conf.d/, so a drop-in is not viable.
if [ -f "$AVAHI_CONF" ]; then
    [ -f "$AVAHI_BACKUP" ] || cp -p "$AVAHI_CONF" "$AVAHI_BACKUP"

    # Read any existing deny-interfaces value from the [server] section.
    # We merge our entries with whatever's already there (deduped) so an
    # admin's pre-existing deny-interfaces is preserved. Order is not
    # significant for avahi.
    EXISTING_DENY=$(awk '
        /^\[server\]/ { in_s=1; next }
        /^\[/         { in_s=0 }
        in_s && /^[[:space:]]*deny-interfaces[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "", $0); print $0; exit
        }
    ' "$AVAHI_CONF")

    WANT="$INTERFACE"
    if [ -n "$EXISTING_DENY" ]; then
        MERGED=$(printf '%s\n%s\n' "$EXISTING_DENY" "$WANT" \
            | tr ',' '\n' \
            | awk 'NF { gsub(/^[ \t]+|[ \t]+$/, "", $0); if (!seen[$0]++) print }' \
            | paste -sd,)
    else
        MERGED="$WANT"
    fi
    AVAHI_DENY_LINE="deny-interfaces=$MERGED"

    # Rewrite avahi-daemon.conf with the canonical deny-interfaces line in
    # [server]. Cases handled:
    #   * [server] missing entirely → append [server] + line at EOF
    #   * [server] present, no deny-interfaces → insert line at end of section
    #   * [server] present, deny-interfaces present → replace it
    AVAHI_TMP="$(mktemp)"
    awk -v repl="$AVAHI_DENY_LINE" '
        BEGIN { in_s=0; have_server=0; replaced=0 }
        /^\[server\]/ { in_s=1; have_server=1; print; next }
        /^\[/ {
            if (in_s && !replaced) { print repl; replaced=1 }
            in_s=0; print; next
        }
        in_s && /^[[:space:]]*deny-interfaces[[:space:]]*=/ {
            print repl; replaced=1; next
        }
        { print }
        END {
            if (!have_server) {
                print ""
                print "[server]"
                print repl
            } else if (!replaced) {
                print repl
            }
        }
    ' "$AVAHI_CONF" > "$AVAHI_TMP"

    if ! cmp -s "$AVAHI_TMP" "$AVAHI_CONF"; then
        install -m 0644 -o root -g root "$AVAHI_TMP" "$AVAHI_CONF"
        info "  avahi: deny-interfaces updated in $AVAHI_CONF (backup: $AVAHI_BACKUP)"
        if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
            systemctl reload-or-restart avahi-daemon 2>/dev/null || true
        fi
    else
        info "  avahi: deny-interfaces already correct"
    fi
    rm -f "$AVAHI_TMP"
else
    info "  avahi-daemon.conf not present — skipping (avahi not installed)"
fi

# =========================================================================
# 5. Dynamic CPU isolation (cgroups v2 isolated cpuset partition) [3/5]
# =========================================================================
echo ""
echo "--- [3/5] Dynamic CPU isolation (cgroups v2) ---"

# Hard requirements: cgroups v2 unified hierarchy with the cpuset
# controller available at the root cgroup. This is standard on Linux >= 5.6
# and the default on Ubuntu 22.04+.
if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
    error "  cgroups v2 not mounted at /sys/fs/cgroup. Need a system using the unified hierarchy."
fi
if ! grep -qw cpuset /sys/fs/cgroup/cgroup.controllers; then
    error "  'cpuset' controller not available at cgroup root. Need Linux >= 5.6."
fi

GRUB_REBOOT_NEEDED=false

# GRUB isolation handling — mandatory and unconditional. Every install ADDS
# the boot-time isolation token set on CPU N (reboot required):
#   isolcpus=managed_irq,domain,N  irqaffinity=<except-N>  nohz_full=N
#   rcu_nocbs=N  psi=0
# This is the only supported mode: the daemon runs on a permanently-isolated
# core. (Removal happens only via ecat_teardown.sh.)

regen_grub() {
    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg
    elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        warn "  Could not find grub-mkconfig. Update GRUB config manually."
        return 1
    fi
}

# Pick which GRUB_CMDLINE_LINUX* variable to edit. Ubuntu default installs put
# boot params in GRUB_CMDLINE_LINUX_DEFAULT (removable by recovery entry).
grub_line_var() {
    if [ -f "$GRUB_FILE" ] && grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
        echo "GRUB_CMDLINE_LINUX_DEFAULT"
    else
        echo "GRUB_CMDLINE_LINUX"
    fi
}

# Ensure a token "name=value" is present in $1 (cmdline string), replacing any
# existing "name=*". Echoes the merged cmdline.
ensure_token() {
    local line="$1" name="$2" value="$3"
    line=$(echo "$line" | sed -E "s/\\b${name}=[^ ]*//g" | xargs)
    if [ -n "$value" ]; then
        if [ -n "$line" ]; then
            line="$line ${name}=${value}"
        else
            line="${name}=${value}"
        fi
    fi
    echo "$line"
}

# Remove a token from cmdline. Echoes the result.
remove_token() {
    echo "$1" | sed -E "s/\\b$2=[^ ]*//g" | xargs
}

# Build a comma-separated CPU list of every online CPU EXCEPT those in $1.
# $1 is itself a comma-separated list (e.g. "2" or "2,3"). Used to build
# irqaffinity=<mask> for the kernel cmdline (boot-time default affinity for
# UNmanaged IRQs — complements isolcpus=managed_irq,N which only covers the
# managed IRQ pool).
cpus_except() {
    local skip_list="$1" n i out=""
    n=$(nproc)
    for ((i=0; i<n; i++)); do
        # Membership test: wrap with commas so "2" doesn't match "12" etc.
        if [[ ",${skip_list}," == *",${i},"* ]]; then
            continue
        fi
        if [ -z "$out" ]; then out="$i"; else out="$out,$i"; fi
    done
    echo "$out"
}

# Return the HT sibling CPU id of $1, or empty string if no sibling exists.
# Reads /sys/devices/system/cpu/cpu<N>/topology/thread_siblings_list which
# is the canonical sysfs source for SMT topology. The list can be expressed
# as a range ("2-3") or a comma list ("2,3" or "2,4"); we expand both forms.
# Returns empty for:
#   - E-cores on hybrid CPUs (Intel 12th gen+) — no SMT
#   - Hosts with SMT disabled in BIOS
#   - Sysfs file unreadable for any reason
get_ht_sibling() {
    local cpu="$1"
    local list_file="/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list"
    [ -r "$list_file" ] || { echo ""; return; }
    local raw
    raw=$(cat "$list_file")
    # Expand "a-b" ranges and comma lists into one CPU per line.
    local expanded
    expanded=$(echo "$raw" | tr ',' '\n' | awk -F- '
        { if (NF==2) for (i=$1; i<=$2; i++) print i; else print $1 }
    ')
    # First entry that is NOT $cpu (sibling), if any.
    # `grep -v` returns 1 when nothing matches (E-core / SMT-off → no sibling).
    # Under `set -euo pipefail` an exit-1 in a command substitution kills the
    # whole script silently, so swallow it with `|| true`.
    echo "$expanded" | grep -v "^${cpu}$" | head -1 || true
}

if [ -f "$GRUB_FILE" ]; then
    GVAR=$(grub_line_var)
    CURRENT=$(grep "^${GVAR}=" "$GRUB_FILE" | head -1 | sed "s/^${GVAR}=\"//" | sed 's/"$//')
    NEW="$CURRENT"

    # Full boot-isolation token set on CPU $ECAT_CPU (mandatory, unconditional).
    #
    #   isolcpus=managed_irq,domain,N — evict managed IRQ pool from CPU N
    #       (NVMe queue N stays dormant under load) and remove CPU N from
    #       sched_domains so userspace never migrates onto it.
    #   irqaffinity=<all-except-N>    — non-managed IRQs (dmar, ME, bare
    #       request_irq() allocations) get their initial affinity set off
    #       CPU N at boot. managed_irq covers the rest.
    #   nohz_full=N                   — kill the 1 kHz periodic tick on
    #       CPU N when only one runnable task is on it. Stops the
    #       timer-tick from scheduling kworkers (igb_watchdog,
    #       output_poll_execute) on the RT CPU.
    #   rcu_nocbs=N                   — move RCU callback work for CPU N
    #       onto housekeeping CPUs. Stops grace-period kworkers from
    #       waking on the RT CPU.
    #   psi=0                         — disable Pressure Stall Info
    #       subsystem entirely. psi_avgs_work was the highest-frequency
    #       kworker contributor on the affected production host (74
    #       fires/30s). Side effect: /proc/pressure/* disappears.
    #
    # Known cost: nohz_full's tickless-mode transitions add a ~250 µs jitter
    # floor. Accepted — it is the only mode and the bounded cost buys
    # elimination of unbounded multi-ms OP-dropping kworker bursts.
    #
    # HT sibling parking: if $ECAT_CPU has a hyperthread sibling we add it to
    # all tokens so it stays out of the scheduler and IRQ vectors — the two
    # logical CPUs share L1+L2, so work on the sibling evicts the RT thread's
    # caches (measured 537→253 µs max under memory stress when parked).
    # E-cores / SMT-off → no sibling → no-op.
    ISOLATED_CPUS="$ECAT_CPU"
    if [ "$PARK_HT_SIBLING" = "on" ]; then
        HT_SIBLING=$(get_ht_sibling "$ECAT_CPU")
        if [ -n "$HT_SIBLING" ] && [ "$HT_SIBLING" != "$ECAT_CPU" ]; then
            ISOLATED_CPUS="${ECAT_CPU},${HT_SIBLING}"
            info "  HT sibling of CPU $ECAT_CPU detected → CPU $HT_SIBLING; parking it via cmdline"
        else
            info "  CPU $ECAT_CPU has no HT sibling (E-core or SMT off) — parking skipped"
        fi
    else
        info "  HT sibling parking disabled (--park-ht-sibling=off)"
    fi

    IRQ_AFF_MASK=$(cpus_except "$ISOLATED_CPUS")
    NEW=$(ensure_token "$NEW" "isolcpus" "managed_irq,domain,$ISOLATED_CPUS")
    NEW=$(ensure_token "$NEW" "irqaffinity" "$IRQ_AFF_MASK")
    NEW=$(ensure_token "$NEW" "nohz_full" "$ISOLATED_CPUS")
    NEW=$(ensure_token "$NEW" "rcu_nocbs" "$ISOLATED_CPUS")
    NEW=$(ensure_token "$NEW" "psi" "0")

    if [ "$NEW" != "$CURRENT" ]; then
        cp "$GRUB_FILE" "${GRUB_FILE}.bak.ecat"
        # Escape slashes just in case (paths in cmdline are rare but possible)
        ESCAPED_NEW=$(printf '%s' "$NEW" | sed 's/[\/&|]/\\&/g')
        sed -i "s|^${GVAR}=.*|${GVAR}=\"$ESCAPED_NEW\"|" "$GRUB_FILE"
        info "  Updated ${GVAR} in $GRUB_FILE"
        info "    was:  $CURRENT"
        info "    now:  $NEW"
        regen_grub || true
        GRUB_REBOOT_NEEDED=true
    fi
fi

# Migration: any previous version of this setup installed an
# always-on ethercat-cpuset.service that reserved CPU $ECAT_CPU from boot.
# Remove it — the new design carves out the CPU on demand from
# ecat_daemon_start.sh, so the core stays usable when no daemon runs.
if [ -f "$CPUSET_SERVICE" ]; then
    systemctl stop ethercat-cpuset.service 2>/dev/null || true
    systemctl disable ethercat-cpuset.service --quiet 2>/dev/null || true
    rm -f "$CPUSET_SERVICE"
    systemctl daemon-reload
    info "  Removed legacy ethercat-cpuset.service (replaced by on-demand helper)"
fi
# Defensive: tear down any partition the old service left behind so
# user.slice gets CPU $ECAT_CPU back immediately.
if [ -d "$CPUSET_DIR" ]; then
    echo member > "$CPUSET_DIR/cpuset.cpus.partition" 2>/dev/null || true
    rmdir "$CPUSET_DIR" 2>/dev/null || true
fi

# Install /usr/local/sbin/ecat-cgroup: a small privileged helper that
# creates the isolated cpuset partition on demand, migrates the daemon
# PID into it, and tears it down on exit. Exposed to the 'ecat' group
# via NOPASSWD sudoers (next step). Doing this from a root helper is
# necessary because cgroups v2 requires write access to the common
# ancestor (/sys/fs/cgroup) to migrate processes across delegated
# subtrees — even mode 0660 on cgroup.procs is not enough.
cat > "$CGROUP_HELPER" <<EOF
#!/bin/bash
# /usr/local/sbin/ecat-cgroup — privileged helper for the EtherCAT RT
# daemon. Installed by ecat_setup.sh, granted to '$ECAT_GROUP' via
# /etc/sudoers.d/ecat with NOPASSWD. Do NOT edit by hand — re-run setup.
#
# Subcommands:
#   up        Carve CPU $ECAT_CPU out of the general scheduler (cgroups v2
#             isolated partition), pin power-management knobs (disable
#             deep C-states, performance governor, scaling_min_freq locked
#             to cpuinfo_max_freq to avoid P-state ramp-up jitter under
#             nohz_full), pause irqbalance, and
#             repin every unmanaged IRQ currently routed to CPU $ECAT_CPU
#             onto the housekeeping CPUs. Snapshots pre-change state into
#             $ECAT_STATE_DIR for accurate revert. Exits non-zero if any
#             MANAGED IRQs (NVMe queues etc.) remain on CPU $ECAT_CPU —
#             those cannot be moved at runtime and are the classic source
#             of multi-ms jitter spikes. Override with:
#                 ECAT_ALLOW_MANAGED_IRQ=1
#             or run 'sudo ecat_setup.sh' + reboot to apply the isolation tokens.
#   up        Create the isolated partition + apply tunings. STRICT: errors
#             if a partition already exists (run 'down' first). Called by the
#             daemon launcher on every start.
#   down      Reverse all 'up' operations: restore IRQ affinities from
#             snapshot, restart irqbalance if it was running, re-enable
#             C-states, restore the prior governor, tear down the cpuset.
#   add PID   Migrate PID into the partition. Validates PID is alive and
#             its comm is 'ecat_rt_daemon'.
#   setcap-daemon PATH
#             Re-apply file capabilities (cap_sys_nice, cap_ipc_lock)
#             on the daemon binary at PATH.
#             cap_sys_nice lets the daemon set SCHED_FIFO without root.
#             cap_ipc_lock lets it mlockall() its address space.
#             Used by the launcher to recover from 'tk build' or
#             'tk install' wiping the caps. PATH is validated: must be a
#             real regular file with basename 'ecat_rt_daemon', under a
#             workspace build/install/tk_binaries tree, and owned by the
#             calling user (prevents repurposing the grant to setcap
#             arbitrary binaries).
#   verify-install
#             Check that load-bearing system artifacts installed by
#             ecat_setup.sh are still in place: sudoers grant, udev
#             rule, ethercat.service, ecat group + user membership,
#             version sentinel matches embedded helper version. Exits
#             non-zero with a single 'sudo ecat_setup.sh' remediation
#             block when anything is missing.
#   status    Print partition state, member PIDs, CPU, and IRQ snapshot
#             summary.

set -e

CPUSET_DIR="$CPUSET_DIR"
ECAT_CPU="$ECAT_CPU"
ECAT_GROUP="$ECAT_GROUP"
ECAT_IFACE="$INTERFACE"
STATE_DIR="$ECAT_STATE_DIR"
INSTALL_VERSION_FILE="$INSTALL_VERSION_FILE"
ECAT_HELPER_VERSION="$ECAT_INSTALL_VERSION"
IRQ_SNAPSHOT="\$STATE_DIR/irq_snapshot.tsv"
IRQBALANCE_PRIOR="\$STATE_DIR/irqbalance.prior"
FREQ_PRIOR="\$STATE_DIR/scaling_min_freq.prior"
HWP_EPP_PRIOR="\$STATE_DIR/hwp_epp.prior"
C1_DISABLE_PRIOR="\$STATE_DIR/c1_disable.prior"
DAEMON_COMM="ecat_rt_daemon"

err() { echo "ecat-cgroup: \$*" >&2; exit 2; }

# --- CPU power-management helpers (on-demand, matching partition lifetime) ---
# These tune the RT CPU only while the daemon is running. ecat_diag.sh flags
# both as WARN sources of jitter on untuned hosts:
#   * deep C-states (wake-up latency > 100 us) — on a 500 us cycle, a C3
#     exit can drop > 2 cycles every time the CPU parks between cycles
#   * scaling_governor=powersave — P-state transitions under RT load add
#     tens of us of jitter per transition
#   * scaling_min_freq well below cpuinfo_max_freq — under nohz_full the RT
#     thread sleeps ~90% of each cycle; intel_pstate reads that as idle and
#     clocks down to min, then ramps on every wake, adding a 50–150 us tail
#     to max jitter. Pinning min=max forces the CPU to stay at turbo.
# The 'up' path disables them; 'down' restores defaults so the CPU goes
# back to normal behaviour the moment the daemon stops.
tune_apply() {
    mkdir -p "\$STATE_DIR" 2>/dev/null || true

    # Disable EVERY cpuidle state on the RT CPU including POLL and C1.
    # Iter-by-iter measurement on Core Ultra 5 225F showed that even C1
    # (lat=1us nominal) re-enabled brought back 200-500us spikes —
    # disabling all idle states drops jmax_max from ~440us → ~140us.
    # The CPU stays in C0 between cycles. Costs ~5-10W extra on the RT
    # core; for an isolated single-core daemon that's negligible vs the
    # jitter win. State-by-state disable lets 'down' restore precisely.
    # Idempotent priors: snapshot ONLY on first run (when the .prior file
    # does not exist). Without this guard, a second tune_apply with a .prior
    # already present would overwrite the original cpuidle-state values with
    # already-tuned ones (1 1 1 1), and tune_revert would later "restore" 1s
    # instead of the
    # operator's original idle policy.
    if [ ! -f "\$C1_DISABLE_PRIOR" ]; then
        : > "\$C1_DISABLE_PRIOR"
        for s in /sys/devices/system/cpu/cpu\${ECAT_CPU}/cpuidle/state*; do
            [ -e "\$s/disable" ] || continue
            local prev; prev=\$(cat "\$s/disable" 2>/dev/null || echo "")
            printf "%s\\t%s\\n" "\$s/disable" "\$prev" >> "\$C1_DISABLE_PRIOR"
        done
    fi
    # Apply: writing 1 to a file already containing 1 is a no-op. Safe on every call.
    for s in /sys/devices/system/cpu/cpu\${ECAT_CPU}/cpuidle/state*; do
        [ -e "\$s/disable" ] || continue
        echo 1 > "\$s/disable" 2>/dev/null || true
    done
    local gov=/sys/devices/system/cpu/cpu\${ECAT_CPU}/cpufreq/scaling_governor
    if [ -f "\$gov" ] && grep -qw performance \
        /sys/devices/system/cpu/cpu\${ECAT_CPU}/cpufreq/scaling_available_governors 2>/dev/null; then
        echo performance > "\$gov" 2>/dev/null || true
    fi

    # Pin P-state floor to cpuinfo_max_freq. Snapshot prior value so 'down'
    # restores it. Silently skip on kernels/boards that don't expose the
    # files (VMs, non-cpufreq drivers) — snapshot absence is the signal for
    # tune_revert to skip restore.
    local minf=/sys/devices/system/cpu/cpu\${ECAT_CPU}/cpufreq/scaling_min_freq
    local maxf=/sys/devices/system/cpu/cpu\${ECAT_CPU}/cpufreq/cpuinfo_max_freq
    if [ -w "\$minf" ] && [ -r "\$maxf" ]; then
        [ -f "\$FREQ_PRIOR" ] || cat "\$minf" > "\$FREQ_PRIOR" 2>/dev/null || true
        cat "\$maxf" > "\$minf"       2>/dev/null || true
    fi

    # EPP (per-CPU): 'balance_performance' gives HW permission to demote;
    # pin 'performance' on the RT CPU so its P-state never demotes under load.
    local epp=/sys/devices/system/cpu/cpu\${ECAT_CPU}/cpufreq/energy_performance_preference
    if [ -w "\$epp" ]; then
        [ -f "\$HWP_EPP_PRIOR" ] || cat "\$epp" > "\$HWP_EPP_PRIOR" 2>/dev/null || true
        echo performance > "\$epp" 2>/dev/null || true
    fi

}
tune_revert() {
    # Restore HWP knobs.
    if [ -s "\$HWP_EPP_PRIOR" ]; then
        local epp=/sys/devices/system/cpu/cpu\${ECAT_CPU}/cpufreq/energy_performance_preference
        [ -w "\$epp" ] && cat "\$HWP_EPP_PRIOR" > "\$epp" 2>/dev/null || true
        rm -f "\$HWP_EPP_PRIOR"
    fi


    local minf=/sys/devices/system/cpu/cpu\${ECAT_CPU}/cpufreq/scaling_min_freq
    if [ -s "\$FREQ_PRIOR" ] && [ -w "\$minf" ]; then
        cat "\$FREQ_PRIOR" > "\$minf" 2>/dev/null || true
    fi
    rm -f "\$FREQ_PRIOR"

    # Restore each cpuidle state from its prior disable value.
    if [ -s "\$C1_DISABLE_PRIOR" ]; then
        while IFS=\$'\\t' read -r path prev; do
            [ -n "\$path" ] && [ -n "\$prev" ] && echo "\$prev" > "\$path" 2>/dev/null || true
        done < "\$C1_DISABLE_PRIOR"
        rm -f "\$C1_DISABLE_PRIOR"
    else
        for s in /sys/devices/system/cpu/cpu\${ECAT_CPU}/cpuidle/state*; do
            [ -e "\$s/disable" ] && echo 0 > "\$s/disable" 2>/dev/null || true
        done
    fi
    local gov=/sys/devices/system/cpu/cpu\${ECAT_CPU}/cpufreq/scaling_governor
    if [ -f "\$gov" ]; then
        for g in schedutil powersave ondemand; do
            if grep -qw "\$g" \
                /sys/devices/system/cpu/cpu\${ECAT_CPU}/cpufreq/scaling_available_governors 2>/dev/null; then
                echo "\$g" > "\$gov" 2>/dev/null || true
                break
            fi
        done
    fi

}

# --- IRQ repin helpers ---
# Build a hex mask of all online CPUs EXCLUDING \$ECAT_CPU. Bitmask
# layout matches /proc/irq/<N>/smp_affinity.
build_off_rt_mask() {
    local n; n=\$(nproc)
    local mask=0 i
    for (( i=0; i<n; i++ )); do
        [ "\$i" = "\$ECAT_CPU" ] && continue
        mask=\$(( mask | (1 << i) ))
    done
    printf "%x" "\$mask"
}

# Pretty name for IRQ N (last non-numeric token in /proc/interrupts row).
irq_pretty() {
    awk -v n="\$1" '\$1==n":"{ for(i=NF;i>=2;i--) if(\$i !~ /^[0-9]+\$/){print \$i; exit} }' /proc/interrupts 2>/dev/null
}

# Fire count for IRQ \$1 on CPU \$2 (reads /proc/interrupts column \$2+2).
irq_cpu_count() {
    awk -v n="\$1" -v col=\$((\$2 + 2)) '\$1==n":"{print \$col}' /proc/interrupts 2>/dev/null
}

# Try to move IRQ \$1 off \$ECAT_CPU. Echoes:
#   moved        — was on \$ECAT_CPU, now off it.
#   pinned       — EtherCAT NIC queue IRQ, now pinned TO \$ECAT_CPU.
#   already_off  — non-EtherCAT IRQ already off \$ECAT_CPU.
#   already_on   — EtherCAT NIC queue IRQ already on \$ECAT_CPU.
#   managed      — kernel refused the affinity write.
#   skip         — no effective_affinity readable.
#
# "managed" is reported whenever the write is rejected or silently ignored by
# the kernel — this is how we detect managed IRQs (NVMe queues etc.) that
# IRQF_MANAGED prevents userspace from repinning.
#
# Special-case: IRQs belonging to the EtherCAT NIC's data-path queues
# (\$ECAT_IFACE-TxRx-*, \$ECAT_IFACE-Tx-*, \$ECAT_IFACE-Rx-*, or the plain
# \$ECAT_IFACE name) need the OPPOSITE treatment — they MUST run on
# \$ECAT_CPU. Under ec_generic (the driver we currently ship), the EtherCAT
# RX path is plain Linux NAPI softirq, which executes on whichever CPU
# services the NIC's IRQ. If that CPU is a saturated housekeeping core,
# the cycle thread on \$ECAT_CPU stalls waiting for the response (observed:
# 6 ms OP-dropping bursts on a multi-NIC production host). Pinning the
# NIC IRQ to \$ECAT_CPU puts the softirq next to the only consumer.
# (With native ec_igb the data path runs inside the IgH master kernel
# thread and IRQ placement is moot — tracked separately as a follow-up.)
irq_repin_one() {
    local n="\$1"
    local name; name=\$(irq_pretty "\$n")
    local eff; eff=\$(cat "/proc/irq/\$n/effective_affinity_list" 2>/dev/null || echo "")
    [ -n "\$eff" ] || { echo skip; return; }

    case "\$name" in
        \${ECAT_IFACE}-TxRx-*|\${ECAT_IFACE}-Tx-*|\${ECAT_IFACE}-Rx-*|\${ECAT_IFACE})
            # EtherCAT NIC queue — pin TO \$ECAT_CPU.
            if [ "\$eff" = "\$ECAT_CPU" ]; then echo already_on; return; fi
            local orig hexmask new_eff
            orig=\$(cat "/proc/irq/\$n/smp_affinity" 2>/dev/null)
            hexmask=\$(printf "%x" \$(( 1 << ECAT_CPU )))
            if ! echo "\$hexmask" > "/proc/irq/\$n/smp_affinity" 2>/dev/null; then
                echo "ecat-cgroup: WARN — could not pin \$name (irq \$n) to CPU \$ECAT_CPU (kernel rejected; likely IRQF_MANAGED). Consider native ec_igb." >&2
                echo managed; return
            fi
            new_eff=\$(cat "/proc/irq/\$n/effective_affinity_list" 2>/dev/null)
            if [ "\$new_eff" != "\$ECAT_CPU" ]; then
                echo "\$orig" > "/proc/irq/\$n/smp_affinity" 2>/dev/null || true
                echo "ecat-cgroup: WARN — pin of \$name (irq \$n) to CPU \$ECAT_CPU did not stick (driver rebound to CPU \$new_eff)." >&2
                echo managed; return
            fi
            printf "%s\\t%s\\t%s\\n" "\$n" "\$orig" "\$name" >> "\$IRQ_SNAPSHOT"
            echo pinned; return
            ;;
    esac

    [ "\$eff" = "\$ECAT_CPU" ] || { echo already_off; return; }

    local orig; orig=\$(cat "/proc/irq/\$n/smp_affinity" 2>/dev/null)
    local mask; mask=\$(build_off_rt_mask)

    # Attempt the write. Managed IRQs reject it (EIO) or accept silently
    # and immediately rebind. Either way, effective_affinity won't change.
    if ! echo "\$mask" > "/proc/irq/\$n/smp_affinity" 2>/dev/null; then
        echo managed; return
    fi
    local new_eff; new_eff=\$(cat "/proc/irq/\$n/effective_affinity_list" 2>/dev/null)
    if [ "\$new_eff" = "\$ECAT_CPU" ]; then
        # Write accepted but didn't stick — driver will keep rebinding.
        # Restore the original bitmask so we don't leave a misleading state.
        echo "\$orig" > "/proc/irq/\$n/smp_affinity" 2>/dev/null || true
        echo managed; return
    fi
    # Success — record for revert.
    printf "%s\\t%s\\t%s\\n" "\$n" "\$orig" "\$name" >> "\$IRQ_SNAPSHOT"
    echo moved
}

# Pause irqbalance + repin every unmanaged IRQ currently on \$ECAT_CPU.
# Emit error if any managed IRQs remain (jitter source operator must
# resolve). Return 3 to hard-fail callers when managed IRQs remain and
# the operator hasn't explicitly acknowledged.
irq_apply() {
    mkdir -p "\$STATE_DIR"
    chmod 0755 "\$STATE_DIR"

    # Clean up any stale snapshot (daemon may have crashed; revert its pins
    # first so the snapshot we write now is accurate).
    if [ -f "\$IRQ_SNAPSHOT" ]; then
        echo "ecat-cgroup: stale IRQ snapshot found — reverting before re-applying"
        while IFS=\$'\\t' read -r sn sorig _; do
            [ -n "\$sn" ] || continue
            echo "\$sorig" > "/proc/irq/\$sn/smp_affinity" 2>/dev/null || true
        done < "\$IRQ_SNAPSHOT"
        rm -f "\$IRQ_SNAPSHOT"
    fi
    : > "\$IRQ_SNAPSHOT"

    # Pause irqbalance so it doesn't re-route our pins away.
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        echo active > "\$IRQBALANCE_PRIOR"
        systemctl stop irqbalance 2>/dev/null || true
    else
        echo inactive > "\$IRQBALANCE_PRIOR"
    fi

    local moved=0 pinned=0 managed=0 managed_nums=() managed_names=()
    for n in \$(ls /proc/irq/ 2>/dev/null | grep -E '^[0-9]+\$'); do
        case "\$(irq_repin_one "\$n")" in
            moved)   moved=\$((moved+1)) ;;
            pinned)  pinned=\$((pinned+1)) ;;
            managed) managed=\$((managed+1))
                     managed_nums+=("\$n")
                     managed_names+=("\$(irq_pretty "\$n")") ;;
        esac
    done

    echo "ecat-cgroup: irq_apply — moved=\$moved pinned=\$pinned managed=\$managed"

    if [ "\$managed" -gt 0 ]; then
        # Fire-activity gate: the old criterion ("any managed IRQ present on
        # the RT CPU is fatal") overfires after boot isolation leaves
        # IRQs technically pinned to CPU N but never firing (domain + nohz_full
        # + rcu_nocbs stop anyone on CPU N from submitting work that would
        # trigger them). Measure fire count over a short window and only
        # hard-fail if there's active jitter. Dormant IRQs get a WARN.
        local win="\${ECAT_MANAGED_IRQ_WINDOW_S:-2}"
        local -a before after delta
        local i
        for i in "\${!managed_nums[@]}"; do
            before[\$i]=\$(irq_cpu_count "\${managed_nums[\$i]}" "\$ECAT_CPU")
            before[\$i]=\${before[\$i]:-0}
        done
        sleep "\$win"
        local any_firing=0 total_fires=0
        for i in "\${!managed_nums[@]}"; do
            after[\$i]=\$(irq_cpu_count "\${managed_nums[\$i]}" "\$ECAT_CPU")
            after[\$i]=\${after[\$i]:-0}
            delta[\$i]=\$((after[i] - before[i]))
            [ "\${delta[\$i]}" -gt 0 ] && any_firing=1
            total_fires=\$((total_fires + delta[i]))
        done

        # Dormant managed IRQs are only genuinely safe when the BOOTED kernel
        # is actually isolated (isolcpus=managed_irq + nohz_full + rcu_nocbs),
        # which guarantees no work lands on \$ECAT_CPU. Between install and the
        # required reboot the tokens are in GRUB but NOT in the running kernel,
        # so gate on the live /proc/cmdline — not on intent. Without the tokens
        # in the running kernel, a quiet 2 s sample is just a sample (a bursty
        # workload can wake them on \$ECAT_CPU at any moment) → fail.
        if [ "\$any_firing" -eq 0 ] && grep -q 'isolcpus=managed_irq' /proc/cmdline; then
            echo ""                                                                                   >&2
            echo "ecat-cgroup: WARN — \$managed managed IRQ(s) pinned to CPU \$ECAT_CPU but dormant (0 fires in \${win}s):" >&2
            for i in "\${!managed_nums[@]}"; do
                echo "  irq \${managed_nums[\$i]}:\${managed_names[\$i]}"                             >&2
            done
            echo "  Proceeding (strict isolation active — kernel keeps them dormant)."                >&2
            return 0
        fi

        echo ""                                                                                       >&2
        if [ "\$any_firing" -gt 0 ]; then
            echo "ecat-cgroup: FAIL — \$managed managed IRQ(s) actively firing on CPU \$ECAT_CPU (\$total_fires fires in \${win}s):" >&2
            for i in "\${!managed_nums[@]}"; do
                echo "  irq \${managed_nums[\$i]}:\${managed_names[\$i]}  (+\${delta[\$i]} in \${win}s)" >&2
            done
        else
            echo "ecat-cgroup: FAIL — \$managed managed IRQ(s) pinned to CPU \$ECAT_CPU without strict isolation (dormant now, but workload-wakeable):" >&2
            for i in "\${!managed_nums[@]}"; do
                echo "  irq \${managed_nums[\$i]}:\${managed_names[\$i]}"                             >&2
            done
        fi
        echo ""                                                                                       >&2
        echo "Managed IRQs cannot be moved at runtime (IRQF_MANAGED, NVMe queue pinning, etc.)."     >&2
        echo "Any future workload burst routed to these queues will preempt the RT thread and"      >&2
        echo "cause deadline misses + EtherCAT OP/SAFEOP churn."                                      >&2
        # Show the managed-IRQ landscape across all CPUs so the operator can
        # tell whether picking a different rt_cpu is even viable. On many hosts
        # (NVMe one-queue-per-CPU is typical) every CPU carries managed IRQs,
        # so strict isolation is the only systematic fix. Name-based heuristic
        # mirrors ecat_diag.sh irq_class: nvme queues (n>=1), virtio req queues,
        # multi-queue NIC rings.
        # NOTE: must be 'nproc --all', not 'nproc' — the partition has already
        # taken \$ECAT_CPU away from this helper's effective cpus, so plain
        # nproc reports N-1 and the loop would miss the last CPU.
        local nproc_n; nproc_n=\$(nproc --all)
        local -a cpu_mgd_count
        local cc; for (( cc=0; cc<nproc_n; cc++ )); do cpu_mgd_count[\$cc]=0; done
        local nn
        for nn in \$(ls /proc/irq/ 2>/dev/null | grep -E '^[0-9]+\$'); do
            local nm; nm=\$(irq_pretty "\$nn")
            case "\$nm" in
                nvme*q[1-9]*|*-nvme*q[1-9]*|virtio*-req*|virtio*-output*|virtio*-input*|*-TxRx-*|*-Tx-*|*-Rx-*) ;;
                *) continue ;;
            esac
            local ef; ef=\$(cat /proc/irq/\$nn/effective_affinity_list 2>/dev/null)
            case "\$ef" in ""|*[,-]*) continue ;; esac   # ignore range/multi-CPU effective
            cpu_mgd_count[\$ef]=\$(( cpu_mgd_count[\$ef] + 1 ))
        done
        local landscape="" clean_cpus=""
        for (( cc=0; cc<nproc_n; cc++ )); do
            landscape="\$landscape cpu\$cc=\${cpu_mgd_count[\$cc]}"
            [ "\${cpu_mgd_count[\$cc]}" -eq 0 ] && clean_cpus="\$clean_cpus \$cc"
        done
        echo "Managed IRQs by CPU:\$landscape"                                                       >&2
        echo ""                                                                                       >&2
        echo "Options:"                                                                               >&2
        echo "  1. Reboot with kernel-level isolation:"                                                >&2
        echo "       sudo ecat_setup.sh"                                                              >&2
        echo "       sudo reboot"                                                                     >&2
        echo "     (adds isolcpus=managed_irq,domain,\$ECAT_CPU nohz_full=\$ECAT_CPU rcu_nocbs=\$ECAT_CPU psi=0)" >&2
        if [ -n "\$clean_cpus" ]; then
            echo "  2. Pick a clean rt_cpu (no managed IRQs):\$clean_cpus"                            >&2
            echo "     Set rt_cpu in ecat_bus.yaml, then: sudo ecat_setup.sh --ecat-cpu <cpu>"        >&2
        else
            echo "  2. (No clean CPU available — every CPU carries managed IRQs; option 1 is the fix.)" >&2
        fi
        echo "  3. Override (NOT recommended for production — jitter will cause link drops):"        >&2
        echo "       ECAT_ALLOW_MANAGED_IRQ=1 ecat_daemon_start.sh"                                   >&2
        echo ""                                                                                       >&2
        if [ "\${ECAT_ALLOW_MANAGED_IRQ:-0}" != "1" ]; then
            return 3
        fi
        echo "ecat-cgroup: proceeding anyway (ECAT_ALLOW_MANAGED_IRQ=1)"                              >&2
    fi
}

irq_revert() {
    if [ -f "\$IRQ_SNAPSHOT" ]; then
        while IFS=\$'\\t' read -r n orig _; do
            [ -n "\$n" ] || continue
            echo "\$orig" > "/proc/irq/\$n/smp_affinity" 2>/dev/null || true
        done < "\$IRQ_SNAPSHOT"
        rm -f "\$IRQ_SNAPSHOT"
    fi
    if [ "\$(cat "\$IRQBALANCE_PRIOR" 2>/dev/null || echo '')" = "active" ]; then
        systemctl start irqbalance 2>/dev/null || true
    fi
    rm -f "\$IRQBALANCE_PRIOR"
}

case "\${1:-}" in
    up)
        # STRICT: refuse to run on a pre-existing partition. The cgroup does
        # not survive reboot, so on a clean boot the dir is absent and we
        # create it from scratch here. If it already exists, the state is
        # unexpected (a previous daemon crashed without 'down', or a manual
        # experiment) — surface it loudly instead of reconciling. There is no
        # self-heal: the operator runs 'ecat-cgroup down' and retries.
        if [ -d "\$CPUSET_DIR" ]; then
            err "partition \$CPUSET_DIR already exists (unexpected state) — run 'ecat-cgroup down' and retry"
        fi

        # Enable +cpuset in subtree_control. The kernel can return EBUSY
        # transiently while propagating controllers; retry up to 3x with
        # 100ms backoff. After the loop, fail loudly if cpuset still
        # isn't there — silent failure is the bug we're fixing.
        if ! grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
            for attempt in 1 2 3; do
                if echo +cpuset > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
            grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control \
                || err "could not enable cpuset controller in cgroup.subtree_control after 3 retries (kernel returned EBUSY persistently — check for unexpected child cgroups under /sys/fs/cgroup with no cpuset.cpus)"
        fi

        mkdir -p "\$CPUSET_DIR"
        echo "\$ECAT_CPU" > "\$CPUSET_DIR/cpuset.cpus"
        [ "\$(cat "\$CPUSET_DIR/cpuset.cpus" 2>/dev/null)" = "\$ECAT_CPU" ] \
            || err "cpuset.cpus did not accept '\$ECAT_CPU' (got: '\$(cat "\$CPUSET_DIR/cpuset.cpus" 2>/dev/null)')"

        # Re-asserting "isolated" on an already-isolated partition is a no-op.
        # Kernel silently accepts it even when the CPU is already isolcpus'd
        # at boot.
        echo isolated > "\$CPUSET_DIR/cpuset.cpus.partition"
        part="\$(cat "\$CPUSET_DIR/cpuset.cpus.partition" 2>/dev/null)"
        [ "\$part" = "isolated" ] \
            || err "cpuset.cpus.partition is '\$part', expected 'isolated' (kernel rejected isolation — usually means CPU \$ECAT_CPU is held by another cpuset)"

        chgrp "\$ECAT_GROUP" "\$CPUSET_DIR/cgroup.procs"
        chmod 0660 "\$CPUSET_DIR/cgroup.procs"
        tune_apply
        # IRQ repin runs regardless of isolation mode — cheap defense-in-depth,
        # catches any unmanaged IRQ that slipped through (hotplug, etc.).
        irq_apply
        echo "ecat-cgroup: up (CPU \$ECAT_CPU isolated, C-states off, performance governor @ max freq, IRQs repinned)"
        ;;
    down)
        # Revert in reverse order of 'up'.
        irq_revert
        if [ -d "\$CPUSET_DIR" ]; then
            # Migrate any stragglers up to the root cgroup so rmdir succeeds.
            if [ -s "\$CPUSET_DIR/cgroup.procs" ]; then
                while read -r p; do
                    [ -n "\$p" ] && echo "\$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
                done < "\$CPUSET_DIR/cgroup.procs"
            fi
            echo member > "\$CPUSET_DIR/cpuset.cpus.partition" 2>/dev/null || true
            rmdir "\$CPUSET_DIR" 2>/dev/null || true
        fi
        tune_revert
        echo "ecat-cgroup: down (CPU \$ECAT_CPU returned to general scheduler, tunings + IRQs reverted)"
        ;;
    add)
        PID="\${2:-}"
        [[ "\$PID" =~ ^[0-9]+\$ ]] || { echo "ecat-cgroup: bad pid '\$PID'" >&2; exit 1; }
        [ -d "/proc/\$PID" ] || { echo "ecat-cgroup: no such pid \$PID" >&2; exit 1; }
        COMM=\$(cat "/proc/\$PID/comm" 2>/dev/null || echo "")
        [ "\$COMM" = "\$DAEMON_COMM" ] || { echo "ecat-cgroup: pid \$PID is '\$COMM', expected '\$DAEMON_COMM'" >&2; exit 1; }
        [ -d "\$CPUSET_DIR" ] || { echo "ecat-cgroup: partition not up — call 'up' first" >&2; exit 1; }
        echo "\$PID" > "\$CPUSET_DIR/cgroup.procs"
        echo "ecat-cgroup: pid \$PID added to partition"
        ;;
    setcap-daemon)
        BIN="\${2:-}"
        [ -n "\$BIN" ] || err "usage: setcap-daemon <path-to-ecat_rt_daemon>"
        # Refuse if invoked as root directly (no sudo). Without SUDO_UID
        # set the ownership check below would default to UID 0 and could
        # spuriously cap a root-owned binary. The helper is *meant* to be
        # called via 'sudo -n ecat-cgroup' from a real user.
        [ -n "\${SUDO_USER:-}" ] && [ -n "\${SUDO_UID:-}" ] \\
            || err "must be invoked via sudo from a user, not as root directly"
        # Resolve symlinks; reject if path doesn't exist or isn't a regular file.
        REAL=\$(realpath -e "\$BIN" 2>/dev/null) || err "path does not exist: \$BIN"
        [ -f "\$REAL" ] || err "not a regular file: \$REAL"
        # Basename gate: only the daemon binary is allowed. Stops the grant
        # being repurposed to cap-bless arbitrary binaries.
        [ "\$(basename "\$REAL")" = "\$DAEMON_COMM" ] \\
            || err "basename must be \$DAEMON_COMM (got: \$(basename "\$REAL"))"
        # Path gate: only workspace build/install/tk_binaries trees.
        # tk_binaries is the canonical fleet-PC deployment layout
        # (ros2_ws/tk_binaries/<pkg>/lib/<pkg>/ecat_rt_daemon) — without
        # it here the launcher's auto-recap is non-functional for every
        # PC that consumes the binarized release. A user could still
        # arrange a path like \$HOME/foo/build/bar/ecat_rt_daemon, but
        # they're already in the ecat group with broad helper privileges,
        # so this adds no real attack surface beyond what they already
        # have — basename + ownership + SUDO_USER gates do the actual
        # work below.
        case "\$REAL" in
            */build/*/\$DAEMON_COMM|*/install/*/\$DAEMON_COMM|*/tk_binaries/*/lib/*/\$DAEMON_COMM) ;;
            *) err "path must live under a workspace build/install/tk_binaries tree (got: \$REAL)" ;;
        esac
        # Ownership gate: the real file must be owned by whoever invoked
        # sudo. Combined with the SUDO_USER check above, this means: only
        # the user's own daemon binaries can ever get capped.
        REAL_UID=\$(stat -c '%u' "\$REAL" 2>/dev/null) || err "stat failed on \$REAL"
        [ "\$REAL_UID" = "\$SUDO_UID" ] \\
            || err "binary owned by uid=\$REAL_UID but caller (\$SUDO_USER) is uid=\$SUDO_UID — refusing"
        setcap cap_sys_nice,cap_ipc_lock+ep "\$REAL" \\
            || err "setcap failed on \$REAL"
        echo "ecat-cgroup: setcap-daemon — applied caps to \$REAL"
        ;;
    verify-install)
        # Eager check of load-bearing system artifacts. Each missing/broken
        # item gets one line that names the file AND the consequence —
        # someone reading the log later (operator, support, future-you)
        # should be able to tell what would have broken without consulting
        # this code. The launcher invokes this first thing on every start.
        drift=()

        # /etc/sudoers.d/ecat: must exist and grant NOPASSWD on the helper.
        # An empty/truncated file passes -f but breaks every helper invocation.
        if [ ! -f /etc/sudoers.d/ecat ]; then
            drift+=("missing: /etc/sudoers.d/ecat — launcher cannot invoke helper, every start would interactive-sudo-prompt")
        elif ! grep -qE "NOPASSWD.*ecat-cgroup" /etc/sudoers.d/ecat 2>/dev/null; then
            drift+=("corrupt: /etc/sudoers.d/ecat exists but has no NOPASSWD grant for ecat-cgroup — same effect as missing")
        fi

        # /etc/udev/rules.d/99-ethercat.rules: must grant /dev/EtherCAT* to ecat group.
        if [ ! -f /etc/udev/rules.d/99-ethercat.rules ]; then
            drift+=("missing: /etc/udev/rules.d/99-ethercat.rules — /dev/EtherCAT0 will revert to root-only after next module reload")
        elif ! grep -qE "EtherCAT.*GROUP=\"\$ECAT_GROUP\"" /etc/udev/rules.d/99-ethercat.rules 2>/dev/null; then
            drift+=("corrupt: /etc/udev/rules.d/99-ethercat.rules exists but doesn't grant /dev/EtherCAT* to '\$ECAT_GROUP'")
        fi

        # /etc/systemd/system/ethercat.service: must define the on-demand unit.
        if [ ! -f /etc/systemd/system/ethercat.service ]; then
            drift+=("missing: /etc/systemd/system/ethercat.service — daemon can't load EtherCAT kernel modules on demand")
        elif ! grep -qE "^ExecStart=" /etc/systemd/system/ethercat.service 2>/dev/null; then
            drift+=("corrupt: /etc/systemd/system/ethercat.service has no ExecStart line")
        fi

        # System group + caller membership.
        if ! getent group "\$ECAT_GROUP" >/dev/null 2>&1; then
            drift+=("missing: '\$ECAT_GROUP' system group — udev rule, sudoers grant, and helper write access all stop working")
        elif [ -n "\${SUDO_USER:-}" ] && ! id -nG "\$SUDO_USER" 2>/dev/null | grep -qw "\$ECAT_GROUP"; then
            drift+=("user '\$SUDO_USER' not in '\$ECAT_GROUP' — log out and back in, or run 'newgrp \$ECAT_GROUP'")
        fi

        # Install version sentinel — catches helper hand-edits and out-of-band
        # installs. Mismatch ≈ "the file shape on disk is no longer the one
        # setup.sh produces", so re-running setup is the canonical fix.
        if [ ! -f "\$INSTALL_VERSION_FILE" ]; then
            drift+=("missing: \$INSTALL_VERSION_FILE — sentinel never written; helper version cannot be cross-checked")
        else
            installed=\$(cat "\$INSTALL_VERSION_FILE" 2>/dev/null)
            if [ "\$installed" != "\$ECAT_HELPER_VERSION" ]; then
                drift+=("version drift: helper=\$ECAT_HELPER_VERSION, sentinel=\$installed — helper was hand-edited or setup.sh updated since last install")
            fi
        fi

        # IgH kernel modules for the CURRENTLY RUNNING kernel. After an unattended
        # distro kernel upgrade (apt installs linux-image-N+1 and reboots into it),
        # /lib/modules/N+1/ exists but lacks ethercat/. The next modprobe inside
        # ethercat.service ExecStart fails with "Module ec_master not found", the
        # service goes to 'failed', /dev/EtherCAT0 never appears, and the daemon
        # spends 10 s in wait_for_ecat_master_ready before giving up with a
        # generic error. Catching it here turns that opaque failure into one
        # actionable line at launcher pre-flight: re-run sudo ecat_setup.sh,
        # which detects the miss and recompiles for uname -r.
        #
        # Two modules are required: ec_master (always) + the chosen NIC device
        # driver, which is exactly one of ec_generic / ec_igb / ec_igc. Setup
        # picks one based on the detected chipset and persists the choice in
        # the unit's ExecStartPost. Reading the unit is the single source of
        # truth — hardcoding ec_generic here would false-alarm on native-driver
        # hosts. Use find under devices/ because some drivers live in a
        # per-chipset subdir (e.g. devices/r8169/ec_r8169.ko).
        _kver=\$(uname -r)
        _kmod_dir=/lib/modules/\$_kver/ethercat
        if [ ! -f "\$_kmod_dir/master/ec_master.ko" ]; then
            drift+=("missing: \$_kmod_dir/master/ec_master.ko — kernel \$_kver has no IgH master module built for it (running kernel changed since last setup)")
        fi
        _drv=\$(awk '/^ExecStartPost=.*modprobe[[:space:]]+ec_/ {for(i=1;i<=NF;i++) if(\$i ~ /^ec_/){print \$i; exit}}' /etc/systemd/system/ethercat.service 2>/dev/null)
        if [ -z "\$_drv" ]; then
            drift+=("corrupt: /etc/systemd/system/ethercat.service has no ExecStartPost=...modprobe ec_<driver> — cannot determine which NIC device driver was installed")
        else
            _drv_ko=\$(find "\$_kmod_dir/devices" -name "\${_drv}.ko" 2>/dev/null | head -1)
            if [ -z "\$_drv_ko" ]; then
                drift+=("missing: \${_drv}.ko under \$_kmod_dir/devices — kernel \$_kver has no IgH \$_drv device driver built for it (chosen driver per /etc/systemd/system/ethercat.service)")
            fi
        fi

        # /etc/NetworkManager/conf.d/99-tk-ethercat.conf: must mark the
        # EtherCAT NIC as unmanaged. Without this, NM cycles DHCP on the
        # NIC, causing wkc_drops and jitter excursions. Skip the check
        # entirely if NM isn't installed — non-NM hosts (systemd-networkd,
        # headless servers) don't have the failure mode the keyfile
        # defends against.
        if command -v nmcli >/dev/null 2>&1 || [ -d /etc/NetworkManager ]; then
            if [ ! -f /etc/NetworkManager/conf.d/99-tk-ethercat.conf ]; then
                drift+=("missing: /etc/NetworkManager/conf.d/99-tk-ethercat.conf — NM will manage \$ECAT_IFACE, causing wkc_drops and jitter excursions")
            elif ! grep -qE "^unmanaged-devices=.*interface-name:\$ECAT_IFACE(\$|;)" /etc/NetworkManager/conf.d/99-tk-ethercat.conf 2>/dev/null; then
                drift+=("corrupt: /etc/NetworkManager/conf.d/99-tk-ethercat.conf exists but doesn't mark \$ECAT_IFACE as unmanaged")
            fi
        fi

        # /etc/avahi/avahi-daemon.conf: must list \$ECAT_IFACE in the
        # deny-interfaces line of the [server] section. Skip if avahi isn't
        # installed.
        if [ -f /etc/avahi/avahi-daemon.conf ]; then
            deny_line=\$(awk '/^\\[server\\]/ {in_s=1; next} /^\\[/ {in_s=0} in_s && /^[[:space:]]*deny-interfaces[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, "", \$0); print; exit}' /etc/avahi/avahi-daemon.conf)
            if [ -z "\$deny_line" ]; then
                drift+=("missing: deny-interfaces= in /etc/avahi/avahi-daemon.conf [server] — avahi will multicast mDNS on \$ECAT_IFACE, adding jitter under RT load")
            else
                case ",\$deny_line," in
                    *",\$ECAT_IFACE,"*) ;;
                    *) drift+=("corrupt: /etc/avahi/avahi-daemon.conf deny-interfaces missing \$ECAT_IFACE") ;;
                esac
            fi
        fi

        if [ "\${#drift[@]}" -gt 0 ]; then
            echo "ecat: install drift detected — run \\\`sudo ecat_setup.sh\\\`" >&2
            for d in "\${drift[@]}"; do
                echo "  \$d" >&2
            done
            exit 1
        fi
        echo "ecat-cgroup: verify-install — all artifacts present (version \$ECAT_HELPER_VERSION)"
        ;;
    status)
        if [ -d "\$CPUSET_DIR" ]; then
            echo "partition: \$(cat "\$CPUSET_DIR/cpuset.cpus.partition" 2>/dev/null)"
            echo "cpus:      \$(cat "\$CPUSET_DIR/cpuset.cpus" 2>/dev/null)"
            echo "members:   \$(tr '\n' ' ' < "\$CPUSET_DIR/cgroup.procs" 2>/dev/null)"
        else
            echo "partition: down"
        fi
        if [ -f "\$IRQ_SNAPSHOT" ]; then
            echo "irqs:      \$(wc -l < "\$IRQ_SNAPSHOT") repinned off CPU \$ECAT_CPU"
        fi
        # Enumerate any IRQs STILL on \$ECAT_CPU — these would be managed
        # survivors or hotplug additions.
        still=""
        for n in \$(ls /proc/irq/ 2>/dev/null | grep -E '^[0-9]+\$'); do
            e=\$(cat "/proc/irq/\$n/effective_affinity_list" 2>/dev/null || echo "")
            [ "\$e" = "\$ECAT_CPU" ] && still="\$still \$n(\$(irq_pretty "\$n"))"
        done
        [ -n "\$still" ] && echo "still_on_rt:\$still"
        ;;
    pin-nic)
        # Pin every IRQ belonging to the EtherCAT NIC (\$ECAT_IFACE-TxRx-*,
        # \$ECAT_IFACE-Tx-*, \$ECAT_IFACE-Rx-*, or the plain \$ECAT_IFACE) onto
        # CPU \$ECAT_CPU. Designed to be called by the launcher AFTER it cycles
        # ethercat.service — at 'up' time the NIC link may still
        # be down and the IRQ unallocated, so irq_apply's whole-system scan
        # can't see it.
        #
        # Reuses irq_repin_one (which already special-cases NIC names to pin
        # TO \$ECAT_CPU instead of off it) so success entries land in
        # \$IRQ_SNAPSHOT and get reverted on 'down'.
        if [ -z "\$ECAT_IFACE" ]; then
            err "pin-nic: ECAT_IFACE empty (re-run sudo ecat_setup.sh)"
        fi
        # Append-mode if a snapshot already exists from 'up'. Otherwise
        # initialise — covers the case where 'up' was skipped (shouldn't
        # happen in practice; defensive).
        [ -f "\$IRQ_SNAPSHOT" ] || { mkdir -p "\$STATE_DIR"; : > "\$IRQ_SNAPSHOT"; }
        pinned=0 already=0 failed=0 examined=0
        for n in \$(ls /proc/irq/ 2>/dev/null | grep -E '^[0-9]+\$'); do
            name=\$(irq_pretty "\$n")
            case "\$name" in
                \${ECAT_IFACE}-TxRx-*|\${ECAT_IFACE}-Tx-*|\${ECAT_IFACE}-Rx-*|\${ECAT_IFACE}) ;;
                *) continue ;;
            esac
            examined=\$((examined+1))
            case "\$(irq_repin_one "\$n")" in
                pinned)     pinned=\$((pinned+1)) ;;
                already_on) already=\$((already+1)) ;;
                *)          failed=\$((failed+1)) ;;
            esac
        done
        if [ "\$examined" -eq 0 ]; then
            echo "ecat-cgroup: pin-nic — no NIC IRQs found for \$ECAT_IFACE (link may be down, or driver uses single shared IRQ not yet allocated)"
        else
            echo "ecat-cgroup: pin-nic — examined=\$examined pinned=\$pinned already=\$already failed=\$failed"
        fi
        ;;
    *)
        echo "Usage: \$0 {up|down|pin-nic|add PID|setcap-daemon PATH|verify-install|status}" >&2
        exit 2
        ;;
esac
EOF
chmod 0755 "$CGROUP_HELPER"
chown root:root "$CGROUP_HELPER"
info "  Installed cgroup helper: $CGROUP_HELPER (on-demand partition for CPU $ECAT_CPU)"

# Grant the daemon binary the file capabilities it needs to run at SCHED_FIFO
# and mlockall without root. tk build wipes these on every rebuild, but the
# daemon launcher's setcap-daemon path auto-restores them — so this initial
# install is just a courtesy for the first launch. Apply to EVERY
# ecat_rt_daemon binary we can find: users frequently have multiple
# workspaces, and `ros2 pkg prefix` returns whichever was sourced last in
# their shell, so capping only the first one breaks the others.
SEARCH_PATHS=()
[ -n "$(command -v ecat_rt_daemon 2>/dev/null || true)" ] && \
    SEARCH_PATHS+=("$(command -v ecat_rt_daemon)")
SEARCH_PATHS+=("/usr/local/bin/ecat_rt_daemon")
for p in /opt/ros/*/lib/tk_ros2_pkg_ethercat_master/ecat_rt_daemon; do
    [ -x "$p" ] && SEARCH_PATHS+=("$p")
done
# Search every user's home for ros2 workspace install + build trees, plus
# the tk_install'd binarized layout (ros2_ws/tk_binaries/<pkg>/lib/<pkg>/)
# which is the dominant deployment path on fleet PCs.
for p in /home/*/*/ros2_ws/install/tk_ros2_pkg_ethercat_master/lib/tk_ros2_pkg_ethercat_master/ecat_rt_daemon \
         /home/*/*/ros2_ws/build/tk_ros2_pkg_ethercat_master/ecat_rt_daemon \
         /home/*/*/ros2_ws/tk_binaries/tk_ros2_pkg_ethercat_master/lib/tk_ros2_pkg_ethercat_master/ecat_rt_daemon; do
    [ -x "$p" ] && SEARCH_PATHS+=("$p")
done

# Deduplicate via realpath (install/.../ecat_rt_daemon is usually a
# symlink to build/.../ecat_rt_daemon, and setcap acts on the inode).
declare -A SEEN=()
DAEMON_BIN=""   # remembered for the summary footer
SETCAP_OK=()
SETCAP_FAIL=()
for cand in "${SEARCH_PATHS[@]}"; do
    [ -x "$cand" ] || continue
    real="$(readlink -f "$cand")"
    [ -n "${SEEN[$real]:-}" ] && continue
    SEEN[$real]=1
    if setcap cap_sys_nice,cap_ipc_lock,cap_net_admin+ep "$real" 2>/dev/null; then
        SETCAP_OK+=("$real")
        DAEMON_BIN="$real"
    else
        SETCAP_FAIL+=("$real")
    fi
done

if [ ${#SETCAP_OK[@]} -gt 0 ]; then
    for b in "${SETCAP_OK[@]}"; do info "  setcap applied: $b"; done
fi
for b in "${SETCAP_FAIL[@]}"; do warn "  setcap failed: $b"; done
if [ ${#SETCAP_OK[@]} -eq 0 ] && [ ${#SETCAP_FAIL[@]} -eq 0 ]; then
    info "  ecat_rt_daemon binary not found yet — that's fine. The launcher's"
    info "  setcap-daemon subcommand will apply caps the first time the daemon runs."
fi

# =========================================================================
# 6. Group + udev — /dev/EtherCAT* access without root [4/5]
# =========================================================================
echo ""
echo "--- [4/5] Group + udev: device access ---"

if ! getent group "$ECAT_GROUP" &>/dev/null; then
    groupadd "$ECAT_GROUP"
    info "  Created group '$ECAT_GROUP'"
else
    info "  Group '$ECAT_GROUP' exists"
fi

GROUP_FRESHLY_ADDED=false
if ! id -nG "$REAL_USER" | grep -qw "$ECAT_GROUP"; then
    usermod -aG "$ECAT_GROUP" "$REAL_USER"
    GROUP_FRESHLY_ADDED=true
    info "  Added '$REAL_USER' to '$ECAT_GROUP'"
else
    info "  '$REAL_USER' already in '$ECAT_GROUP'"
fi

cat > "$UDEV_RULE" <<EOF
# EtherCAT master devices — allow $ECAT_GROUP access (created by ecat_setup.sh)
KERNEL=="EtherCAT[0-9]*", MODE="0660", GROUP="$ECAT_GROUP"
EOF
udevadm control --reload-rules
info "  Udev rule: $UDEV_RULE"

# Provision the state dir used by the cgroup helper for IRQ snapshot and
# irqbalance prior-state tracking. Group-owned so the helper (root via sudo)
# can write freely; not world-readable since it contains live system state.
install -d -m 0755 -o root -g "$ECAT_GROUP" "$ECAT_STATE_DIR"

# Install version sentinel — read by 'ecat-cgroup verify-install' and
# compared against the helper's embedded ECAT_HELPER_VERSION constant.
# Mismatch tells the launcher to suggest re-running setup.
echo "$ECAT_INSTALL_VERSION" > "$INSTALL_VERSION_FILE"
chmod 0644 "$INSTALL_VERSION_FILE"
info "  Install version: $ECAT_INSTALL_VERSION (sentinel: $INSTALL_VERSION_FILE)"


# =========================================================================
# 7. Sudoers drop-in — let ecat group start/stop the on-demand service [5/5]
# =========================================================================
echo ""
echo "--- [5/5] Sudoers drop-in: on-demand ethercat.service ---"

# Scoped exactly to start/stop of ethercat.service so ecat_daemon_start.sh
# can switch the port between normal-Ethernet and EtherCAT modes without
# prompting. No general sudo grant is given.
TMP_SUDOERS="$(mktemp)"
cat > "$TMP_SUDOERS" <<EOF
# /etc/sudoers.d/ecat — created by ecat_setup.sh
# Two on-demand grants for members of the '$ECAT_GROUP' group:
#  1. Start/stop ethercat.service: load the EtherCAT kernel modules so
#     ecat_daemon_start.sh can switch the port between Ethernet and
#     EtherCAT modes without prompting.
#  2. The /usr/local/sbin/ecat-cgroup helper: create/destroy the isolated
#     cpuset partition (carves CPU $ECAT_CPU out of the general scheduler
#     only while the daemon is running) and migrate the daemon PID into
#     the partition. cgroups v2 requires a privileged migrator because
#     mode 0660 on cgroup.procs alone is not enough across delegated
#     subtrees.
%$ECAT_GROUP ALL=(root) NOPASSWD: /usr/bin/systemctl start ethercat.service, /usr/bin/systemctl stop ethercat.service, $CGROUP_HELPER, $CGROUP_HELPER *
EOF

if visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
    install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_FILE"
    info "  Sudoers: $SUDOERS_FILE (scoped to systemctl start/stop ethercat.service)"
else
    rm -f "$TMP_SUDOERS"
    error "  Generated sudoers file failed visudo validation. Refusing to install."
fi
rm -f "$TMP_SUDOERS"

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "============================================"
if [ "$IS_REINSTALL" = true ]; then
    echo "  Refresh complete"
else
    echo "  Done — that was the only sudo you'll need"
fi
echo "============================================"
echo ""
echo "What's installed:"
echo "  IgH:       $INSTALL_PREFIX (kernel module + library + ethercat CLI)"
echo "  Port:      $INTERFACE ($MAC_ADDR) — unmanaged by NM, bound to EtherCAT while daemon runs"
echo "  CPU isol:  CPU $ECAT_CPU carved out at boot via GRUB cmdline (mandatory)"
echo "  Group:     $REAL_USER -> $ECAT_GROUP   (NOPASSWD on the helper + service)"
echo "  Helper:    $CGROUP_HELPER (subcommands: verify-install, setcap-daemon, up, down)"
echo "  Sentinel:  $INSTALL_VERSION_FILE = $ECAT_INSTALL_VERSION"
echo ""
if [ "$GRUB_REBOOT_NEEDED" = true ]; then
    echo -e "${YELLOW}>>> REBOOT REQUIRED <<<${NC}  (one-time, to apply GRUB isolation tokens)"
    echo ""
    echo "After reboot, CPU $ECAT_CPU will be permanently carved out and managed"
    echo "IRQs (NVMe queues etc.) won't be allowed on it. Then just launch the daemon."
    echo ""
    echo "    sudo reboot"
    echo ""
elif grep -q 'isolcpus=managed_irq' /proc/cmdline; then
    # No GRUB change this run and the running kernel already has the tokens —
    # the host has been booted under the isolation cmdline. Nothing to do.
    echo -e "${GREEN}>>> Isolation active <<<${NC}  (GRUB tokens already in the running kernel — no reboot needed)"
    echo ""
elif [ "$GROUP_FRESHLY_ADDED" = true ]; then
    echo -e "${YELLOW}>>> Log out and back in <<<${NC}  (so the '$ECAT_GROUP' group takes effect)"
    echo "    Or in this terminal only:  newgrp $ECAT_GROUP"
    echo ""
fi
if [ "$IS_REINSTALL" != true ]; then
    echo "On every daemon launch:"
    echo "  • cgroup partition + isolation → created fresh by 'ecat-cgroup up' (strict: errors if stale)"
    echo "  • file caps wiped by tk build  → re-applied by 'ecat-cgroup setcap-daemon'"
    echo "  • /etc/* artifact drift        → surfaced by 'ecat-cgroup verify-install': 'sudo ecat_setup.sh'"
    echo ""
fi
echo "Start the daemon (no sudo):"
echo "    ecat_daemon_start.sh <config.yaml>"
echo ""
echo "Inspect the bus without launching the daemon:"
echo "    sudo systemctl start ethercat.service && ethercat slaves && sudo systemctl stop ethercat.service"
echo ""
echo "Undo everything:           sudo ecat_teardown.sh"
echo "Fix anything that drifted: sudo ecat_setup.sh   (idempotent, fast on a healthy system)"
