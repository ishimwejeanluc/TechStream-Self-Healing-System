FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# stress-ng drives the CPU chaos mode. curl is used by the container health check.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        stress-ng \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080

# One worker keeps the chaos state and all metrics in a single process, so there
# is no need for prometheus_client multiprocess mode and no risk of a request
# landing on a worker that does not know chaos is active. Threads carry the
# request concurrency, and stress-ng runs as a separate child process.
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "1", \
     "--worker-class", "gthread", \
     "--threads", "16", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
