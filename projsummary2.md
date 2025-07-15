# CS5525 LLM Security Infrastructure Project Summary (Alternate)

## Project Overview

This project implements a multi-layer, modular security system for Large Language Models (LLMs) on Google Cloud Platform. Its primary function is to filter and block malicious prompts and jailbreak attempts—including prompt injection, adversarial inputs, and spam—before they reach the LLM. The system uses a combination of fast statistical and deep learning-based filters, and is designed for scalability, observability, and research extensibility.

## Threat Model

- **Attacks Mitigated:** Prompt injection, jailbreak attempts, adversarial prompts, spam, and other malicious LLM inputs.
- **Defense in Depth:** Multiple layers (statistical and transformer-based) reduce false negatives and provide robust protection.

## Architecture

The system uses a cascading filter approach:

```
User Request → BFilter (Bayesian) → SFilter (Transformer) → LLM Stub
                     ↓ (if jailbreak detected)
               Pub/Sub → GCS Storage (for audit/event logging)
```

- **BFilter**: Fast, statistical filter for initial screening.
- **SFilter**: Deep learning-based filter for more nuanced detection.
- **LLM Stub**: Placeholder for the actual LLM (can be replaced with a real model).
- **Pub/Sub & GCS**: Capture and store detected jailbreak attempts for auditing, research, and possible retraining.

## Component Summaries

### 1. BFilter (Primary Bayesian Filter)
- **Role**: First line of defense, using a Naive Bayes classifier for fast, statistical filtering of user messages.
- **Features**: Pre-trained model, request caching, public web interface, configurable threshold, message validation, Pub/Sub event publishing on detection.
- **Implementation**: Flask app, scikit-learn, joblib, Google Cloud authentication, runs on Cloud Run (port 8082).
- **Logic**: 
  - If the message is classified as a likely jailbreak (score ≥ threshold), it is blocked immediately.
  - If the message is uncertain (score < threshold), it is forwarded to SFilter for deeper analysis.
  - Detected jailbreaks (via SFilter) are published to Pub/Sub for logging in GCS.

### 2. SFilter (Secondary Transformer Filter)
- **Role**: Deep learning-based filter for messages that pass BFilter, using a HuggingFace transformer model (`jackhhao/jailbreak-classifier`).
- **Features**: Model loaded from GCS, CUDA support, reduced token limits for speed, confidence threshold, health checks, error handling.
- **Implementation**: Flask app, PyTorch, HuggingFace Transformers, runs on Cloud Run (port 8083), internal-only.
- **Logic**: 
  - If the message is classified as a jailbreak, returns HTTP 401 (triggers BFilter to log the event).
  - If the message is clean, returns HTTP 200 and allows the request to proceed to the LLM Stub.

### 3. LLM Stub
- **Role**: Placeholder for the actual LLM service, currently echoes input for demonstration.
- **Features**: Minimal Flask app, health/readiness endpoints, internal-only (port 8081).
- **Integration**: Receives messages from BFilter after filtering. Can be replaced with a real LLM or API endpoint.

### 4. Model Downloader
- **Role**: Downloads models from HuggingFace and uploads to GCS for use by SFilter.
- **Features**: Automated download/upload, runs as a Cloud Run job, supports large models, can be triggered for updates.
- **Implementation**: Python script using huggingface_hub and google-cloud-storage.

### 5. Infrastructure & Supporting Services
- **Cloud Run**: Serverless container hosting for all services, auto-scaling, internal/external access as needed.
- **VPC & Networking**: Custom VPC, subnets, VPC connectors, firewall rules for isolation and security.
- **Cloud Storage**: Buckets for model storage and event logging, IAM for access control.
- **Pub/Sub**: Event streaming for detected jailbreaks, storage subscription for audit logs.
- **Cloud Monitoring**: Health checks, latency alerts, email notifications, custom metrics endpoints.

## Data Flow for Detected Jailbreaks
- **Detection:** If SFilter detects a jailbreak, BFilter publishes the event to a Pub/Sub topic.
- **Logging:** Pub/Sub writes the event to a GCS bucket for audit and research.
- **Review/Research:** Logged events can be reviewed, analyzed, or used for retraining models.

## Monitoring & Alerting
- **Endpoints:** All services expose `/health`, `/ready`, and `/metrics` endpoints.
- **Metrics:** Latency, error rates, cache size, uptime, and request counts are tracked.
- **Alerting:** Cloud Monitoring triggers alerts for high latency (>100ms), service failures, or unhealthy endpoints.

## Deployment & Configuration
- **Deployment:** Automated with Terraform and `setup.sh`. Includes API enablement, network setup, and service deployment.
- **Configuration:** Thresholds, resource allocations, and model paths are set via environment variables and Terraform variables.
- **Model Updates:** New models can be downloaded and deployed with minimal downtime.

## Extensibility & Modularity
- **Modular Design:** Each component (BFilter, SFilter, LLM Stub) can be replaced or extended independently.
- **Easy Integration:** Supports swapping in new models, adding filters, or integrating with other LLMs.
- **Experimentation:** Designed for rapid prototyping and evaluation of new filtering strategies or models.

## Limitations
- **Cold Start Latency:** Cloud Run cold starts may add initial latency.
- **False Positives/Negatives:** Filtering is not perfect; thresholds may need tuning.
- **Model Update Frequency:** Regular retraining and updates are recommended for best results.

## Example Use Cases
- **Academic Research:** Experiment with filtering strategies, collect data on adversarial prompts.
- **Production LLM APIs:** Protect public LLM endpoints from prompt injection and abuse.
- **Security Benchmarking:** Evaluate the effectiveness of different filters and models.

## Security Details
- **IAM:** Least-privilege service accounts for each component.
- **VPC Isolation:** Only BFilter is public; all other services are internal.
- **Data Protection:** No persistent user message storage; only detected threats are logged (via Pub/Sub to GCS).

## Performance & Scalability
- **Latency:** <100ms total filtering overhead (BFilter <10ms, SFilter 50-100ms typical).
- **Scalability:** Cloud Run auto-scales services; minimum instance counts for critical services.
- **Availability:** Multi-level health checks, error handling, retry logic, and monitoring.

## Development & Operations
- **Local Testing:** Docker-based development, performance test scripts, model validation.
- **Deployment:** Automated with Terraform and setup scripts; includes API enablement, network setup, and service deployment.
- **Maintenance:** Model updates, threshold tuning, and scaling are supported with minimal downtime.
- **Observability:** Health endpoints, metrics, and logs are available for all services.

## Academic & Research Features
- **Experimentation:** Easy threshold/config changes, modular design, detailed logging, and benchmarking tools.
- **Data Collection:** Anonymous usage, performance, and security event metrics for research.
- **Extensibility:** Designed for rapid prototyping and evaluation of new filtering strategies or models.

## Future Enhancements
- Model ensembles, real-time retraining, advanced caching, global deployment, A/B testing, and custom model training are all possible extensions.

## Conclusion

This project demonstrates a robust, scalable, and research-friendly LLM security infrastructure, balancing performance, security, and extensibility for both academic and production use. Its modular design and comprehensive logging make it ideal for experimentation, benchmarking, and future enhancements.
