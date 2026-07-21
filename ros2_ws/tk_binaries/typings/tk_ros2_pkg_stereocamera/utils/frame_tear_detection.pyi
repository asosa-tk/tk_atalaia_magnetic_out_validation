import numpy as np

class FrameTearDetector:
    """Detects buffer-wrap frame corruption via FFT cross-correlation.

    A buffer-wrapped frame is a circularly-shifted version of the real
    scene, produced when the camera driver writes a new frame starting
    mid-buffer. The detector compares the current frame's column-mean
    and row-mean signals against a ring buffer of previously accepted
    reference frames using FFT cross-correlation.

    Uses **unanimous rejection**: a frame is flagged as torn only when
    **all** references in the buffer detect a significant shift. This
    prevents a single false-negative (corrupted frame that sneaked into
    the cache) from causing cascading false-positive rejections.

    Works on both 3D colour arrays (uses green channel) and 2D
    depth/grayscale arrays.

    Attributes:
        _ref_buffer (deque): Ring buffer of ``(col_means, row_means)``
            tuples from the last accepted frames.
    """
    def __init__(self, ds: int = 4, min_shift: int = 5, mad_ratio: float = 0.5, ref_cache_size: int = 3, logger=None) -> None:
        """Creates a new FrameTearDetector instance.

        Args:
            ds (int): Downsample factor for mean signals. Default 4.
            min_shift (int): Minimum shift in downsampled pixels to flag
                a wrap. Default 5.
            mad_ratio (float): Shifted MAD must be below this fraction
                of the unshifted MAD to confirm a wrap. Default 0.50.
            ref_cache_size (int): Number of reference frames to keep in
                the ring buffer. A frame is torn only if all references
                flag it (unanimous rejection). Default 3.
            logger: Optional logger (any object with a ``warning``
                method). If ``None``, no logging is emitted.
        """
    def is_torn(self, image: np.ndarray) -> bool:
        """Detects buffer-wrap corruption via cross-correlation shift.

        Checks whether the current frame is a circularly-shifted version
        of the previously accepted frames along either axis. Uses
        **unanimous rejection**: the frame is torn only if **all**
        references in the ring buffer detect a shift.

        - 3-D arrays (colour): uses channel index 1 (green in BGR/RGB).
        - 2-D arrays (depth/grayscale): uses values directly.

        When a corrupted frame is detected the internal reference buffer
        is NOT updated, so the next frame is still compared against the
        last known good frames.

        Args:
            image (np.ndarray): Image to inspect. ``uint8 (H, W, 3)``
                for colour or ``float32 (H, W)`` for depth/grayscale.

        Returns:
            bool: ``True`` if the frame appears buffer-wrapped (torn).
        """
