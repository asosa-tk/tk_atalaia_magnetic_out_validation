import numpy as np
from _typeshed import Incomplete
from rclpy.node import Node as Node
from std_msgs.msg import Header as Header
from tk_ros2_pkg_stereocamera.utils.frame_tear_detection import FrameTearDetector as FrameTearDetector

FILTER_REGISTRY: dict[str, type[FrameFilter]]

def register_filter(cls) -> type[FrameFilter]:
    """Class decorator that registers a filter by its ``name`` attribute.

    Args:
        cls (type[FrameFilter]): Filter subclass to register.

    Returns:
        type[FrameFilter]: The same class, unchanged.
    """

class FrameFilter:
    '''Base class for all postprocessing filters.

    Filters process ``(frame, header)`` pairs. A filter that transforms
    pixel data in place (e.g. blur) must pass the header through
    unchanged. A filter that substitutes frame data (e.g. replacing a
    corrupted frame with a cached good one) must substitute the header
    along with it, preserving the image/timestamp pairing.

    Attributes:
        name (str): Unique identifier used in the ``postprocess_filters``
            parameter list and as the parameter namespace prefix.
        target (str): Which frames this filter processes.
            One of ``"color"``, ``"depth"``, or ``"both"``.
    '''
    name: str
    target: str
    node: Incomplete
    def __init__(self, node: Node) -> None:
        """Initializes the filter and loads its parameters from the node.

        Args:
            node (Node): The ROS 2 node that owns this filter.
        """
    def declare_parameters(self) -> None:
        """Declares ROS 2 parameters for this filter.

        Override in subclasses. Parameters should be declared under
        ``postprocess.<name>.*``.
        """
    def load_parameters(self) -> None:
        """Loads declared parameters into instance attributes.

        Override in subclasses.
        """
    def apply_color(self, color: np.ndarray, header: Header) -> tuple[np.ndarray, Header]:
        """Processes a color frame along with its source header.

        Args:
            color (np.ndarray): ``(H, W, 3)`` BGR uint8 image.
            header (Header): Header of the source ``sensor_msgs/Image``
                carrying the original capture timestamp.

        Returns:
            tuple[np.ndarray, Header]: The processed frame and the
            header that corresponds to the returned pixel data.
        """
    def apply_depth(self, depth: np.ndarray, header: Header) -> tuple[np.ndarray, Header]:
        """Processes a depth frame along with its source header.

        Args:
            depth (np.ndarray): ``(H, W)`` depth array.
            header (Header): Header of the source ``sensor_msgs/Image``
                carrying the original capture timestamp.

        Returns:
            tuple[np.ndarray, Header]: The processed frame and the
            header that corresponds to the returned pixel data.
        """
    def apply_pair(self, color: np.ndarray | None, depth: np.ndarray) -> tuple[np.ndarray | None, np.ndarray]:
        """Processes a color-depth pair.

        The default implementation delegates to ``apply_color`` and
        ``apply_depth`` independently based on ``target``.  Filters
        that need **coupled rejection** (replacing both frames when
        either is corrupted) should override this method instead.

        Args:
            color (np.ndarray | None): ``(H, W, 3)`` BGR uint8 image,
                or ``None`` if not decoded.
            depth (np.ndarray): ``(H, W)`` depth array.

        Returns:
            tuple: ``(color, depth)`` after processing.
        """

class PostprocessPipeline:
    """Ordered chain of ``FrameFilter`` instances.

    Built from the ``postprocess_filters`` ROS 2 parameter (list of
    filter names). Applies each filter in order to color and/or depth
    frames depending on each filter's ``target``.

    Attributes:
        enabled (bool): Whether the pipeline is active.
        filters (list[FrameFilter]): Ordered list of active filters.
        has_color_filters (bool): True if any active filter targets
            color frames.
    """
    node: Incomplete
    filters: list[FrameFilter]
    enabled: Incomplete
    has_color_filters: bool
    def __init__(self, node: Node) -> None:
        """Creates the pipeline by reading ROS 2 parameters from ``node``.

        Args:
            node (Node): The ROS 2 node that owns this pipeline.
        """
    def apply(self, color: np.ndarray | None, depth: np.ndarray, color_header: Header | None, depth_header: Header) -> tuple[np.ndarray | None, np.ndarray, Header | None, Header]:
        """Runs all filters on the given frames.

        Each filter may either pass the header through unchanged (pure
        transforms) or substitute the header together with the frame
        data (e.g. when replacing a corrupted frame with a cached good
        one). The returned header always corresponds to the returned
        pixel data.

        Args:
            color (np.ndarray | None): Color frame (may be None if not
                decoded, e.g. when ``show`` is False in the standard node).
            depth (np.ndarray): Depth frame after unit conversion.
            color_header (Header | None): Header of the source color
                message. May be None when ``color`` is None.
            depth_header (Header): Header of the source depth message.

        Returns:
            tuple: ``(color, depth, color_header, depth_header)`` after
            all filters have been applied. Each header corresponds to
            the frame returned alongside it.
        """

class DepthFillFilter(FrameFilter):
    """Fills invalid depth pixels (NaN, Inf, <= 0) using iterative
    neighborhood averaging on GPU or nearest-valid fill on CPU.

    This wraps the existing ``process_depth_frame`` function.

    Parameters:
        postprocess.depth_fill.iters (int): Fill iterations. Default 6.
        postprocess.depth_fill.ksize (int): Kernel size (odd >= 3). Default 3.
    """
    name: str
    target: str
    def declare_parameters(self) -> None: ...
    iters: Incomplete
    ksize: Incomplete
    def load_parameters(self) -> None: ...
    def apply_depth(self, depth: np.ndarray, header: Header) -> tuple[np.ndarray, Header]: ...

class MedianDepthFilter(FrameFilter):
    """Applies a median filter to the depth frame for salt-and-pepper
    noise removal.

    Parameters:
        postprocess.median_depth.ksize (int): Kernel size (odd >= 3).
            Default 5.
    """
    name: str
    target: str
    def declare_parameters(self) -> None: ...
    ksize: Incomplete
    def load_parameters(self) -> None: ...
    def apply_depth(self, depth: np.ndarray, header: Header) -> tuple[np.ndarray, Header]: ...

class BilateralDepthFilter(FrameFilter):
    """Applies a bilateral filter to the depth frame for edge-preserving
    smoothing.

    Parameters:
        postprocess.bilateral_depth.d (int): Diameter of pixel
            neighborhood. Default 5.
        postprocess.bilateral_depth.sigma_color (float): Filter sigma in
            the color/intensity space. Default 75.0.
        postprocess.bilateral_depth.sigma_space (float): Filter sigma in
            coordinate space. Default 75.0.
    """
    name: str
    target: str
    def declare_parameters(self) -> None: ...
    d: Incomplete
    sigma_color: Incomplete
    sigma_space: Incomplete
    def load_parameters(self) -> None: ...
    def apply_depth(self, depth: np.ndarray, header: Header) -> tuple[np.ndarray, Header]: ...

class GaussianBlurColorFilter(FrameFilter):
    """Applies Gaussian blur to the color frame.

    Parameters:
        postprocess.gaussian_color.ksize (int): Kernel size (odd >= 1).
            Default 5.
        postprocess.gaussian_color.sigma (float): Gaussian sigma.
            Default 0.0 (auto from ksize).
    """
    name: str
    target: str
    def declare_parameters(self) -> None: ...
    ksize: Incomplete
    sigma: Incomplete
    def load_parameters(self) -> None: ...
    def apply_color(self, color: np.ndarray, header: Header) -> tuple[np.ndarray, Header]: ...

class ClaheColorFilter(FrameFilter):
    """Applies CLAHE (Contrast Limited Adaptive Histogram Equalization)
    to the color frame in LAB color space for improved contrast.

    Parameters:
        postprocess.clahe_color.clip_limit (float): Contrast limit.
            Default 2.0.
        postprocess.clahe_color.tile_size (int): Grid tile size.
            Default 8.
    """
    name: str
    target: str
    def declare_parameters(self) -> None: ...
    clip_limit: Incomplete
    tile_size: Incomplete
    def load_parameters(self) -> None: ...
    def apply_color(self, color: np.ndarray, header: Header) -> tuple[np.ndarray, Header]: ...

class NoiseDetectionFilter(FrameFilter):
    """Detects noise-corrupted color frames via spatial gradient analysis
    and applies **coupled rejection** to the entire RGB-D pair.

    Computes the mean absolute difference between adjacent pixels in both
    horizontal and vertical directions on a downsampled single channel.
    Natural images have smooth regions that keep this metric low (~5-20),
    while pure noise frames produce very high values (~50+).

    Works on single frames (no reference needed), is independent of camera
    motion, and runs in < 0.5 ms thanks to 4x downsampling.

    Detection is performed on **color frames only**, but when noise is
    detected both color and depth are replaced with the last known good
    pair to maintain RGB-D coherence.

    When a frame is classified as noise, both the cached pixel data and
    the cached source header (with its original capture timestamp) are
    returned, so that the substituted image travels with the timestamp
    of the frame it originally came from.

    Parameters:
        postprocess.noise_detection.threshold (float): Mean gradient above
            which the frame is considered noise. Default 50.0.
        postprocess.noise_detection.ds (int): Downsample factor. Default 4.
    """
    name: str
    target: str
    def declare_parameters(self) -> None: ...
    threshold: Incomplete
    ds: Incomplete
    def load_parameters(self) -> None: ...
    def apply_color(self, color: np.ndarray, header: Header) -> tuple[np.ndarray, Header]: ...

class FrameTearFilter(FrameFilter):
    """Detects buffer-wrap (frame tear) corruption and applies
    **coupled rejection** to the entire RGB-D pair.

    Uses FFT cross-correlation on downsampled column-mean and row-mean
    signals to detect circularly-shifted frames. When a tear is
    detected, the affected stream (color and/or depth) is replaced with
    its last accepted frame. This filter should be placed **first** in
    the pipeline.

    Each stream caches its pixel data together with the source header,
    so a substituted frame is always published with the original
    capture timestamp of the cached good frame — the image/timestamp
    pairing is never broken.

    Parameters:
        postprocess.frame_tear.ds (int): Downsample factor for mean
            signals. Default 4.
        postprocess.frame_tear.min_shift (int): Minimum shift in
            downsampled pixels to flag a wrap. Default 5.
        postprocess.frame_tear.mad_ratio (float): Shifted MAD must be
            below this fraction of unshifted MAD. Default 0.65.
        postprocess.frame_tear.ref_cache_size (int): Number of
            reference frames in the ring buffer. A frame is rejected
            only when all references flag it (unanimous). Default 3.
        postprocess.frame_tear.check_color (bool): Run tear detection
            on the color frame. Default True.
        postprocess.frame_tear.check_depth (bool): Run tear detection
            on the depth frame. Default True.
    """
    name: str
    target: str
    def declare_parameters(self) -> None: ...
    ds: Incomplete
    min_shift: Incomplete
    mad_ratio: Incomplete
    ref_cache_size: Incomplete
    check_color: Incomplete
    check_depth: Incomplete
    def load_parameters(self) -> None: ...
    def apply_color(self, color: np.ndarray, header: Header) -> tuple[np.ndarray, Header]: ...
    def apply_depth(self, depth: np.ndarray, header: Header) -> tuple[np.ndarray, Header]: ...
