# TkStereoCamMsg.msg
#
# Combined synchronized stereo camera message
# Contains:
#   - RGB image
#   - Depth image
#   - Camera info
#
# Use this for pipelines that expect a single RGBD message.

std_msgs/Header header
sensor_msgs/Image color
sensor_msgs/Image depth
sensor_msgs/CameraInfo camera_info
