import yaml
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def _read_rtsp_params(config):
    """Return the rtsp_camera_node parameter block, regardless of YAML key form.

    Supports both the legacy ``rtsp_camera_node:`` top-level key and the
    namespace-agnostic ``/**/rtsp_camera_node:`` wildcard form used by
    multi-camera configs.
    """
    block = config.get('/**/rtsp_camera_node') or config.get('rtsp_camera_node') or {}
    return block.get('ros__parameters', {})


def _read_stereo_params(config):
    """Return the stereo_camera_node parameter block (any key form).

    Mirrors ``_read_rtsp_params`` for the post-processing/viewer config —
    used to extract the ``visualization.*`` block that drives whether the
    merged viewer should be spawned.
    """
    block = config.get('/**/stereo_camera_node') or config.get('stereo_camera_node') or {}
    return block.get('ros__parameters', {})


def _load_cameras(cameras_file, param_file_config):
    """Resolve the multi-camera spawn list.

    Tries, in order:
      1. ``cameras_file`` (when the launch argument is non-empty) — the
         recommended split-file form, required for binary consumers that
         ingest the params YAML via ``--params-file``.
      2. An inlined ``multi_camera.cameras`` block inside the params YAML
         itself — kept for backward compatibility with ament-only setups
         that ran through ``launch_ros.Node`` and never hit the rcl
         parser directly.

    Returns:
        list[str]: Camera names. Empty list ⇒ single-camera mode at root
        namespace.
    """
    if cameras_file:
        with open(cameras_file) as f:
            cams_yaml = yaml.safe_load(f) or {}
        return (cams_yaml.get('multi_camera') or {}).get('cameras', []) or []
    return (param_file_config.get('multi_camera') or {}).get('cameras', []) or []


def _make_camera_nodes(namespace, param_file_path, rtsp_topic_overrides):
    """Build the (rtsp_camera_node, stereo_camera_node) pair for one camera.

    ``namespace`` may be ``''`` (root) or e.g. ``'cam_front'``. The topic
    overrides use relative names, so ROS2 automatically prefixes them with
    the namespace when one is set.
    """
    return [
        Node(
            package='tk_ros2_pkg_stereocamera',
            executable='rtsp_camera_node',
            name='rtsp_camera_node',
            namespace=namespace,
            parameters=[param_file_path],
        ),
        Node(
            package='tk_ros2_pkg_stereocamera',
            executable='stereo_camera_node',
            name='stereo_camera_node',
            namespace=namespace,
            parameters=[param_file_path, rtsp_topic_overrides],
        ),
    ]


def _make_viewer_node(cameras, stereo_params):
    """Build the aggregated stereo_viewer_node when merged mode is on.

    Pulls the layout / topic / QoS knobs out of the shared
    ``stereo_camera_node`` block so the user only has to configure one
    place. Pass the spawn list as the ``cameras`` parameter; an empty
    list maps to single-camera root-namespace mode inside the viewer.

    Returns:
        launch_ros.actions.Node: The viewer-node action ready to spawn.
    """
    viz = stereo_params.get('visualization', {}) or {}
    image_qos = stereo_params.get('image_qos', {}) or {}
    rgbd_topic_suffix = stereo_params.get('pub_rgbd_topic', 'stereo/rgbd')

    return Node(
        package='tk_ros2_pkg_stereocamera',
        executable='stereo_viewer_node',
        name='stereo_viewer_node',
        parameters=[{
            'cameras': list(cameras) if cameras else [''],
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
    cameras_file = LaunchConfiguration('cameras_file').perform(context)

    with open(param_file_path) as f:
        config = yaml.safe_load(f) or {}

    rtsp_params = _read_rtsp_params(config)
    rtsp_enabled = rtsp_params.get('rtsp', {}).get('enabled', False)
    cameras = _load_cameras(cameras_file, config)
    stereo_params = _read_stereo_params(config)
    merged_viz = bool(
        (stereo_params.get('visualization') or {}).get('merged', False)
    )

    nodes = []

    if rtsp_enabled:
        rtsp_topic_overrides = {
            'color_image_topic': rtsp_params.get('pub_color_topic', 'rtsp/color/image_raw'),
            'depth_image_topic': rtsp_params.get('pub_depth_topic', 'rtsp/depth/image_raw'),
            'camera_info_topic': rtsp_params.get('pub_camera_info_topic', 'rtsp/camera_info'),
        }

        if cameras:
            for cam_name in cameras:
                nodes.extend(_make_camera_nodes(cam_name, param_file_path, rtsp_topic_overrides))
        else:
            nodes.extend(_make_camera_nodes('', param_file_path, rtsp_topic_overrides))
    else:
        nodes.append(Node(
            package='tk_ros2_pkg_stereocamera',
            executable='stereo_camera_node',
            name='stereo_camera_node',
            parameters=[param_file_path]
        ))

    if merged_viz:
        nodes.append(_make_viewer_node(cameras, stereo_params))

    return nodes


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument(
            'param_file',
            description='Full path to the parameter YAML file'
        ),
        DeclareLaunchArgument(
            'cameras_file',
            default_value='',
            description=(
                'Optional path to a YAML file containing the multi-camera '
                'spawn list (top-level `multi_camera.cameras: [...]`). '
                'When set, this overrides any inlined `multi_camera` block '
                'in `param_file`. Required when the params YAML must stay '
                'rcl-clean (e.g. binary install via --params-file).'
            ),
        ),
        OpaqueFunction(function=launch_setup),
    ])
