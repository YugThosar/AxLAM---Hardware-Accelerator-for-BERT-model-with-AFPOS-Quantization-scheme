import os
import torch
import torch.nn.functional as F
from transformers import BertTokenizer, BertForSequenceClassification
from bert_afpos_model import replace_linear_with_afpos

def load_trained_model(checkpoint_path="results/checkpoint-10"):
    print(f"Loading tokenizer and base model from: {checkpoint_path} ...")
    tokenizer = BertTokenizer.from_pretrained("bert-base-uncased")
    
    # 1. Load the model weights from the checkpoint
    model = BertForSequenceClassification.from_pretrained(checkpoint_path)
    
    # 2. Inject AFPOS linear layers and copy trained weights into them
    print("Injecting AFPOSLinear layers and transferring trained weights...")
    replace_linear_with_afpos(model)
    
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = model.to(device)
    model.eval()
    print(f"Model successfully loaded on {device}!")
    return model, tokenizer, device

def predict(sentence, model, tokenizer, device):
    # Tokenize input sentence
    inputs = tokenizer(
        sentence,
        padding="max_length",
        truncation=True,
        max_length=128,
        return_tensors="pt"
    )
    
    # Move tensors to the correct device
    inputs = {k: v.to(device) for k, v in inputs.items()}
    
    with torch.no_grad():
        outputs = model(**inputs)
        logits = outputs.logits
        probs = F.softmax(logits, dim=-1)
        prediction = torch.argmax(probs, dim=-1).item()
        confidence = probs[0][prediction].item()
        
    return prediction, confidence

def main():
    # Find the latest/best checkpoint directory
    checkpoint_dir = "results/checkpoint-10"
    if not os.path.exists(checkpoint_dir):
        checkpoint_dir = "results/checkpoint-5"
    
    if not os.path.exists(checkpoint_dir):
        print("Error: Could not find any checkpoint directory in './results'. Please ensure training completed successfully.")
        return

    model, tokenizer, device = load_trained_model(checkpoint_dir)
    
    # Test sentences
    demo_sentences = [
        "The boy is playing in the backyard.",  # Acceptable (Grammatical)
        "The boy are playing in the backyard.",  # Unacceptable (Ungrammatical)
        "She went to the store to buy some milk.",  # Acceptable
        "She went store to buy some milk.",  # Unacceptable
    ]
    
    print("\n=== Running predictions on demo sentences ===")
    for sent in demo_sentences:
        pred, conf = predict(sent, model, tokenizer, device)
        label = "Grammatically Acceptable (1)" if pred == 1 else "Grammatically Unacceptable (0)"
        print(f"\nSentence: \"{sent}\"")
        print(f"Prediction: {label} (Confidence: {conf:.2%})")
        
    print("\n" + "="*40)
    print("Interactive Mode: Type a sentence below to test, or type 'exit' to quit.")
    print("="*40)
    
    while True:
        try:
            user_input = input("\nEnter a sentence: ").strip()
            if not user_input:
                continue
            if user_input.lower() == 'exit':
                break
                
            pred, conf = predict(user_input, model, tokenizer, device)
            label = "Grammatically Acceptable (1)" if pred == 1 else "Grammatically Unacceptable (0)"
            print(f"Result: {label} (Confidence: {conf:.2%})")
        except KeyboardInterrupt:
            break
            
    print("\nExiting inference script. Goodbye!")

if __name__ == "__main__":
    main()
