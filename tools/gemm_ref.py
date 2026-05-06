import numpy as np

def gemm_ref(A, B, C, dtype=np.float16):
    """
    Golden model: D = A @ B + C
    
    Args:
        A: [M, K] matrix
        B: [K, N] matrix  
        C: [M, N] matrix
        dtype: output dtype (default float16)
    
    Returns:
        D: [M, N] result in specified dtype
    """
    A_f = A.astype(np.float32)
    B_f = B.astype(np.float32)
    C_f = C.astype(np.float32)
    D_f = A_f @ B_f + C_f
    return D_f.astype(dtype)

def compare_ulp(rtl_result, ref_result, normal_ulp=1, subnormal_ulp=4):
    """
    Compare RTL result against reference with ULP tolerance.
    
    Returns:
        (pass_bool, max_ulp, mismatch_count)
    """
    rtl_f = rtl_result.astype(np.float32)
    ref_f = ref_result.astype(np.float32)
    
    # Calculate ULP difference (simplified: abs difference / ULP size)
    # For FP16, ULP size varies by exponent
    diff = np.abs(rtl_f - ref_f)
    
    # Count mismatches
    mismatch = 0
    max_ulp = 0
    
    for i in range(rtl_result.size):
        r = rtl_f.flat[i]
        e = ref_f.flat[i]
        
        # Skip NaN comparison (NaN != NaN)
        if np.isnan(r) or np.isnan(e):
            continue
            
        # Calculate ULP for this exponent range
        abs_val = max(abs(r), abs(e))
        if abs_val < 2**-14:  # subnormal
            ulp_size = 2**-24
            threshold = subnormal_ulp
        else:
            exponent = np.floor(np.log2(abs_val))
            ulp_size = 2**(exponent - 10)
            threshold = normal_ulp
        
        ulp_diff = abs(r - e) / ulp_size if ulp_size > 0 else 0
        max_ulp = max(max_ulp, ulp_diff)
        
        if ulp_diff > threshold:
            mismatch += 1
    
    return (mismatch == 0, max_ulp, mismatch)

def generate_random_matrix(rows, cols, dtype=np.float16, seed=None):
    """Generate random FP16 matrix."""
    if seed is not None:
        np.random.seed(seed)
    return np.random.randn(rows, cols).astype(dtype)

def generate_identity_matrix(n, dtype=np.float16):
    """Generate identity matrix."""
    return np.eye(n, dtype=dtype)

if __name__ == "__main__":
    # Quick self-test
    M, N, K = 4, 4, 4
    A = generate_random_matrix(M, K)
    B = generate_random_matrix(K, N)
    C = generate_random_matrix(M, N)
    
    D = gemm_ref(A, B, C)
    print(f"Shape: {D.shape}, dtype: {D.dtype}")
    print(f"Sample values: {D[0,:3]}")
    
    # Identity test: I @ I + 0 = I
    I = generate_identity_matrix(4)
    Z = np.zeros((4, 4), dtype=np.float16)
    result = gemm_ref(I, I, Z)
    print(f"Identity test close: {np.allclose(result.astype(np.float32), I.astype(np.float32), atol=1e-3)}")
