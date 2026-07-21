import yaml
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def _read_stereo_params(config):
    """Return the stereo_camera_node parameter block (any key form).

    Supports both the legacy ``stereo_camera_node:`` top-level key and
    the namespace-agnostic ``/**/stereo_camera_node:`` wildcard form.
    """
    block = config.get('/**/stereo_camera_node') or config.get('stereo_camera_node') or {}
    return block.get('ros__parameters', {})


def _make_viewer_node(stereo_params):
    """Build the aggregated stereo_viewer_node when merged mode is on.

    The fast launcher currently only runs a single camera at the root
    namespace, so the viewer is wired for that mode (no `multi_camera`
    spawn list). Reads layout, topic, and QoS knobs from the shared
    ``stereo_camera_node`` block so configuration stays in one place.
    """
    viz = stereo_params.get('visualization', {}) or {}
    image_qos = stereo_params.get('image_qos', {}) or {}
    rgbd_topic_suffix = stereo_params.get('pub_rgbd_topic', 'stereo/rgbd')

    return Node(
        package='tk_ros2_pkg_stereocamera',
        executable='stereo_viewer_node',
        name='stereo_viewer_node',
        parameters=[{
            'cameras': [''],
            'rgbd_topic_suffix': rgbd_topic_suffix,
            'visualization.display_fps': float(viz.get('display_fps', 30.0)),
            'visualization.grid_cols': int(viz.get('grid_cols', 2)),
            'visualization.tile_width': int(viz.get('tile_width', 640)),
            'visualization.tile_height': int(viz.get('tile_height', 360)),
            'pub_merged_topic': str(viz.get('pub_merged_topic', 'stereo_viewer/merged_frame')),
            'image_qos.reliability': str(image_qos.get('reliability', 'best_effort')),
            'image_qos.depth': int(image_qos.get('depth', 5)),
        }],
    )


def launch_setup(context, *args, **kwargs):
    param_file_path = LaunchConfiguration('param_file').perform(context)

    with open(param_file_path) as f:
        config = yaml.safe_load(f)

    rtsp_params = config.get('rtsp_camera_node', {}).get('ros__parameters', {})
    rtsp_enabled = rtsp_params.get('rtsp', {}).get('enabled', False)
    stereo_params = _read_stereo_params(config)
    merged_viz = bool(
        (stereo_params.get('visualization') or {}).get('merged', False)
    )

    nodes = []

    if rtsp_enabled:
        nodes.append(Node(
            package='tk_ros2_pkg_stereocamera',
            executable='rtsp_camera_node',
            name='rtsp_camera_node',
            parameters=[param_file_path]
        ))

        rtsp_topic_overrides = {
            'color_image_topic': rtsp_params.get('pub_color_topic', 'rtsp/color/image_raw'),
            'depth_image_topic': rtsp_params.get('pub_depth_topic', 'rtsp/depth/image_raw'),
            'camera_info_topic': rtsp_params.get('pub_camera_info_topic', 'rtsp/camera_info'),
        }
        nodes.append(Node(
            package='tk_ros2_pkg_stereocamera',
            executable='stereo_camera_node_fast',
            name='stereo_camera_node',
            parameters=[param_file_path, rtsp_topic_overrides]
        ))
    else:
        nodes.append(Node(
            package='tk_ros2_pkg_stereocamera',
            executable='stereo_camera_node_fast',
            name='stereo_camera_node',
            parameters=[param_file_path]
        ))

    if merged_viz:
        nodes.append(_make_viewer_node(stereo_params))

    return nodes


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument(
            'param_file',
            description='Full path to the parameter YAML file'
        ),
        OpaqueFunction(function=launch_setup),
    ])
