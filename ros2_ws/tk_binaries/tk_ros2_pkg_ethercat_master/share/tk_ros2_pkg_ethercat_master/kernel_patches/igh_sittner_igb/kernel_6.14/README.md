# IgH sittner stable-1.6 igb on Linux kernel 6.14

**Status: PREDICTED — needs hardware validation. No `VALIDATED` sentinel
file present in this folder, so `ecat_setup.sh` will NOT attempt this
path automatically — it will recommend `ec_generic` instead.**

## Recommendation until validated

**Use `ec_generic` on kernel 6.14.x.** The script will warn and route
you there automatically. ec_generic works on every modern kernel that
ships a working mainline `igb` driver; the empirical jitter delta vs
native is modest with strict isolation in place (see
`docs/jitter_validation_2026-05-18.md` §14).

If you specifically need native ec_igb on 6.14 (e.g. for production
durability against tail spike density under combined stress), follow
the validation procedure below, then `touch VALIDATED` in this folder
with a record and contribute back.

## TL;DR for the prediction

If you're on a 6.14.x kernel host, sittner stable-1.6 `./configure
--enable-igb --with-igb-kernel=6.12 ...` SHOULD compile directly. The
4 API changes that the `kernel_6.17/` patch set addresses all landed
in mainline **after** 6.14. But this is a prediction from kernel
changelog timing, not a measured fact — until validated, use generic.

## Detailed reasoning

The 4 API breaks that needed patching at kernel 6.17 are:

| API change | First kernel where it landed (approx.) | Sittner 6.12 source at 6.14? |
|---|---|---|
| `del_timer_sync` → `timer_delete_sync` | ~6.10 (alias kept; removal of old name later) | Builds (alias exists) |
| `from_timer` → `timer_container_of` | ~6.16 (new symbol) | Builds (old `from_timer` still exists) |
| `igb_ndo_fdb_add` gains `bool *notified` arg | ~6.16 | Builds (callback prototype matches old signature) |
| `cyclecounter::read` callback non-const | ~6.16-6.17 | Builds (`const` still required, source supplies it) |

If this reasoning is wrong on a real 6.14 host, the failure will surface
at configure / make time with a clear pointer to the offending symbol.

## Validation procedure (TODO)

To upgrade this folder from "predicted" to "validated":

```bash
uname -r                       # confirm 6.14.x
cd /tmp && rm -rf igh_sittner
git clone --depth=1 -b stable-1.6 https://github.com/sittner/EtherCAT igh_sittner
cd igh_sittner
./bootstrap
./configure --enable-igb --with-igb-kernel=6.12 \
            --disable-rtl8169 --disable-r8169 --disable-e1000 \
            --disable-e1000e --disable-generic --disable-8139too \
            --disable-ccat --disable-ec_master_in_kernel
make -j"$(nproc)" 2>&1 | tee /tmp/build-6.14.log
```

Expected outcomes:

* **Build succeeds:** open a PR to this repo updating the table above
  ("Validated on real hardware: YES") + log host details
  (`uname -r`, NIC PCI ID, distro).
* **Build fails on a known API:** identify the failing symbol, write a
  minimal patch, format-patch it, drop it in this folder, update the
  README with the rationale. Then re-validate.

## If you hit a problem here

* Compare against `kernel_6.17/README.md` — the 4 patches there are
  documented per-symbol so you can pick the ones that apply.
* The fix-and-format-patch loop is mechanical; each of the 4 patches in
  the 6.17 set is one-symbol, one-hunk, so adding a kernel_6.14 patch
  follows the same template.

## Why ship an empty folder

Three reasons:

1. The script auto-detects `kernel_<X.Y>` folders and uses presence as a
   "validated for this kernel" signal. An empty folder + README is the
   canonical way of saying "no patches are needed here".
2. It gives a clear contribution point for someone with a 6.14 host.
3. It documents the prediction so future operators don't accidentally
   re-apply the 6.17 patches (which would break the build on 6.14).
