
FROM python:3.11-slim

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Copy requirements and install
COPY src/requirements.txt .
RUN pip install -r requirements.txt --no-cache-dir

# Copy application
COPY src/server.py .

# Clean up
RUN rm requirements.txt

# Switch to non-root user  
USER appuser

# Add health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8081/health || exit 1

CMD ["gunicorn", "-b", "0.0.0.0:8081", "server:app"]

