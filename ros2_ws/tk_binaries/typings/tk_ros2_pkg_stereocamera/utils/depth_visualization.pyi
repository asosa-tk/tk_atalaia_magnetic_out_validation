import numpy as np

def visualize_depth(depth_img: np.ndarray, max_range: float = 10.0, p_lo: float = 2.0, p_hi: float = 98.0, sample_stride: int = 4) -> np.ndarray:
    """Convert a raw depth map into a colorized BGR image for display.

    Robust against partial invalid data: never collapses to a black frame
    just because some pixels are NaN/inf/out-of-range. Auto-detects whether
    the input is in meters or millimeters.

    Args:
        depth_img (np.ndarray): Raw depth map (HxW). dtype uint16 (mm) or
            float (m/mm — auto-detected by magnitude).
        max_range (float): Upper bound for valid depth, in the same unit as
            the input. Defaults to 10 m / 10 000 mm.
        p_lo (float): Low percentile for robust contrast stretching.
        p_hi (float): High percentile for robust contrast stretching.
        sample_stride (int): Stride used when subsampling for percentile
            estimation. Larger → faster, less precise.

    Returns:
        np.ndarray: HxWx3 uint8 BGR image colorized with COLORMAP_TURBO.
    """
