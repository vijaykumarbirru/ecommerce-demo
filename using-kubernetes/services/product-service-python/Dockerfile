FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
# Instrumentation packages are pinned explicitly in requirements.txt;
# `opentelemetry-instrument` below activates them with zero code changes.
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
EXPOSE 8001
CMD ["opentelemetry-instrument", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
