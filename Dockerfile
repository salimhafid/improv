FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# ca-certificates for TLS; curl_cffi ships its own libcurl-impersonate.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

ENV PORT=8080
EXPOSE 8080

# 1 worker keeps the in-memory cache coherent; threads handle concurrent reads.
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 120 app:app
