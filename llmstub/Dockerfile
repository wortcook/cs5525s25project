FROM python:3.11

# Copy requirements.txt
COPY src/server.py .
COPY src/requirements.txt .

# Install the specified packages
RUN pip install -r requirements.txt

RUN rm ./requirements.txt

# Set the CMD to your handler (could also be done as a parameter override outside of the Dockerfile)
CMD ["gunicorn", "-b", "0.0.0.0:8081", "server:app"]

