# tk_ros2_pkg_ethercat_master_interface

ROS2 interface definitions (messages and services) for the `tk_ros2_pkg_ethercat_master` package.

## Messages

### EcatServoCommand.msg

DS402 servo command. Supports runtime mode switching.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Device name from config |
| `target_velocity` | int32 | Velocity command |
| `target_position` | int32 | Position command |
| `target_torque` | int16 | Torque command (0.1% of rated) |
| `mode_of_operation` | int8 | DS402 mode (0 = use config default) |
| `max_profile_velocity` | uint32 | Profile velocity limit (0 = use config default) |

**Mode constants:** `MODE_PROFILE_POSITION=1`, `MODE_PROFILE_VELOCITY=3`, `MODE_PROFILE_TORQUE=4`, `MODE_CSP=8`, `MODE_CSV=9`, `MODE_CST=10`

### EcatServoStatus.msg

DS402 servo feedback/status.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Device name |
| `bus_position` | uint8 | Position on EtherCAT bus |
| `status_word` | uint16 | DS402 status word |
| `ds402_state` | uint8 | Current DS402 state |
| `fault_code` | uint16 | Fault/error code |
| `actual_position` | int32 | Current position (encoder counts) |
| `torque_feedback` | int16 | Current torque (0.1% of rated) |
| `mode_display` | int8 | Active operation mode |
| `touch_probe_status` | uint16 | Touch probe status |
| `touch_probe_1_pos` | int32 | Touch probe 1 position |
| `touch_probe_2_pos` | int32 | Touch probe 2 position |

### EcatHealth.msg

Bus health diagnostics.

| Field | Type | Description |
|-------|------|-------------|
| `wkc` | int32 | Working counter |
| `all_op` | bool | All slaves operational |
| `wkc_ok` | bool | Working counter matches expected |
| `err_wkc_count` | uint32 | Accumulated WKC errors |
| `err_state_count` | uint32 | Accumulated state errors |
| `total_cycles` | uint64 | Total RT cycles |
| `recovery_count` | uint32 | Recovery attempts |

### EcatIsokernelCommand.msg

Command for Isokernel I/O modules.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Device name |
| `mcp_mask` | uint16 | MCP output mask |
| `mcp_value` | uint16 | MCP output value |
| `pca_masks` | uint16[] | PCA channel masks |
| `pca_duties` | uint16[] | PCA channel duties |

### EcatIsokernelStatus.msg

Status from Isokernel I/O modules.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Device name |
| `bus_position` | uint8 | Position on EtherCAT bus |
| `analog_mask` | uint8 | Active analog channels mask |
| `analog_channels` | uint16[] | Analog channel readings |
| `pcf8574_mask` | uint8 | PCF8574 I/O mask |
| `pcf8574_value` | uint8 | PCF8574 I/O value |
| `pcf8575_mask` | uint16 | PCF8575 I/O mask |
| `pcf8575_value` | uint16 | PCF8575 I/O value |
| `cycle_count` | uint64 | RT cycle count |

## Services

### EcatServoEnable.srv

Enable or disable a DS402 servo drive.

| Request | Type | Description |
|---------|------|-------------|
| `device_name` | string | Device name |
| `enable` | bool | True = enable, False = disable |

| Response | Type | Description |
|----------|------|-------------|
| `success` | bool | Operation result |
| `ds402_state` | uint8 | Resulting DS402 state |
| `message` | string | Status message |

### EcatWriteSDO.srv

Write a Service Data Object to a drive.

| Request | Type | Description |
|---------|------|-------------|
| `device_name` | string | Device name |
| `index` | uint16 | SDO index |
| `subindex` | uint8 | SDO subindex |
| `data_type` | uint8 | Data type |
| `value` | uint32 | Value to write |

| Response | Type | Description |
|----------|------|-------------|
| `success` | bool | Operation result |
| `message` | string | Status message |

### EcatReadSDO.srv

Read a Service Data Object from a drive.

| Request | Type | Description |
|---------|------|-------------|
| `device_name` | string | Device name |
| `index` | uint16 | SDO index |
| `subindex` | uint8 | SDO subindex |
| `data_type` | uint8 | Data type |

| Response | Type | Description |
|----------|------|-------------|
| `success` | bool | Operation result |
| `value` | uint32 | Read value |
| `message` | string | Status message |
