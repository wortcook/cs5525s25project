
import os
import logging
import subprocess
from google.cloud import storage

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def main():
    """
    Clones a model repo from GitHub and uploads it to a GCS bucket.
    """
    repo_url = os.environ.get("MODEL_GIT_URL")
    bucket_name = os.environ.get("GCS_BUCKET_NAME")

    if not repo_url:
        logging.error("MODEL_GIT_URL environment variable not set.")
        exit(1)
    if not bucket_name:
        logging.error("GCS_BUCKET_NAME environment variable not set.")
        exit(1)

    local_dir = "/app/model"
    os.makedirs(local_dir, exist_ok=True)

    logging.info(f"Cloning model repo from '{repo_url}'...")
    try:
        subprocess.run(["git", "clone", "--depth=1", repo_url, local_dir], check=True)
        subprocess.run(["git", "lfs", "pull"], cwd=local_dir, check=True)
        logging.info(f"Model repo cloned to {local_dir}")
    except Exception as e:
        logging.error(f"Failed to clone model repo: {e}")
        exit(1)

    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)

    model_folder_in_bucket = os.path.splitext(os.path.basename(repo_url))[0]
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