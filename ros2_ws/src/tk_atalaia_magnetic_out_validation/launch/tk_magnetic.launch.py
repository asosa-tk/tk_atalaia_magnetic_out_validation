
import os

from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument,
    EmitEvent,
    ExecuteProcess,
    LogInfo,
    OpaqueFunction,
    RegisterEventHandler,
)
from launch.event_handlers import OnProcessExit
from launch.events import Shutdown
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


"""Launch the Atalaia lighting abstraction node.

The EtherCAT daemon + ROS2 bridge (tk_ros2_pkg_ethercat_master) must be
launched separately. By default this launch waits for the bridge to report
all slaves OP (ecat/health.all_op) before starting the node. Set
wait_for_ecat:=false to skip the gate and run standalone.
"""


def _launch_setup(context, *args, **kwargs):
    pkg_share = get_package_share_directory('tk_ros2_pkg_atalaia')
    config_path = os.path.join(pkg_share, 'configs', 'atalaia_config.yaml')

    node = Node(
        package='tk_ros2_pkg_atalaia',
        executable='atalaia_node',
        name='atalaia_node',
        parameters=[config_path],
    )

    wait = LaunchConfiguration('wait_for_ecat').perform(context).lower() \
        in ('1', 'true', 'yes', 'on')
    if not wait:
        return [node]

    gate = ExecuteProcess(
        name='ecat_gate_atalaia',
        cmd=['ros2', 'run', 'tk_ros2_pkg_ethercat_master', 'ecat_gate',
             '--topic', 'ecat/health',
             '--type', 'tk_ros2_pkg_ethercat_master_interface/msg/EcatHealth',
             '--field', 'all_op', '--equals', 'true',
             '--qos', 'volatile',
             '--timeout', LaunchConfiguration('gate_timeout').perform(context)],
        output='screen',
    )

    def _on_gate_exit(event, context):
        if event.returncode == 0:
            return [node]
        return [
            LogInfo(msg='[atalaia] ecat_gate did not reach '
                        'ecat/health.all_op — aborting bringup'),
            EmitEvent(event=Shutdown(reason='ecat_gate failed/timed out')),
        ]

    return [
        gate,
        RegisterEventHandler(OnProcessExit(target_action=gate,
                                           on_exit=_on_gate_exit)),
    ]


def generate_launch_description():
    bus_config_path = LaunchConfiguration('bus_config_path')
    param_file = LaunchConfiguration('param_file')
    rtsp_config_path = os.path.join(
        get_package_share_directory('tk_atalaia_magnetic_out_validation'),
        'config', 'rtsp_camera.yaml')

    return LaunchDescription([
        # Default → this project's bench-specific bus definition at
        # config/ecat_bus.yaml (installed to share/<pkg>/config). This file must
        # exist; provide the real slave definition before launching. Override by
        # passing bus_config_path:=<absolute path> on the launch command.
        # Used to read per-slave heartbeat_timeout_ms for the per-device freshness
        # deadman. heartbeat_timeout_ms is REQUIRED on every slave; the bridge
        # fails to start if it's missing.
        DeclareLaunchArgument(
            'bus_config_path',
            default_value=os.path.join(get_package_share_directory('tk_atalaia_magnetic_out_validation'),
                            'config', 'ecat_bus.yaml')
        ),

        DeclareLaunchArgument(
            'wait_for_ecat', default_value='true',
            description='Wait for ecat/health.all_op before starting the node. '
                        'Set false to run standalone without the EtherCAT bridge.'
        ),

        DeclareLaunchArgument(
            'gate_timeout', default_value='60.0',
            description='Seconds to wait for ecat/health.all_op before aborting.'
        ),

        # Node(
        #     package='tk_ros2_pkg_ethercat_master',
        #     executable='ecat_rt_daemon',
        #     name='ecat_rt_daemon',
        #     output='log',
        #     parameters=[bus_config_path],
        # ),

        Node(
            package='tk_ros2_pkg_ethercat_master',
            executable='ecat_ros2_node',
            name='ecat_ros2_node',
            output='log',
            parameters=[{
                'shm_name': '/ecat_shm',
                'publish_rate_hz': 100.0,
                'heartbeat_hz': 50.0,
                'bus_config_path': bus_config_path,
            }],
        ),

        OpaqueFunction(function=_launch_setup),
        
        Node(
            package='tk_ros2_pkg_atalaia',
            executable='atalaia_gui',
            name='atalaia_gui',
        ),

        # ---- Live RTSP monitoring feed ------------------------------------
        # rtsp_camera_node (tk_ros2_pkg_stereocamera) pulls the bench RTSP
        # stream over GStreamer and republishes it as sensor_msgs/Image on
        # /rtsp/color/image_raw. Point rgb_url at the camera in
        # config/rtsp_camera.yaml.
        Node(
            package='tk_ros2_pkg_stereocamera',
            executable='rtsp_camera_node',
            name='rtsp_camera_node',
            parameters=[rtsp_config_path],
            output='screen',
        ),

        # Show the live stream in a window. The feed is published best_effort;
        # if the window stays black, set rqt's QoS "Reliability" to Best Effort.
        ExecuteProcess(
            name='rtsp_stream_viewer',
            cmd=['ros2', 'run', 'rqt_image_view', 'rqt_image_view',
                 '/rtsp/color/image_raw'],
            output='screen',
        ),
    ])



