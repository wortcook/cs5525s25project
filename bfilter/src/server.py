# --- Error Handling Decorator ---
def handle_errors(func):
    @wraps(func)
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except requests.exceptions.Timeout:
            structured_logger.error("Request timeout", endpoint=func.__name__)
            return {"error": "Service temporarily unavailable"}, 503
        except requests.exceptions.ConnectionError:
            structured_logger.error("Connection error", endpoint=func.__name__)
            return {"error": "Service temporarily unavailable"}, 503
        except ValueError as e:
            structured_logger.error("Validation error", endpoint=func.__name__, error=str(e))
            return {"error": "Invalid request"}, 400
        except Exception as e:
            structured_logger.error("Unexpected error", endpoint=func.__name__, error=str(e))
            return {"error": "Internal server error"}, 500
    return wrapper
import random
from functools import wraps
# --- Retry Logic with Exponential Backoff ---
def retry_with_backoff(max_retries: int = 3, base_delay: float = 1.0, max_delay: float = 60.0):
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            for attempt in range(max_retries + 1):
                try:
                    return func(*args, **kwargs)
                except requests.exceptions.RequestException as e:
                    if attempt == max_retries:
                        structured_logger.error(
                            "Max retry attempts reached",
                            function=func.__name__,
                            attempts=attempt + 1,
                            error=str(e)
                        )
                        raise e
                    delay = min(base_delay * (2 ** attempt) + random.uniform(0, 1), max_delay)
                    structured_logger.warning(
                        "Request failed, retrying",
                        function=func.__name__,
                        attempt=attempt + 1,
                        delay=delay,
                        error=str(e)
                    )
                    time.sleep(delay)
            return None
        return wrapper
    return decorator


import json
import joblib
from flask import Flask, request, render_template_string, Response
import os
import requests
from google.auth.transport import requests as auth_requests
from google.oauth2 import id_token as google_id_token
from google.cloud import pubsub_v1
import hashlib
import time
import logging
import sys
import gc
from datetime import datetime
from collections import defaultdict
from enum import Enum
from typing import Optional, Dict, Any, Callable, Tuple

LLMSTUB_URL = os.getenv("LLMSTUB_URL")
SFILTER_URL = os.getenv("SFILTER_URL")

# Configurable parameters
BFILTER_THRESHOLD = float(os.getenv("BFILTER_THRESHOLD", "0.9"))
ENABLE_REQUEST_LOGGING = os.getenv("ENABLE_REQUEST_LOGGING", "false").lower() == "true"
MAX_MESSAGE_LENGTH = int(os.getenv("MAX_MESSAGE_LENGTH", "10000"))

# Global model variables - loaded lazily
clf = None
cv = None

def load_models():
    """Load models lazily to reduce memory footprint during startup"""
    global clf, cv
    if clf is None or cv is None:
        try:
            structured_logger.info("Starting lazy model loading", stage="model_init")
            
            # Force garbage collection before loading
            gc.collect()
            
            structured_logger.info("Loading Bayesian models")
            clf = joblib.load("model.pkl")
            cv = joblib.load("cv.pkl")
            
            # Force garbage collection after loading
            gc.collect()
            
            structured_logger.info("Models loaded successfully", 
                                 clf_type=type(clf).__name__,
                                 cv_type=type(cv).__name__)
        except Exception as e:
            structured_logger.error("Failed to load models", error=str(e))
            raise e


# Configure structured logging
logging.basicConfig(
    level=logging.INFO,
    format='%(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)

class StructuredLogger:
    def __init__(self, name: str):
        self.logger = logging.getLogger(name)
        self.service_name = name
    def _log(self, level: str, message: str, **kwargs) -> None:
        log_entry = {
            "timestamp": datetime.utcnow().isoformat(),
            "level": level,
            "service": self.service_name,
            "message": message,
            **kwargs
        }
        self.logger.info(json.dumps(log_entry))
    def info(self, message: str, **kwargs) -> None:
        self._log("INFO", message, **kwargs)
    def error(self, message: str, **kwargs) -> None:
        self._log("ERROR", message, **kwargs)
    def warning(self, message: str, **kwargs) -> None:
        self._log("WARNING", message, **kwargs)

structured_logger = StructuredLogger("bfilter")

app = Flask(__name__)

# Cache for processed messages to avoid reprocessing
prediction_cache = {}


def get_cached_prediction(message_hash: str) -> Optional[float]:
    """Get cached prediction for a message hash"""
    return prediction_cache.get(message_hash)


def cache_prediction(message_hash: str, score: float) -> None:
    """Cache a prediction result with aggressive memory management"""
    # More aggressive cache cleanup to prevent memory issues
    if len(prediction_cache) > 500:  # Reduced from 1000
        keys = list(prediction_cache.keys())
        # Remove 60% of cache when limit reached
        for key in keys[:300]:  # Increased from 100
            del prediction_cache[key]
        structured_logger.info("Cache cleanup performed", 
                             remaining_size=len(prediction_cache),
                             removed_count=300)
    prediction_cache[message_hash] = score

# Performance tracking
request_start_times = {}


@app.before_request
def before_request() -> None:
    request_start_times[request] = time.time()
    app.request_count = getattr(app, 'request_count', 0) + 1

@app.after_request
def after_request(response: Response) -> Response:
    if request in request_start_times:
        duration: float = time.time() - request_start_times[request]
        structured_logger.info("Request duration", duration=duration)
        del request_start_times[request]
    return response

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>Message Filter</title>
    <style>
        body { font-family: sans-serif; margin: 2em; background-color: #f4f4f9; color: #333; }
        h1, h2 { color: #444; }
        form { background: white; padding: 2em; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        textarea { width: 100%; min-height: 100px; margin-bottom: 1em; border: 1px solid #ccc; border-radius: 4px; padding: 0.5em; box-sizing: border-box; }
        input[type="submit"] { background-color: #007bff; color: white; padding: 10px 15px; border: none; border-radius: 4px; cursor: pointer; font-size: 1em; }
        input[type="submit"]:hover { background-color: #0056b3; }
        #response { background-color: #e9ecef; }
    </style>
</head>
<body>
    <h1>Enter a message to classify</h1>
    <form id="messageForm">
        <label for="message">Message:</label><br>
        <textarea id="message" name="message" rows="5" cols="50" required></textarea><br>
        <input type="submit" value="Submit">
    </form>

    <h2>Response:</h2>
    <textarea id="response" name="response" rows="5" cols="50" readonly></textarea>

    <script>
        document.getElementById('messageForm').addEventListener('submit', function(event) {
            event.preventDefault(); // Prevent the default form submission

            const message = document.getElementById('message').value;
            const responseArea = document.getElementById('response');

            responseArea.value = 'Processing...'; // Show a processing message

            fetch('/handle', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: 'message=' + encodeURIComponent(message)
            })
            .then(response => response.text())
            .then(data => {
                responseArea.value = data;
            })
            .catch(error => {
                console.error('Error:', error);
                responseArea.value = 'Error processing your request.';
            });
        });
    </script>
</body>
</html>
"""

def process_text(text: str) -> str:
    """
    Creates a new version of text processing, per the request.
    This version filters out short words and corrects the iteration bug
    from the original script. It does not include the text reversal logic.
    """
    words = text.split(" ")
    processed_words = [word for word in words if len(word) > 1]
    return " ".join(processed_words)


# --- Circuit Breaker Implementation ---
class CircuitState(Enum):
    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"

class CircuitBreaker:
    def __init__(self, failure_threshold: int = 5, timeout: int = 60):
        self.failure_threshold = failure_threshold
        self.timeout = timeout
        self.failure_count = 0
        self.last_failure_time = None
        self.state = CircuitState.CLOSED
    def call(self, func: Callable, *args, **kwargs) -> Any:
        if self.state == CircuitState.OPEN:
            if time.time() - self.last_failure_time > self.timeout:
                self.state = CircuitState.HALF_OPEN
            else:
                raise Exception("Circuit breaker is OPEN")
        try:
            result = func(*args, **kwargs)
            if self.state == CircuitState.HALF_OPEN:
                self.state = CircuitState.CLOSED
                self.failure_count = 0
            return result
        except Exception as e:
            self.failure_count += 1
            self.last_failure_time = time.time()
            if self.failure_count >= self.failure_threshold:
                self.state = CircuitState.OPEN
            raise e

sfilter_breaker = CircuitBreaker(failure_threshold=3, timeout=30)
llmstub_breaker = CircuitBreaker(failure_threshold=3, timeout=30)

@retry_with_backoff(max_retries=3, base_delay=1.0)
def make_authenticated_post_request(url: str, data: Dict[str, str]) -> requests.Response:
    auth_req = auth_requests.Request()
    identity_token = google_id_token.fetch_id_token(auth_req, url)
    headers = {"Authorization": f"Bearer {identity_token}"}
    response = requests.post(url, data=data, headers=headers, timeout=10)
    response.raise_for_status()
    return response

def call_sfilter_with_breaker(data: Dict[str, str]) -> requests.Response:
    return sfilter_breaker.call(make_authenticated_post_request, SFILTER_URL, data)

def call_llmstub_with_breaker(data: Dict[str, str]) -> requests.Response:
    return llmstub_breaker.call(make_authenticated_post_request, LLMSTUB_URL, data)

@app.route("/")
def index():
    """Serves the HTML form."""
    return render_template_string(HTML_TEMPLATE)

@app.route("/handle", methods=["POST"])
@handle_errors
def main():
    # Ensure models are loaded
    load_models()
    
    userMessage = request.form.get('message', '')
    # Input validation
    if not userMessage:
        structured_logger.warning("Empty message received")
        return {"error": "Message cannot be empty"}, 400
    if len(userMessage) > MAX_MESSAGE_LENGTH:
        structured_logger.warning("Message too long", length=len(userMessage))
        return {"error": f"Message too long (max {MAX_MESSAGE_LENGTH} characters)"}, 413
    userMessage = userMessage.strip()
    testMessage = userMessage.lower().replace("aeiou0123456789", "")
    score = 0.0
    try:
        if userMessage:
            # Check cache first
            message_hash = hashlib.md5(userMessage.encode()).hexdigest()
            cached_result = get_cached_prediction(message_hash)
            if cached_result is not None:
                score = cached_result
                if ENABLE_REQUEST_LOGGING:
                    structured_logger.info("Cache hit", message_hash=message_hash, cache_size=len(prediction_cache))
            else:
                processed_message = process_text(testMessage)
                if processed_message:
                    v = cv.transform([processed_message]).toarray()
                    score = clf.predict_proba(v)[0][1]
                    cache_prediction(message_hash, score)
                    if ENABLE_REQUEST_LOGGING:
                        structured_logger.info("BFilter score", score=score, message_length=len(userMessage))
        if score < BFILTER_THRESHOLD:
            # If the score is low, proceed to the secondary filter (sfilter).
            try:
                call_sfilter_with_breaker({"message": userMessage})
            except requests.exceptions.HTTPError as e:
                if e.response.status_code == 401:
                    try:
                        project_id = os.getenv("PROJECT_ID")
                        topic_id = "secondary-filter"
                        publisher = pubsub_v1.PublisherClient()
                        topic_path = publisher.topic_path(project_id, topic_id)
                        data = json.dumps({"message": userMessage}).encode("utf-8")
                        future = publisher.publish(topic_path, data)
                        message_id = future.result()
                        structured_logger.info("Published message to pubsub", topic=topic_path, message_id=message_id)
                    except Exception as e:
                        structured_logger.error("Error publishing event", error=str(e))
                        return {"error": f"Error publishing event {e}"}, 503
                    structured_logger.info("sfilter service detected a jailbreak.")
                    return "I don't understand your message, can you say it another way? (secondary)"
                else:
                    structured_logger.error("HTTP error during sfilter check", url=SFILTER_URL, error=str(e))
                    return {"error": f"Error communicating with the secondary filter. {e.response.status_code}"}, 503
            try:
                llmstub_response = call_llmstub_with_breaker({"message": userMessage})
                return llmstub_response.text
            except requests.exceptions.RequestException as e:
                structured_logger.error("Error calling llmstub service", url=LLMSTUB_URL, error=str(e))
                return {"error": "Error communicating with the primary service."}, 503
        else:
            return "I don't understand your message, can you say it another way?"
    except Exception as e:
        structured_logger.error("Unexpected error in main handler", error=str(e))
        return {"error": "Internal server error"}, 500

# Health check endpoint
@app.route("/health", methods=["GET"])
def health_check():
    """Health check endpoint for load balancer"""
    try:
        # Ensure models are loaded for health check
        load_models()
        # Quick model validation
        test_vector = cv.transform(["test"]).toarray()
        clf.predict_proba(test_vector)
        return {"status": "healthy", "timestamp": time.time()}, 200
    except Exception as e:
        structured_logger.error("Health check failed", error=str(e))
        return {"status": "unhealthy", "error": str(e)}, 503

# Readiness check endpoint  
@app.route("/ready", methods=["GET"])
def readiness_check():
    """Readiness check to verify dependencies are available"""
    errors = []
    checks = {}
    # Check environment variables
    required_env_vars = ["LLMSTUB_URL", "SFILTER_URL", "PROJECT_ID"]
    for var in required_env_vars:
        if not os.getenv(var):
            errors.append(f"{var} not configured")
            checks[var] = "FAIL"
        else:
            checks[var] = "OK"
    # Check model files
    try:
        # Ensure models are loaded
        load_models()
        if clf is None or cv is None:
            errors.append("Models not loaded")
            checks["models"] = "FAIL"
        else:
            test_vector = cv.transform(["test"]).toarray()
            clf.predict_proba(test_vector)
            checks["models"] = "OK"
    except Exception as e:
        errors.append(f"Model validation failed: {str(e)}")
        checks["models"] = "FAIL"
    # Check dependencies with timeout
    dependency_checks = [
        ("sfilter", SFILTER_URL),
        ("llmstub", LLMSTUB_URL)
    ]
    for service_name, url in dependency_checks:
        try:
            response = requests.get(f"{url.rstrip('/')}/health", timeout=5)
            if response.status_code == 200:
                checks[service_name] = "OK"
            else:
                errors.append(f"{service_name} unhealthy: {response.status_code}")
                checks[service_name] = "FAIL"
        except requests.exceptions.RequestException as e:
            errors.append(f"{service_name} unreachable: {str(e)}")
            checks[service_name] = "FAIL"
    # Check cache health
    try:
        cache_size = len(prediction_cache)
        if cache_size > 10000:
            errors.append(f"Cache size too large: {cache_size}")
            checks["cache"] = "WARN"
        else:
            checks["cache"] = "OK"
    except Exception:
        errors.append("Cache access failed")
        checks["cache"] = "FAIL"
    status_code = 503 if errors else 200
    status = "not_ready" if errors else "ready"
    return {
        "status": status,
        "timestamp": time.time(),
        "checks": checks,
        "errors": errors if errors else None,
        "service": "bfilter"
    }, status_code


# --- Prometheus Metrics Implementation ---
metrics_data = {
    "requests_total": 0,
    "requests_filtered": 0,
    "requests_passed": 0,
    "cache_hits": 0,
    "cache_misses": 0,
    "error_count": defaultdict(int),
    "response_time_sum": 0.0,
    "response_time_count": 0
}

@app.route("/metrics", methods=["GET"])
def metrics() -> Tuple[str, int]:
    """Prometheus-compatible metrics endpoint"""
    uptime = time.time() - app.start_time
    avg_response_time = (metrics_data["response_time_sum"] /
                        max(metrics_data["response_time_count"], 1))
    cache_hit_rate = (metrics_data["cache_hits"] /
                     max(metrics_data["cache_hits"] + metrics_data["cache_misses"], 1))
    metrics_output = f"""# HELP bfilter_requests_total Total number of requests
# TYPE bfilter_requests_total counter
bfilter_requests_total {metrics_data["requests_total"]}

# HELP bfilter_requests_filtered Number of requests filtered
# TYPE bfilter_requests_filtered counter  
bfilter_requests_filtered {metrics_data["requests_filtered"]}

# HELP bfilter_requests_passed Number of requests passed
# TYPE bfilter_requests_passed counter
bfilter_requests_passed {metrics_data["requests_passed"]}

# HELP bfilter_cache_hits Cache hits
# TYPE bfilter_cache_hits counter
bfilter_cache_hits {metrics_data["cache_hits"]}

# HELP bfilter_cache_misses Cache misses  
# TYPE bfilter_cache_misses counter
bfilter_cache_misses {metrics_data["cache_misses"]}

# HELP bfilter_cache_hit_rate Cache hit rate
# TYPE bfilter_cache_hit_rate gauge
bfilter_cache_hit_rate {cache_hit_rate:.4f}

# HELP bfilter_cache_size Current cache size
# TYPE bfilter_cache_size gauge
bfilter_cache_size {len(prediction_cache)}

# HELP bfilter_uptime_seconds Service uptime in seconds
# TYPE bfilter_uptime_seconds gauge
bfilter_uptime_seconds {uptime:.2f}

# HELP bfilter_avg_response_time_seconds Average response time
# TYPE bfilter_avg_response_time_seconds gauge
bfilter_avg_response_time_seconds {avg_response_time:.6f}
"""
    return metrics_output, 200, {'Content-Type': 'text/plain; version=0.0.4'}

# Initialize app start time and request counter
app.start_time = time.time()
app.request_count = 0

if __name__ == "__main__":
    # Startup logging for Cloud Run diagnostics
    structured_logger.info("BFilter service starting", 
                         stage="startup",
                         python_version=sys.version,
                         available_memory_mb=os.environ.get('CLOUDSDK_COMPUTE_MEMORY_LIMIT', 'unknown'))
    
    # Force initial garbage collection
    gc.collect()
    
    structured_logger.info("Starting Flask application", port=8082, host="0.0.0.0")
    app.run(debug=True, port=8082, host='0.0.0.0')