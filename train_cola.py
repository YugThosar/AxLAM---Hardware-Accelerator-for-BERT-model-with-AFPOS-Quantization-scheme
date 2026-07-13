import os
import torch
import numpy as np
from datasets import load_dataset
from transformers import BertTokenizer, Trainer, TrainingArguments
from sklearn.metrics import matthews_corrcoef, accuracy_score
from bert_afpos_model import get_afpos_bert

def compute_metrics(eval_pred):
    logits, labels = eval_pred
    predictions = np.argmax(logits, axis=-1)
    
    mcc = matthews_corrcoef(labels, predictions)
    acc = accuracy_score(labels, predictions)
    return {
        'accuracy': acc,
        'mcc': mcc
    }

def main():
    print("Loading CoLA dataset...")
    # CoLA dataset is part of GLUE
    dataset = load_dataset("nyu-mll/glue", "cola")
    
    tokenizer = BertTokenizer.from_pretrained("bert-base-uncased")
    
    def tokenize_function(examples):
        return tokenizer(examples["sentence"], padding="max_length", truncation=True, max_length=128)
    
    print("Tokenizing dataset...")
    tokenized_datasets = dataset.map(tokenize_function, batched=True)
    
    train_dataset = tokenized_datasets["train"]
    eval_dataset = tokenized_datasets["validation"]
    
    print("Initializing AFPOS BERT model...")
    model = get_afpos_bert("bert-base-uncased", num_labels=2)
    
    # Check if GPU is available
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Using device: {device}")
    
    training_args = TrainingArguments(
        output_dir="./results",
        eval_strategy="steps",
        eval_steps=5,
        learning_rate=2e-5,
        per_device_train_batch_size=16,
        per_device_eval_batch_size=16,
        num_train_epochs=2,
        weight_decay=0.01,
        save_strategy="steps",
        save_steps=5,
        load_best_model_at_end=True,
        metric_for_best_model="mcc" #, max_steps=10
    )
    
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        compute_metrics=compute_metrics,
    )
    
    print("Starting training...")
    trainer.train()
    
    print("Evaluating...")
    eval_results = trainer.evaluate()
    print(f"Evaluation Results: {eval_results}")

if __name__ == "__main__":
    main()
