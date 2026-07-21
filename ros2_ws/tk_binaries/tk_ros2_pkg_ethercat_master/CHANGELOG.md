# Changelog

## [0.4.4] — 2026-07-20

### Fixed
- **False-positive OP-timeout FATAL (empty `stuck:` list).** The runtime
  OP-recovery deadline raced the last slave's PREOP→OP transition: the FATAL
  decision read `all_op`, which is refreshed only at 1 Hz, while per-device AL
  states are polled at 20 Hz — so the daemon could abort with every slave
  already operational (observed 2026-07-20 on mnlla0103 after an FSoE door
  event: `FATAL: bus failed to reach OP for 5s (stuck: )` in the same tick as
  `'mbm' pos 4: PREOP -> OP`). The deadline block now re-checks the fresh
  per-device snapshot and continues (`false-positive FATAL averted` in the
  log) when nothing is actually stuck. A device must be online AND in OP to
  be skipped from the stuck list.

### Added
- **`bus.op_wait_fatal_s` (default 90)** — the runtime non-OP→FATAL window is
  now configurable (was hardcoded 5 s). Sized for safety devices (Pilz PNOZ,
  Euchner MBM) that need well over 5 s to re-climb INIT→OP after an FSoE
  event. Existing configs without the key keep working (default applies).
- **In-place config re-trigger, `bus.op_retrigger_s` (default 10).** Every
  `op_retrigger_s` seconds of sustained non-OP the daemon calls
  `ecrt_master_reset()` so IgH retries the slave config FSM in place —
  cold-started safety slaves reach OP without a single daemon restart
  (previously 3–10 min of restart churn every morning). Set 0 to disable
  (patient wait only).
- **`bus.sdo_ready_budget_ms` (default 60000)** — SDO-readiness gate: before
  configuring, wait until every slave's CoE server answers 3 consecutive
  reads (shared wall-clock budget). A slave can report PREOP with a live
  mailbox long before its SDO application serves requests (MBM: ~30 s after
  power-on); configuring earlier aborts the PREOP→SAFEOP mapping downloads.

### Changed
- The `OP drop detected after healthy OP` line now states the FATAL deadline
  (`FATAL restart if not back to OP within 90s`).
- **`0` semantics defined for the new knobs.** `op_wait_fatal_s: 0` = never
  FATAL (wait forever; previously it would have tripped the deadline check on
  every healthy cycle), `op_retrigger_s: 0` = no re-trigger,
  `sdo_ready_budget_ms: 0` = shared budget off (a device with
  `preop_settle_ms` set still gates — that is also the recipe for mixed buses
  with non-CoE slaves: global 0 + per-device `preop_settle_ms` on the CoE
  devices that need the gate).
- **`ecat_gate` default `--timeout` 60 s → 180 s**, sized above
  `op_wait_fatal_s` (90 s) + `sdo_ready_budget_ms` (60 s) so downstream
  bringup gating outlives a slow safety-device cold start instead of
  fail-closing while the daemon is still patiently waiting. Launches passing
  an explicit `--timeout` should review it against the same sum.
- The daemon echoes its effective timing knobs at startup
  (`[ecat] Timing config: cycle_us=... warmup_cycles=... sdo_ready_budget_ms=...
  op_wait_fatal_s=... op_retrigger_s=...`) — the 2026-07-20 incident had to be
  diagnosed against a window that existed only inside the binary.
- **RT tuning is now "global out"** — the setup no longer applies any host-wide
  knob to chase latency. Removed: `netdev_budget=64` (`78e5cb4`), `no_turbo=1`
  (`618a852`), `min_perf_pct=100` floor (`5f99f39`), the `/dev/cpu_dma_latency=0`
  PM-QoS holder (`9b401d9`), and the self-heal + knob-drift watchdog (`b995adc`,
  which also makes `ecat-cgroup up` strict). Only per-RT-core, per-daemon-lifetime
  tuning remains. Net effect: re-enables Turbo, dynamic frequency, and deep idle
  on every non-RT core — a general-CPU-performance win for the vision/ML load.
- `nvme.poll_queues=1` was added (`35970ab`) then reverted (`b72335e`) — it did
  not evict the NVMe completion IRQ from the RT CPU.

### Docs
- New [RT_TUNING_GLOBAL_OUT.md](RT_TUNING_GLOBAL_OUT.md): what was removed and why,
  the general-performance rationale, and a read-only host certification procedure.

> **Downstream configs:** no action required (defaults apply), but cells with
> slow safety devices should review `op_wait_fatal_s` in their
> `environments/<env>/ecat_bus.yaml` against their worst-case re-climb time.

## [0.4.3] — 2026-07-11

### Added

- **Flight-recorder ring for OP-drop post-mortems.** The daemon continuously
  records bus state (slaves_responding, al_states, NIC link_up, per-device AL
  state) into a preallocated RT-safe ring (~13–26 s of history) at the existing
  state-poll cadence — no new bus I/O, no jitter impact. On self-heal back to
  OP or on the 5 s FATAL it dumps a delta-compressed `[trace]` trajectory to
  stderr, so an OP drop can be diagnosed as a full-bus link blink vs a
  partial/downstream drop instead of guessing from the 1 Hz "Waiting for OP"
  line. Healthy steady-state logging is unchanged. Note: the trace goes to the
  daemon's stderr — persist it (or capture it in the launcher/panel) if you
  need it after the process exits.

## [0.4.2] — 2026-07-10

### Fixed

- **Consumer install shim: executables lost their exec bit.** The shipped
  `CMakeLists.txt` copied `lib/` with CMake's default permissions (644), so
  `ecat_rt_daemon`, `ecat_ros2_node`, `ecat_gate` and the `ecat_*.sh` scripts
  landed non-executable in `install/` on a fresh consumer workspace — `ros2
  run` and the daemon launcher failed with "executable not found". The shim
  now preserves source permissions (`USE_SOURCE_PERMISSIONS`). Binaries are
  unchanged from the previous release.

## [0.3.7] — 2026-06-03

### Fixed
- **SDO service vs dead CoE mailbox** — `ecat_read_sdo` / `ecat_write_sdo` no longer wedge the daemon when a slave's CoE mailbox dies (e.g. a servo dropping out of OP with a sync error). SDO transfers are now serviced asynchronously inside the RT loop: a dead mailbox returns a clear error after a 1 s per-transfer timeout, requests to offline or pre-PREOP slaves fail immediately, and shutdown always completes — previously the daemon could become an unkillable zombie that held the EtherCAT master reserved (EBUSY on every relaunch) until reboot. Service request/response surface is unchanged.
- **`monitoring.log_dir` portability** — leading `~` and `${VAR}` references are now expanded when reading the config, so paths like `"${TK_WORKSPACE}/ros2_ws/logs/ecat"` work on any machine. Hardcoded absolute paths keep working as before.

## [0.3.6] — 2026-06-03

### Fixed
- **`ecat_setup.sh` on hardened hosts** — IgH build now succeeds on machines where `/tmp` is mounted `noexec` (e.g. Inditex security policy). The build directory falls back to `/var/lib/igh_ethercat_build` when the flag is detected; normal hosts continue using `/tmp` as before.

## [0.3.5] — 2026-06-02

### Added
- **`EcatReadSDO.str_value`** — `EcatReadSDO` response now includes a `string str_value` field. Set `data_type: 9` to read a VISIBLE_STRING object (e.g. `0x1008` device name, `0x1009` HW version, `0x100A` FW version); the NUL-stripped text is returned in `str_value`. Numeric reads (`data_type` 5/6/7) are unchanged — `str_value` is empty, `value` carries the result as before.
- **`SHM_VERSION` bumped 9 → 10** — `ShmSdoRequest` gained a 64-byte `str_value` buffer (struct now 188 B). Daemon and bridge built from this release are not wire-compatible with v9 binaries; update both together.
