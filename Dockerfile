# ========================================
# DayPlan - Dockerfile
# ========================================
# Multi-stage build for a lean production image.
#
# Build:
#   docker build -t dayplan .
#
# Run:
#   docker run -p 8000:8000 -v dayplan_data:/app/data dayplan

FROM python:3.11-slim AS base

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    FLASK_ENV=production \
    FLASK_DEBUG=False

WORKDIR /app

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r dayplan && \
    useradd -r -g dayplan -d /app -s /sbin/nologin dayplan

# ----------------------------------------
# Dependencies stage
# ----------------------------------------
FROM base AS deps

COPY requirements-prod.txt .
RUN pip install --no-cache-dir -r requirements-prod.txt

# ----------------------------------------
# Application stage
# ----------------------------------------
FROM deps AS app

# Copy application code
COPY app.py config.py models.py storage.py validation.py gunicorn_config.py ./
COPY templates/ ./templates/
COPY static/ ./static/

# Create directories for data, logs, and backups
RUN mkdir -p /app/data /app/logs /app/backups && \
    chown -R dayplan:dayplan /app

# Copy operational scripts
COPY backup.sh ./
RUN chmod +x backup.sh

# Switch to non-root user
USER dayplan

# Expose Gunicorn port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Default environment variables (can be overridden)
ENV GUNICORN_BIND=0.0.0.0:8000 \
    GUNICORN_WORKERS=2 \
    DATA_FILE_PATH=/app/data/dayplan_data.json \
    LOG_FILE=/app/logs/dayplan.log \
    GUNICORN_ACCESS_LOG=/app/logs/gunicorn-access.log \
    GUNICORN_ERROR_LOG=/app/logs/gunicorn-error.log

# Start with Gunicorn
CMD ["gunicorn", "--config", "gunicorn_config.py", "app:app"]
