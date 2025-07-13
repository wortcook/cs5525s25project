# LLM Stub

This directory contains a stub service that mimics the API of the `bfilter` service.

## Purpose

The stub server can be used for:
-   Client-side development and testing without needing to run the full `bfilter` service.
-   Integration testing in a CI/CD pipeline.
-   Providing a predictable response for demos.

## `src/server.py`

This is a Lambda handler that implements the same API as `bfilter/src/server.py`. It accepts `GET` and `POST` requests with a `message` and returns a score.

Unlike the real service, it does not use a machine learning model. Instead, it always returns a fixed score of `0.5`.