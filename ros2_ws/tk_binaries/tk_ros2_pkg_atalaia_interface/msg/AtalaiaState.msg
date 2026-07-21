# Decoded telemetry + status for one Atalaia Shield v3, published periodically.
#
# Sensor fields are decoded from the 32-byte TxPDO (DAEMON_INTEGRATION.md S4,
# TX_FMT = "<hHIhhhHhHHH3HH"). Status / state / fault fields are polled
# acyclically from the 0x6000 object (S5/S6). Values are faithful decodes of
# what the board reports — no derived/computed fields.

string device_name           # device name from config

# --- state machine / faults (CoE 0x6000) ---
uint8 device_state           # 0 BOOT 1 INIT 2 SENSOR_INIT 3 SAFE 4 STANDBY
                             # 5 READY 6 ACTIVE 7 WARN_DERATED 8 FAULT
                             # 9 RECOVERY 10 FWUPD
uint16 status_word           # 0x6000:01 packed status word
uint32 warnings              # 0x6000:04 warning bitfield (S7)
uint32 faults                # 0x6000:05 fault bitfield (S7)
uint32 latched_faults        # 0x6000:06 latched faults

# --- environment (BME280) ---
float32 bme_temp_c           # board ambient temperature, degC
float32 bme_humidity         # relative humidity, %
uint32 bme_pressure_pa       # barometric pressure, Pa

# --- power rails / consumption ---
float32 efuse_current_ma     # total board load current (eFuse IMON), mA
float32 vin_volts            # 48 V PoE input rail, V
float32 v24_volts            # 24 V buck rail, V
float32 wled0_current_ma     # strip A white-LED current, mA
float32 wled1_current_ma     # strip B white-LED current, mA

# --- thermal probes ---
float32 ntc1_c               # chassis NTC 1, degC (NaN if open/short)
float32 ntc2_c               # chassis NTC 2, degC (NaN if open/short)

# --- fans ---
uint16[3] fan_rpm            # measured fan 1/2/3 tach, rpm

# --- raw ---
uint8 efuse_status           # eFuse EFS_* bitfield (TxPDO off 30, S7)
uint8[] raw_tx               # raw 32-byte TxPDO image (debug)
