
FROM pytorch/pytorch:2.7.1-cuda11.8-cudnn9-runtime AS basepython

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

RUN python -m pip install --upgrade pip --no-cache-dir

COPY src/requirements.txt .
RUN pip install -r requirements.txt --no-cache-dir

FROM basepython AS basesetup

WORKDIR /app
COPY src/server.py .

FROM basesetup AS final

# Clean up
RUN rm -f requirements.txt

# Switch to non-root user
USER appuser

# Add health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8083/health || exit 1

CMD ["gunicorn", "-b", "0.0.0.0:8083", "server:app", "--workers=1", "--timeout=120"]

