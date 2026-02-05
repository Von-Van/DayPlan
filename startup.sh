#!/bin/bash
# ========================================
# DayPlan - Application Startup Script
# ========================================
# Starts the application using Gunicorn WSGI server.
#
# Usage:
#   ./startup.sh              # Start with defaults
#   APP_HOME=/custom/path ./startup.sh  # Override app home
#
set -euo pipefail

# ----------------------------------------
# Configuration
# ----------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_HOME="${APP_HOME:-$SCRIPT_DIR}"
VENV="${APP_HOME}/.venv"
LOG_DIR="${APP_HOME}/logs"
LOG_FILE="${LOG_DIR}/startup.log"

# ----------------------------------------
# Setup
# ----------------------------------------
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "========================================="
log "Starting DayPlan Application"
log "APP_HOME: $APP_HOME"
log "========================================="

# ----------------------------------------
# Load environment
# ----------------------------------------
if [ -f "$APP_HOME/.env" ]; then
    set -a
    source "$APP_HOME/.env"
    set +a
    log "Environment loaded from .env"
else
    log "WARNING: .env file not found at $APP_HOME/.env"
    log "Using default environment settings"
fi

# ----------------------------------------
# Activate virtual environment
# ----------------------------------------
if [ -d "$VENV" ]; then
    source "$VENV/bin/activate"
    log "Virtual environment activated: $VENV"
elif [ -d "${APP_HOME}/venv" ]; then
    VENV="${APP_HOME}/venv"
    source "$VENV/bin/activate"
    log "Virtual environment activated: $VENV"
else
    log "WARNING: No virtual environment found. Using system Python."
fi

# ----------------------------------------
# Verify dependencies
# ----------------------------------------
python3 -c "import flask" 2>/dev/null || {
    log "ERROR: Flask not installed. Run: pip install -r requirements-prod.txt"
    exit 1
}

python3 -c "import gunicorn" 2>/dev/null || {
    log "ERROR: Gunicorn not installed. Run: pip install -r requirements-prod.txt"
    exit 1
}

# ----------------------------------------
# Create required directories
# ----------------------------------------
mkdir -p "${APP_HOME}/logs"
mkdir -p "${APP_HOME}/backups"

# ----------------------------------------
# Start Gunicorn
# ----------------------------------------
cd "$APP_HOME"

BIND="${GUNICORN_BIND:-127.0.0.1:8000}"
log "Starting Gunicorn on $BIND..."

exec gunicorn \
    --config gunicorn_config.py \
    app:app
