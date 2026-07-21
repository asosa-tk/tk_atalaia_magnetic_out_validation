from _typeshed import Incomplete
from dataclasses import dataclass

RXPDO_SIZE: int
HEADER_SIZE: int
LEDS_PER_STRIP: int
PANEL_LEDS: int
STRIP_A_OFF: int
STRIP_B_OFF: int
MODE_SOLID: int
MODE_PER_LED: int
STRIP_A: str
STRIP_B: str
STRIP_BOTH: str
DAC_MAX: int

def create_buffer() -> bytearray:
    """Allocate a zeroed 976-byte RxPDO buffer (SOLID mode, all dark)."""
def set_strip_rgb(buf: bytearray, strip: str, r: int, g: int, b: int) -> bool:
    """Set the SOLID-mode RGB colour of strip a/b/both. Returns False if the
    strip name is invalid. Does not change the MODE byte."""
def set_white(buf: bytearray, strip: str, pwm: int, dac: int) -> bool:
    """Set white-LED enable + brightness of strip a/b/both.

    FW 2.0.3: the PWM byte is now an ON/OFF gate (0 = off, >0 = full on); it no
    longer dims. Brightness is the analog DAC only (0..DAC_MAX). `pwm` is
    normalised to 0/1, `dac` clamped to 0..DAC_MAX."""
def set_fan(buf: bytearray, fan_index: int, duty: int) -> bool:
    """Set fan duty (0-255). fan_index 1-3 for one fan, 0 for all three."""
def set_mode(buf: bytearray, mode: int) -> None:
    """Set the MODE byte (0 = SOLID, 1 = PER-LED)."""
def get_mode(buf: bytearray) -> int: ...
def set_strip_leds(buf: bytearray, strip: str, leds: list[int]) -> bool:
    """Write a PER-LED buffer (0x00RRGGBB per LED) into strip a/b. Up to
    LEDS_PER_STRIP entries; extra entries are ignored. 'both' not allowed
    (each strip has its own pattern)."""
def clear_outputs(buf: bytearray) -> None:
    """Darken everything: zero RGB, white PWM/DAC, fans and both per-LED
    buffers. Leaves the MODE byte unchanged."""
def pack_command(buf: bytearray) -> list[int]:
    """Return the RxPDO as a list[int] for EcatDeviceCommand.data."""

TX_FMT: str
TX_SIZE: Incomplete
DEFAULT_NTC_BETA: int

@dataclass
class Telemetry:
    """Decoded TxPDO. Engineering units; NTC temps are NaN if open/short."""
    bme_temp_c: float
    bme_humidity: float
    bme_pressure_pa: int
    efuse_current_ma: float
    efuse_die_temp_c: float
    wled0_current_ma: float
    vin_volts: float
    wled1_current_ma: float
    v24_volts: float
    ntc1_c: float
    ntc2_c: float
    fan_rpm: tuple[int, int, int]
    efuse_status: int

def ntc_mv_to_c(mv: int, beta: int = ...) -> float:
    """Convert a raw NTC divider reading (mV) to degC (S4). Returns NaN for
    an open/short reading (no thermistor present)."""
def unpack_telemetry(data, beta: int = ...) -> Telemetry:
    """Decode a 32-byte TxPDO image into a Telemetry. Accepts bytes or a
    list[int]; extra trailing bytes are ignored."""

SDO_U8: int
SDO_U16: int
SDO_U32: int
OD_ACTIVE_LED_A: Incomplete
OD_ACTIVE_LED_B: Incomplete
OD_EFFECT_MODE: Incomplete
OD_WHITE_PWM_FREQ: Incomplete
OD_FAN_PWM_FREQ: Incomplete
OD_WHITE_CURRENT_LIMIT: Incomplete
OD_NTC_BETA: Incomplete
OD_CONTROL_WORD: Incomplete
OD_STATUS_WORD: Incomplete
OD_DEVICE_STATE: Incomplete
OD_WARNINGS: Incomplete
OD_FAULTS: Incomplete
OD_LATCHED_FAULTS: Incomplete
CONFIG_FIELDS: Incomplete
CW_ENABLE: int
CW_WHITE_EN: int
CW_FAN_AUTO: int
CW_BUCK_REQ: int
CW_RGB_MASTER: int
CW_FAULT_RESET: int
CW_WARN_ACK: int
CW_TEST: int
DEVICE_STATE_NAMES: Incomplete
WARNING_NAMES: Incomplete
FAULT_NAMES: Incomplete
EFUSE_STATUS_NAMES: Incomplete

def decode_bits(value: int, names: dict[int, str]) -> list[str]:
    """Return the names of the set bits in `value`, for logging/diagnostics."""
