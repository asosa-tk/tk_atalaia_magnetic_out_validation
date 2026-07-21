# IgH (EtherLab stable-1.6) igb driver — kernel 6.17 port

Vendored set of 4 patches that port EtherLab `ethercat.git`'s `stable-1.6`
`devices/igb/igb_main-6.12-ethercat.c` and `igb_ptp-6.12-ethercat.c`
forward from kernel **6.12** to **6.17**. Required to build the native
`ec_igb` driver against modern Linux without downgrading the host kernel.

> **Note on the folder name.** This directory is named `igh_sittner_igb/`
> for historical reasons (the patches were originally drafted against the
> sittner community mirror). The current patch set is generated against
> `gitlab.com/etherlab.org/ethercat.git stable-1.6` — the same repo
> `scripts/ecat_setup.sh` clones at build time. The folder rename is
> deferred to avoid churn in `auto_compiler` / CMakeLists wiring.

## Why these patches exist

Upstream IgH (EtherLab) `stable-1.6` and `stable-1.7` both cap the bundled
igb driver at kernel **6.4** and **6.12** respectively. Past 6.12, the
build fails with API errors:

| Kernel symbol broken | What changed in 6.13+ |
|---|---|
| `del_timer_sync` | Renamed to `timer_delete_sync` |
| `from_timer(var, t, member)` | Renamed to `timer_container_of(var, t, member)` |
| `ndo_fdb_add` callback | Added `bool *notified` arg before `extack` (mainline; SUSE backport had it earlier under `#ifdef CONFIG_SUSE_KERNEL` — the gitlab base ships the guarded version, and the 6.17 patch drops the guard) |
| `cyclecounter::read` callback | Dropped `const` from `struct cyclecounter *` |

EtherLab `stable-1.6` HEAD (commit `46cc20e`, "Merge branch r8169_6.1x")
does not ship a 6.17 fix for the bundled igb sources. This vendoring
lets us run native `ec_igb` on kernel 6.17 today, without waiting for
upstream.

## When to apply these

You need these only if **all** of the following are true:

1. Host kernel is **6.17.x** specifically. For 6.13–6.16, see the
   sibling `kernel_<X.Y>/` folders or the top-level README. The four
   patches here reference kernel symbols (`timer_container_of`, the
   notified arg on `ndo_fdb_add`, non-const `cyclecounter::read`) that
   were introduced in mainline 6.16+ — applying them on 6.13–6.15
   would break the build, not fix it.
2. EtherCAT NIC is an Intel I210/I211/I350 (anything that lights up
   `ec_igb`). I226 → `ec_igc` is a separate (likely-parallel) concern;
   see TODO in `scripts/ecat_setup.sh`.
3. You want the native PCI-direct driver (no kernel net stack). For
   `--enable-generic`, none of this is needed.

If those don't all hold, skip — `ecat_setup.sh` defaults to either the
stock IgH (older kernels) or `ec_generic` (no native build needed).

## How to apply

**Automatic (recommended):** `scripts/ecat_setup.sh` detects the
`VALIDATED` sentinel here, applies the 4 patches with `git am -3` against
its build tree (`/tmp/igh_ethercat_build`), and adds
`--with-igb-kernel=6.12` to the IgH `./configure` invocation. No manual
step is required if you install via the wrapper.

The standalone procedure below is for builds **outside** the wrapper
(local validation runs, debugging a configure failure, etc.).

### Standalone

```bash
# Clone EtherLab stable-1.6 fresh (do not reuse a polluted tree).
# This is the same repo ecat_setup.sh clones at /tmp/igh_ethercat_build.
cd /tmp
rm -rf igh_ethercat
git clone --depth=1 -b stable-1.6 https://gitlab.com/etherlab.org/ethercat.git igh_ethercat
cd igh_ethercat
git config user.email a@b && git config user.name a  # git am needs identity

# Apply each patch in order. The `-3` lets git fall back to 3-way merge
# if EtherLab rebases stable-1.6 since these patches were generated.
for p in /path/to/tk_ros2_pkg_ethercat_master/kernel_patches/igh_sittner_igb/kernel_6.17/*.patch; do
    git am -3 "$p" || { echo "FAIL on $p"; exit 1; }
done

# Build + install (igb only — adjust ./configure for your NIC needs)
./bootstrap
./configure --enable-igb --with-igb-kernel=6.12 \
            --disable-rtl8169 --disable-r8169 --disable-e1000 \
            --disable-e1000e --disable-generic --disable-8139too \
            --disable-ccat --disable-ec_master_in_kernel
make -j"$(nproc)"
sudo make modules_install
sudo depmod
```

The `--with-igb-kernel=6.12` tells IgH to use the 6.12 source files as
the base — that's what our patches modify. The kernel build will then
target whatever `uname -r` reports.

## How to verify the build worked

```bash
# Module must claim the PCI device
sudo modprobe ec_master main_devices=<MAC>
sudo modprobe ec_igb
lspci -k -s 06:00.0 | grep "Kernel driver"
# Expected: Kernel driver in use: ec_igb
```

If it says `igb` instead, the stock kernel driver beat `ec_igb` to the
PCI device. `ecat_setup.sh` prevents this by writing
`/etc/modprobe.d/tk-ethercat-ec_igb.conf` (an `install igb` wrapper that
sets PCI `driver_override="ec_igb"` on the EtherCAT NIC's BDF before
stock `igb` loads). If you're hitting `Kernel driver in use: igb` on a
host where `ecat_setup.sh` succeeded, that file is missing or
out-of-date — re-run `sudo ecat_setup.sh` (which also `update-initramfs`'s
the rule into early boot).

Manual recovery without re-running setup:
```bash
BDF=$(basename "$(readlink -f /sys/class/net/<iface>/device)")
echo ec_igb | sudo tee /sys/bus/pci/devices/$BDF/driver_override
echo $BDF   | sudo tee /sys/bus/pci/drivers/igb/unbind
echo $BDF   | sudo tee /sys/bus/pci/drivers_probe
```

## Patch hygiene notes

- Patches are `git am`-formatted: subject lines, body justification,
  proper attribution. They apply cleanly against EtherLab `stable-1.6`
  HEAD `46cc20e` ("Merge branch r8169_6.1x into stable-1.6").
- Each patch is **one** API fix (no bundling), so reviewers can verify
  each kernel-API mapping independently.
- If EtherLab rebases stable-1.6, the patches MAY need `git am -3` to
  resolve via 3-way merge — but the changes touch only ~20 lines total,
  so manual conflict resolution is trivial.
- The base matters: an earlier draft of this patch set was generated
  against the sittner GitHub mirror (`github.com/sittner/EtherCAT`),
  which has slightly different `igb_main-6.12-ethercat.c` content (no
  `#ifdef CONFIG_SUSE_KERNEL` guard around the `notified` arg). That
  draft applied 0001/0002 with fuzz and then failed 0003 with
  "could not build fake ancestor" because the patch chain's parent
  blobs are not reachable from a gitlab clone. Always regenerate
  against the **same repo `ecat_setup.sh` clones** — gitlab, not sittner.
- These are **forward-ports** (the 6.12 file becomes 6.17-compatible).
  EtherLab's existing 6.4 / 6.1 igb sources are untouched.

## Provenance & validation

- **Generated:** 2026-05-26 from EtherLab `stable-1.6` @ `46cc20e`.
- **Tested on:** kernel 6.17.0-29-generic (Ubuntu 24.04 with HWE stack),
  Intel I210-T1 PCI 8086:1533.
- **Stress validation:** the prior validation campaign
  (`docs/jitter_validation_2026-05-18.md`, 253 µs worst-case under
  memory pressure) was against the same end-state of the patched tree,
  reached via the sittner-base path — the regenerated patches produce
  a byte-identical post-apply tree, so the result carries.

## Upstreaming status

These patches should eventually go to EtherLab directly. Tracker: TODO
once EtherLab cuts 1.6.9 or 1.7.0 with 6.17 support.
