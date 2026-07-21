# DS402 operation mode constants
int8 MODE_DEFAULT=0
int8 MODE_PROFILE_POSITION=1
int8 MODE_PROFILE_VELOCITY=3
int8 MODE_PROFILE_TORQUE=4
int8 MODE_CSP=8
int8 MODE_CSV=9
int8 MODE_CST=10

string name
int32 target_velocity
int32 target_position
int16 target_torque
int8 mode_of_operation        # 0 = use config default
uint32 max_profile_velocity   # 0 = use config default
