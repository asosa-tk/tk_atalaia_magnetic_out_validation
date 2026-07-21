<p align="center">
  <img src="docs/THEKER sphere WHITE.png" width="250" alt="Project Logo"/>
</p>

# tk_ros2_pkg_stereocamera

A unified ROS 2 node for synchronized RGB-D processing, optional depth post-processing, and a clean "stereo camera" abstraction layer for downstream perception.

---

## Overview

`tk_ros2_pkg_stereocamera` provides **two ROS 2 node variants** (`stereo_camera_node` and `stereo_camera_node_fast`) that:

- Subscribes to **color + depth** streams from any stereo-capable pipeline (ZED, RealSense, OAK, custom rigs), or from **RTSP streams** via the built-in GStreamer-based `rtsp_camera_node`.
- Performs **approximate time synchronization**.
- Runs an **extensible postprocessing pipeline** on color and/or depth frames (configurable via parameters).
- **Converts depth units**.
- Republishes either:
  - a **combined RGB-D message** (`TkStereoCamMsg`), or
  - **separate** color/depth topics.
- Always republishes **CameraInfo** for ROS compatibility.
- Exposes a **placement-oriented service** (`FindDeepestZone`) to compute a robust "deepest zone" pixel inside a ROI.

This package is designed to sit between **hardware drivers** and **perception / manipulation** stacks, keeping camera specifics out of higher-level modules.

---

## Package Architecture

High-level structure of the package:

```bash
tk_ros2_pkg_stereocamera/
├── auto_compiler
├── configs
│   ├── stereo_camera_node.yaml
│   ├── stereo_camera_node_fast.yaml
│   └── stereo_camera_node_rtsp.yaml
├── docs
│   ├── THEKER sphere black.png
│   └── THEKER sphere WHITE.png
├── README.md
├── requirements.txt
├── tk_ros2_pkg_stereocamera
│   ├── launch
│   │   ├── stereocamera_launcher.launch.py
│   │   └── stereocamera_fast_launcher.launch.py
│   ├── package.xml
│   ├── resource
│   │   └── tk_ros2_pkg_stereocamera
│   ├── setup.cfg
│   ├── setup.py
│   ├── test
│   │   ├── test_copyright.py
│   │   ├── test_flake8.py
│   │   └── test_pep257.py
│   └── tk_ros2_pkg_stereocamera
│       ├── __init__.py
│       ├── nodes
│       │   ├── rtsp_camera_node.py
│       │   ├── stereo_camera_node.py
│       │   └── stereo_camera_node_fast.py
│       └── utils
│           ├── deepest_zone_srv.py
│           ├── depth_preprocess.py
│           ├── frame_tear_detection.py
│           ├── postprocess_pipeline.py
│           └── __init__.py
└── tk_ros2_pkg_stereocamera_interface
    ├── CMakeLists.txt
    ├── msg
    │   └── TkStereoCamMsg.msg
    ├── package.xml
    └── srv
        └── FindDeepestZone.srv
```

---

## System Diagram

### Standard mode (camera driver topics)
```text
(Camera Driver)
  ├─ /camera/color/image_raw  ───────────────┐
  ├─ /camera/depth/image_raw  ───────────────┼──> [StereoCameraNode / StereoCameraNodeFast]
  └─ /camera/depth/camera_info ──────────────┘          │
                                                        │  (postprocess pipeline)
                                                        │
                publish_combined_msg=True               │     publish_combined_msg=False
                ┌───────────────────────────────┐       │     ┌───────────────────────────────┐
                │ stereo/rgbd (TkStereoCamMsg)  │ <─────┼──── │ stereo/color/image_raw        │
                │ stereo/camera_info            │       │     │ stereo/depth/image_raw        │
                └───────────────────────────────┘       │     │ stereo/camera_info            │
                                                        │     └───────────────────────────────┘
                                                        │
                                                        └──> Service: /stereo/find_deepest_zone (FindDeepestZone)
                                                               (ROI-based robust placement pixel)
```

### RTSP mode (enabled via `rtsp.enabled: true`)
```text
(RTSP Server)
  ├─ rtsp://.../rgb       (JPEG)  ──┐
  └─ rtsp://.../depth_raw (GRAY16)──┼──> [RtspCameraNode]
                                    │        │
                                    │        ├─ rtsp/color/image_raw  ──────┐
                                    │        ├─ rtsp/depth/image_raw  ──────┼──> [StereoCameraNode / Fast]
                                    │        └─ rtsp/camera_info  ──────────┘         │
                                    │                                                 │ (same pipeline as above)
                                    │                                                 ▼
                                    │                                        stereo/rgbd, services, etc.
```

When RTSP is enabled in the config, the launch file **automatically** starts `rtsp_camera_node` and overrides the stereocamera node's input topics to the RTSP outputs. All downstream behavior (postprocessing, visualization, services) remains unchanged.

---

## Dependencies

```bash
pip install -r requirements.txt
```

#### **External runtime dependencies (ROS 2):**
This node depends on an upstream camera driver node running in the system that publishes the input topics configured in color_image_topic, depth_image_topic, and camera_info_topic (e.g., ZED ROS 2 wrapper, RealSense ROS 2 wrapper, OAK pipeline, or any compatible camera publisher). Without an active camera publisher on those topics, stereo_camera_node will have no data to synchronize or republish.

#### **RTSP mode dependencies:**
When using `rtsp_camera_node`, the following GStreamer system packages are required (typically pre-installed on Ubuntu 24):
- `gstreamer1.0-tools`
- `gstreamer1.0-plugins-good` (provides `rtpjpegdepay`, `jpegdec`)
- `gstreamer1.0-plugins-bad` (provides `rtpgstdepay`)
- `gir1.2-gstreamer-1.0` and `gir1.2-gst-plugins-base-1.0` (GObject introspection bindings)
- Python package `PyGObject` (`gi` module)

---

## Custom Message Definitions (msg)

> **Note:** These interfaces are defined in `tk_ros2_pkg_stereocamera_interface/msg` and imported by this package.

| Message File         | Description |
| -------------------- | ----------- |
| `TkStereoCamMsg.msg` | Combined RGB-D payload (color + depth + camera_info). Used only when `publish_combined_msg=True`. |

**`TkStereoCamMsg.msg` fields**
- `std_msgs/Header header`
- `sensor_msgs/Image color`
- `sensor_msgs/Image depth`
- `sensor_msgs/CameraInfo camera_info`

---

## Custom Service Definitions (srv)

> **Note:** These interfaces are defined in `tk_ros2_pkg_stereocamera_interface/srv` and imported by this package.

| Service File          | Request Fields | Response Fields | Description |
| --------------------- | -------------- | --------------- | ----------- |
| `FindDeepestZone.srv` | `roi_polygon`, `object_mask`, `object_width_px`, `object_height_px`, `use_ellipse`, `min_depth_m`, `max_depth_m`, `min_coverage_ratio` | `success`, `status`, `u`, `v`, `mean_depth_m`, `coverage_ratio` | Computes a robust placement pixel maximizing **masked mean depth** within an ROI (winsorized + coverage-gated). |

---

## Nodes

### Node: `rtsp_camera_node`

**Description**
Captures RTSP streams via GStreamer and publishes them as standard `sensor_msgs/Image` topics. Acts as a drop-in camera driver replacement when the video source is an RTSP server instead of a physical camera driver node. Supports JPEG-encoded RGB streams and raw GRAY16_LE depth streams (uint16, millimeters). Runs two independent daemon capture threads (one per stream) with automatic reconnection and exponential backoff on stream loss.

> **Note:** This node uses GStreamer Python bindings (`gi.repository.Gst`) directly and does **not** require OpenCV to be built with GStreamer support.

#### Published Topics

| Topic (parameter) | Type | Description |
| --- | --- | --- |
| `pub_color_topic` | `sensor_msgs/msg/Image` | RGB frames decoded from RTSP JPEG stream (`bgr8` encoding). |
| `pub_depth_topic` | `sensor_msgs/msg/Image` | Depth frames from RTSP raw stream (`16UC1` encoding, uint16 mm). |
| `pub_camera_info_topic` | `sensor_msgs/msg/CameraInfo` | Camera intrinsics. When `fx/fy/cx/cy` are known (from config or auto-detected from the stream), `K`, `R` (identity), `P` (mirrors `K`), `distortion_model` (`"plumb_bob"`), and `D` (zeros) are all populated — required by `image_geometry::PinholeCameraModel` / `depth_image_proc` to reproject depth. Empty until intrinsics are known. |

#### Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `rtsp.enabled` | bool | `false` | Master switch — when `true`, the launch file starts this node and wires stereo input topics automatically. |
| `rtsp.rgb_url` | string | `"rtsp://192.168.3.108:8554/rgb"` | RTSP URL for the JPEG-encoded RGB stream. |
| `rtsp.depth_url` | string | `"rtsp://192.168.3.109:8554/depth_raw"` | RTSP URL for the raw GRAY16_LE depth stream. |
| `rtsp.rgb_latency` | int | `20` | GStreamer latency (ms) for the RGB pipeline. |
| `rtsp.depth_latency` | int | `200` | GStreamer latency (ms) for the depth pipeline. |
| `rtsp.rgb_protocols` | string | `"tcp"` | RTSP transport protocol for the RGB stream. |
| `rtsp.reconnect_delay_s` | float | `2.0` | Initial reconnection delay (seconds) on stream loss. |
| `rtsp.max_reconnect_delay_s` | float | `30.0` | Maximum reconnection delay cap (exponential backoff). |
| `pub_color_topic` | string | `"rtsp/color/image_raw"` | Output topic for RGB frames. |
| `pub_depth_topic` | string | `"rtsp/depth/image_raw"` | Output topic for depth frames. |
| `pub_camera_info_topic` | string | `"rtsp/camera_info"` | Output topic for CameraInfo. |
| `image_qos.reliability` | string | `"best_effort"` | Publisher QoS reliability (`"best_effort"` or `"reliable"`). |
| `image_qos.depth` | int | `5` | Publisher QoS history queue depth. |
| `camera_info.frame_id` | string | `"rtsp_camera_frame"` | TF frame ID for published messages. |
| `camera_info.fx` | float | `0.0` | Focal length X (pixels). Set to `0.0` if unknown. |
| `camera_info.fy` | float | `0.0` | Focal length Y (pixels). |
| `camera_info.cx` | float | `0.0` | Principal point X (pixels). |
| `camera_info.cy` | float | `0.0` | Principal point Y (pixels). |
| `debug` | bool | `false` | Enables per-second Hz logging for both streams. |

---

### Node: `stereo_camera_node`

**Description**
Synchronizes RGB + depth (approx time), runs an extensible postprocessing pipeline on both color and depth frames, converts depth units, republishes either a combined RGB-D message or separate topics, and provides a deterministic placement-oriented depth service. Uses `cv_bridge` for image conversion and `message_filters.ApproximateTimeSynchronizer` for frame synchronization.

### Node: `stereo_camera_node_fast`

**Description**
High-performance variant of `stereo_camera_node` optimized for **60-200 FPS** operation. Provides the same functionality (topics, services, parameters) but with a redesigned internal pipeline for maximum throughput.

#### Improvements over `stereo_camera_node`

| Area | `stereo_camera_node` | `stereo_camera_node_fast` |
| --- | --- | --- |
| **Image conversion** | `cv_bridge` (memory copy per frame) | Zero-copy via `numpy.frombuffer` (no allocation in hot path) |
| **Frame synchronization** | `message_filters.ApproximateTimeSynchronizer` (iterates queues) | Custom O(1) timestamp matcher on bounded ring buffers |
| **Callback groups** | `MutuallyExclusiveCallbackGroup` (serializes color/depth) | `ReentrantCallbackGroup` (concurrent color/depth callbacks) |
| **Output QoS** | Fixed | Configurable reliability (`best_effort` / `reliable`) and queue depth via `image_qos.*` parameters |
| **Depth message building** | Via `cv_bridge` | Manual `Image` construction (no `cv_bridge` dependency at publish) |
| **Debug telemetry** | Basic | Per-stage timing breakdown (color, depth, units, post, lock, build, pub) and separate sync/publish Hz counters |

> **When to use each variant:** Use `stereo_camera_node` for general-purpose pipelines where simplicity and `cv_bridge` compatibility are preferred. Use `stereo_camera_node_fast` when operating at high frame rates (>30 FPS) or when minimizing end-to-end latency is critical.

### Node: `stereo_viewer_node`

**Description**
Lightweight aggregator node spawned by the launchers when `visualization.merged: true`. Subscribes to every camera's combined `TkStereoCamMsg` topic and renders all color + depth frames inside ONE OpenCV window arranged as a grid of `2 × N` tiles. Click any tile to expand it; press `ESC` to collapse back to the grid; press `q` to close the viewer. See [Merged visualization](#merged-visualization) for the full description.

> **Note:** This node never runs alongside per-node viewers — when it spawns, the launchers force `visualization.show = false` on every `stereo_camera_node` instance so only one window exists.

---

## **`stereo_camera_node`** Behavior Overview

### When `publish_combined_msg=True`

Publishes only:
- `stereo/rgbd` *(TkStereoCamMsg)*
- `stereo/camera_info`

Notes:
- Individual color/depth image topics are **not** published.
- The depth image is **processed** before being included in the combined message.

### When `publish_combined_msg=False`

Publishes:
- `stereo/color/image_raw`
- `stereo/depth/image_raw`
- `stereo/camera_info`

Notes:
- The depth image is **processed** before being published.
- The combined RGB-D message is **not** published.

---

### Subscribed Topics

| Topic (parameter) | Type | Description |
| --- | --- | --- |
| `color_image_topic` | `sensor_msgs/msg/Image` | Input RGB stream. |
| `depth_image_topic` | `sensor_msgs/msg/Image` | Input depth stream (raw). |
| `camera_info_topic` | `sensor_msgs/msg/CameraInfo` | Input intrinsics (republished). |
| `keyboard_topic` *(optional)* | `std_msgs/msg/String` | Capture trigger events (only if `img_save_active=True`). |

---

### Published Topics

| Topic (parameter) | Type | Description |
| --- | --- | --- |
| `pub_camera_info_topic` | `sensor_msgs/msg/CameraInfo` | Always republished camera info. |
| `pub_rgbd_topic` *(combined mode)* | `tk_ros2_pkg_stereocamera_interface/msg/TkStereoCamMsg` | Fused RGB-D message containing processed depth. |
| `pub_color_topic` *(separate mode)* | `sensor_msgs/msg/Image` | Republished color image. |
| `pub_depth_topic` *(separate mode)* | `sensor_msgs/msg/Image` | Republished processed depth image. |

---

## Services

### FindDeepestZone Service

This service computes a **robust placement pixel** that maximizes the **mean depth under an object footprint** within a user-defined **Region of Interest (ROI)**.

**Key properties**
- Enforces a **minimum valid-depth coverage** threshold to reject unreliable regions
- Uses **percentile-clipped depth (winsorization)** to suppress outliers and sensor noise
- Optimizes **average support depth**, not single-pixel maxima
- Fully **deterministic and repeatable**, suitable for industrial pipelines

| Service (parameter) | Type | Description |
| --- | --- | --- |
| `deepest_zone_service` | `tk_ros2_pkg_stereocamera_interface/srv/FindDeepestZone` | Returns best `(u,v)` placement pixel plus `mean_depth_m` and `coverage_ratio`. |

### Publish Toggle Service

Exposed by **all three nodes** (`stereo_camera_node`, `stereo_camera_node_fast`, `rtsp_camera_node`). Activates or deactivates publishing of **all** of the node's camera topics (color, depth, rgbd, and `camera_info`) at runtime — useful to pause heavy RGBD traffic or silence a camera without restarting.

**Key properties**
- `data: true` activates publishing, `data: false` deactivates it.
- **No stale frames on reactivation:** the node keeps decoding/syncing while paused and only skips the `publish()` calls, so the very next emitted message after reactivation is the live frame, never a buffered one. (Output QoS is `best_effort`/`volatile`, so there is no transient-local replay either.) While paused, the viewer and `FindDeepestZone` keep working on fresh frames.
- Startup state is controlled by the `publish_active_on_startup` parameter (default `true`).

| Service (parameter) | Type | Description |
| --- | --- | --- |
| `publishing_control_service` | `std_srvs/srv/SetBool` | Toggle publishing of all camera topics. Default name `stereo/set_publishing` (stereo nodes) / `rtsp/set_publishing` (RTSP node). |

Example:

```bash
ros2 service call /<ns>/stereo/set_publishing std_srvs/srv/SetBool "{data: false}"   # pause
ros2 service call /<ns>/stereo/set_publishing std_srvs/srv/SetBool "{data: true}"    # resume
```

---

## Configuration Files

### `stereo_camera_node` config

Example `configs/stereo_camera_node.yaml`:

```yaml
stereo_camera_node:
  ros__parameters:
    debug: False

    # Depth pipeline
    depth_encoding: "32FC1"          # e.g. "32FC1", "passthrough"
    input_depth_unit: "m"            # m / dm / cm / mm
    output_depth_unit: "mm"          # m / dm / cm / mm
    invalid_depth_thresh: 0.5        # Max ratio of invalid pixels (0.0-1.0), null to disable

    # Postprocess pipeline
    postprocess_frames: True
    postprocess_filters:             # Ordered list of filters to apply
      - "depth_fill"                 # Available: frame_tear, noise_detection, depth_fill, median_depth, bilateral_depth, gaussian_color, clahe_color
    # Filter-specific parameters (uncomment to override defaults):
    # postprocess:
    #   noise_detection:
    #     threshold: 50.0
    #     ds: 4
    #   frame_tear:
    #     ds: 4
    #     min_shift: 5
    #     mad_ratio: 0.50
    #     check_color: True
    #     check_depth: True
    #   depth_fill:
    #     iters: 6
    #     ksize: 3
    #   median_depth:
    #     ksize: 5
    #   bilateral_depth:
    #     d: 5
    #     sigma_color: 75.0
    #     sigma_space: 75.0
    #   gaussian_color:
    #     ksize: 5
    #     sigma: 0.0
    #   clahe_color:
    #     clip_limit: 2.0
    #     tile_size: 8

    # Output mode
    publish_combined_msg: True

    # Visualization
    visualization:
      show: False              # per-node viewer (color + depth windows)
      display_fps: 30.0
      merged: False            # see "Merged visualization" section below
      grid_cols: 2
      tile_width: 640
      tile_height: 360

    # Inputs
    color_image_topic: "/camera/color/image_raw"
    depth_image_topic: "/camera/depth/image_raw"
    camera_info_topic: "/camera/depth/camera_info"

    sync_callback:
      queue_size: 10
      slop: 0.05

    # Outputs
    image_qos:
      reliability: 'best_effort'
    pub_color_topic: "stereo/color/image_raw"
    pub_depth_topic: "stereo/depth/image_raw"
    pub_camera_info_topic: "stereo/camera_info"
    pub_rgbd_topic: "stereo/rgbd"

    # Deepest Zone srv
    deepest_zone_service: "stereo/find_deepest_zone"
    default_window_radius_px: 35
    winsor_p_lo: 2.0
    winsor_p_hi: 98.0

    # Optional capture tool
    img_save_active: False
    keyboard_topic: "/keyboard/key"
    capture_output_dir: "/tmp/stereo_captures"
    capture_debounce_s: 0.30
```

### `rtsp_camera_node` config (RTSP mode)

Example `configs/stereo_camera_node_rtsp.yaml`. This config enables the RTSP camera driver and configures the stereocamera processing node to receive frames from the RTSP streams. Both nodes are defined under the `/**/` wildcard so they apply to any namespace — see [Multi-camera setup (RTSP)](#multi-camera-setup-rtsp) for the multi-camera use case (where the camera spawn list lives in a separate `stereo_cameras.yaml`):

```yaml
# RTSP Camera Node — shared params (apply to every camera)
/**/rtsp_camera_node:
  ros__parameters:
    debug: False

    rtsp:
      enabled: true
      rgb_url: "rtsp://192.168.3.108:8554/rgb"
      depth_url: "rtsp://192.168.3.109:8554/depth_raw"
      rgb_latency: 20
      depth_latency: 200
      rgb_protocols: "tcp"
      reconnect_delay_s: 2.0
      max_reconnect_delay_s: 30.0

    pub_color_topic: "rtsp/color/image_raw"
    pub_depth_topic: "rtsp/depth/image_raw"
    pub_camera_info_topic: "rtsp/camera_info"

    image_qos:
      reliability: 'best_effort'
      depth: 5

    camera_info:
      frame_id: "rtsp_camera_frame"
      fx: 0.0
      fy: 0.0
      cx: 0.0
      cy: 0.0

# Stereo Camera Processing Node — shared params
# (input topics are auto-overridden by the launch file when rtsp.enabled=true)
/**/stereo_camera_node:
  ros__parameters:
    debug: False
    depth_encoding: "16UC1"
    invalid_depth_thresh: 0.3
    input_depth_unit: "mm"
    output_depth_unit: "mm"

    postprocess_frames: True
    postprocess_filters:
      - "depth_fill"

    publish_combined_msg: True
    visualization:
      show: False              # per-node viewer (color + depth windows)
      display_fps: 30.0
      merged: False            # see "Merged visualization" section below
      grid_cols: 2
      tile_width: 640
      tile_height: 360

    # Relative names matching rtsp_camera_node's outputs, so binary
    # consumers running via --params-file get correct wiring out of
    # the box. The upstream launcher re-asserts these via parameter
    # overrides; in practice that becomes a no-op now.
    color_image_topic: "rtsp/color/image_raw"
    depth_image_topic: "rtsp/depth/image_raw"
    camera_info_topic: "rtsp/camera_info"

    sync_callback:
      queue_size: 10
      slop: 0.1          # Looser slop for RTSP (two independent capture threads)

    image_qos:
      reliability: 'best_effort'
      depth: 5
    pub_color_topic: "stereo/color/image_raw"
    pub_depth_topic: "stereo/depth/image_raw"
    pub_camera_info_topic: "stereo/camera_info"
    pub_rgbd_topic: "stereo/rgbd"

    # Relative name (no leading "/") so it gets prefixed by the node's
    # namespace at runtime. Required for multi-camera mode — see below.
    deepest_zone_service: "stereo/find_deepest_zone"
    default_window_radius_px: 35
    winsor_p_lo: 2.0
    winsor_p_hi: 98.0

    img_save_active: False
    keyboard_topic: "/keyboard/pressed_key"
    capture_output_dir: "/tmp/stereo_captures"
    capture_debounce_s: 0.3
```

> **Note:** When `rtsp.enabled: true`, the stereo node's input topics already point at `rtsp_camera_node`'s outputs via the relative `rtsp/...` defaults. The upstream launcher additionally re-asserts those values as parameter overrides, so it's safe to skip the launcher entirely (e.g. binary install) and reach the same wiring.

> **Note:** The RTSP depth stream is raw GRAY16_LE (uint16 millimeters), so set `depth_encoding: "16UC1"` and `input_depth_unit: "mm"` in the stereocamera node section. The full postprocessing pipeline (depth fill, bilateral, etc.) works correctly with this format.

---

### `stereo_camera_node_fast` config

Example `configs/stereo_camera_node_fast.yaml`:

```yaml
stereo_camera_node:
  ros__parameters:
    debug: False

    # Depth pipeline
    depth_encoding: "32FC1"          # "32FC1", "16UC1", "passthrough"
    input_depth_unit: "m"            # m / dm / cm / mm
    output_depth_unit: "mm"          # m / dm / cm / mm

    # Postprocess pipeline
    postprocess_frames: False        # False for max throughput
    postprocess_filters:             # Ordered list of filters to apply (when enabled)
      - "depth_fill"                 # Available: frame_tear, noise_detection, depth_fill, median_depth, bilateral_depth, gaussian_color, clahe_color

    # Output mode
    publish_combined_msg: True

    # Visualization
    visualization:
      show: False              # per-node viewer (color + depth windows)
      display_fps: 60.0
      merged: False            # see "Merged visualization" section below
      grid_cols: 2
      tile_width: 640
      tile_height: 360

    # Inputs
    color_image_topic: "/camera/color/image_raw"
    depth_image_topic: "/camera/depth/image_raw"
    camera_info_topic: "/camera/depth/camera_info"

    # Custom O(1) synchronizer
    sync_callback:
      queue_size: 20                 # larger buffer for high-FPS streams
      slop: 0.003                    # 3 ms — tight for hardware-synced cameras

    # Outputs
    image_qos:
      reliability: 'best_effort'
      depth: 5                       # publisher history queue depth
    pub_color_topic: "stereo/color/image_raw"
    pub_depth_topic: "stereo/depth/image_raw"
    pub_camera_info_topic: "stereo/camera_info"
    pub_rgbd_topic: "stereo/rgbd"

    # Deepest Zone srv
    deepest_zone_service: "stereo/find_deepest_zone"
    default_window_radius_px: 35
    winsor_p_lo: 2.0
    winsor_p_hi: 98.0

    # Optional capture tool
    img_save_active: False
    keyboard_topic: "/keyboard/key"
    capture_output_dir: "/tmp/stereo_captures"
    capture_debounce_s: 0.3
```

> **Note:** The fast config defaults to `postprocess_frames: False` and a much tighter `slop: 0.003` (3 ms) for maximum throughput. It also adds `image_qos.*` parameters for publisher QoS tuning.

### Parameter Explanation

| Parameter                  | Type   | Description                                                                                                              | Nodes |
| -------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------ | ----- |
| `debug`                    | bool   | Flag to show debug messages on screen.                                                                                   | Both |
| `depth_encoding`           | string | Encoding for depth conversion (`"32FC1"`, `"16UC1"`, `"passthrough"`).                                                   | Both |
| `input_depth_unit`         | string | Unit of incoming depth (`"m"` or `"mm"`).                                                                                | Both |
| `output_depth_unit`        | string | Unit used internally and for published depth (`"m"` or `"mm"`).                                                          | Both |
| `invalid_depth_thresh`     | float  | Max ratio (0.0-1.0) of invalid pixels (NaN, out-of-range) allowed. Frames exceeding this are marked invalid. Set to `null` to disable validation. | Both |
| `postprocess_frames`       | bool   | Enables the postprocessing pipeline on color and depth frames.                                                            | Both |
| `postprocess_filters`      | string[] | Ordered list of filter names to apply. See [Postprocessing Pipeline](#postprocessing-pipeline) for available filters.   | Both |
| `publish_combined_msg`     | bool   | If `true`, publish only `/stereo/rgbd` (+ camera_info). If `false`, publish separate color/depth topics (+ camera_info). | Both |
| `visualization.show`        | bool   | Enable the per-node OpenCV viewer (color + depth windows for THIS camera).                                              | Both |
| `visualization.display_fps` | float  | Maximum viewer refresh rate. | Both |
| `visualization.merged`      | bool   | If `true`, suppress every per-node viewer and spawn a single `stereo_viewer_node` that aggregates ALL cameras into one window. See [Merged visualization](#merged-visualization). | Both |
| `visualization.grid_cols`   | int    | Tile columns in the merged window. Only used when `merged=true`.                                                         | Both |
| `visualization.tile_width`  | int    | Per-tile width (px) in the merged window. Only used when `merged=true`.                                                 | Both |
| `visualization.tile_height` | int    | Per-tile height (px) in the merged window. Only used when `merged=true`.                                                | Both |
| `visualization.pub_merged_topic` | string | Topic name for the rendered merged grid (`sensor_msgs/Image`, BGR8). Set to `""` to disable. Default: `stereo_viewer/merged_frame`. | Both |
| `color_image_topic`        | string | RGB input topic.                                                                                                         | Both |
| `depth_image_topic`        | string | Depth input topic.                                                                                                       | Both |
| `camera_info_topic`        | string | CameraInfo input topic.                                                                                                  | Both |
| `sync_callback.queue_size` | int    | Message filter buffer depth (per topic). Larger values tolerate jitter/drops but can increase latency/backlog.           | Both |
| `sync_callback.slop`       | float  | Max allowed timestamp difference (seconds) between color and depth to form a pair. Smaller = tighter sync, less lag.     | Both |
| `image_qos.reliability`    | string | Publisher QoS reliability policy (`"best_effort"` or `"reliable"`).                                                      | Fast only |
| `image_qos.depth`          | int    | Publisher QoS history queue depth (minimum 1).                                                                           | Fast only |
| `pub_color_topic`          | string | Output color topic (only if separate mode).                                                                              | Both |
| `pub_depth_topic`          | string | Output depth topic (only if separate mode).                                                                              | Both |
| `pub_camera_info_topic`    | string | Output CameraInfo topic (always published).                                                                              | Both |
| `pub_rgbd_topic`           | string | Output fused RGB-D topic (only if combined mode).                                                                        | Both |
| `deepest_zone_service`     | string | Service name for deepest-zone computation.                                                                               | Both |
| `default_window_radius_px` | int    | Fallback footprint radius when request mask is empty (implementation-dependent).                                         | Both |
| `winsor_p_lo`              | float  | Lower percentile for depth winsorization inside ROI.                                                                     | Both |
| `winsor_p_hi`              | float  | Upper percentile for depth winsorization inside ROI.                                                                     | Both |
| `img_save_active`          | bool   | Enables keyboard-triggered capture to disk.                                                                              | Both |
| `keyboard_topic`           | string | Topic carrying keystrokes (e.g., from a keyboard node).                                                                  | Both |
| `capture_output_dir`       | string | Folder where captures are saved.                                                                                         | Both |
| `capture_debounce_s`       | float  | Minimum seconds between captures to avoid spamming.                                                                      | Both |

## Merged visualization

By default each `stereo_camera_node` opens its own pair of OpenCV windows (one for color, one for depth). With `N` cameras this means `2 × N` windows on screen, which becomes unmanageable beyond a couple of cameras.

Setting `visualization.merged: true` in the `stereo_camera_node` config block flips the launcher behavior:

- Every per-node viewer is suppressed (so `visualization.show` is ignored while `merged` is on).
- A single extra node — `stereo_viewer_node` — is spawned alongside the camera nodes.
- It subscribes to every camera's combined `TkStereoCamMsg` topic (`/<cam>/<pub_rgbd_topic>`) and renders all `2 × N` frames into ONE OpenCV window arranged as a grid.

Each tile carries an overlay label of the form `<camera_name> - color` or `<camera_name> - depth`, so multi-camera setups stay disambiguated.

### Controls

| Input | Effect |
| --- | --- |
| Left-click on a tile | Expands that tile to fill the entire window. |
| `ESC` | Collapses an expanded tile back to the grid. No-op while already on the grid. |
| `q` / `Q` | Closes the merged viewer and shuts down `stereo_viewer_node`. The camera nodes keep publishing. |

### Tuning the grid

The layout knobs (`grid_cols`, `tile_width`, `tile_height`) live in the same `visualization:` block as `merged`. They are read only by `stereo_viewer_node`; per-camera nodes ignore them.

With two cameras and the defaults (`grid_cols: 2`, `tile_width: 640`, `tile_height: 360`) the window is `1280 × 720` and shows:

```
+----------------------+----------------------+
| cam_front - color    | cam_front - depth    |
+----------------------+----------------------+
| cam_back  - color    | cam_back  - depth    |
+----------------------+----------------------+
```

For three cameras with `grid_cols: 2`, the bottom row contains four tiles wrapped across two rows (six tiles total, last row partially filled with a dark placeholder).

### Published topic

`stereo_viewer_node` publishes the rendered merged grid as a `sensor_msgs/Image` (BGR8) on:

```
/stereo_viewer/merged_frame
```

This topic is the intended subscription point for any tool that wants to monitor, record, or forward the visualization — rosbag, a web UI, a secondary display node, etc. Using this topic instead of subscribing directly to the individual camera topics means the camera nodes always have **at most one subscriber** (the viewer itself), regardless of how many monitoring tools are attached.

Configure via `visualization.pub_merged_topic` in the stereo camera config. Set it to an empty string (`""`) to disable publishing entirely. The publisher only encodes and sends frames when at least one subscriber is active.

## Postprocessing Pipeline

Both node variants include an extensible postprocessing pipeline that applies an ordered chain of filters to color and/or depth frames. The pipeline is controlled by two parameters:

- **`postprocess_frames`** (`bool`): Master switch. When `false`, no filters run.
- **`postprocess_filters`** (`string[]`): Ordered list of filter names. Filters execute in the order listed.

Each filter declares its own parameters under `postprocess.<filter_name>.*`.

### Available Filters

| Filter Name | Target | Description | Parameters |
| --- | --- | --- | --- |
| `frame_tear` | both | Detects buffer-wrap (frame tear) corruption via FFT cross-correlation. Replaces torn frames with the last known good frame. Should be placed **first** in the pipeline. | `postprocess.frame_tear.ds` (int, 4), `postprocess.frame_tear.min_shift` (int, 5), `postprocess.frame_tear.mad_ratio` (float, 0.50), `postprocess.frame_tear.check_color` (bool, true), `postprocess.frame_tear.check_depth` (bool, true) |
| `depth_fill` | depth | Fills invalid depth pixels (NaN, Inf, <=0) using iterative neighborhood averaging on GPU (CUDA) or nearest-valid fill on CPU. | `postprocess.depth_fill.iters` (int, 6), `postprocess.depth_fill.ksize` (int, 3) |
| `median_depth` | depth | Applies a median filter for salt-and-pepper noise removal. | `postprocess.median_depth.ksize` (int, 5) |
| `bilateral_depth` | depth | Edge-preserving bilateral smoothing on depth. | `postprocess.bilateral_depth.d` (int, 5), `postprocess.bilateral_depth.sigma_color` (float, 75.0), `postprocess.bilateral_depth.sigma_space` (float, 75.0) |
| `gaussian_color` | color | Gaussian blur on the color frame. | `postprocess.gaussian_color.ksize` (int, 5), `postprocess.gaussian_color.sigma` (float, 0.0) |
| `clahe_color` | color | CLAHE contrast enhancement on the color frame (LAB color space). | `postprocess.clahe_color.clip_limit` (float, 2.0), `postprocess.clahe_color.tile_size` (int, 8) |
| `noise_detection` | color | Detects noise-corrupted color frames via spatial gradient analysis and replaces them with the last known good frame. Computes mean absolute difference between adjacent pixels on a downsampled single channel; natural images score ~5-20, pure noise ~50+. Works on single frames, independent of camera motion, < 0.5 ms. **Color only — do not use on depth.** | `postprocess.noise_detection.threshold` (float, 50.0), `postprocess.noise_detection.ds` (int, 4) |

### Example: Multiple filters

```yaml
postprocess_frames: True
postprocess_filters:
  - "frame_tear"       # detect and discard torn frames (run first)
  - "depth_fill"       # fill invalid depth pixels
  - "bilateral_depth"  # smooth depth while preserving edges

postprocess:
  frame_tear:
    check_color: True
    check_depth: True
  depth_fill:
    iters: 6
    ksize: 3
  bilateral_depth:
    d: 5
    sigma_color: 75.0
    sigma_space: 75.0
```

---

## Environment Variables

| Variable | Description |
| --- | --- |
| ROS_NAMESPACE | Legacy way to launch a binary inside a namespace. Works on most distros but is **unreliable on ROS 2 Jazzy** when the binary is started via `launch.actions.ExecuteProcess` — the env is honored at the shell level but the node still comes up at the root namespace. Prefer the CLI remap `--ros-args -r __ns:=/<namespace>` (shown in the **Launch** section). |

When using namespace, all the topics with no inital '/' will be defined as **'/{namespace}/{topic}'**. If namespace is not defined, topics will be **'/{topic}'**.

## Launch

### Standard node (`stereo_camera_node`)

Launch the standard node from a main repo's launch:
```python
from launch import LaunchDescription
from launch_ros.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from ament_index_python.packages import get_package_share_directory
import os

config_file = "<Path to the node config file>"

def generate_launch_description():
    pkg_dir = get_package_share_directory('tk_ros2_pkg_stereocamera')

    return LaunchDescription([
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(pkg_dir, 'launch', 'stereocamera_launcher.launch.py')
            ),
            launch_arguments={'param_file': config_file}.items()
        )
    ])

```

### Fast node (`stereo_camera_node_fast`)

Launch the fast node from a main repo's launch:
```python
from launch import LaunchDescription
from launch_ros.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from ament_index_python.packages import get_package_share_directory
import os

config_file = "<Path to the fast node config file>"

def generate_launch_description():
    pkg_dir = get_package_share_directory('tk_ros2_pkg_stereocamera')

    return LaunchDescription([
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(pkg_dir, 'launch', 'stereocamera_fast_launcher.launch.py')
            ),
            launch_arguments={'param_file': config_file}.items()
        )
    ])

```

### RTSP mode launch

To use RTSP streams instead of a camera driver, use the RTSP config preset with either launcher. The launch file detects `rtsp.enabled: true` in the config and automatically starts the `rtsp_camera_node` alongside the stereocamera processing node:

```python
from launch import LaunchDescription
from launch_ros.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from ament_index_python.packages import get_package_share_directory
import os

config_file = "<Path to the RTSP config file>"

def generate_launch_description():
    pkg_dir = get_package_share_directory('tk_ros2_pkg_stereocamera')

    return LaunchDescription([
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(pkg_dir, 'launch', 'stereocamera_launcher.launch.py')
            ),
            launch_arguments={'param_file': config_file}.items()
        )
    ])
```

> **Tip:** The same launch file works for both standard and RTSP modes. When `rtsp.enabled` is absent or `false`, the launcher behaves exactly as before (single stereocamera node, no RTSP). To switch between modes, simply change the config file.

---

### Multi-camera setup (RTSP)

When the robot has more than one RTSP camera (e.g. `/cam_front` and `/cam_back`, each streaming RGB + depth + CameraInfo), the launcher can spawn one full pipeline per camera under its own ROS 2 namespace. Each camera ends up with its own pair of nodes (`rtsp_camera_node` + `stereo_camera_node`), its own topic tree, and its own deepest-zone service — fully isolated, but driven by shared param blocks.

The pattern relies on the standard ROS 2 `/**` wildcard for namespace-agnostic params, plus per-camera blocks that only contain the values that differ (URLs, `frame_id`).

#### Config layout — split across two files

Two files in `configs/`:

1. **`stereo_cameras.yaml`** — the multi-camera spawn list. Read **only** by the launcher.
2. **`stereo_camera_node_rtsp.yaml`** — the actual node parameters. Read by both the launcher (to detect `rtsp.enabled`) and the nodes themselves.

They have to be split because `rcl_yaml_param_parser` rejects top-level YAML keys that are not node FQNs — putting `multi_camera:` inside the params file would crash any binary consumer that ingests the YAML via `--params-file`. Keeping the two concerns split lets both consumption paths (`launch_ros.Node` and `ExecuteProcess --params-file`) work cleanly.

`configs/stereo_cameras.yaml`:

```yaml
multi_camera:
  cameras: ["cam_front", "cam_back"]   # empty list → single-camera at root
```

`configs/stereo_camera_node_rtsp.yaml` — two parts:

```yaml
# 1. Shared params — applied to every rtsp_camera_node and every
#    stereo_camera_node regardless of namespace.
/**/rtsp_camera_node:
  ros__parameters:
    rtsp:
      enabled: true
      rgb_latency: 20
      depth_latency: 200
      # ... other settings shared by all cameras
    pub_color_topic: "rtsp/color/image_raw"
    pub_depth_topic: "rtsp/depth/image_raw"
    pub_camera_info_topic: "rtsp/camera_info"

/**/stereo_camera_node:
  ros__parameters:
    depth_encoding: "16UC1"
    input_depth_unit: "mm"
    output_depth_unit: "mm"
    publish_combined_msg: True
    # Relative input topics → namespaced per camera at runtime.
    color_image_topic: "rtsp/color/image_raw"
    depth_image_topic: "rtsp/depth/image_raw"
    camera_info_topic: "rtsp/camera_info"
    # ... shared processing/QoS/sync settings

# 2. Per-camera overrides — only the keys that differ. The fully
#    qualified path (/cam_front/..., /cam_back/...) wins over the
#    /** wildcard for that specific namespace.
/cam_front/rtsp_camera_node:
  ros__parameters:
    rtsp:
      rgb_url: "rtsp://192.168.3.108:8554/rgb"
      depth_url: "rtsp://192.168.3.109:8554/depth_raw"
    camera_info:
      frame_id: "cam_front_frame"

/cam_back/rtsp_camera_node:
  ros__parameters:
    rtsp:
      rgb_url: "rtsp://192.168.3.110:8554/rgb"
      depth_url: "rtsp://192.168.3.111:8554/depth_raw"
    camera_info:
      frame_id: "cam_back_frame"
```

> **Note:** Only the bits that genuinely differ per camera (URLs, `frame_id`) need an override block. Everything else — latencies, QoS, postprocess pipeline, sync slop, output topic names, deepest-zone params — stays in the shared `/**` blocks.

#### Launch (ament install)

Pass both files to the upstream launcher via `param_file` and `cameras_file`:

```python
from launch import LaunchDescription
from launch_ros.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from ament_index_python.packages import get_package_share_directory
import os

params_file  = "<Path to stereo_camera_node_rtsp.yaml>"
cameras_file = "<Path to stereo_cameras.yaml>"

def generate_launch_description():
    pkg_dir = get_package_share_directory('tk_ros2_pkg_stereocamera')

    return LaunchDescription([
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(pkg_dir, 'launch', 'stereocamera_launcher.launch.py')
            ),
            launch_arguments={
                'param_file':   params_file,
                'cameras_file': cameras_file,
            }.items()
        )
    ])
```

The launcher reads `multi_camera.cameras` from `cameras_file` and loops over the list, spawning one namespaced `rtsp_camera_node` + `stereo_camera_node` pair per entry. Omitting `cameras_file` (or pointing it at an empty list) makes the launcher fall back to its original single-camera behavior at root namespace.

#### Binary install (ExecuteProcess loop)

When the package is installed via `tk_pkg_installer` (binaries under `tk_binaries/tk_ros2_pkg_stereocamera/*.bin`), the package is **not** ament-registered. That means `launch_ros.Node(package='tk_ros2_pkg_stereocamera', ...)` and `IncludeLaunchDescription(...)` against the upstream launcher both fail to resolve — you have to call the `.bin` files directly via `ExecuteProcess` and replicate the launcher logic locally:

```python
"""Launch the stereocamera pipeline for one or more cameras.

Replicates the upstream stereocamera_launcher.launch.py logic for
binary-only installs (where Node(package='tk_ros2_pkg_stereocamera')
can't resolve because the package is not ament-registered).
"""
import os
import yaml

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import ExecuteProcess


def _build_actions(rtsp_bin, stereo_bin, config, cameras):
    actions = []
    # Empty list → single-camera at root namespace (back-compat).
    for cam in cameras or ['']:
        ns_args = ['-r', f'__ns:=/{cam}'] if cam else []

        actions.append(ExecuteProcess(
            cmd=[rtsp_bin, '--ros-args', '--params-file', config] + ns_args,
            output='screen',
        ))

        # If you kept the /zed/... defaults for some reason, re-assert
        # the RTSP inputs explicitly here. With the shipped config the
        # stereo node's defaults already match rtsp_camera_node's
        # outputs, so these -p flags are redundant — kept for clarity.
        actions.append(ExecuteProcess(
            cmd=[
                stereo_bin, '--ros-args', '--params-file', config,
                '-p', 'color_image_topic:=rtsp/color/image_raw',
                '-p', 'depth_image_topic:=rtsp/depth/image_raw',
                '-p', 'camera_info_topic:=rtsp/camera_info',
            ] + ns_args,
            output='screen',
        ))
    return actions


def generate_launch_description():
    tk_workspace = os.environ.get('TK_WORKSPACE')
    if not tk_workspace:
        raise RuntimeError('TK_WORKSPACE not set; enter the workspace via direnv.')

    binaries_dir = os.path.join(
        tk_workspace, 'ros2_ws', 'tk_binaries', 'tk_ros2_pkg_stereocamera',
    )
    rtsp_bin   = os.path.join(binaries_dir, 'rtsp_camera_node.bin')
    stereo_bin = os.path.join(binaries_dir, 'stereo_camera_node.bin')

    # Config files live in the consumer package's `config/` dir; adjust
    # `get_package_share_directory(...)` accordingly.
    pkg_config_dir  = os.path.join(get_package_share_directory('YOUR_PKG'), 'config')
    rtsp_config     = os.path.join(pkg_config_dir, 'stereo_camera_node_rtsp.yaml')
    cameras_config  = os.path.join(pkg_config_dir, 'stereo_cameras.yaml')

    with open(cameras_config) as f:
        cameras_yaml = yaml.safe_load(f) or {}
    cameras = (cameras_yaml.get('multi_camera') or {}).get('cameras', []) or []

    return LaunchDescription(
        _build_actions(rtsp_bin, stereo_bin, rtsp_config, cameras)
    )
```

Two things worth flagging in this pattern:

- **Namespacing uses `-r __ns:=/<cam>`, not `ROS_NAMESPACE`.** The env-var path is honored at the shell level but on ROS 2 Jazzy + `ExecuteProcess` the node still comes up at the root namespace — both cameras then match only the `/**/<node>:` block and the per-camera overrides are silently skipped.
- **Each binary is launched in its own `ExecuteProcess`.** The split-file config layout from the previous section is what makes this safe: `stereo_camera_node_rtsp.yaml` contains only node FQN keys (`rcl`-clean), so `--params-file` doesn't crash. The `multi_camera.cameras` list comes from the separate `stereo_cameras.yaml`, read only by the launch file.

#### Resulting topology

For `cameras: ["cam_front", "cam_back"]` the runtime exposes two parallel trees:

```text
/cam_front/rtsp/color/image_raw           /cam_back/rtsp/color/image_raw
/cam_front/rtsp/depth/image_raw           /cam_back/rtsp/depth/image_raw
/cam_front/rtsp/camera_info               /cam_back/rtsp/camera_info
/cam_front/stereo/rgbd                    /cam_back/stereo/rgbd
/cam_front/stereo/camera_info             /cam_back/stereo/camera_info
/cam_front/stereo/find_deepest_zone (srv) /cam_back/stereo/find_deepest_zone (srv)
```

Downstream consumers address each camera by its fully-qualified topic / service name — there is no global `/stereo/rgbd` to disambiguate.

> **TF note:** Give each camera a distinct `camera_info.frame_id` (`cam_front_frame`, `cam_back_frame`, …) in its override block. The `rtsp_camera_node` stamps every `Image` and `CameraInfo` with that frame_id, so TF stays unambiguous when both cameras feed the same downstream graph.

#### Backward compatibility

Omitting the `cameras_file` launch argument (or pointing it at a file whose `multi_camera.cameras` list is empty) makes the launcher fall back to its original single-camera behavior: one `rtsp_camera_node` + one `stereo_camera_node` at the root namespace, no namespacing applied.

#### Diagnostic checklist — "streams won't open"

Roughly cheapest → most involved. The first two catch most multi-camera namespacing issues:

1. **Logger prefix carries the namespace** — at startup each line should read `[cam_front.rtsp_camera_node]`. If it just reads `[rtsp_camera_node]`, namespacing failed; check that `-r __ns:=/<cam>` is on the CLI (the env-var path is not enough under Jazzy).
2. **The "Connecting to … stream" URL matches the YAML override** — if it shows the shared `/**/rtsp_camera_node` default instead of the per-camera URL, the override block didn't match. Usually a symptom of #1.
3. **The RTSP server actually serves that mount** — `ffplay rtsp://host:8554/<cam>/rgb` from the same machine; a 404 means the mount isn't published.
4. **Network reachability** — `ping host`, `ip neigh show host` (look for `INCOMPLETE` / `FAILED`), `nc -zv host 8554`.
5. **stereo_camera_node listening on the right input** — `ros2 node info /cam_front/stereo_camera_node` should show subscriptions on `/cam_front/rtsp/...`, not `/zed/...`. If it's on `/zed/...`, the YAML defaults didn't get picked up; check that `--params-file` actually loaded the shared `/**/stereo_camera_node` block.

---

### Binary launch (both variants)

Alternatively, if you are using the binary version of the package, you can launch it using the ExecuteProcess command. To run inside a namespace, pass the `__ns` remap on the CLI — the `ROS_NAMESPACE` env-var path is fragile under Jazzy + `ExecuteProcess`:

```python
from launch import LaunchDescription
from launch.actions import ExecuteProcess
import getpass

USER = getpass.getuser()

def generate_launch_description():

    # Path to the YAML parameter file
    bin_stereocamera = f'/home/{USER}/<path to .bin>'
    param_path = f'/home/{USER}/<path to config file>'


    return LaunchDescription([
        ExecuteProcess(
            cmd=[bin_stereocamera,
                '--ros-args',
                '--params-file', param_path,
                # Uncomment to launch inside a namespace (preferred over
                # ROS_NAMESPACE env var):
                # '-r', '__ns:=/my_namespace',
            ],
            output='screen'
        ),
    ])
```

---

## Maintainers

- **THEKER Robotics Engineering Team**
- **Miquel Beltran Moncada** — ([m.beltran@theker.eu](mailto:m.beltran@theker.eu))
