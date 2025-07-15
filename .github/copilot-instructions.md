# AI Coding Agent Instructions

This document provides essential guidance for AI coding agents working in the LLM Security Infrastructure project. Read this carefully before making any changes to understand the project's architecture, patterns, and constraints.

## Project Overview

**Purpose**: Multi-layer security system for filtering malicious prompts and jailbreak attempts before they reach Large Language Models (LLMs).

**Architecture**: Cascading filter pipeline with three microservices:
```
User Request → BFilter (Bayesian) → SFilter (Transformer) → LLM Stub
                     ↓ (if jailbreak detected)
               Pub/Sub → GCS Storage
```

**Platform**: Google Cloud Platform using serverless Cloud Run containers with Terraform Infrastructure-as-Code.

## Critical Architecture Patterns

### 1. Service Communication Flow
- **BFilter** (port 8082): Public-facing, processes all requests
- **SFilter** (port 8083): Internal-only, handles uncertain cases from BFilter  
- **LLMStub** (port 8081): Internal-only, placeholder for actual LLM service
- **Authentication**: All internal calls use Google Cloud identity tokens
- **Error Propagation**: HTTP 401 from SFilter triggers Pub/Sub logging in BFilter

### 2. Request Processing Logic
```python
# BFilter decision flow:
if bayesian_confidence >= threshold:
    return "blocked immediately"
else:
    forward_to_sfilter()
    if sfilter_returns_401:
        publish_to_pubsub()
        return "blocked (secondary)"
    else:
        forward_to_llmstub()
```

### 3. Environment Configuration
- **BFilter**: `BFILTER_THRESHOLD` (0.9), `MAX_MESSAGE_LENGTH` (10000), `ENABLE_REQUEST_LOGGING`
- **SFilter**: `SFILTER_CONFIDENCE_THRESHOLD` (0.5), `SECONDARY_MODEL` (HuggingFace model path)
- **URLs**: `SFILTER_URL`, `LLMSTUB_URL`, `PROJECT_ID` for Pub/Sub

## Code Quality Standards

### 1. Type Safety (CRITICAL)
- **Always** add type annotations to function signatures
- Import from `typing` module: `Optional`, `Dict`, `List`, `Tuple`, etc.
- Example: `def process_message(text: str, threshold: float) -> Optional[Dict[str, Any]]:`

### 2. Structured Logging Pattern
```python
# Use StructuredLogger class (already implemented in bfilter)
structured_logger.info("Operation completed", 
    message_length=len(text),
    processing_time=elapsed,
    cache_hit=True
)

# Log entry format:
{
    "timestamp": "2025-01-15T10:30:00Z",
    "level": "INFO", 
    "service": "bfilter",
    "message": "Operation completed",
    "message_length": 150,
    "processing_time": 0.045,
    "cache_hit": true
}
```

### 3. Error Handling Patterns
```python
# Use @handle_errors decorator for endpoints
@app.route("/endpoint", methods=["POST"])
@handle_errors
def endpoint_handler():
    # Implementation
    pass

# Circuit breaker for external calls
@retry_with_backoff(max_retries=3)
def make_service_call():
    # Implementation with exponential backoff
    pass
```

### 4. Health Check Standards
All services must implement:
- `/health` - Basic service health (model loaded, quick validation)
- `/ready` - Dependency checks (external services, environment vars)
- `/metrics` - Prometheus-compatible metrics

## Infrastructure Patterns

### 1. Terraform Module Structure
- **Reusable modules**: `modules/cloud-run-service/` for common Cloud Run patterns
- **Main configuration**: Root `main.tf` instantiates modules with region parameter
- **Variables**: Use `variables.tf` with validation rules and descriptions

### 2. Docker Security Standards
```dockerfile
# Always use non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser
USER appuser

# Include health checks
HEALTHCHECK --interval=30s --timeout=3s \
    CMD curl -f http://localhost:8082/health || exit 1
```

### 3. Dependency Management
- Pin exact versions in `requirements.txt`
- Separate `requirements.txt` files per service
- Use multi-stage Docker builds for smaller images

## Performance Considerations

### 1. Caching Strategy
- **BFilter**: MD5-based message caching with `prediction_cache` dict
- **SFilter**: Model pre-loading and mounting from GCS (not download on startup)
- **Cache limits**: Monitor cache size in readiness checks

### 2. Resource Optimization
- **Cold start mitigation**: Minimum instance counts for critical services
- **Memory allocation**: Configured per service based on model requirements
- **Token limits**: Reduced to 512 for faster transformer processing

### 3. Latency Targets
- **Total pipeline**: < 100ms overhead
- **BFilter**: < 10ms typical
- **SFilter**: 50-100ms transformer processing

## Security Requirements

### 1. Network Isolation
- Only BFilter has public access
- SFilter and LLMStub are VPC-internal only
- Service-to-service authentication via Google Cloud identity tokens

### 2. Data Handling
- **No persistent storage** of user messages in services
- **Detected jailbreaks only** are logged via Pub/Sub → GCS
- **Request caching** uses hashed keys, not raw content

### 3. Input Validation
```python
# Standard validation pattern
if not userMessage:
    return {"error": "Message cannot be empty"}, 400
if len(userMessage) > MAX_MESSAGE_LENGTH:
    return {"error": f"Message too long (max {MAX_MESSAGE_LENGTH})"}, 413
userMessage = userMessage.strip()
```

## Development Workflows

### 1. Model Updates
```bash
# Update model reference in variables.tf
# Run model downloader job
gcloud run jobs execute model-downloader-job --region=us-central1
# Restart SFilter to pick up new model
terraform apply -target=module.sfilter
```

### 2. Threshold Tuning
```bash
# Enable detailed logging
export TF_VAR_enable_request_logging=true
terraform apply
# Analyze logs and adjust thresholds
# Update terraform.tfvars and redeploy
```

### 3. Testing Commands
```bash
# Check deployment status
./setup.sh check

# Performance testing
python3 test_performance.py --url https://bfilter-url --concurrent 10

# Service health checks
curl -f https://service-url/health
curl -f https://service-url/ready
```

## Common Integration Points

### 1. Adding New Filter Services
1. Create new service following BFilter/SFilter patterns
2. Add to main.tf using cloud-run-service module
3. Update BFilter routing logic to include new service
4. Add environment variables for service URL

### 2. Model Integration
- Models loaded via `joblib.load()` for Bayesian (BFilter)
- HuggingFace transformers via `pipeline()` for deep learning (SFilter)
- Mount models from GCS, don't download on container startup
- Validate models in health checks with test inputs

### 3. Monitoring Integration
- All metrics exposed at `/metrics` endpoint
- Use structured logging for Cloud Monitoring integration
- Include request timing, cache statistics, and error rates

## Debugging Patterns

### 1. Service Communication Issues
```bash
# Check service connectivity
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  https://internal-service-url/health

# View service logs
gcloud logs read "resource.type=cloud_run_revision AND \
  resource.labels.service_name=service-name" --project=PROJECT_ID
```

### 2. Model Loading Problems
- Check GCS bucket permissions for model files
- Verify SECONDARY_MODEL environment variable points to correct path
- Review model-downloader job logs for download issues

### 3. Authentication Failures
- Verify service account permissions
- Check identity token generation in make_authenticated_post_request()
- Ensure VPC connector allows internal communication

## Anti-Patterns to Avoid

❌ **Never** store user messages persistently in services  
❌ **Never** download models on container startup (use GCS mounting)  
❌ **Never** make external calls without circuit breakers  
❌ **Never** skip type annotations on new functions  
❌ **Never** use print() statements (use structured logging)  
❌ **Never** hardcode URLs or credentials in code  
❌ **Never** deploy without health check validation  

## Quick Reference

### Essential Files
- `bfilter/src/server.py` - Main filtering logic with full patterns implemented
- `main.tf` - Infrastructure entry point using reusable modules  
- `modules/cloud-run-service/main.tf` - Reusable Cloud Run template
- `variables.tf` - Configuration parameters with validation
- `setup.sh` - Deployment automation script

### Key Environment Variables
```bash
BFILTER_THRESHOLD=0.9
SFILTER_CONFIDENCE_THRESHOLD=0.5
MAX_MESSAGE_LENGTH=10000
ENABLE_REQUEST_LOGGING=false
PROJECT_ID=your-project-id
SFILTER_URL=https://internal-sfilter-url
LLMSTUB_URL=https://internal-llmstub-url
SECONDARY_MODEL=gs://bucket/path/to/model
```

### Health Check URLs
- BFilter: `https://your-bfilter-url/health`
- SFilter: `https://internal-sfilter-url/health` 
- LLMStub: `https://internal-llmstub-url/health`

This project prioritizes security, performance, and maintainability. When in doubt, follow the patterns established in `bfilter/src/server.py` which implements all recommended practices.
