# Full control image for one Atalaia Shield v3 lighting module.
#
# Maps onto the 16-byte RxPDO control header (DAEMON_INTEGRATION.md S3).
# Per-strip RGB, white-LED PWM and white-LED DAC are independent.
#
# mode = 0 (SOLID): strip_a_rgb / strip_b_rgb paint every active LED of
#                   each strip one colour; the per-LED arrays are ignored.
# mode = 1 (PER-LED): each LED takes its colour from the per-LED buffer
#                     (0x00RRGGBB per LED, first active_led_count LEDs lit).
#                     Empty per-LED array => leave that strip's buffer
#                     unchanged.

string device_name           # target device (matches ecat_bus.yaml + config)

uint8 MODE_SOLID = 0
uint8 MODE_PER_LED = 1
uint8 mode                   # 0 = SOLID, 1 = PER-LED

uint8[3] strip_a_rgb         # SOLID colour, R/G/B (0-255)
uint8[3] strip_b_rgb         # SOLID colour, R/G/B (0-255)

uint8 white_a_pwm            # strip A white-LED PWM dim, 0-255
uint8 white_b_pwm            # strip B white-LED PWM dim, 0-255
uint16 white_a_dac           # strip A white-LED current setpoint, 0-4095
uint16 white_b_dac           # strip B white-LED current setpoint, 0-4095

uint8[3] fan_duty            # fan 1/2/3 PWM duty, 0-255 (ignored if FAN_AUTO)

uint32[] strip_a_leds        # PER-LED buffer strip A (0x00RRGGBB), up to 120
uint32[] strip_b_leds        # PER-LED buffer strip B (0x00RRGGBB), up to 120
