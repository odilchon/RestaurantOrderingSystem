FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# System deps: libpq for psycopg, curl for HEALTHCHECK
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential libpq5 libpq-dev curl \
    && rm -rf /var/lib/apt/lists/*

# Install deps first for layer cache reuse
COPY pyproject.toml .
RUN pip install --upgrade pip \
    && pip install -e . || true

COPY . .
RUN pip install -e .

# Drop privileges
RUN useradd -m -u 1000 app && chown -R app:app /app
USER app

EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
    CMD curl -fsS http://localhost:8000/health || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
