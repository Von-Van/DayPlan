"""
DayPlan - Gunicorn Configuration
Production WSGI server settings.

Usage:
    gunicorn -c gunicorn_config.py app:app
"""

import os
import multiprocessing

# ========================================
# Server Socket
# ========================================
bind = os.getenv("GUNICORN_BIND", "127.0.0.1:8000")
backlog = 2048

# ========================================
# Worker Processes
# ========================================
# Default: 2x CPU cores (good for I/O-bound apps)
# For a personal local app, 2-4 workers is typically sufficient
workers = int(os.getenv("GUNICORN_WORKERS", min(multiprocessing.cpu_count() * 2, 4)))
worker_class = "sync"
worker_connections = 1000
timeout = 30
keepalive = 2
max_requests = 1000          # Restart workers after N requests (prevents memory leaks)
max_requests_jitter = 50     # Random jitter to prevent all workers restarting at once

# ========================================
# Logging
# ========================================
accesslog = os.getenv("GUNICORN_ACCESS_LOG", "./logs/gunicorn-access.log")
errorlog = os.getenv("GUNICORN_ERROR_LOG", "./logs/gunicorn-error.log")
loglevel = os.getenv("GUNICORN_LOG_LEVEL", "info")
access_log_format = '%(h)s %(l)s %(u)s %(t)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s" %(D)sμs'

# ========================================
# Process Naming
# ========================================
proc_name = "dayplan"

# ========================================
# Security
# ========================================
limit_request_line = 4094
limit_request_fields = 100
limit_request_field_size = 8190

# ========================================
# Server Hooks
# ========================================
def on_starting(server):
    """Called just before the master process is initialized."""
    print(f"Starting DayPlan with {workers} workers on {bind}")


def when_ready(server):
    """Called just after the server is started."""
    print("DayPlan server is ready to accept connections")


def pre_fork(server, worker):
    """Called just before a worker is forked."""
    pass


def post_fork(server, worker):
    """Called just after a worker has been forked."""
    server.log.info(f"Worker spawned (pid: {worker.pid})")


def pre_exec(server):
    """Called just before a new master process is forked."""
    server.log.info("Forked child, re-executing.")


def on_exit(server):
    """Called just before exiting Gunicorn."""
    print("DayPlan server shutting down")
