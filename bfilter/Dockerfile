FROM python:3.11 AS basepython
# FROM us-docker.pkg.dev/vertex-ai/prediction/pytorch-gpu.2-4:latest AS basepython
# FROM huggingface/transformers-gpu
# FROM pytorch/pytorch:2.7.1-cuda11.8-cudnn9-runtime AS basepython

RUN python -m pip install --upgrade pip

COPY src/requirements.txt .
# Install the specified packages
RUN pip install -r requirements.txt

ENV LLMSTUB_URL=google_cloud_run_v2_service.llm-stub-service.uri
ENV SFILTER_URL=google_cloud_run_v2_service.sfilter-service.uri
# ENV SECONDARY_MODEL=jackhhao/jailbreak-classifier

FROM basepython AS basesetup

# Copy function code
COPY src/server.py .
COPY src/dataprep.py .

# Copy requirements.txt

# Copy the CSV training data
COPY data/jailbreaks.csv .

RUN mkdir -p /storage/models

FROM basesetup
# Run the data prep script to create the pickles
RUN python ./dataprep.py

# Remove the files that are no longer needed
RUN rm ./dataprep.py
RUN rm ./jailbreaks.csv
RUN rm ./requirements.txt

# Set the CMD to your handler (could also be done as a parameter override outside of the Dockerfile)
CMD ["gunicorn", "-b", "0.0.0.0:8082", "server:app"]

