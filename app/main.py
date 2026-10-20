import os

from fastapi import FastAPI

APP_NAME = os.getenv("APP_NAME", "devops-microservice")
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")

app = FastAPI(title=APP_NAME, version=APP_VERSION)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "healthy", "service": APP_NAME, "environment": ENVIRONMENT}


@app.get("/")
def root() -> dict[str, str]:
    return {"name": APP_NAME, "version": APP_VERSION, "environment": ENVIRONMENT}


@app.get("/api/v1/message")
def message() -> dict[str, str]:
    return {"message": "Hello from the DevOps microservice", "version": APP_VERSION}
