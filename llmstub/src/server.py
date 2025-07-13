import os
from flask import Flask
from flask import request
import time


app = Flask(__name__)
app.start_time = time.time()

# Health check endpoint
@app.route("/health", methods=["GET"])
def health_check():
    """Health check endpoint"""
    return {"status": "healthy", "timestamp": time.time(), "service": "llmstub"}, 200

@app.route("/ready", methods=["GET"])
def readiness_check():
    """Readiness check"""
    return {"status": "ready", "timestamp": time.time()}, 200

@app.route("/", methods=["POST"])
def main():
    return request.form.get('message')

if __name__ == "__main__":
    app.run(debug=True, port=8081, host='0.0.0.0')