import torch
import torch.nn as nn
import torch.nn.functional as F

def quantize_afpos(x):
    """
    Quantizes a tensor to the AFPOS format as described in the AxLaM paper.
    Format: N=10, es=4, beta=-7. 
    Value = (-1)^sign * 2^beta * 2^exp * (1.mantissa)
    - sign: 1 bit
    - exp: 4 bits (so values 0 to 15, yielding effective exponents -7 to 8)
    - mantissa: 3 bits (values 0/8, 1/8, ..., 7/8)
    Max value: 2^8 * (1 + 7/8) = 480.0
    Min positive value: 2^-7 * 1.0 = 0.0078125
    """
    zero_mask = (x == 0)
    sign = torch.sign(x)
    abs_x = torch.abs(x)
    
    # Clamp to representable range
    min_val = 2.0 ** -7
    max_val = 2.0 ** 8 * (1.0 + 7.0/8.0)
    
    # Mask out values that are too small to be represented, turn them to zero
    too_small_mask = abs_x < min_val
    abs_x_clamped = torch.clamp(abs_x, min=min_val, max=max_val)
    
    # frexp gives m in [0.5, 1) and e such that x = m * 2^e
    # We want x = (1 + f) * 2^E where f in [0, 1)
    m, e = torch.frexp(abs_x_clamped)
    
    # frexp returns exponent as int on some torch builds; cast to float
    # so in-place float additions don't raise a type-cast error
    E = (e - 1).float()
    f = m * 2.0 - 1.0
    
    # Quantize mantissa to 3 bits (8 levels)
    f_q = torch.round(f * 8.0) / 8.0
    
    # Handle rounding overflow
    overflow_mask = (f_q >= 1.0)
    f_q[overflow_mask] -= 1.0
    E[overflow_mask] += 1.0
    
    # Re-clamp E after overflow
    E = torch.clamp(E, max=8)
    
    val_q = sign * (2.0 ** E) * (1.0 + f_q)
    val_q[zero_mask | too_small_mask] = 0.0
    
    return val_q

class AFPOSQuantizer(torch.autograd.Function):
    @staticmethod
    def forward(ctx, x):
        return quantize_afpos(x)
    
    @staticmethod
    def backward(ctx, grad_output):
        # Straight-Through Estimator (STE)
        return grad_output

def afpos_quantize(x):
    return AFPOSQuantizer.apply(x)

class AFPOSLinear(nn.Linear):
    """
    A linear layer that quantizes its inputs and weights to AFPOS format
    during the forward pass.
    """
    def __init__(self, in_features, out_features, bias=True, device=None, dtype=None):
        super().__init__(in_features, out_features, bias, device, dtype)
        
    def forward(self, input):
        q_weight = afpos_quantize(self.weight)
        q_input = afpos_quantize(input)
        q_bias = afpos_quantize(self.bias) if self.bias is not None else None
        
        return F.linear(q_input, q_weight, q_bias)
