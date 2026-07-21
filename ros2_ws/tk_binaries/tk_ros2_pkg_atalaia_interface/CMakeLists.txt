cmake_minimum_required(VERSION 3.8)
project(tk_ros2_pkg_atalaia_interface)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(std_msgs REQUIRED)
find_package(rosidl_default_generators REQUIRED)

rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/AtalaiaCommand.msg"
  "msg/AtalaiaState.msg"
  "srv/SetColor.srv"
  "srv/SetWhite.srv"
  "srv/SetFan.srv"
  "srv/FaultReset.srv"
  "srv/AllOff.srv"
  "srv/SetConfig.srv"
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
