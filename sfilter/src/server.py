from flask import Flask, request, render_template_string
import os
import requests
import time
import logging

from transformers import AutoTokenizer, AutoModelForSequenceClassification, pipeline
import torch

app = Flask(__name__)
app.start_time = time.time()

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SECONDARY_MODEL = os.getenv("SECONDARY_MODEL")
if not SECONDARY_MODEL:
  raise ValueError("SECONDARY_MODEL environment variable is not set.")

#Log secondary model
logger.info(f"SECONDARY_MODEL = {SECONDARY_MODEL}")
logger.info(f"PyTorch version: {torch.__version__}")
logger.info(f"CUDA available: {torch.cuda.is_available()}")

# Global variables for model components
classifier = None
model_loaded = False

def load_model():
    """Load model with error handling and optimization"""
    global classifier, model_loaded
    
    try:
        logger.info("Starting model loading...")
        start_time = time.time()
        
        # Load model components
        tokenizer = AutoTokenizer.from_pretrained(SECONDARY_MODEL)
        model = AutoModelForSequenceClassification.from_pretrained(SECONDARY_MODEL)
        
        # Optimize model for inference
        model.eval()  # Set to evaluation mode
        if torch.cuda.is_available():
            model = model.cuda()
            logger.info("Model moved to CUDA")
        
        # Create pipeline with optimizations
        classifier = pipeline(
            "text-classification",
            model=model,
            tokenizer=tokenizer,
            truncation=True,
            max_length=512,  # Reduced from 8192 for faster processing
            device=torch.device("cuda" if torch.cuda.is_available() else "cpu"),
            batch_size=1,
            return_all_scores=False  # Only return top prediction
        )
        
        model_loaded = True
        load_time = time.time() - start_time
        logger.info(f"SFilter model loaded successfully in {load_time:.2f}s")
        
        # Test the model with a simple input
        test_result = classifier("test message")
        logger.info(f"Model test successful: {test_result}")
        
    except Exception as e:
        logger.error(f"Error during model loading: {e}")
        model_loaded = False
        raise Exception(f"Error during startup: {e}, Secondary Model: {SECONDARY_MODEL}")

# Load model on startup
load_model()

# Health check endpoint
@app.route("/health", methods=["GET"])
def health_check():
    """Health check endpoint"""
    try:
        if not model_loaded or classifier is None:
            return {"status": "unhealthy", "error": "Model not loaded"}, 503
            
        # Quick model validation with a simple test
        test_result = classifier("hello world")
        return {
            "status": "healthy", 
            "timestamp": time.time(), 
            "model": SECONDARY_MODEL,
            "cuda_available": torch.cuda.is_available()
        }, 200
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return {"status": "unhealthy", "error": str(e)}, 503

@app.route("/ready", methods=["GET"])
def readiness_check():
    """Readiness check"""
    if not model_loaded or classifier is None:
        return {"status": "not_ready", "error": "Model not loaded"}, 503
    return {"status": "ready", "timestamp": time.time()}, 200



@app.route("/", methods=["POST"])
def main():
    """Main classification endpoint with performance tracking"""
    start_time = time.time()
    
    userMessage = request.form.get('message', '')
    
    if not model_loaded or classifier is None:
        logger.error("Model not loaded")
        return "Service temporarily unavailable", 503
    
    if not userMessage.strip():
        return "ok", 200
    
    try:
        # Perform classification
        classification = classifier(userMessage)
        
        # Log processing time
        processing_time = time.time() - start_time
        logger.info(f"Classification took {processing_time:.3f}s for message length {len(userMessage)}")
        
        if classification[0]['label'] == 'jailbreak':
            logger.info(f"Jailbreak detected: confidence={classification[0]['score']:.3f}")
            return "I don't understand your message, can you say it another way? (secondary)", 401
        
        logger.debug(f"Message passed: confidence={classification[0]['score']:.3f}")
        return "ok", 200
        
    except Exception as e:
        logger.error(f"Classification error: {e}")
        return "Classification service error", 500
            
if __name__ == "__main__":
    app.run(debug=True, port=8082, host='0.0.0.0')