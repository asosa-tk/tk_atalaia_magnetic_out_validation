<p align="center">
  <img src="docs/THEKER sphere WHITE.png" width="250" alt="Project Logo"/>
</p>

# tk_binaries

Welcome to TKBinaries, the official package manager of Theker. Here you will find the explanation about how TKBinaries works, as well as an introduction to each package.  

## Introduction

The goal of TKBinaries is to provide a package manager for all of the tk_ros2_pkg and tk_pkg projects. These ROS2 packages implement common necessities that one may need during a project, allowing for a unified development and library system.

Each package comes with different files:
 - ***.bin**: Compiled version of executable python files (`ROS2 nodes`). They are made to work on a Ubuntu24.04 machine
 - ***.so**: Compiled version of library python files (`utils`). They are made to work on a Ubuntu24.04 machine
 - ***_interface**: Interface for that package
 - **typings/**: A folder that contains `.pyi` files for all of the compiled `utils` python files. If setup correctly, these files allows the IDE to show the headers and descriptions of all elements declared inside them
 - **configs/**: Example YAML files for the given `*.bin` nodes and other relevant `.yaml` files
 - **notebooks/**: Notebooks that provide examples or simple codes for the user
 - **docs/**: Images for the README. Ignore it.
 - **requirements.txt**: Requirements folder for pip
 - **README.md**: Package documentation

Additionally, TKBinaries comes with three scripts made to help the user:
 - **pathSimulation.sh**: Due to the nature of the compiling from python to c to binary, a fixed reference is created to the virtual environment from which the command was executed. This would then **crash** in another computer, since when it tried to import any package the link to the virtual environment wouldn't exist. This script solves this issues by creating `soft links` from each *.venv* where the package was compiled to your project *.venv*, so if you have the correct python libraries installed then you won't have a problem. This will be explained more later.
 - **obtainPackages.sh**: This script is a copy of the **tk install** command that you should have on your Ubuntu pc. It's purpose is to retrieve only the packaages that you need for your project, as well as the specific versions you want, instead of the latest. 
 - **checkLatestVersion.sh** This script checks the latest version of the provided package. 

## Installation

TKBinaries is meant to be cloned on your pc. The recommended option is to install it in your home directory, since that way it can be reused for multiple projects in the same PC. 

```bash
cd  ~ && git clone git@github.com:THEKER/tk_binaries.git
```


Additionally, to ease the use of the scripts that need to access TK Binaries, make sure to add an export line to the `.bashrc` file:

```bash
# Add this line to ~/.bashrc
export TK_BINARIES="/path/to/tk_binaries" >> ~/.bashrc
```

## Starting a new project

When starting a new project (or retaking one in a new PC), the steps to correctly setup your workspace and environment while using TKBinaries is the following.

First of all, initialize the python environment in which you will work. You can do this using:

```bash
mkdir ~/demonstration_project
cd ~/demonstration_project
tk init
```

This will create your python environment as well as setup `direnv`/`.envrc` so that entering a folder in the workspace will automatically activate the environment and create `ros2_ws`, `tk_binaries` and `typings` folders if they don't already exists. Additionally, it will also setup a new environment variable `TK_WORSKPACE`, which simplifies the use of `tk install` and other scripts from inside the workspace folder. It will also setup the correct pyrightconfig to make sure you can read the stubbings from the `typings` folder If you need the environment to activate in a script, you can use the following instruction while inside the environment folder.

```bash
eval "$(direnv export bash)"
```

Once you have created your ROS2 workspace, you must create the necessary soft links to solve the import problem explained before. To do this, you must execute the `tk gl` instruction using the `gl_list.txt` file present in **tk_binaries**. If the `TK_BINARIES` and `TK_WORKSPACE` environment variables are correctly setup, you don't need to override their values:

```bash
cd ~/tk_binaries
tk gl 
```

Now, you can safely use any `tk_ros2_pkg` you want. However, to be able to use them inside your project, you must first use the `tk install` instruction to install the desired packages into your workspace.
First, write your desired packages into `binaries_requirements.txt`. This file is very similar to a **pip** `requirementst.txt` file, but for internal pkgs. Currently, you can either choose the latest version (only put the name of the package) or a specific version using `==version`.

```text
tk_ros2_pkg_realsense
tk_ros2_pkg_stereocamera==0.1.1
tk_pkg_objectqueue
```

Once you have selected the desired packages, install them using `tk install`. This instruction takes in the path to a `binaries_requirements.txt` package and the path to your project. However, If you correctly configured `TK_BINARIES` and are inside the workspace folder, the environment variables will automatically take care of this for you, so you don't need to pass any argument.

```bash
cd ~/demonstration_project
tk install 
```

`tk install` automatically installs all requirements specified in each packages `requirements.txt` **(it doesn't check for conflicts)** as well as builds the ros2 workspace. It also source the workspace. This fails however the first time an (interface) package is added. In that case, you will need to do a second `source install/setup.bash`.

Alternatively, to manually build the workspace you can use the `tk build` instruction.

```bash
cd ~/demonstration_project/ros2_ws
tk build
```

## Current packages

Here is a short list of the packages currently present in tk_binaries

### Cameras

- **tk_ros2_pkg_stereocamera**: This package acts as a middlemen between the physical camera device and it's node implementation (realsense, zed, oak...) and your code, to provide a unique and uniform communication
- **tk_ros2_pkg_oak**: This package allows you to control oak cameras and do YOLO inference on device
- **tk_ros2_pkg_camera_recorder**: This package records any mix of raw and compressed camera topics to timestamped MP4 files, with support for depth images and topic-driven start/stop
- **tk_ros2_pkg_thermal_camera_tc001**: Drives a Topdon TC001 USB thermal camera and publishes a false-color heatmap, a raw per-pixel °C matrix and per-frame thermal stats, with runtime ROIs, CSV logging, snapshots and a Qt dashboard

### Vision

- **tk_pkg_plane_extractor**: Extracts the dominant top-facing plane from normal-map segmentation masks using spherical KMeans clustering, multi-component scoring, and optional RGB edge refinement
- **tk_ros2_pkg_yoloinference**: This package allows you to run YoloV11 models in realtime to detect objects
- **tk_ros2_pkg_sam2**: This package allows for the segmentation of images based on points or bounding boxes
- **tk_ros2_pkg_sam3inference**: This package allows for the segmentation of images based on a prompt, without requiring trainig
- **tk_ros2_pkg_depth_anything_v2**: This package allows for the prediction of a relative depth in your images
- **tk_ros2_pkg_normal**: This package allows for the prediciton of the normals of your surface

### Training

- **tk_pkg_sam3finetune**: This package provides a complete pipeline for fine-tuning SAM3 models on custom COCO datasets, including config generation, annotation cleaning, checkpoint conversion and evaluation

### Utility

 - **tk_pkg_objectqueue**: The objectqueue allows for the ordering of detection and decision making about how to pick, useful for binpicking usecases
 - **tk_ros2_pkg_aruco_calibration**: This package allows for the automatic calibration of robots using ArUco Markers
 - **tk_ros2_pkg_aruco_detector**: This package implements a universal detection of ArUco markers or ChArUco boards
 - **tk_ros2_pkg_keyboard**: This package is used to detect keyboard strokes to control other nodes
 - **tk_ros2_pkg_clouddataingestion**: This package standardizes the data ingestion and output process, enabling cloud uploads or local saves
 - **tk_ros2_pkg_computer_health_logger**: This package periodically samples CPU, RAM, GPU and NVMe sensors and pushes them to a local VictoriaMetrics time-series database for live and historical Grafana dashboards (CSV logging optional), emitting ROS warnings on configurable threshold breaches
 - **tk_ros2_pkg_presence_checker**: This package is used to control how much a packet has been grabbed when the tool consists of several elements (multiple vacuums, duplicate sensors, etc...)

### Robot control
 - **tk_ros2_pkg_fanuc**: This package is used to control the Fanuc Robots
 - **tk_ros2_pkg_mitsubishi**: Unified ROS 2 communication interface for Mitsubishi CR8 series robot controllers
 - **tk_ros2_pkg_curobo_planner**: This package provides GPU-accelerated collision-free trajectory planning for robotic arms using NVIDIA CuRobo, outputting cubic spline coefficients for realtime control

### EtherCAT

This group of packages forms Theker's EtherCAT control stack. They are organized in two layers, and **the master is always required to use any of the device packages**.

**Layer 1 — Master (required)**
 - **tk_ros2_pkg_ethercat_master** (+ `_interface`): C++ real-time daemon that owns the EtherCAT cycle, and a bridge node that exposes it to ROS2 over shared memory. The daemon itself is hardware-agnostic — it doesn't know about any specific slave on its own.

**Layer 2 — Device packages (add one per hardware on your bus)**

The daemon has zero hardware knowledge on its own — every slave is driven by a *plugin*. There are two flavors, and which one a device uses depends on how complex the slave is:

 - **Passthrough (built-in, no `.so` needed)** — for pure-I/O slaves with a static PDO image and no per-cycle logic. The daemon's built-in passthrough plugin auto-discovers the PDO layout from the slave's SII/EEPROM at startup and just shuttles raw bytes. Used by `electrovalves` (mode `valve`), `anybus`, `smc_modular_block`, `isokernel`, `atalaia`. In `ecat_bus.yaml` these slaves only list `name` / `position` / `publish_rate_hz`.
 - **Custom `.so` plugin** — for slaves with protocol logic that has to run inside the RT cycle: state machines (CiA 402 servos), command primitives that map to bit patterns (ZK2 ejectors), safety-relay framing (Euchner MBM, Pilz PNOZ). The device package ships a compiled `.so` (e.g. `libdevice_servo.so`, `libdevice_zk2_ejector.so`) that the daemon `dlopen`s at runtime. The bus YAML wires it in with `plugin: pkg::lib.so`.

Either way, the device package is what makes the bus do anything useful — the master alone has nothing to drive.

 - **tk_ros2_pkg_servos** (+ `_interface`): servo drives over CiA 402, single- or multi-axis — drive family is plugin-swappable via the bundled `tk_servos_a6_plugin` (StepperOnline A6-EC) and `tk_servos_mr_j5_plugin` (Mitsubishi MR-J5, 1..N axes)
 - **tk_ros2_pkg_electrovalves** (+ `_interface`): SMC EX260 valve manifolds
 - **tk_ros2_pkg_smc_modular_block** (+ `_interface`): SMC EX600 modular I/O
 - **tk_ros2_pkg_isokernel** (+ `_interface`): IsoKernel I/O slave
 - **tk_ros2_pkg_euchner_mbm** (+ `_interface`): Euchner MBM safety door
 - **tk_ros2_pkg_pilz_pnoz** (+ `_interface`): Pilz PNOZ safety relay
 - **tk_ros2_pkg_anybus**: Anybus Communicator EtherCAT↔Profinet gateway (passthrough)
 - **tk_ros2_pkg_atalaia** (+ `_interface`): Theker Atalaia Shield v3 camera-illumination module — RGB + white LED strips, fans, and on-board environment/power/thermal telemetry (passthrough)

**Layer 3 — Semantic IO abstraction (optional)**

 - **tk_ros2_pkg_io_comms** (+ `_interface`): config-driven IO abstraction layer on top of the device packages — use-case nodes actuate and read IO by action name under tool profiles (do_action / set_io / read + periodic sensor topics) without touching any device protocol. Includes a Tkinter bench GUI for commissioning

**Usage:** add `tk_ros2_pkg_ethercat_master` to `binaries_requirements.txt`, then add only the device packages whose hardware is on your EtherCAT bus.

## Mantainers

- **THEKER Robotics Engineering Team** 
- **Joan Cintas Navarro** — ([j.cintas@theker.eu](mailto:j.cintas@theker.eu))  