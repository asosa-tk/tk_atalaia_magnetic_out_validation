# IgH (sittner stable-1.6) igb — per-kernel patch sets

Vendored patch sets that forward-port sittner/EtherCAT `stable-1.6`'s
bundled igb driver to **specific** Linux kernel versions where upstream
sittner has not yet shipped a fix.

## Layout

```
igh_sittner_igb/
├── README.md                    ← this file
├── kernel_6.14/                 ← predicted for kernel 6.14.x (no VALIDATED sentinel)
│   └── README.md                  (predicts NO patches needed; not hardware-tested)
└── kernel_6.17/                 ← validated for kernel 6.17.x
    ├── README.md
    ├── VALIDATED                  ← presence = hardware-validated
    └── *.patch                    (4 patches: timer rename, ndo_fdb_add, cyclecounter)
```

Each `kernel_X.Y/` subfolder may be:

* **Validated** — contains a `VALIDATED` sentinel file in its body
  documenting the hardware test (kernel build, NIC, distro, jitter
  numbers, author). `ecat_setup.sh` will use this folder unconditionally.
* **Predicted / draft** — no `VALIDATED` sentinel. The README inside
  documents what's expected to happen based on kernel changelog
  reasoning, but no one has run the build on this kernel.
  `ecat_setup.sh` will **NOT** use a draft folder; it will recommend
  `ec_generic` instead (see below).

Each folder also contains:

* a `README.md` documenting which kernel API changes are addressed and
  how the patch set was generated / validated;
* zero or more `*.patch` files (`git format-patch` output) to apply
  against `https://github.com/sittner/EtherCAT` branch `stable-1.6`.

A validated folder with **no** `.patch` files (just README + VALIDATED)
is the canonical way of saying "this kernel version doesn't need any
patches — sittner stable-1.6 builds against it directly, and we've
proven it on real hardware".

## How `ecat_setup.sh` consumes this

When the script detects an `igb`-capable NIC (Intel I210) and the host
kernel is ≥ 6.13, it:

1. Reads `uname -r` and extracts MAJOR.MINOR (e.g. `6.17`).
2. Looks for `kernel_patches/igh_sittner_igb/kernel_<MAJOR.MINOR>/`
   **AND** checks for a `VALIDATED` sentinel file inside.
3. If both exist, `NATIVE_AVAILABLE=true`:
   * Folder has `*.patch` files → the script stages them. After the
     fresh `git clone` (or `git clean -fdx` on a re-run) of sittner
     stable-1.6, it applies each patch with `git am -3` against the
     build tree, and then runs `./configure` with `--with-igb-kernel=6.12`
     so IgH uses the patched 6.12 igb base as its source.
   * Folder has no patches → the script just sets `NATIVE_AVAILABLE=true`
     (sittner stable-1.6 builds on this kernel without forward-porting).
4. Otherwise (folder missing **or** no `VALIDATED` sentinel):
   `NATIVE_AVAILABLE=false`, the script emits a warning, and the driver
   selection menu (see below) doesn't offer native at all. Generic works
   on every modern kernel that ships a working mainline `igb` driver —
   it goes through the kernel net stack but with strict isolation the
   empirical difference is modest (~5× more spikes under combined
   stress, 0 cycle drops in our tests). The trade-off is documented in
   `docs/jitter_validation_2026-05-18.md` §14.

After computing `NATIVE_AVAILABLE`, the script presents an interactive
menu (skippable via `--driver igb|igc|generic`) that lets the operator
pick the driver to install. `ec_generic` is always selectable; native
is offered (and recommended as default) only when `NATIVE_AVAILABLE=true`.

The intent is: never silently try a build that hasn't been validated
for the host kernel. Operators on a non-validated kernel either
validate locally (and `touch VALIDATED`) or fall back to generic — no
"hope it works" middle ground.

## How to add a new kernel version

If you have a host on a kernel version not yet covered (e.g. 6.15, 6.18):

1. Boot into the host running that kernel.
2. Clone `https://github.com/sittner/EtherCAT` branch `stable-1.6`.
3. Try `./bootstrap && ./configure --enable-igb --with-igb-kernel=6.12`.
4. If configure / make fails with kernel API mismatches:
   * Identify each API change (compare error symbols against the kernel
     headers under `/lib/modules/$(uname -r)/build/include/linux/`).
   * Apply the minimum fix needed, commit it, and `git format-patch` it.
5. If configure / make succeeds without changes:
   * Create `kernel_<MAJOR.MINOR>/README.md` documenting "no patches
     needed; sittner stable-1.6 + --with-igb-kernel=6.12 builds cleanly".
6. Open a PR to this repo with the new folder.

## Kernels currently covered

| Kernel | Patches needed | VALIDATED sentinel? | Script behaviour |
|---|---|---|---|
| `< 6.14` | unknown | no folder | warn → fall back to `ec_generic` |
| `6.14`   | none (predicted — API breaks are in 6.16+) | NO (draft) | warn → fall back to `ec_generic` |
| `6.15`   | unknown | no folder | warn → fall back to `ec_generic` |
| `6.16`   | unknown (likely partial overlap with 6.17 set) | no folder | warn → fall back to `ec_generic` |
| `6.17`   | 4 patches (see `kernel_6.17/README.md`) | **YES** (AGV bench, 2026-05-18) | auto-applies patches + `--with-igb-kernel=6.12`, then builds ec_igb |
| `> 6.17` | unknown — may need extra patches | no folder | warn → fall back to `ec_generic` |

The 6.14 prediction is based on the kernel changelog timing of the 4
API changes addressed by the 6.17 set (all introduced in mainline
roughly 6.16+). Until someone validates it on a real 6.14 host the
README in `kernel_6.14/` notes this caveat explicitly.

## Upstreaming status

All vendored patches should eventually go to sittner directly. Until
they do, this directory keeps the wrapper self-sufficient across kernel
upgrades that outpace sittner's release cadence.
