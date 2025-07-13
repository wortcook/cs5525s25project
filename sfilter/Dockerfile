# FROM us-docker.pkg.dev/vertex-ai/prediction/pytorch-gpu.2-4:latest AS basepython
FROM pytorch/pytorch:2.7.1-cuda11.8-cudnn9-runtime AS basepython


RUN python -m pip install --upgrade pip

COPY src/requirements.txt .
# Install the specified packages
RUN pip install -r requirements.txt

# ENV SECONDARY_MODEL=/storage/models/jailbreak-classifier

FROM basepython AS basesetup

# Copy function code
COPY src/server.py .

# Copy requirements.txt

# RUN mkdir -p /storage/models

FROM basesetup
# Run the data prep script to create the pickles
# RUN rm ./requirements.txt

# Set the CMD to your handler (could also be done as a parameter override outside of the Dockerfile)
CMD ["gunicorn", "-b", "0.0.0.0:8083", "server:app"]

