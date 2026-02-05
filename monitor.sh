#!/bin/bash
# ========================================
# DayPlan - Health Monitor Script
# ========================================
# Periodically checks application health and restarts if unhealthy.
# Designed to run as a systemd service or background process.
#
# Usage:
#   ./monitor.sh                          # Run with defaults
#   CHECK_INTERVAL=60 ./monitor.sh        # Check every 60 seconds
#
set -uo pipefail

# ----------------------------------------
# Configuration
# ----------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_HOME="${APP_HOME:-$SCRIPT_DIR}"

# Load .env if present
if [ -f "$APP_HOME/.env" ]; then
    set -a
    source "$APP_HOME/.env"
    set +a
fi

HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:${FLASK_PORT:-8000}/health}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"          # Seconds between checks
RESTART_THRESHOLD="${RESTART_THRESHOLD:-3}"      # Failures before restart
MAX_RESTARTS="${MAX_RESTARTS:-5}"                # Max restarts before giving up
LOG_FILE="${APP_HOME}/logs/monitor.log"

# State
ERROR_COUNT=0
RESTART_COUNT=0

# ----------------------------------------
# Functions
# ----------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - MONITOR - $1" | tee -a "$LOG_FILE"
}

check_health() {
    local response
    local http_code

    # Use curl with timeout, accept self-signed certs
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        --connect-timeout 5 \
        -k "$HEALTH_URL" 2>/dev/null)

    if [ "$http_code" = "200" ]; then
        if [ "$ERROR_COUNT" -gt 0 ]; then
            log "Service recovered after $ERROR_COUNT failed check(s)"
        fi
        ERROR_COUNT=0
        return 0
    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
        log "Health check failed (HTTP $http_code). Consecutive failures: $ERROR_COUNT"
        return 1
    fi
}

restart_service() {
    if [ "$RESTART_COUNT" -ge "$MAX_RESTARTS" ]; then
        log "ERROR: Max restarts ($MAX_RESTARTS) reached. Manual intervention required."
        log "Continuing monitoring but NOT restarting."
        ERROR_COUNT=0  # Reset to avoid tight restart loop
        return 1
    fi

    log "Restarting DayPlan service (attempt $((RESTART_COUNT + 1))/$MAX_RESTARTS)..."

    # Try systemctl first, fall back to direct process management
    if command -v systemctl &>/dev/null && systemctl is-active dayplan &>/dev/null; then
        sudo systemctl restart dayplan
    elif command -v launchctl &>/dev/null; then
        # macOS: try launchctl
        launchctl stop com.dayplan.app 2>/dev/null || true
        sleep 2
        launchctl start com.dayplan.app 2>/dev/null || true
    else
        log "WARNING: No service manager found. Attempting direct restart..."
        pkill -f "gunicorn.*app:app" 2>/dev/null || true
        sleep 2
        cd "$APP_HOME"
        nohup ./startup.sh >> "$APP_HOME/logs/startup.log" 2>&1 &
    fi

    RESTART_COUNT=$((RESTART_COUNT + 1))
    sleep 5  # Wait for service to come up

    # Check if restart was successful
    if check_health; then
        log "Service restarted successfully"
    else
        log "WARNING: Service still unhealthy after restart"
    fi
}

# ----------------------------------------
# Ensure log directory exists
# ----------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"

# ----------------------------------------
# Main loop
# ----------------------------------------
log "DayPlan Health Monitor started"
log "Monitoring: $HEALTH_URL (every ${CHECK_INTERVAL}s, threshold: $RESTART_THRESHOLD)"

# Handle graceful shutdown
trap 'log "Monitor shutting down"; exit 0' SIGTERM SIGINT

while true; do
    if ! check_health; then
        if [ "$ERROR_COUNT" -ge "$RESTART_THRESHOLD" ]; then
            restart_service
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
