from flask import Flask, request, render_template_string
import os
import requests
import time
import logging
from google.cloud import storage

from transformers import AutoTokenizer, AutoModelForSequenceClassification, pipeline
import torch

app = Flask(__name__)
app.start_time = time.time()

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SECONDARY_MODEL = os.getenv("SECONDARY_MODEL")
GCS_BUCKET_NAME = os.getenv("GCS_BUCKET_NAME")
MODEL_PATH_IN_BUCKET = os.getenv("MODEL_PATH_IN_BUCKET", "jailbreak-model")

if not SECONDARY_MODEL:
    raise ValueError("SECONDARY_MODEL environment variable is not set.")
if not GCS_BUCKET_NAME:
    raise ValueError("GCS_BUCKET_NAME environment variable is not set.")

#Log secondary model
logger.info(f"SECONDARY_MODEL = {SECONDARY_MODEL}")
logger.info(f"GCS_BUCKET_NAME = {GCS_BUCKET_NAME}")
logger.info(f"MODEL_PATH_IN_BUCKET = {MODEL_PATH_IN_BUCKET}")
logger.info(f"PyTorch version: {torch.__version__}")
logger.info(f"CUDA available: {torch.cuda.is_available()}")

# Global variables for model components
classifier = None
model_loaded = False

def download_model_from_gcs():
    """Download model from GCS bucket to local storage"""
    try:
        logger.info("Starting model download from GCS...")
        
        # Create local directory
        os.makedirs(SECONDARY_MODEL, exist_ok=True)
        
        # Initialize GCS client
        storage_client = storage.Client()
        bucket = storage_client.bucket(GCS_BUCKET_NAME)
        
        # List and download all files in the model directory
        blobs = bucket.list_blobs(prefix=f"{MODEL_PATH_IN_BUCKET}/")
        downloaded_files = 0
        
        for blob in blobs:
            if not blob.name.endswith('/'):  # Skip directory entries
                # Calculate local file path
                relative_path = blob.name[len(f"{MODEL_PATH_IN_BUCKET}/"):]
                local_file_path = os.path.join(SECONDARY_MODEL, relative_path)
                
                # Create directory if needed
                os.makedirs(os.path.dirname(local_file_path), exist_ok=True)
                
                # Download file
                blob.download_to_filename(local_file_path)
                logger.info(f"Downloaded {blob.name} to {local_file_path}")
                downloaded_files += 1
        
        logger.info(f"Model download complete. Downloaded {downloaded_files} files.")
        return True
        
    except Exception as e:
        logger.error(f"Error downloading model from GCS: {e}")
        return False

def load_model():
    """Load model with error handling and optimization"""
    global classifier, model_loaded
    
    try:
        logger.info("Starting model loading...")
        start_time = time.time()
        
        # First, download the model from GCS if it doesn't exist locally
        if not os.path.exists(os.path.join(SECONDARY_MODEL, "config.json")):
            logger.info("Model not found locally, downloading from GCS...")
            if not download_model_from_gcs():
                raise Exception("Failed to download model from GCS")
        else:
            logger.info("Model found locally, skipping download")
        
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