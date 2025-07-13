import json
import joblib
from flask import Flask, request, render_template_string
import os
import requests
from google.auth.transport import requests as auth_requests
from google.oauth2 import id_token as google_id_token
from google.cloud import pubsub_v1
import hashlib
import time

LLMSTUB_URL = os.getenv("LLMSTUB_URL")
SFILTER_URL = os.getenv("SFILTER_URL")

# Configurable parameters
BFILTER_THRESHOLD = float(os.getenv("BFILTER_THRESHOLD", "0.9"))
ENABLE_REQUEST_LOGGING = os.getenv("ENABLE_REQUEST_LOGGING", "false").lower() == "true"
MAX_MESSAGE_LENGTH = int(os.getenv("MAX_MESSAGE_LENGTH", "10000"))

#MODEL LOAD FOR BAYESIAN FILTER
clf = joblib.load("model.pkl")
cv = joblib.load("cv.pkl")

app = Flask(__name__)

# Cache for processed messages to avoid reprocessing
prediction_cache = {}

def get_cached_prediction(message_hash):
    """Get cached prediction for a message hash"""
    return prediction_cache.get(message_hash)

def cache_prediction(message_hash, score):
    """Cache a prediction result"""
    if len(prediction_cache) > 1000:  # Simple LRU-like behavior
        # Remove oldest entries when cache gets too large
        keys = list(prediction_cache.keys())
        for key in keys[:100]:  # Remove oldest 100 entries
            del prediction_cache[key]
    prediction_cache[message_hash] = score

# Performance tracking
request_start_times = {}

@app.before_request
def before_request():
    request_start_times[request] = time.time()
    app.request_count = getattr(app, 'request_count', 0) + 1

@app.after_request
def after_request(response):
    if request in request_start_times:
        duration = time.time() - request_start_times[request]
        app.logger.info(f"Request duration: {duration:.3f}s")
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

def make_authenticated_post_request(url: str, data: dict) -> requests.Response:
    """
    Makes an authenticated POST request to a Google Cloud Run service.

    This function fetches a Google-signed ID token for the target audience (URL)
    and includes it in the Authorization header of the POST request. It will
    raise an HTTPError for 4xx or 5xx responses.

    Args:
        url: The URL of the Cloud Run service to call.
        data: The dictionary of data to send in the POST request body.

    Returns:
        The requests.Response object from the call.
    """
    auth_req = auth_requests.Request()
    identity_token = google_id_token.fetch_id_token(auth_req, url)
    headers = {"Authorization": f"Bearer {identity_token}"}
    response = requests.post(url, data=data, headers=headers)
    response.raise_for_status()
    return response

@app.route("/")
def index():
    """Serves the HTML form."""
    return render_template_string(HTML_TEMPLATE)

@app.route("/handle", methods=["POST"])
def main():
    userMessage = request.form.get('message', '')
    
    # Input validation
    if len(userMessage) > MAX_MESSAGE_LENGTH:
        app.logger.warning(f"Message too long: {len(userMessage)} chars")
        return "Message too long", 413
    
    testMessage = userMessage.lower().replace("aeiou0123456789", "")

    score = 0.0

    if userMessage.strip():
        # Check cache first
        message_hash = hashlib.md5(userMessage.encode()).hexdigest()
        cached_result = get_cached_prediction(message_hash)
        
        if cached_result is not None:
            score = cached_result
            if ENABLE_REQUEST_LOGGING:
                app.logger.info(f"Cache hit for message hash: {message_hash}")
        else:
            processed_message = process_text(testMessage)
            if processed_message:
                v = cv.transform([processed_message]).toarray()
                score = clf.predict_proba(v)[0][1]
                # Cache the result
                cache_prediction(message_hash, score)
                if ENABLE_REQUEST_LOGGING:
                    app.logger.info(f"BFilter score: {score:.3f} for message length: {len(userMessage)}")

    if score < BFILTER_THRESHOLD:
        # If the score is low, proceed to the secondary filter (sfilter).
        try:
            make_authenticated_post_request(SFILTER_URL, data={"message": userMessage})
        except requests.exceptions.HTTPError as e:
            # sfilter returns a 401 on jailbreak detection.
            if e.response.status_code == 401:

                #fire pub-sub event to "secondary-filter"
                try:
                    #Pub/Sub
                    # The ID of your Google Cloud project
                    project_id = os.getenv("PROJECT_ID")
                    # The ID of your Pub/Sub topic
                    topic_id = "secondary-filter"

                    publisher = pubsub_v1.PublisherClient()
                    # The `topic_path` method creates a fully qualified identifier
                    # in the form `projects/{project_id}/topics/{topic_id}`
                    topic_path = publisher.topic_path(project_id, topic_id)

                    # Data must be a byte string
                    data = json.dumps({"message": userMessage}).encode("utf-8")
                    # When you publish a message, the client returns a future.
                    future = publisher.publish(topic_path, data)
                    message_id = future.result()
                    app.logger.info(f"Published message to {topic_path}: {message_id}")
                except Exception as e:
                    app.logger.error("Error publishing event")
                    return f"Error publishing event {e}", 503


                app.logger.info("sfilter service detected a jailbreak.")
                return "I don't understand your message, can you say it another way? (secondary)"
            else:
                app.logger.error(f"HTTP error during sfilter check for URL {SFILTER_URL}: {e}")
                return f"Error communicating with the secondary filter. {e.response.status_code}", 503

        # If sfilter passes (returns 200 OK), call the final LLM stub.
        try:
            llmstub_response = make_authenticated_post_request(LLMSTUB_URL, data={"message": userMessage})
            return llmstub_response.text
        except requests.exceptions.RequestException as e:
            app.logger.error(f"Error calling llmstub service at {LLMSTUB_URL}: {e}")
            return "Error communicating with the primary service.", 503
    else:
        return "I don't understand your message, can you say it another way?"

# Health check endpoint
@app.route("/health", methods=["GET"])
def health_check():
    """Health check endpoint for load balancer"""
    try:
        # Quick model validation
        test_vector = cv.transform(["test"]).toarray()
        clf.predict_proba(test_vector)
        return {"status": "healthy", "timestamp": time.time()}, 200
    except Exception as e:
        app.logger.error(f"Health check failed: {e}")
        return {"status": "unhealthy", "error": str(e)}, 503

# Readiness check endpoint  
@app.route("/ready", methods=["GET"])
def readiness_check():
    """Readiness check to verify dependencies are available"""
    errors = []
    
    # Check if required environment variables are set
    if not LLMSTUB_URL:
        errors.append("LLMSTUB_URL not configured")
    if not SFILTER_URL:
        errors.append("SFILTER_URL not configured")
    
    # Test connectivity to dependencies (with timeout)
    try:
        # Quick ping to sfilter
        response = requests.get(f"{SFILTER_URL.replace('/', '')}/health", timeout=2)
        if response.status_code != 200:
            errors.append(f"SFilter unhealthy: {response.status_code}")
    except Exception as e:
        errors.append(f"SFilter unreachable: {str(e)}")
    
    try:
        # Quick ping to llmstub  
        response = requests.get(f"{LLMSTUB_URL.replace('/', '')}/health", timeout=2)
        if response.status_code != 200:
            errors.append(f"LLMStub unhealthy: {response.status_code}")
    except Exception as e:
        errors.append(f"LLMStub unreachable: {str(e)}")
    
    if errors:
        return {"status": "not_ready", "errors": errors}, 503
    else:
        return {"status": "ready", "timestamp": time.time()}, 200

# Metrics endpoint for monitoring
@app.route("/metrics", methods=["GET"])
def metrics():
    """Basic metrics endpoint"""
    return {
        "cache_size": len(prediction_cache),
        "uptime": time.time() - app.start_time,
        "total_requests": getattr(app, 'request_count', 0)
    }, 200

# Initialize app start time and request counter
app.start_time = time.time()
app.request_count = 0

if __name__ == "__main__":
    app.run(debug=True, port=8082, host='0.0.0.0')