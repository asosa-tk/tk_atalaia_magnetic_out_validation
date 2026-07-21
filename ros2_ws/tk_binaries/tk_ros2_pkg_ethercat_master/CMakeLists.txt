cmake_minimum_required(VERSION 3.8)
project(tk_ros2_pkg_ethercat_master LANGUAGES NONE)

find_package(ament_cmake REQUIRED)

# Re-install prebuilt artifacts produced by the maintainer's auto_compiler.
# USE_SOURCE_PERMISSIONS: plain install(DIRECTORY) strips exec bits, which
# breaks ros2 run (ecat_gate, ecat_ros2_node) and the daemon/scripts in
# lib/tk_ros2_pkg_ethercat_master on the consumer side.
install(DIRECTORY lib/     DESTINATION lib USE_SOURCE_PERMISSIONS)
install(DIRECTORY include/ DESTINATION include)
install(DIRECTORY share/   DESTINATION share)

# SHM header export — preserved from the source CMakeLists.txt so that
# downstream find_package(tk_ros2_pkg_ethercat_master) consumers (e.g.
# tk_ros2_pkg_servos_plugin) get include paths set correctly.
ament_export_include_directories(include)

ament_package()
