int32 wkc
bool all_op
bool wkc_ok
bool cmd_hold
bool cmd_kill
uint32 err_wkc_count
uint32 err_wkc_preop_count
uint32 err_state_count
uint64 total_cycles
uint32 recovery_count

# Per-device freshness (parallel arrays indexed together).
# Bridge tracks the wall time of the last command received for each device and
# zeros that device's command bytes if silence > heartbeat_timeout_ms (per-slave
# in ecat_bus.yaml). Distinct from cmd_hold/cmd_kill above, which are the
# daemon-side global deadman protecting against a dead bridge.
string[] device_names
bool[]   device_cmd_zeroed              # true while the bridge is zeroing this device's cmd
uint32[] device_ms_since_last_cmd
uint32[] device_heartbeat_timeout_ms    # echo of the configured per-device timeout
