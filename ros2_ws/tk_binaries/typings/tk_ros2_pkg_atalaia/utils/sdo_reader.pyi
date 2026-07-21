from dataclasses import dataclass
from rclpy.node import Node as Node

DT_UINT8: int
DT_UINT16: int
DT_UINT32: int
DT_INT8: int
DT_INT16: int
DT_INT32: int

@dataclass
class SDOEntry:
    """Static description of an SDO entry to read/write."""
    index: int
    subindex: int
    dtype: int
    signed: bool = ...

class SDOReader:
    """Async SDO read/write helper bound to one EtherCAT device.

    Args:
        node: owning ROS2 node (used to create clients + spin the executor).
        device_name: EtherCAT alias as declared in ecat_bus.yaml.
        timeout_s: per-call wall-clock timeout, in seconds.
    """
    def __init__(self, node: Node, device_name: str, timeout_s: float = 1.0) -> None: ...
    def read_sync(self, entry: SDOEntry) -> int | None:
        """Read one SDO entry, blocking on the executor up to timeout_s.
        Returns the decoded int, or None if it failed/timed out (transient —
        the slave may simply be busy this cycle)."""
    def write_sync(self, entry: SDOEntry, value: int) -> tuple[bool, str]:
        """Write one SDO entry, blocking up to timeout_s. Returns (ok, msg)."""
