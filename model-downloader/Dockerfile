

FROM python:3.11-slim

# Install git for model repo cloning
RUN apt-get update && apt-get install -y git git-lfs && rm -rf /var/lib/apt/lists/*

# Create non-root user
#RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Create model directory and set ownership
#RUN mkdir -p /app/model && chown -R appuser:appuser /app
RUN mkdir -p /app/model 

# Switch to non-root user
#USER appuser

CMD ["python", "main.py"]