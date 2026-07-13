import torch
import torch.nn as nn
from transformers import BertForSequenceClassification
from afpos_emulator import AFPOSLinear

def replace_linear_with_afpos(module):
    """
    Recursively replaces all nn.Linear layers in the module with AFPOSLinear.
    Copies the weights and biases from the original linear layers.
    """
    for name, child in module.named_children():
        if isinstance(child, nn.Linear):
            # Create a new AFPOSLinear layer
            afpos_layer = AFPOSLinear(
                in_features=child.in_features,
                out_features=child.out_features,
                bias=(child.bias is not None),
                device=child.weight.device,
                dtype=child.weight.dtype
            )
            # Copy weights and biases
            afpos_layer.weight.data = child.weight.data.clone()
            if child.bias is not None:
                afpos_layer.bias.data = child.bias.data.clone()
            
            # Replace the child in the parent module
            setattr(module, name, afpos_layer)
        else:
            # Recurse for nested modules
            replace_linear_with_afpos(child)

def get_afpos_bert(model_name="bert-base-uncased", num_labels=2):
    print(f"Loading pretrained {model_name}...")
    model = BertForSequenceClassification.from_pretrained(model_name, num_labels=num_labels)
    print("Replacing nn.Linear with AFPOSLinear...")
    replace_linear_with_afpos(model)
    print("Replacement complete.")
    return model

if __name__ == "__main__":
    model = get_afpos_bert()
    print(model)
