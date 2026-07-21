# Generic device command: raw byte payload for any device type.
# The transcriber node in each device package packs typed fields into data[].

string name         # Device name (matches bus config)
uint8[] data        # Raw command bytes (size must match device's shmCmdSize)
