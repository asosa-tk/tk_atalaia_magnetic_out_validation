from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    bus_config_path = LaunchConfiguration('bus_config_path')

    return LaunchDescription([
        # Empty default → the bridge searches AMENT_PREFIX_PATH/share/<pkg>/configs
        # for ecat_bus.yaml (the same file the daemon loads). Override by passing
        # bus_config_path:=<absolute path> on the launch command, which is what
        # the ecat_panel does when a bench-specific YAML is selected.
        # Used to read per-slave heartbeat_timeout_ms for the per-device freshness
        # deadman. heartbeat_timeout_ms is REQUIRED on every slave; the bridge
        # fails to start if it's missing.
        DeclareLaunchArgument('bus_config_path', default_value=''),

        Node(
            package='tk_ros2_pkg_ethercat_master',
            executable='ecat_ros2_node',
            name='ecat_ros2_node',
            output='screen',
            parameters=[{
                'shm_name': '/ecat_shm',
                'publish_rate_hz': 100.0,
                'heartbeat_hz': 50.0,
                'bus_config_path': bus_config_path,
            }],
        ),
    ])
