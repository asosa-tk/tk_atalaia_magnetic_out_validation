import numpy as np

def kernel_from_object_size_px(width_px: int, height_px: int, *, use_ellipse: bool = True, erosion_px: int = 2, erosion_iterations: int = 1) -> np.ndarray:
    """
    Build a compact sliding footprint kernel from object (width,height) in pixels.

    - If use_ellipse=True, creates a filled ellipse inside the (h,w) box.
    - If use_ellipse=False, creates a filled rectangle (all ones).
    - Applies a light erosion to avoid using border pixels (often noisy in depth).

    Returns: float32 kernel with values {0.0, 1.0}, odd-sized.
    """
