import os
import time
import torch
import numpy as np
from datasets import load_dataset
from transformers import BertTokenizer, BertForSequenceClassification
from sklearn.metrics import matthews_corrcoef, accuracy_score, classification_report
from bert_afpos_model import replace_linear_with_afpos

def evaluate_model(model, dataloader, device):
    model.eval()
    all_preds = []
    all_labels = []
    
    start_time = time.time()
    with torch.no_grad():
        for batch in dataloader:
            inputs = {k: v.to(device) for k, v in batch.items() if k != "labels"}
            labels = batch["labels"]
            
            outputs = model(**inputs)
            preds = torch.argmax(outputs.logits, dim=-1).cpu().numpy()
            
            all_preds.extend(preds)
            all_labels.extend(labels.numpy())
            
    latency = time.time() - start_time
    
    accuracy = accuracy_score(all_labels, all_preds)
    mcc = matthews_corrcoef(all_labels, all_preds)
    
    return {
        "accuracy": accuracy,
        "mcc": mcc,
        "latency": latency,
        "preds": all_preds,
        "labels": all_labels
    }

def main():
    # Find the latest/best checkpoint directory
    checkpoint_dir = "results/checkpoint-10"
    if not os.path.exists(checkpoint_dir):
        checkpoint_dir = "results/checkpoint-5"
    
    if not os.path.exists(checkpoint_dir):
        print("Error: Could not find any checkpoint directory in './results'. Please ensure training completed successfully.")
        return

    print("Loading CoLA validation dataset...")
    dataset = load_dataset("nyu-mll/glue", "cola", split="validation")
    
    tokenizer = BertTokenizer.from_pretrained("bert-base-uncased")
    
    print("Tokenizing dataset...")
    def tokenize_function(examples):
        return tokenizer(examples["sentence"], padding="max_length", truncation=True, max_length=128)
        
    tokenized_dataset = dataset.map(tokenize_function, batched=True)
    tokenized_dataset.set_format(type="torch", columns=["input_ids", "token_type_ids", "attention_mask", "label"])
    
    # Create dataloader
    from torch.utils.data import DataLoader
    dataloader = DataLoader(tokenized_dataset, batch_size=16, shuffle=False)
    
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Using device: {device}\n")
    
    # --- SCENARIO 1: Evaluate Standard BERT (Dequantized / FP32) ---
    print("--- Scenario 1: Loading model in standard FP32 mode (De-quantized) ---")
    model_fp32 = BertForSequenceClassification.from_pretrained(checkpoint_dir).to(device)
    # Prepare batch matching glue names
    formatted_dataloader = []
    for batch in dataloader:
        formatted_dataloader.append({
            "input_ids": batch["input_ids"],
            "token_type_ids": batch["token_type_ids"],
            "attention_mask": batch["attention_mask"],
            "labels": batch["label"]
        })
        
    results_fp32 = evaluate_model(model_fp32, formatted_dataloader, device)
    print(f"FP32 Accuracy: {results_fp32['accuracy']:.4f}")
    print(f"FP32 MCC:      {results_fp32['mcc']:.4f}")
    print(f"Time Taken:    {results_fp32['latency']:.2f} seconds")
    
    # Free memory
    del model_fp32
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    print()

    # --- SCENARIO 2: Evaluate AFPOS BERT (Quantized 10-bit) ---
    print("--- Scenario 2: Loading model in AFPOS-quantized mode ---")
    model_afpos = BertForSequenceClassification.from_pretrained(checkpoint_dir)
    replace_linear_with_afpos(model_afpos)
    model_afpos = model_afpos.to(device)
    
    results_afpos = evaluate_model(model_afpos, formatted_dataloader, device)
    print(f"AFPOS Accuracy: {results_afpos['accuracy']:.4f}")
    print(f"AFPOS MCC:      {results_afpos['mcc']:.4f}")
    print(f"Time Taken:     {results_afpos['latency']:.2f} seconds")
    
    print("\n" + "="*50)
    print("                COMPARISON SUMMARY")
    print("="*50)
    print(f"{'Metric':<15} | {'FP32 (De-quantized)':<20} | {'AFPOS (Quantized)':<20}")
    print("-"*50)
    print(f"{'Accuracy':<15} | {results_fp32['accuracy']:<20.4f} | {results_afpos['accuracy']:<20.4f}")
    print(f"{'MCC':<15} | {results_fp32['mcc']:<20.4f} | {results_afpos['mcc']:<20.4f}")
    print(f"{'Eval Latency':<15} | {results_fp32['latency']:<18.2f}s | {results_afpos['latency']:<18.2f}s")
    print("="*50)
    
    # Note on training steps
    if results_afpos['mcc'] == 0.0:
        print("\n[NOTE] The MCC score is currently 0.0. This is because the model was trained for only 10 steps.")
        print("To get high-quality grammatical predictions, edit 'train_cola.py' to remove or increase 'max_steps' (e.g. comment out line 56) and train for at least 1-3 epochs.")

if __name__ == "__main__":
    main()
