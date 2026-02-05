#!/bin/bash
# ========================================
# DayPlan - SSL Certificate Setup
# ========================================
# Generates a self-signed SSL certificate for local development.
# For production, use Let's Encrypt or a proper CA certificate.
#
# Usage:
#   ./setup-ssl.sh                        # Default /etc/nginx/ssl/
#   SSL_DIR=./ssl ./setup-ssl.sh          # Custom directory
#
set -euo pipefail

# ----------------------------------------
# Configuration
# ----------------------------------------
SSL_DIR="${SSL_DIR:-/etc/nginx/ssl}"
CERT_FILE="${SSL_DIR}/dayplan.crt"
KEY_FILE="${SSL_DIR}/dayplan.key"
DAYS_VALID="${DAYS_VALID:-365}"
COMMON_NAME="${COMMON_NAME:-localhost}"

# ----------------------------------------
# Functions
# ----------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - SSL - $1"
}

# ----------------------------------------
# Check if certificates already exist
# ----------------------------------------
if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    # Check expiration
    EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$EXPIRY" ]; then
        EXPIRY_EPOCH=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY" "+%s" 2>/dev/null || date -d "$EXPIRY" "+%s" 2>/dev/null || echo "0")
        NOW_EPOCH=$(date "+%s")
        if [ "$EXPIRY_EPOCH" -gt "$NOW_EPOCH" ]; then
            log "Valid certificate already exists (expires: $EXPIRY)"
            log "To force regeneration, delete existing files and re-run."
            exit 0
        fi
    fi
    log "Existing certificate has expired. Regenerating..."
fi

# ----------------------------------------
# Create SSL directory
# ----------------------------------------
log "Creating SSL directory: $SSL_DIR"
sudo mkdir -p "$SSL_DIR"

# ----------------------------------------
# Generate self-signed certificate
# ----------------------------------------
log "Generating self-signed certificate..."
log "  Common Name: $COMMON_NAME"
log "  Valid for: $DAYS_VALID days"

sudo openssl req -x509 -nodes \
    -days "$DAYS_VALID" \
    -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/C=US/ST=Local/L=Local/O=DayPlan/CN=$COMMON_NAME" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    2>/dev/null

# Set permissions
sudo chmod 644 "$CERT_FILE"
sudo chmod 600 "$KEY_FILE"

# ----------------------------------------
# Verify
# ----------------------------------------
log "Certificate generated successfully:"
log "  Certificate: $CERT_FILE"
log "  Private Key: $KEY_FILE"

openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null | grep -E "Subject:|Not After" | sed 's/^/  /'

log ""
log "NOTE: This is a self-signed certificate for local development."
log "Browsers will show a security warning. Add an exception to proceed."
log "For production, use Let's Encrypt: https://letsencrypt.org/"
