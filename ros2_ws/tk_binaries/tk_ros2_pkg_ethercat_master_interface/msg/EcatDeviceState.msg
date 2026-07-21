# Generic device state: raw byte payload for any device type.
# The transcriber node in each device package unpacks data[] into typed fields.

string name         # Device name (matches bus config)
uint8 bus_position  # EtherCAT bus position
uint8[] data        # Raw state bytes (size matches device's shmStateSize)
