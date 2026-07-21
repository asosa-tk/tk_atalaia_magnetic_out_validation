import numpy as np
from _typeshed import Incomplete

DepthUnit: Incomplete

def convert_depth_units(depth: np.ndarray, input_unit: DepthUnit, output_unit: DepthUnit) -> np.ndarray:
    '''
    Convert depth image between metric units.

    Supported units:
        - m  : meters
        - dm : decimeters
        - cm : centimeters
        - mm : millimeters

    Parameters
    ----------
    depth : np.ndarray
        Depth image (any numeric dtype).
    input_unit : {"m", "dm", "cm", "mm"}
        Unit of the input depth.
    output_unit : {"m", "dm", "cm", "mm"}
        Desired output unit.

    Returns
    -------
    depth_out : np.ndarray
        Depth image converted to the desired unit (float32).
    '''
def process_depth_frame(depth: np.ndarray, min_val: float | int | None = None, max_val: float | int | None = None, *, iters: int = 6, ksize: int = 3, fill_value_if_all_invalid: float = 0.0, invalid_depth_thresh: float | None = None) -> tuple[bool, np.ndarray]:
    """
    Fast depth cleanup using PyTorch on GPU if available, with CPU fallback.

    Guarantees:
      - Keeps valid pixels unchanged
      - Fills invalid pixels (NaN/Inf/<=0/out-of-range)
      - Output has same dtype as input
      - Output contains no NaN/Inf (for float inputs)
      - No unit conversion (numeric scale preserved)

    GPU algorithm:
      Iterative masked neighborhood averaging via conv2d.
      Each iteration fills currently-invalid pixels from nearby valid pixels.

    CPU fallback:
      Nearest-valid fill using OpenCV distance transform labels.

    Args:
        depth: HxW depth array (float32 or uint16).
        min_val/max_val: Valid range thresholds (same units as input).
        iters: Number of fill iterations (more fills larger holes).
        ksize: Neighborhood kernel size (odd int >= 3, typically 3 or 5).
        fill_value_if_all_invalid: Used if entire frame has no valid pixels.
        invalid_depth_thresh: If provided, percentage threshold (0.0-1.0) of invalid pixels.
            If the proportion of invalid pixels exceeds this threshold, the frame
            is marked as invalid. If None, no validation check is performed.

    Returns:
        Tuple of (is_valid_frame, cleaned_depth):
          - is_valid_frame: True if the frame passes validation (invalid pixels
            percentage <= invalid_depth_thresh), or if invalid_depth_thresh is None.
          - cleaned_depth: Cleaned depth array with same dtype as input.
    """
