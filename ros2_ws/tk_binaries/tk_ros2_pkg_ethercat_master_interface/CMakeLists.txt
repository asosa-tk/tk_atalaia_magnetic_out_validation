cmake_minimum_required(VERSION 3.8)
project(tk_ros2_pkg_ethercat_master_interface)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

# find dependencies
find_package(ament_cmake REQUIRED)
find_package(std_msgs REQUIRED)
find_package(rosidl_default_generators REQUIRED)

rosidl_generate_interfaces(${PROJECT_NAME}
  # Generic device messages (new plugin architecture)
  "msg/EcatDeviceCommand.msg"
  "msg/EcatDeviceState.msg"
  "msg/EcatDeviceCommandBatch.msg"
  # Legacy typed messages (kept for transition)
  "msg/EcatServoStatus.msg"
  "msg/EcatServoCommand.msg"
  "msg/EcatServoCommandBatch.msg"
  "msg/EcatIsokernelStatus.msg"
  "msg/EcatIsokernelCommand.msg"
  "msg/EcatHealth.msg"
  "srv/EcatWriteSDO.srv"
  "srv/EcatReadSDO.srv"
  "srv/EcatServoEnable.srv"
  DEPENDENCIES std_msgs
)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  set(ament_cmake_copyright_FOUND TRUE)
  set(ament_cmake_cpplint_FOUND TRUE)
  ament_lint_auto_find_test_dependencies()
endif()

ament_export_dependencies(rosidl_default_runtime)
ament_package()
