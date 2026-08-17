FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Standard library only. No requirements file, nothing to install.
COPY app.py .

EXPOSE 8000

CMD ["python3", "app.py"]
