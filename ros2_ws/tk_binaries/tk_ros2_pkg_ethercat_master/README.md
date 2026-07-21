# tk_ros2_pkg_ethercat_master

Generic EtherCAT master for ROS2 via shared memory. Zero device knowledge — all device-specific logic lives in runtime plugins (`.so` files) loaded via `dlopen`.

Runs on a standard Linux kernel ≥ 5.6. **One-time setup** (`sudo ecat_setup.sh`) installs the IgH kernel module, the on-demand CPU isolation helper, and the permissions/sudoers grants the daemon needs. From then on `ecat_daemon_start.sh` runs without sudo — it creates the isolated partition fresh on every start (`ecat-cgroup up`, strict) and re-applies file caps after `tk build`.

The CPU core and kernel modules are only claimed while the daemon is running — when stopped, the core returns to the general scheduler. The EtherCAT NIC is the one exception: it stays permanently NM-unmanaged and on avahi's `deny-interfaces` list. NetworkManager retrying DHCP on it (every 45 s) and avahi multicasting mDNS on it were the long-standing source of `wkc_drops` and multi-ms jitter excursions; the on-demand model only stays clean because nothing on the host's IP stack ever touches that port. See [Network interface isolation](../SETUP_CONFIG.md#network-interface-isolation) in SETUP_CONFIG.md.

## Self-healing

### On every launch

`ecat_daemon_start.sh` invokes three subcommands of `/usr/local/sbin/ecat-cgroup` (NOPASSWD via `/etc/sudoers.d/ecat`):

| Subcommand | What it does | When it acts |
|---|---|---|
| `verify-install` | Checks `/etc/sudoers.d/ecat`, `/etc/udev/rules.d/99-ethercat.rules`, `/etc/systemd/system/ethercat.service`, `ecat` group membership, the `/var/lib/ecat/installed_version` sentinel, and — since `2026-05-22.2` — that `ec_master.ko` plus the chosen NIC device driver (`ec_generic` / `ec_igb` / `ec_igc`, parsed from the systemd unit's `ExecStartPost`) are actually built under `/lib/modules/$(uname -r)/ethercat/`. Each missing/corrupt artifact gets one line with the consequence. | Drift surfaces as `sudo ecat_setup.sh`; otherwise silent. |
| `up` | Creates the cgroup partition, sets `cpuset.cpus` + `cpuset.cpus.partition='isolated'`, applies per-CPU tunings (C-states, governor, freq floor, EPP), repins unmanaged IRQs. **Strict:** errors if a partition already exists (run `down` first) — no reconciliation. | Every daemon launch. |
| `setcap-daemon <path>` | Re-applies `cap_sys_nice,cap_ipc_lock,cap_net_admin+ep` on the workspace daemon binary. Validates path (basename, workspace tree, owned by caller, invoked via sudo). | Triggered only when caps are missing — i.e. right after `tk build`. |

If `verify-install` fails, the launcher exits with a `>>> ECAT PRE-FLIGHT FAILED — NOT A DAEMON CRASH <<<` banner so monitoring callers can tell the difference from a runtime issue.

### Pre-flight failure → auto-invoke `ecat_diag.sh --report`

On any pre-flight failure (or `READY=false` exit), the launcher automatically pipes through a plain-text, ANSI-free, copy-paste-friendly host snapshot from `ecat_diag.sh --report`: install version, kernel, NIC, GRUB cmdline, modules (with dynamically-detected driver name), service state, `/dev/EtherCAT0`, cgroup partition, C-states, governor, freq, `cpu_dma_latency` holder, IRQs, daemon process, journal tail. The operator pastes the whole block to the maintainer in one message — no "can you also send me uname / lsmod / journalctl?" round-trips. The same `--report` is available standalone (`ecat_diag.sh --report`) and works daemon-up or daemon-down.

### Continuous runtime

There is no knob-drift watchdog. The global RT-PM knobs it used to re-assert
(`no_turbo`, `min_perf_pct`, `netdev_budget`, the `cpu_dma_latency` holder) have
been removed; the remaining per-CPU knobs are applied once by `ecat-cgroup up`
at launch. If something external fights them, fix the root cause rather than
reconciling in a loop.

## Drift recovery: re-run `sudo ecat_setup.sh`

The setup script is idempotent. On a healthy system, it's fast — it just re-asserts the `/etc/*` artifacts, helper, file caps, and version sentinel. The kernel module is only rebuilt if the kernel changed; GRUB is touched on the first run (writes the mandatory 5-token isolation set, requires one reboot) and is left alone on subsequent runs. Run it whenever `verify-install` reports drift — that's the one and only repair command.

> ⚠️ **Stop the daemon first.** The script may rebuild + reinstall the kernel module (after a distro kernel upgrade) and cycle `ethercat.service`, which yanks `/dev/EtherCAT0` from the live daemon mid-cycle. Re-run the full setup when verify-install reports module drift or sentinel mismatch.

> ⚠️ **Don't `tk build` while the bus is live.** Build process churn (forks, page-cache pressure, kernel IPIs, TLB shootdowns) leaks past the cgroup briefly and produces transient jitter spikes for the duration of the build. The daemon's RT thread won't lose cycles in a way that drops WKC, but the spike CSV will fill with multi-100 µs entries you'd otherwise not see. Stop the daemon, build, restart.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Business logic                                          │
│  (tk_ros2_pkg_clamp, tk_ros2_pkg_electrovalves, ...)     │
│                                                          │
│  ServoCommand (RPM, "torque")    ValveCommand (on/off)   │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────┴────────────────────────────────────┐
│  Transcriber nodes       (Python, device-specific)       │
│  servo_node, electrovalves_node, isokernel_test_node     │
│                                                          │
│  Translate typed msgs ↔ raw bytes via device codecs      │
│                                                          │
│  EcatDeviceCommand (raw uint8[])   EcatDeviceState       │
└────────────────────┬────────────────────────────────────┘
                     │ ROS2 topics
┌────────────────────┴────────────────────────────────────┐
│  ecat_ros2_node          (this package, C++, generic)    │
│                                                          │
│  Moves raw bytes between ROS2 topics and SHM.            │
│  Zero device knowledge.                                  │
└────────────────────┬────────────────────────────────────┘
                     │ POSIX SHM (double-buffered, spinlock)
┌────────────────────┴────────────────────────────────────┐
│  ecat_rt_daemon          (this package, C++, SCHED_FIFO) │
│                                                          │
│  RT loop at 250–500μs. Plugin architecture:              │
│                                                          │
│  ┌────────────────────┐  ┌────────────────────────────┐ │
│  │ libdevice_servo.so │  │ built-in passthrough       │ │
│  │ (DS402 FSM,        │  │ (auto-discovers PDOs from  │ │
│  │  safety gating,    │  │  slave SII/EEPROM at       │ │
│  │  control_word)     │  │  startup — zero config)    │ │
│  └────────────────────┘  └────────────────────────────┘ │
│                                                          │
│  Calls IgH EtherCAT Master kernel module                 │
└────────────────────┬────────────────────────────────────┘
                     │ IgH kernel module
┌────────────────────┴────────────────────────────────────┐
│  EtherCAT bus (wire)                                     │
│                                                          │
│  pos 0: servo drive    pos 1: isokernel    pos 2: EX260 │
│  (DS402, DC sync)      (ESP32+LAN9252)     (SMC valves) │
└─────────────────────────────────────────────────────────┘
```

Device packages provide:
- A **transcriber node** that packs/unpacks typed ROS2 messages to/from raw bytes
- Optionally, a **plugin `.so`** for devices with protocol logic (DS402 servos)
- Most devices need **no plugin** — the built-in passthrough auto-discovers PDOs from the device

## Setup

### One-time (sudo)

```bash
sudo ecat_setup.sh [--ecat-cpu N] [--interface IFACE] [--park-ht-sibling=off]
```

1. Builds IgH EtherCAT Master from source (kernel module, library, CLI)
2. Installs `ethercat.service` in **on-demand** mode — NOT enabled at boot,
   so the EtherCAT NIC stays managed by NetworkManager unless the daemon
   is running. The start script loads it; the cleanup releases it.
3. Installs `/usr/local/sbin/ecat-cgroup` — a small privileged helper
   that, on each daemon launch, creates a cgroups v2 isolated cpuset
   partition on CPU `N`, disables deep C-states, pins the `performance`
   governor, repins unmanaged IRQs off CPU `N`, and pauses
   `irqbalance`. Everything is reverted when the daemon exits, so CPU
   `N` is immediately reusable by everything else. If any **managed**
   IRQs (NVMe queues, virtio-req, multi-queue NICs) remain on CPU `N`
   after the repin step — they can't be moved at runtime — the helper
   hard-fails and points the operator at the boot isolation tokens (see
   below). See [SETUP_CONFIG.md](../SETUP_CONFIG.md) for the full
   rationale.
4. Creates `ecat` group + udev rule for `/dev/EtherCAT0` access without root.
5. Writes `/etc/security/limits.d/99-ethercat.conf` (`rtprio=99`,
   `memlock=unlimited`) — grants SCHED_FIFO and locked memory to members
   of the `ecat` group, so the daemon doesn't need `sudo` or file
   capabilities at runtime. Applies to the user, not the binary, so
   rebuilding the daemon does NOT require redoing anything.
6. Writes `/etc/sudoers.d/ecat` with NOPASSWD grants strictly scoped to
   `systemctl start/stop ethercat.service` and the `ecat-cgroup` helper.

**Boot-time CPU isolation (mandatory, the only mode).** Every install adds
`isolcpus=managed_irq,domain,N nohz_full=N rcu_nocbs=N psi=0
irqaffinity=<except-N>` to GRUB so CPU `N` is carved out at boot. This is
the only way to keep managed IRQs (NVMe queues etc.) and per-CPU kworker
chains (`psi_avgs_work`, `igb_watchdog`, `pci_pme_list_scan`) off the RT CPU.
It carries a known ~250 µs `nohz_full` jitter floor — accepted as the cost
of the only supported mode.

> **Note (removed):** the old `--strict-isolation` / `--strict-isolation=off`
> opt-out no longer exists. Boot isolation is always applied; there is no
> cgroup-only fallback. (NVMe-queue eviction on the RT CPU is handled via the
> isolation tokens plus `nvme.poll_queues`.)

**One reboot per GRUB change.** First run on a host writes the tokens
and prompts reboot. Re-runs are no-ops on GRUB (no reboot prompt).

### Teardown

```bash
sudo ecat_teardown.sh
```

Removes everything the setup created (service, helper, sudoers, udev
rule, limits, file caps, legacy GRUB params if present). Reboot only if
the teardown stripped legacy GRUB params (it will tell you).

## Run

This package provides the EtherCAT infrastructure (C++ daemon + ROS2 bridge). It is a prerequisite for all EtherCAT device packages (`tk_ros2_pkg_servos`, `tk_ros2_pkg_electrovalves`, etc.). One-time machine setup via `ecat_setup.sh` is required before first run (see Setup section above).

```bash
# Terminal 1 — RT daemon (must be first; runs SCHED_FIFO on isolated CPU)
ecat_daemon_start.sh

# Terminal 2 — ROS2 bridge (SHM <-> topics)
ros2 run tk_ros2_pkg_ethercat_master ecat_ros2_node
# or via launch file:
ros2 launch tk_ros2_pkg_ethercat_master launch_ecat_ros2.launch.py
```

No `sudo` needed at runtime — all permissions are configured by `ecat_setup.sh`.

### Why the EtherCAT NIC disappears from `ip link` (native `ec_igb`)

On a host using a **native** driver (`ec_igb` / `ec_igc`), the EtherCAT NIC has **no normal network interface while the daemon runs** — it is absent from `ip link`. This is by design, not a fault: the native driver hands the raw card to the master and publishes no netdev. (`ec_generic` keeps the netdev, at the cost of routing frames through the kernel stack.)

The **card itself is always there** — only its netdev comes and goes. Three states:

| State | `driver` | in `ip link`? |
|-------|----------|---------------|
| daemon running | `ec_igb` | no — EtherCAT owns the card |
| daemon stopped, still installed | `none` (slot reserved) | no — returns only after teardown |
| after `sudo ecat_teardown.sh` | `igb` | yes — ordinary NIC again |

See the card and its current driver in **any** of those states — this is the "`ip link` for EtherCAT":

```bash
ecat_diag.sh --nic
```

`sudo ecat_teardown.sh` rebinds the card to its stock driver, so the netdev returns **live, no reboot**. Full mechanics: [NIC_DRIVER_BINDING.md](../NIC_DRIVER_BINDING.md).

## Diagnostics

`ecat_diag.sh` is a two-phase RT-host health check. It validates every piece of
the setup (kernel module, cgroups, PAM limits, NIC IRQs, CPU isolation,
C-states, governor, daemon attributes) and reports PASS / WARN / FAIL with an
ordered list of suggested fixes at the end.

### Usage

```bash
# Full run — Phase A, then wait for daemon, then Phase B
ecat_diag.sh

# Phase A only (setup + idle baseline; daemon must be DOWN)
ecat_diag.sh --phase a

# Phase B only (runtime checks; daemon must already be running)
ecat_diag.sh --phase b
```

Options: `--config <path>` (override `ecat_bus.yaml`), `--rt-cpu N`,
`--window <seconds>` (Phase B observation window, default 10),
`--wait-timeout <seconds>` (how long to wait for the daemon between phases).

### Flow (default, both phases)

1. **Phase A** runs with the daemon **DOWN**. Validates setup artifacts and
   records an idle baseline of IRQ counts and C-state entries on the RT CPU.
2. The script prints *"Start the daemon now in another terminal"* and polls
   for the `ecat_rt_daemon` process once per second.
3. In another terminal, run `ecat_daemon_start.sh` (as you normally would).
4. As soon as the script sees the daemon PID, it pauses 3 s to let it
   stabilize and then automatically proceeds to **Phase B**.
5. **Phase B** confirms the cpuset partition is isolated, the daemon is
   inside it with the expected SCHED_FIFO priority and CPU affinity, and
   watches for IRQ activity on the RT CPU over the observation window.

### Exit codes

- `0` — all PASS
- `1` — at least one FAIL (host not ready; see the "Suggested fixes" list)
- `2` — WARN items only (likely fine, but worth investigating for jitter)

### Silent driver wedge — `Link: UP` but `Slaves: 0` and `Tx frames: 0`

Failure shape (looks like a hardware fault, isn't):

```
$ sudo ethercat master
Main:
  Link: UP
  Slaves: 0
  Tx frames: 0     ← but no bytes leaving the wire
  Tx errors: <climbing>
```

Cause: the wrong EtherCAT NIC driver got loaded into the kernel at some
earlier point — typically `ec_generic` slipped in before `ecat_setup.sh`
applied the `driver_override=ec_$DRIVER` pin, or someone called
`modprobe ec_generic` manually. Once `ec_generic` is holding `ec_master`,
the situation self-perpetuates across `systemctl` cycles:

- `systemctl stop ethercat.service` reports success but `rmmod ec_master`
  silently fails (held by `ec_generic`). Modules stay in memory.
- `systemctl start ethercat.service` is a no-op (modules already loaded,
  with stale `main_devices=`) but also reports success.
- `tk install` of a newer package version does not help — the bug is in
  loaded kernel state, not on disk.
- The pre-flight passes because `ec_master.ko` + the expected driver `.ko`
  are both *built* under `/lib/modules/$(uname -r)/ethercat/`. Pre-flight
  doesn't compare to what's actually *loaded*.

Diagnose in one line — what's actually loaded vs. what the unit expects:

```bash
lsmod | grep '^ec_'                                           # what's loaded
grep ExecStartPost /etc/systemd/system/ethercat.service       # what the unit modprobes
```

If those disagree (e.g. `lsmod` shows `ec_generic` but the unit modprobes
`ec_igb`), you're in this state.

Recovery — clear kernel state, then let the unit re-establish it cleanly:

```bash
sudo rmmod ec_generic ec_igb ec_igc 2>/dev/null
sudo rmmod ec_master
sudo systemctl restart ethercat.service
sudo ethercat master                                          # verify Tx frames climbing, Slaves > 0
```

The `2>/dev/null` is intentional: most of those `rmmod`s will fail (the
module isn't loaded), and that's fine — only one driver is ever held.
After this, `ec_master` reloads with the current `main_devices=` and the
PCI `driver_override` (since 0.3.4) keeps stock `igb`/`igc` from grabbing
the slot before `ec_$DRIVER` binds.

If you hit this on a fresh host, also re-run `sudo ecat_setup.sh` once —
that writes `/etc/modprobe.d/tk-ethercat-ec_*.conf` and propagates it into
the initramfs, so the override survives reboots and early-boot races.

## Configuration

Single config file: `configs/ecat_bus.yaml` — defines the bus topology: which slaves, at which positions, with which plugins.

```yaml
bus:
  cycle_us: 250              # RT loop cycle (microseconds)
  rt_cpu: 2                  # Isolated CPU core
  rt_priority: 90            # SCHED_FIFO priority
  shm_name: "/ecat_shm"
  cmd_timeout_ms: 50         # Daemon backstop (bridge dead): hold after this
  cmd_kill_ms: 250           # Daemon backstop (bridge dead): zero ALL commands after this
  warmup_cycles: 16000       # Wait for slaves to reach OP before running device logic
                             # Increase if slaves are slow (16000 × 250μs = 4 seconds)
                             # Servos are the bottleneck — their internal DS402 state machine
                             # walks INIT → PREOP → SAFEOP → OP sequentially, and SDO traffic
                             # serializes across drives. Scale roughly linearly with the number
                             # of servos on the bus (e.g. ~16000/servo at 250μs); other devices
                             # (I/O blocks, valves) add negligible warm-up time.

slaves:
  # Servo: needs explicit plugin .so (DS402 state machine)
  - name: "clamp"
    position: 0
    plugin: tk_ros2_pkg_servos::libdevice_servo.so
    publish_rate_hz: 100.0

  # I/O devices: just name + position (PDOs auto-discovered from slave SII)
  - name: "io_board"
    position: 1
    publish_rate_hz: 10.0

  - name: "valves_1"
    position: 2
    publish_rate_hz: 10.0
```

### Plugin resolution

By default, slaves use the **passthrough** plugin which auto-discovers PDOs from the slave's SII/EEPROM at startup. No configuration needed — just name, position, and rate.

Only devices with protocol logic (servos) need an explicit `plugin:` field pointing to a `.so`.

| Config field | When needed | Description |
|-------------|-------------|------------|
| *(none)* | Most devices | Passthrough with auto-discovered PDOs |
| `plugin: pkg::lib.so` | Servos / protocol devices | Load custom `.so` plugin |
| `pdo_map: pkg::file.yaml` | Optional override | Force specific PDO layout instead of auto-discovery |
| `plugin_config: pkg::file.yaml` | With `.so` plugins | Plugin-specific configuration |

Path resolution: `pkg::file` searches `AMENT_PREFIX_PATH/share/pkg/configs/` (YAML) or `AMENT_PREFIX_PATH/lib/pkg/` (`.so`).

## Plugin Interface

Device plugins implement `EcatDevicePlugin` (see `ecat_plugin_interface.hpp`):

```cpp
class EcatDevicePlugin {
    virtual std::vector<SyncManagerDesc> defineSyncManagers() = 0;
    virtual void configureSDOs(ec_slave_config_t* sc) = 0;          // queued (non-blocking) config-SDOs
    virtual void applyCriticalSDOs(ec_master_t*, uint8_t pos) {}    // optional: synchronous SDO download + readback
    virtual uint16_t shmCmdSize() const = 0;
    virtual uint16_t shmStateSize() const = 0;
    virtual void readInputs(uint8_t* domain_pd) = 0;
    virtual void writeOutputs(uint8_t* domain_pd) = 0;
    virtual void cyclicTask() = 0;
    virtual void readShmCmd(const uint8_t* shm_cmd) = 0;
    virtual void writeShmState(uint8_t* shm_state) = 0;
};
```

External `.so` plugins export: `create_plugin()`, `destroy_plugin()`, `plugin_api_version()`. Current `ECAT_PLUGIN_API_VERSION` is `3` — bumped from `2` when `applyCriticalSDOs` was added (vtable layout change). Plugin and master must be built against the same version.

The **passthrough plugin** is built-in for devices with no protocol logic (pure I/O). At startup, it auto-discovers the slave's PDO layout from its SII/EEPROM using the IgH API (`ecrt_master_get_sync_manager`, `ecrt_master_get_pdo`, `ecrt_master_get_pdo_entry`). No YAML or C++ needed. Optionally, a `pdo_map` YAML can override the auto-discovered layout.

## Adding a New Device

**I/O device (no protocol logic) — most devices:**
1. Add a slave entry to `ecat_bus.yaml` (just name, position, rate)
2. Write a Python codec for packing/unpacking the raw PDO bytes
3. Write a ROS2 transcriber node (topics/services for your device)

No plugin, no PDO map YAML, no C++ needed. PDOs are auto-discovered.

**Protocol device (DS402, custom FSM):**
1. Write a C++ plugin implementing `EcatDevicePlugin`, build as `.so`
2. Write a Python codec for packing/unpacking bytes
3. Add a slave entry with `plugin: pkg::lib.so` to `ecat_bus.yaml`

Zero changes to the ethercat master package in either case.

## ROS2 Interface

The bridge exposes four kinds of topics. Two flow *down* (commands from upstream
Python device nodes into SHM), two flow *up* (state from SHM out to ROS2).

```
                                          ┌── /ecat/health (BRIDGE → world, 10 Hz)
                                          │      bus + per-device safety snapshot
                                          │
business logic ─► device node (Py)        │
                       │                  │
        /ecat/{name}/command         ─►───┤
        /ecat/device_command_batch   ─►───┤ ► [BRIDGE] ─► SHM ─► [RT daemon] ─► slave
                                          │                                       │
                                          │                                       ▼
        /ecat/{name}/status          ─◄───┤ ◄── SHM ◄── (state PDOs from EtherCAT)
                                          │
                       ◄──────────────────┘
                       device node consumes status
```

### Messages (`tk_ros2_pkg_ethercat_master_interface`)

#### `EcatDeviceCommand`
Raw command bytes for one device, written verbatim to its SHM cmd region.
```
string  name      # device_name from ecat_bus.yaml
uint8[] data      # exactly cmd_size bytes for this device (padding included)
```
The bridge never inspects `data` — semantics are entirely up to the device
plugin (servo plugin, valve passthrough, etc.). Wrong size → message rejected
with a throttled WARN.

#### `EcatDeviceState`
Raw state bytes the EtherCAT slave produced (PDO inputs after one bus cycle).
```
string  name
uint8   bus_position
uint8[] data      # exactly state_size bytes
```
Pure telemetry. Direction: hardware → daemon → SHM → bridge → ROS2.

#### `EcatDeviceCommandBatch`
Multiple commands written atomically under a single SHM lock acquisition.
For when several devices must update in the same RT cycle.
```
EcatDeviceCommand[] commands
```

#### `EcatHealth` (the interesting one)
Two distinct safety layers in one message: bus-wide health from the daemon,
and per-device freshness observed by the bridge.

```
# --- Bus-wide (filled from ShmHealth, written by RT daemon) ---
int32  wkc                       # last working counter (matches expected = wkc_ok)
bool   all_op                    # all slaves reached OPERATIONAL state
bool   wkc_ok                    # last cycle's WKC matched the expected value
bool   cmd_hold                  # daemon GLOBAL deadman tier 1: holding last cmd
bool   cmd_kill                  # daemon GLOBAL deadman tier 2: zeroed everything
uint32 err_wkc_count             # WKC mismatches while all slaves were OP
uint32 err_wkc_preop_count       # WKC mismatches before all slaves reached OP
uint32 err_state_count           # SDO/state read failures
uint64 total_cycles              # daemon RT cycle counter
uint32 recovery_count            # times the daemon re-INITed slaves after a fault

# --- Per-device freshness (filled by the bridge, parallel arrays) ---
string[] device_names                  # SHM device order (index = ShmDeviceDesc index)
bool[]   device_cmd_zeroed             # bridge is currently zeroing this device's cmd
uint32[] device_ms_since_last_cmd      # ms since the bridge last received a cmd msg
uint32[] device_heartbeat_timeout_ms   # configured threshold (echo of ecat_bus.yaml)
```

Read it like this:

| You see | What it means |
|---|---|
| `all_op = false` | Some slave hasn't reached OPERATIONAL. Check daemon logs. |
| `wkc_ok = false`, `err_wkc_count` rising | Bus is dropping frames — wiring, EMI, missing slave. |
| `cmd_hold = true` | **Daemon** hasn't seen an SHM heartbeat in 50 ms. Bridge is sluggish or just died. |
| `cmd_kill = true` | **Daemon** zeroed everything — bridge has been dead > 250 ms. |
| `device_cmd_zeroed[i] = true` | **Bridge** zeroed device `i`'s cmd bytes. Its upstream Python node has been silent > `device_heartbeat_timeout_ms[i]`. |
| `device_ms_since_last_cmd[i]` flat / not increasing | Device `i`'s upstream Python node is publishing fine. |

`cmd_hold`/`cmd_kill` and `device_cmd_zeroed[]` are independent — one detects a
dead bridge, the other detects a dead device-side publisher. See **Two-Layer
Deadman** below.

### Topics

| Topic | Type | Direction | Rate | Notes |
|-------|------|-----------|------|------|
| `ecat/{name}/status` | `EcatDeviceState` | bridge → world | per-device `publish_rate_hz` (e.g. 100 Hz for `clamp`) | Raw state bytes the slave produced. Subscribed by the device's own Python node (e.g. servos node, electrovalves node) plus any diagnostics. QoS depth 10, RELIABLE by default — device nodes typically subscribe with `sensor_data` (BEST_EFFORT) for lower-jitter dispatch. |
| `ecat/{name}/command` | `EcatDeviceCommand` | world → bridge | device-side `heartbeat_hz` floor (e.g. 10 Hz), faster on every business-logic command | Raw command bytes for one device. Bridge writes to SHM and updates the per-device `last_recv_ns` (per-device deadman). QoS depth 1 (KEEP_LAST). |
| `ecat/device_command_batch` | `EcatDeviceCommandBatch` | world → bridge | on demand | Multiple devices written atomically under one SHM lock. Refreshes per-device `last_recv_ns` for every device in the batch. |
| `ecat/health` | `EcatHealth` | bridge → world | 10 Hz | One snapshot of everything safety-relevant. See message description above. |

### Services

| Service | Request | Response | Description |
|---------|---------|----------|-------------|
| `ecat_read_sdo` | `EcatReadSDO` | `EcatReadSDO` | Blocking CoE SDO upload (read), serviced asynchronously by the daemon's RT loop. |
| `ecat_write_sdo` | `EcatWriteSDO` | `EcatWriteSDO` | Blocking CoE SDO download (write), serviced asynchronously by the daemon's RT loop. |

#### `EcatReadSDO`

```
# Request
string  device_name   # slave name from ecat_bus.yaml
uint16  index         # CoE object index (e.g. 0x1009)
uint8   subindex      # CoE subindex
uint8   data_type     # 5 = UINT8, 6 = UINT16, 7 = UINT32, 9 = VISIBLE_STRING
---
# Response
bool    success
uint32  value         # numeric result for data_type 5/6/7; 0 for VISIBLE_STRING
string  str_value     # text result for data_type 9; empty for numeric reads
string  message       # error description on failure
```

`data_type = 9` reads a VISIBLE_STRING object (e.g. `0x1008` device name, `0x1009` HW version, `0x100A` FW version). The result is NUL-stripped and returned in `str_value`; `value` is always 0. All other `data_type` values return the numeric result in `value`; `str_value` is always empty. Blocking — typical round-trip 10–50 ms on a healthy mailbox. A dead mailbox fails with a clear error after a 1 s per-transfer timeout (the bridge gives up at 2 s); requests to slaves that are offline or below PREOP fail immediately.

#### `EcatWriteSDO`

```
# Request
string  device_name
uint16  index
uint8   subindex
uint8   data_type     # 5 = UINT8, 6 = UINT16, 7 = UINT32
uint32  value         # value to write
---
# Response
bool    success
string  message
```

## SHM Layout (v6)

```
ShmHeader (50B)
  magic, version, cycle_ns, num_devices, active_cmd_buffer, offsets...
ShmDeviceDesc[] (30B each)
  device_index, cmd_offset, cmd_size, state_offset, state_size, publish_rate_hz, name[16]
CmdBuffer A (header + device command regions)
CmdBuffer B (double-buffered)
State region (device state regions, contiguous)
ShmHealth (28B, seqlock-guarded)
ShmCmdLock (spinlock, process-shared)
```

Fully generic — no device types, no device-specific structs. Sizes are dynamic from plugins.

## Two-Layer Deadman

There are two heartbeats in the safety stack. Each one is *produced* by one
component and *enforced* by the next component down.

```
                       PRODUCER                         ENFORCER          ON FAILURE
 ┌────────────────────────────────────┐   ┌──────────────────────────┐   ┌─────────────────────┐
 │ Layer 1                            │   │                          │   │  zero ONLY that     │
 │ Python device node heartbeat       ├──►│   C++ bridge             ├──►│  device's cmd bytes │
 │ re-publishes last EcatDeviceCommand│   │   per-device freshness   │   │  in SHM             │
 │ at heartbeat_hz on                 │   │   tracks last_recv_ns[i] │   │  (other devices     │
 │ /ecat/{name}/command               │   │   threshold:             │   │   unaffected)       │
 │ (servos, electrovalves, …)         │   │   heartbeat_timeout_ms[i]│   │                     │
 └────────────────────────────────────┘   └──────────────────────────┘   └─────────────────────┘

 ┌────────────────────────────────────┐   ┌──────────────────────────┐   ┌─────────────────────┐
 │ Layer 2                            │   │                          │   │  HOLD then KILL ALL │
 │ C++ bridge heartbeat               ├──►│   RT daemon              ├──►│  cmd_hold @  50 ms  │
 │ refreshes SHM cmd-buffer timestamp │   │   global timestamp       │   │  cmd_kill @ 250 ms  │
 │ at 50 Hz (always — independent of  │   │   deadman                │   │  (every device)     │
 │ per-device freshness)              │   │                          │   │                     │
 └────────────────────────────────────┘   └──────────────────────────┘   └─────────────────────┘
```

The two layers are independent — they compose, they don't replace each other.
A dead Python node trips Layer 1 only. A dead bridge trips Layer 2 only.

### Layer 1 — device node heartbeat, bridge enforces

Each device-side Python node (servos, electrovalves, …) creates a timer at
its configured `heartbeat_hz` that re-publishes the last `EcatDeviceCommand`.
This is the *only* signal the bridge has that the upstream is still alive
(business-logic silence is indistinguishable from a crash without it).

The bridge tracks `last_recv_ns[i]` per device. On every 50 Hz tick:

- **Hold (silence ≤ heartbeat_timeout_ms[i])** — bridge does NOT touch
  device `i`'s cmd bytes. The last command remains in SHM and the daemon
  keeps applying it on every RT cycle.
- **Zero (silence > heartbeat_timeout_ms[i])** — bridge `memset`s device
  `i`'s cmd region to 0 and sets `device_cmd_zeroed[i] = true` on
  `/ecat/health`. Other devices are untouched.

`heartbeat_timeout_ms` is **REQUIRED** for every slave in `ecat_bus.yaml`
(bridge refuses to start otherwise). Pick it larger than `1 / heartbeat_hz`
plus expected jitter — 5× the heartbeat period is a comfortable default
(e.g. 10 Hz heartbeat ⇒ 500 ms timeout).

State transitions log on the bridge:
- `[safety] Device 'X' silent for NNN ms (>500 ms) — zeroing cmd bytes` (WARN)
- `[safety] Device 'X' fresh again (NNN ms since last cmd)` (INFO)

### Layer 2 — bridge heartbeat, daemon enforces

The C++ bridge runs a 50 Hz timer that always refreshes the SHM cmd-buffer
timestamp, regardless of any per-device staleness. This is the bridge's
liveness signal to the daemon: "I am still alive, keep applying SHM
commands."

The RT daemon checks the SHM timestamp on every cycle:

```
                cmd_timeout_ms (50 ms)         cmd_kill_ms (250 ms)
 ──────────────────┼──────────────────────────────────┼──────────────
 Normal            │             Hold                 │     Kill
 (read new cmds)   │   (keep last cmd, set flag)      │  (zero all)
```

- **Normal** (silence < 50 ms): daemon reads fresh commands from SHM.
- **Hold** (50–250 ms): daemon keeps applying the last command. `cmd_hold`
  flag set in `/ecat/health`. No log output. Harmless — resumes on next
  bridge heartbeat.
- **Kill** (> 250 ms): daemon zeros every device's command bytes (servos
  drop torque, valves de-energize, every slave gets all-zero PDOs).
  `cmd_kill` flag set. Logs `CRITICAL`. **Only fires when the bridge itself
  is dead** — the bridge's heartbeat is unconditional, so SHM silence
  implies the bridge process is gone.

The daemon-level deadman is global by construction: the SHM has a single
cmd-buffer timestamp, not one per device, so when this layer fires it
zeros everything.

E-stop and disable are explicit command writes — they work regardless of
deadman state.

### Choosing thresholds

| Knob | Owner | Where | Typical value | What to tune for |
|---|---|---|---|---|
| `heartbeat_hz` | device node | `<device>_config.yaml` (per device) | 10 Hz | Faster than `1000 / heartbeat_timeout_ms`, with jitter margin. Higher = faster crash detection but more bus traffic. |
| `heartbeat_timeout_ms` | bridge | `ecat_bus.yaml` (per slave) | 500 ms | ~5× the period of the device's `heartbeat_hz`. Higher = more tolerance to pub jitter, slower crash detection. |
| `cmd_timeout_ms` | daemon | `ecat_bus.yaml` (`bus:` block) | 50 ms | Daemon backstop (bridge dead): hold tier. Tuned for the bridge's 50 Hz heartbeat — change in step with the bridge's tick rate, not per-device. |
| `cmd_kill_ms` | daemon | `ecat_bus.yaml` (`bus:` block) | 250 ms | Daemon backstop (bridge dead): kill tier. Same constraint. |

The Python heartbeat runs on a `SingleThreadedExecutor` for predictable
dispatch (see `tk_ros2_pkg_servos/CLAUDE.md` and the heartbeat study at
`heartbeat_testing/progress.md`). With `SingleThreadedExecutor`, sustained
publish jitter has been measured ≤ 51 ms p99 at 20 Hz — comfortable margin
under a 500 ms Layer 1 budget.

The bridge heartbeat runs in C++ (no Python GIL) at 50 Hz, so the daemon's 50 ms hold threshold has 2–3× margin under healthy operation. `cmd_timeout_ms` and `cmd_kill_ms` are tuned to that bridge tick rate; if you ever change the bridge's heartbeat frequency, retune both together.

E-stop and disable are explicit command writes — they work regardless of deadman state.

## Monitoring

Optional CPU-jitter telemetry, off by default. Enable it by editing the
`monitoring:` block in `ecat_bus.yaml`:

```yaml
monitoring:
  enabled: false              # opt-in (default: disabled, zero RT overhead)
  log_dir: "/var/log/ecat"    # daemon mkdirs if missing (mode 0775); ~ and ${VAR} are expanded
  summary_period_ms: 1000     # 1 Hz baseline rows
  spike_threshold_us: 0       # 0 → auto = cycle_us / 5 (e.g. 100µs at 500µs cycle)
  spike_burst_window_ms: 50   # coalesce contiguous spikes into one row
  ring_capacity: 4096         # SPSC ring slots (~2 s @ 2 kHz)
  rotate_max_mb: 64           # per-CSV size cap before suffix rotation
  rotate_keep_days: 7         # files older than this are unlinked daily
```

When enabled, the RT loop pushes per-cycle samples into a lock-free SPSC
ring; a non-RT consumer thread drains it and writes two CSV streams under
`log_dir`:

- `summary-YYYYMMDD.csv` — one row per `summary_period_ms` with rolling
  jitter stats and delta IRQ/softirq/schedstat counters for the RT CPU
- `spikes-YYYYMMDD.csv` — one row per burst of cycles whose jitter
  exceeded `spike_threshold_us`, coalesced via `spike_burst_window_ms`

When disabled the RT loop has a single null-pointer branch per cycle (no
allocation, no sample push, no consumer thread). See the in-source
`MONITORING.md` for the full column reference, triage examples, and
optional ftrace integration via `ecat_ftrace_setup.sh` / diagnostic
bundling via `ecat_jitter_diag.sh`.

## Version

**0.3.5**

## Maintainers

- **THEKER Robotics Engineering Team**
- **Raul Adell Segarra** — (r.adell@theker.eu)
