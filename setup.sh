#!/bin/bash

# LLM Infrastructure Setup Script
# This script helps deploy and test the LLM security infrastructure

set -e

PROJECT_ID="${PROJECT_ID:-thomasjones-llm-project-2025}"
REGION="${REGION:-us-central1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if gcloud is installed
    if ! command -v gcloud &> /dev/null; then
        log_error "gcloud CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check if terraform is installed
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform is not installed. Please install it first."
        exit 1
    fi
    
    # Check if authenticated with gcloud
    if ! gcloud auth list --format="value(account)" | grep -q "@"; then
        log_error "Not authenticated with gcloud. Please run 'gcloud auth login'"
        exit 1
    fi
    
    # Check if project exists
    if ! gcloud projects describe "$PROJECT_ID" &> /dev/null; then
        log_error "Project $PROJECT_ID does not exist or you don't have access."
        exit 1
    fi
    
    log_info "Prerequisites check passed!"
}

setup_terraform() {
    log_info "Setting up Terraform..."
    
    # Initialize Terraform
    terraform init
    
    # Create terraform.tfvars if it doesn't exist
    if [ ! -f terraform.tfvars ]; then
        cat > terraform.tfvars << EOF
project = "$PROJECT_ID"
region  = "$REGION"

# Performance tuning
bfilter_threshold = 0.9
sfilter_confidence_threshold = 0.5
enable_request_logging = false
max_message_length = 10000

# Optional: uncomment and modify these if needed
# secondary_model_name = "jackhhao/jailbreak-classifier"
# llm_stub_port = 8081
# sfilter_port = 8083
# bfilter_port = 8082
EOF
        log_info "Created terraform.tfvars with default values"
    fi
    
    # Plan the deployment
    log_info "Creating Terraform plan..."
    terraform plan -out=tfplan
}

deploy_infrastructure() {
    log_info "Deploying infrastructure..."
    terraform apply tfplan
    
    log_info "Infrastructure deployed successfully!"
}

wait_for_services() {
    log_info "Waiting for services to be ready..."
    
    # Get service URLs
    BFILTER_URL=$(terraform output -raw bfilter_url 2>/dev/null || echo "")
    
    if [ -z "$BFILTER_URL" ]; then
        log_warn "Could not get BFilter URL from terraform output"
        return 1
    fi
    
    # Wait for BFilter to be ready
    log_info "Waiting for BFilter service to be ready..."
    for i in {1..30}; do
        if curl -sf "$BFILTER_URL/health" > /dev/null 2>&1; then
            log_info "BFilter service is ready!"
            break
        fi
        
        if [ $i -eq 30 ]; then
            log_error "BFilter service failed to become ready within 5 minutes"
            return 1
        fi
        
        log_info "Attempt $i/30: BFilter not ready yet, waiting 10s..."
        sleep 10
    done
}

run_basic_tests() {
    log_info "Running basic functionality tests..."
    
    BFILTER_URL=$(terraform output -raw bfilter_url 2>/dev/null || echo "")
    
    if [ -z "$BFILTER_URL" ]; then
        log_error "Could not get BFilter URL for testing"
        return 1
    fi
    
    # Test 1: Health check
    log_info "Testing health check..."
    if curl -sf "$BFILTER_URL/health" | grep -q "healthy"; then
        log_info "✓ Health check passed"
    else
        log_error "✗ Health check failed"
        return 1
    fi
    
    # Test 2: Normal message
    log_info "Testing normal message..."
    RESPONSE=$(curl -sf -X POST "$BFILTER_URL/handle" -d "message=Hello, how are you?" || echo "ERROR")
    if [ "$RESPONSE" != "ERROR" ]; then
        log_info "✓ Normal message test passed: $RESPONSE"
    else
        log_error "✗ Normal message test failed"
        return 1
    fi
    
    # Test 3: Web interface
    log_info "Testing web interface..."
    if curl -sf "$BFILTER_URL/" | grep -q "Enter a message to classify"; then
        log_info "✓ Web interface test passed"
    else
        log_error "✗ Web interface test failed"
        return 1
    fi
    
    log_info "All basic tests passed!"
    echo
    log_info "You can access the web interface at: $BFILTER_URL"
}

run_performance_tests() {
    log_info "Running performance tests..."
    
    BFILTER_URL=$(terraform output -raw bfilter_url 2>/dev/null || echo "")
    
    if [ -z "$BFILTER_URL" ]; then
        log_error "Could not get BFilter URL for performance testing"
        return 1
    fi
    
    # Check if Python and required packages are available
    if command -v python3 &> /dev/null; then
        log_info "Running Python performance tests..."
        if python3 test_performance.py --url "$BFILTER_URL" --concurrent 5 --rounds 2; then
            log_info "✓ Performance tests completed"
        else
            log_warn "Performance tests failed (this might be due to missing dependencies like aiohttp)"
        fi
    else
        log_warn "Python3 not available, skipping performance tests"
    fi
}

show_outputs() {
    log_info "Deployment Summary:"
    echo "==================="
    
    if command -v terraform &> /dev/null; then
        echo "Project ID: $(terraform output -raw project_id 2>/dev/null || echo $PROJECT_ID)"
        echo "Region: $(terraform output -raw region 2>/dev/null || echo $REGION)"
        echo
        echo "Service URLs:"
        echo "  BFilter (Web Interface): $(terraform output -raw bfilter_url 2>/dev/null || echo 'Not available')"
        echo
        echo "Configuration:"
        echo "  BFilter Threshold: $(terraform output -raw bfilter_threshold 2>/dev/null || echo '0.9')"
        echo "  Max Message Length: $(terraform output -raw max_message_length 2>/dev/null || echo '10000')"
    fi
    
    echo
    log_info "Next steps:"
    echo "1. Access the web interface using the BFilter URL above"
    echo "2. Test with various messages to see the filtering in action"
    echo "3. Monitor the services using Google Cloud Console"
    echo "4. Check logs: gcloud logs read --project=$PROJECT_ID"
}

cleanup() {
    log_warn "Cleaning up infrastructure..."
    terraform destroy -auto-approve
    log_info "Infrastructure destroyed"
}

# Main execution
case "${1:-deploy}" in
    "check")
        check_prerequisites
        ;;
    "plan")
        check_prerequisites
        setup_terraform
        ;;
    "deploy")
        check_prerequisites
        setup_terraform
        deploy_infrastructure
        wait_for_services
        run_basic_tests
        show_outputs
        ;;
    "test")
        run_basic_tests
        run_performance_tests
        ;;
    "destroy")
        cleanup
        ;;
    "outputs")
        show_outputs
        ;;
    *)
        echo "Usage: $0 {check|plan|deploy|test|destroy|outputs}"
        echo
        echo "  check   - Check prerequisites"
        echo "  plan    - Setup Terraform and create plan"
        echo "  deploy  - Full deployment with testing"
        echo "  test    - Run tests on existing deployment"
        echo "  destroy - Destroy all infrastructure"
        echo "  outputs - Show deployment information"
        exit 1
        ;;
esac
