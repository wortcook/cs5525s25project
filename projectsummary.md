# CS5525 LLM Security Infrastructure Project Summary

## Project Overview

This project implements a **multi-layer security system for Large Language Models (LLMs)** designed to filter malicious prompts and jailbreak attempts before they reach the actual LLM service. The system is built on Google Cloud Platform using serverless architecture for horizontal scalability and cost optimization.

## Architecture

The system follows a **cascading filter architecture** with three main processing stages:

```
User Request → BFilter (Bayesian) → SFilter (Transformer) → LLM Stub
                     ↓ (if jailbreak detected)
               Pub/Sub → GCS Storage
```

### Key Design Principles

1. **Performance First**: Fast initial filtering (< 10ms) using Bayesian classification
2. **Defense in Depth**: Multiple layers of detection with increasing sophistication
3. **Scalable**: Cloud-native serverless architecture with automatic scaling
4. **Observable**: Comprehensive monitoring, logging, and alerting
5. **Cost Effective**: Pay-per-request model with efficient resource utilization

## Component Analysis

### 1. BFilter (Primary Bayesian Filter)

**Purpose**: Fast statistical analysis using Naive Bayes classification for initial threat detection.

**Key Features**:
- **Pre-trained Model**: Uses scikit-learn Naive Bayes classifier with CountVectorizer
- **Performance**: Sub-10ms response times for most requests
- **Caching**: MD5-based request caching to avoid reprocessing identical messages
- **Web Interface**: Public-facing HTML form for testing and demonstration
- **Request Validation**: Message length limits and input sanitization
- **Threshold-based Routing**: Configurable confidence threshold (default: 0.9)

**Technical Implementation**:
- Flask web server with gunicorn WSGI
- Model artifacts (model.pkl, cv.pkl) built during container creation
- Training data preprocessing with `dataprep.py`
- Google Cloud authentication for internal service calls
- Pub/Sub integration for event logging

**Decision Logic**:
- If confidence score ≥ threshold: Block immediately
- If confidence score < threshold: Forward to SFilter for secondary analysis

### 2. SFilter (Secondary Transformer Filter)

**Purpose**: Sophisticated transformer-based classification for messages that pass the initial filter.

**Key Features**:
- **HuggingFace Integration**: Uses `jackhhao/jailbreak-classifier` transformer model
- **Model Optimization**: CUDA acceleration when available, optimized pipeline settings
- **GCS Mount**: Model loaded from Google Cloud Storage for faster cold starts
- **Performance Tuning**: Reduced token limits (512 vs 8192) for faster processing
- **Resource Scaling**: Configurable memory allocation (default: 4Gi)

**Technical Implementation**:
- PyTorch-based transformer pipeline
- Model pre-loading during container startup
- Health checks with model validation
- Error handling and fallback responses
- Confidence-based classification with configurable thresholds

### Port Configuration:
- **BFilter**: Port 8082 (public access)
- **SFilter**: Port 8083 (internal only) 
- **LLM Stub**: Port 8081 (internal only)

**Processing Flow**:
- Receives messages from BFilter
- Returns HTTP 401 for detected jailbreaks
- Returns HTTP 200 for clean messages

### 3. LLM Stub

**Purpose**: Placeholder for actual LLM integration, currently echoes input for demonstration.

**Key Features**:
- **Simple Implementation**: Minimal Flask server for testing pipeline
- **Extensible Design**: Easy replacement with actual LLM services
- **Health Monitoring**: Standard health/readiness endpoints
- **Internal Access**: Only accessible from within the VPC

**Integration Points**:
- Receives filtered messages from BFilter
- Can be replaced with services like Vertex AI, OpenAI API, or custom models

### 4. Model Downloader

**Purpose**: Utility service for downloading and managing ML models from HuggingFace Hub.

**Key Features**:
- **HuggingFace Integration**: Automated model downloading using `huggingface_hub`
- **GCS Upload**: Transfers models to Google Cloud Storage for service access
- **Job-based Execution**: Runs as Cloud Run Job with retry capabilities
- **Resource Management**: Configurable CPU/memory for large model downloads

**Operational Use**:
- Executed during initial deployment
- Can be triggered manually for model updates
- Supports resume downloads for interrupted transfers

### 5. Infrastructure Components

#### Google Cloud Services Used:

**Cloud Run**: 
- Serverless container platform for all services
- Automatic scaling based on demand
- Internal-only networking for security
- Health check integration

**VPC and Networking**:
- Custom VPC (`llm-vpc`) for service isolation
- Separate subnets for different service tiers
- VPC Access Connectors for Cloud Run integration
- Firewall rules for controlled access

**Cloud Storage**:
- `model-store`: Stores ML models and artifacts
- `secondary-spam`: Logs detected jailbreak attempts
- Bucket-level IAM for service access control

**Pub/Sub**:
- `secondary-filter` topic for event streaming
- Automatic subscription to storage for audit logs
- Decoupled event processing architecture

**Cloud Monitoring**:
- Health check uptime monitoring
- Latency alerting (threshold: 100ms)
- Email notification channels
- Custom metrics endpoints

#### Security Architecture:

**Network Security**:
- Only BFilter has public internet access
- Internal services use VPC-only communication
- IAM service accounts with minimal permissions
- Google Cloud authentication for service-to-service calls

**Data Protection**:
- No persistent storage of user messages
- Audit logging of detected threats only
- Hash-based caching for privacy
- Separate storage for sensitive events

## Configuration Management

### Environment Variables:

**BFilter Configuration**:
- `BFILTER_THRESHOLD`: Confidence threshold (0.0-1.0)
- `MAX_MESSAGE_LENGTH`: Message size limits
- `ENABLE_REQUEST_LOGGING`: Debug logging control

**SFilter Configuration**:
- `SFILTER_CONFIDENCE_THRESHOLD`: Detection sensitivity
- `SECONDARY_MODEL`: Model path in GCS mount

**System Configuration**:
- `PROJECT_ID`: Google Cloud project identifier
- Service URLs for internal communication

### Terraform Variables:

The system uses infrastructure-as-code with configurable parameters:
- Regional deployment settings
- Service resource allocations
- Model configurations
- Performance tuning parameters

## Performance Characteristics

### Latency Requirements:
- **Target**: < 100ms total filtering overhead
- **BFilter**: < 10ms typical response time
- **SFilter**: 50-100ms for transformer processing
- **Overall Pipeline**: Monitored with alerting

### Scalability Features:
- **Automatic Scaling**: Cloud Run scales 0-10 instances per service
- **Cold Start Mitigation**: Minimum instance counts for critical services
- **Resource Optimization**: CPU allocation tuning and startup boosts
- **Caching Strategy**: Request-level caching in BFilter

### Availability Design:
- **Health Monitoring**: Multi-level health checks (/health, /ready, /metrics)
- **Error Handling**: Graceful degradation and error responses
- **Retry Logic**: Automatic retries for transient failures
- **Monitoring Integration**: Cloud Monitoring with alerting

## Deployment Process

### Infrastructure Provisioning:
1. **Prerequisites**: gcloud CLI, Terraform, project setup
2. **API Enablement**: Automatic enabling of required Google Cloud APIs
3. **Network Setup**: VPC, subnets, and firewall rule creation
4. **Service Accounts**: IAM configuration with minimal permissions
5. **Storage Setup**: Bucket creation with appropriate access controls

### Application Deployment:
1. **Container Building**: Docker image creation with embedded models
2. **Artifact Registry**: Image storage and versioning
3. **Model Download**: Automated model retrieval and GCS upload
4. **Service Deployment**: Cloud Run service creation with configuration
5. **Networking**: VPC connector and internal routing setup

### Verification Process:
1. **Health Checks**: Automated service health validation
2. **Performance Testing**: Latency and throughput validation
3. **Integration Testing**: End-to-end pipeline verification
4. **Monitoring Setup**: Alert configuration and dashboard creation

## Development and Testing

### Local Development:
- **Container Testing**: Docker-based local development
- **Performance Benchmarking**: Included test scripts with aiohttp
- **Configuration Testing**: Environment variable validation
- **Model Validation**: Local model testing capabilities

### Production Monitoring:
- **Real-time Metrics**: Request latency, error rates, throughput
- **Health Dashboards**: Service status and dependency monitoring
- **Log Aggregation**: Centralized logging with Cloud Logging
- **Alert Management**: Automated incident response

### Maintenance Operations:
- **Model Updates**: Streamlined model replacement process
- **Threshold Tuning**: Data-driven parameter optimization
- **Scale Adjustment**: Resource allocation modification
- **Security Updates**: Container base image updates

## Academic Research Features

### Experimental Capabilities:
- **Configurable Thresholds**: Easy parameter adjustment for research
- **Comprehensive Logging**: Detailed request and performance data
- **Modular Design**: Component replacement for algorithm comparison
- **Performance Instrumentation**: Built-in benchmarking tools

### Data Collection:
- **Request Patterns**: Anonymous usage analytics
- **Model Performance**: Classification accuracy tracking
- **System Performance**: Latency and resource utilization metrics
- **Security Events**: Threat detection and response logging

## Cost Optimization

### Serverless Benefits:
- **Pay-per-Request**: No charges during idle periods
- **Automatic Scaling**: Scale to zero when not in use
- **Resource Efficiency**: Right-sized container allocations
- **Regional Deployment**: Single-region cost optimization

### Resource Management:
- **Container Optimization**: Minimal base images and efficient layering
- **Storage Lifecycle**: Automated cleanup of temporary data
- **Compute Allocation**: Appropriate CPU/memory sizing
- **Network Optimization**: Internal-only communication where possible

## Future Enhancement Opportunities

### Technical Improvements:
1. **Model Ensemble**: Combine multiple detection algorithms
2. **Real-time Training**: Continuous model improvement
3. **Advanced Caching**: Redis/Memcached integration
4. **Global Deployment**: Multi-region load balancing

### Operational Enhancements:
1. **A/B Testing**: Model version comparison framework
2. **Custom Training**: Domain-specific model fine-tuning
3. **Advanced Analytics**: Machine learning for system optimization
4. **Integration APIs**: Webhook and event-driven architectures

## Conclusion

This project demonstrates a production-ready, scalable security infrastructure for LLM services that balances performance, security, and cost-effectiveness. The multi-layer approach provides robust protection while maintaining sub-100ms latency requirements, making it suitable for both academic research and production deployment scenarios.

The cloud-native architecture ensures the system can handle varying loads automatically while providing comprehensive observability and maintenance capabilities. The modular design allows for easy experimentation and enhancement, making it an excellent foundation for ongoing research in LLM security and performance optimization.
