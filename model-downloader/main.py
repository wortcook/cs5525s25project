import os
import logging
from huggingface_hub import snapshot_download
from google.cloud import storage

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def main():
    """
    Downloads a model from Hugging Face and uploads it to a GCS bucket.
    """
    model_name = os.environ.get("HF_MODEL_NAME")
    bucket_name = os.environ.get("GCS_BUCKET_NAME")

    if not model_name:
        logging.error("HF_MODEL_NAME environment variable not set.")
        exit(1)
    if not bucket_name:
        logging.error("GCS_BUCKET_NAME environment variable not set.")
        exit(1)

    local_dir = "/model"
    os.makedirs(local_dir, exist_ok=True)
    
    logging.info(f"Downloading model '{model_name}' from Hugging Face.")
    
    try:
        snapshot_download(repo_id=model_name, local_dir=local_dir, local_dir_use_symlinks=False, resume_download=True)
        logging.info(f"Model downloaded to {local_dir}")
    except Exception as e:
        logging.error(f"Failed to download model: {e}")
        exit(1)

    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    
    model_folder_in_bucket = model_name.split("/")[-1]
    logging.info(f"Uploading model to gs://{bucket_name}/{model_folder_in_bucket}/")

    for root, _, files in os.walk(local_dir):
        for filename in files:
            local_path = os.path.join(root, filename)
            gcs_path = os.path.join(model_folder_in_bucket, os.path.relpath(local_path, local_dir))
            blob = bucket.blob(gcs_path)
            blob.upload_from_filename(local_path)
            logging.info(f"Uploaded {local_path} to gs://{bucket_name}/{gcs_path}")
    
    logging.info("Model upload complete.")

if __name__ == "__main__":
    main()