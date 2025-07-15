FROM python:3.11-slim 
# AS basepython

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Install system dependencies and clean up in single layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --upgrade pip --no-cache-dir

# Copy requirements first for better layer caching
COPY src/requirements.txt .
RUN pip install -r requirements.txt --no-cache-dir

RUN rm ./requirements.txt

#FROM basepython AS basesetup

# Set working directory
WORKDIR /app

# Copy application files
COPY src/server.py .
COPY src/dataprep.py .
COPY data/jailbreaks.csv .

# Create storage directory
RUN mkdir -p /storage/models && chown -R appuser:appuser /storage

#FROM basesetup AS final

# Run data preparation
RUN python ./dataprep.py

# Clean up build artifacts
RUN rm ./dataprep.py ./jailbreaks.csv

# Switch to non-root user
USER appuser

# Add health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8082/health || exit 1

# Set the CMD
CMD ["gunicorn", "-b", "0.0.0.0:8082", "server:app", "--workers=2", "--timeout=30"]

