cmake_minimum_required(VERSION 3.8)
project(tk_ros2_pkg_atalaia LANGUAGES NONE)

find_package(ament_cmake REQUIRED)

# Node binaries -> lib/<pkg>/<node> (ros2 run location, drop .bin)
install(PROGRAMS atalaia_node.bin RENAME atalaia_node DESTINATION lib/${PROJECT_NAME})
install(PROGRAMS atalaia_gui.bin  RENAME atalaia_gui  DESTINATION lib/${PROJECT_NAME})

# Nuitka utils.so -> site-packages/<pkg>/  (Python import path: <pkg>.utils)
file(GLOB UTILS_SO RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "utils.cpython-*.so")
install(PROGRAMS ${UTILS_SO} DESTINATION lib/python3.12/site-packages/${PROJECT_NAME})

# Configs + launch -> share/<pkg>/
install(DIRECTORY configs DESTINATION share/${PROJECT_NAME})
install(DIRECTORY launch  DESTINATION share/${PROJECT_NAME})

ament_package()
