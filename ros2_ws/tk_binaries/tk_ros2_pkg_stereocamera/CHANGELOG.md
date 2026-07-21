# Changelog

## [1.0.3] — 2026-06-30

### Changes

- **`stereo_camera_node` viewer loop** — Reworked to render on change only, which improves viewer efficiency.
- **`rtsp_camera_node` executor** — Now runs on a 2-thread executor to prevent all cores from being strangled
- **Depth unit conversion** — Avoids a redundant full-frame copy of the depth
  image when the input and output depth units are identical, removing a
  per-frame allocation from the processing path.

> **Note:** Version 1.0.2 was released as a binary but is not yet documented in
> this changelog.

---

## [1.0.1] — 2026-06-04

### Added
- **`publishing_control_service`** (`std_srvs/srv/SetBool`) — Runtime service exposed by all three nodes (`stereo_camera_node`, `stereo_camera_node_fast`, `rtsp_camera_node`) to activate (`data: true`) or deactivate (`data: false`) publishing of every camera topic (color, depth, rgbd and `camera_info`) without restarting the node. Default names `stereo/set_publishing` (stereo nodes) and `rtsp/set_publishing` (RTSP node). Reactivation never emits stale frames — the node keeps decoding/syncing while paused and resumes on the live frame.
- **`publish_active_on_startup`** (bool, default `true`) — Whether the node publishes its camera topics immediately on startup, or starts paused until activated via the service.
