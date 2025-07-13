# LLM Security Infrastructure

A horizontally scalable multi-layer security system for Large Language Models (LLMs) designed to filter malicious prompts and jailbreak attempts before they reach the LLM service.

## Architecture Overview

```
User Request → BFilter (Bayesian) → SFilter (Transformer) → LLM Stub
                     ↓ (if jailbreak detected)
               Pub/Sub → GCS Storage
```

### Components

1. **BFilter** - Primary Bayesian filter using Naive Bayes classification
   - Fast statistical analysis (< 10ms typical)
   - Configurable confidence threshold (default: 0.9)
   - Request caching for improved performance
   - Public web interface for testing

2. **SFilter** - Secondary transformer-based filter
   - Uses HuggingFace transformer model (`jackhhao/jailbreak-classifier`)
   - More sophisticated but slower analysis (50-100ms typical)
   - Only processes messages that pass BFilter threshold
   - Model mounted from GCS for faster cold starts

3. **LLMStub** - Placeholder for actual LLM service
   - Currently echoes input for demonstration
   - Replace with actual LLM integration

4. **Model Downloader** - Utility for model management
   - Downloads models from HuggingFace to GCS
   - Runs as Cloud Run job

### Infrastructure

- **Google Cloud Run** - Serverless container platform for horizontal scaling
- **VPC** - Isolated network for internal service communication
- **Cloud Storage** - Model storage and event logging
- **Pub/Sub** - Event streaming for detected jailbreaks
- **Cloud Monitoring** - Health checks and alerting

## Performance Targets

- **Latency**: < 100ms total filtering overhead
- **Availability**: 99.9% uptime with health monitoring
- **Scalability**: Automatic horizontal scaling based on demand
- **Throughput**: Supports concurrent requests with rate limiting

## Quick Start

### Prerequisites

- Google Cloud Platform account with billing enabled
- `gcloud` CLI installed and authenticated
- `terraform` >= 1.0 installed
- Project with necessary APIs enabled

### Deploy

```bash
# Set your project ID
export PROJECT_ID="your-project-id"

# Quick deployment
./setup.sh deploy
```

### Test

```bash
# Run basic functionality tests
./setup.sh test

# Access web interface (URL provided after deployment)
# Or test via curl:
curl -X POST "https://your-bfilter-url/handle" -d "message=Hello world"
```

## Configuration

### Environment Variables

#### BFilter Configuration
- `BFILTER_THRESHOLD` - Confidence threshold (0.0-1.0, default: 0.9)
- `MAX_MESSAGE_LENGTH` - Maximum message length (default: 10000)
- `ENABLE_REQUEST_LOGGING` - Enable detailed logging (default: false)

#### SFilter Configuration
- `SFILTER_CONFIDENCE_THRESHOLD` - Detection threshold (default: 0.5)
- `SECONDARY_MODEL` - Path to transformer model

### Terraform Variables

```hcl
# terraform.tfvars
project = "your-project-id"
region  = "us-central1"

# Performance tuning
bfilter_threshold = 0.9
sfilter_confidence_threshold = 0.5
enable_request_logging = false
max_message_length = 10000
```

## Monitoring and Alerting

### Health Checks

All services expose health check endpoints:
- `/health` - Service health status
- `/ready` - Readiness check for dependencies
- `/metrics` - Basic performance metrics

### Cloud Monitoring

- **Uptime Checks** - Monitor service availability
- **Latency Alerts** - Alert when average latency > 100ms
- **Error Rate Monitoring** - Track failed requests

### Logs

```bash
# View logs for all services
gcloud logs read --project=your-project-id

# View specific service logs
gcloud logs read "resource.type=cloud_run_revision AND resource.labels.service_name=bfilter-service" --project=your-project-id
```

## Security Considerations

### Network Security
- Only BFilter is publicly accessible
- SFilter and LLMStub are internal-only
- VPC isolation for service communication
- IAM service accounts with minimal permissions

### Data Protection
- No persistent storage of user messages
- Detected jailbreaks logged to separate bucket
- Request caching uses hash-based keys
- Health checks don't expose sensitive data

## Performance Optimization

### Cold Start Mitigation
- Minimum instance counts for critical services
- CPU allocated when idle
- Startup CPU boost enabled
- Model pre-loading and caching

### Request Optimization
- Message-level caching in BFilter
- Configurable thresholds to reduce SFilter load
- Connection pooling and keep-alive
- Request size validation

### Model Optimization
- Model mounted from GCS (not downloaded on startup)
- Reduced token limits (512 vs 8192)
- CUDA acceleration when available
- Pipeline optimization with batch_size=1

## Development

### Local Testing

```bash
# Check prerequisites
./setup.sh check

# Plan deployment
./setup.sh plan

# Performance testing (requires aiohttp)
pip install aiohttp
python3 test_performance.py --url https://your-bfilter-url --concurrent 10
```

### Model Updates

1. Update `secondary_model_name` in variables.tf
2. Run model downloader job:
   ```bash
   gcloud run jobs execute model-downloader-job --region=us-central1
   ```
3. Restart SFilter service to pick up new model

### Threshold Tuning

1. Enable request logging: `enable_request_logging = true`
2. Deploy changes: `terraform apply`
3. Analyze logs to optimize thresholds
4. Update thresholds and redeploy

## Troubleshooting

### Common Issues

1. **Service not ready**
   - Check health endpoints: `curl https://service-url/health`
   - View logs: `gcloud logs read`
   - Verify dependencies are healthy

2. **High latency**
   - Check minimum instance settings
   - Monitor CPU/memory usage
   - Consider reducing token limits
   - Verify model mounting is working

3. **Model loading failures**
   - Ensure model downloader job completed successfully
   - Check GCS bucket permissions
   - Verify model path configuration

### Useful Commands

```bash
# Service status
gcloud run services list --region=us-central1

# Force new deployment
gcloud run services replace-traffic SERVICE_NAME --to-latest --region=us-central1

# Manual job execution
gcloud run jobs execute model-downloader-job --region=us-central1

# View monitoring
gcloud monitoring uptime-checks list
```

## Cost Optimization

- **Request-based pricing** - Only pay for actual requests
- **Automatic scaling** - Scale to zero when not in use
- **Spot instances** - Consider for batch jobs
- **Storage lifecycle** - Auto-delete old logs and models
- **Regional deployment** - Single region reduces costs

## Academic Use

This implementation is designed for academic research and demonstration purposes:

- **Configurable thresholds** for experimentation
- **Comprehensive logging** for analysis
- **Performance testing tools** for evaluation
- **Modular design** for component replacement
- **Open architecture** for extension and modification

## Future Enhancements

1. **Model ensemble** - Combine multiple detection models
2. **Real-time retraining** - Update models based on new data
3. **A/B testing framework** - Compare model versions
4. **Advanced caching** - Redis/Memcached integration
5. **Multi-region deployment** - Global load balancing
6. **Custom model training** - Fine-tune on specific datasets

## License

This project is intended for academic research and educational purposes.
