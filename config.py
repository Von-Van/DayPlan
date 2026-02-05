"""
DayPlan Configuration Management
Handles environment-based configuration for different deployment contexts
"""

import os
from datetime import timedelta


class Config:
    """Base configuration - shared across all environments"""
    
    # Flask settings
    SECRET_KEY = os.getenv("SECRET_KEY", "dev-key-change-in-production")
    JSON_SORT_KEYS = False
    
    # Session configuration
    SESSION_COOKIE_SECURE = True
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    PERMANENT_SESSION_LIFETIME = timedelta(days=7)
    
    # Data storage
    DATA_FILE_PATH = os.getenv("DATA_FILE_PATH", "./dayplan_data.json")
    
    # Logging
    LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
    LOG_FILE = os.getenv("LOG_FILE", "./logs/dayplan.log")
    LOG_DIR = os.path.dirname(LOG_FILE) if LOG_FILE else "./logs"
    
    # CSRF Protection
    WTF_CSRF_ENABLED = True
    WTF_CSRF_TIME_LIMIT = None  # No time limit for CSRF token validity


class DevelopmentConfig(Config):
    """Development configuration"""
    DEBUG = True
    TESTING = False
    SESSION_COOKIE_SECURE = False  # Allow HTTP in development
    LOG_LEVEL = "DEBUG"
    WTF_CSRF_ENABLED = True  # Keep CSRF enabled even in dev


class ProductionConfig(Config):
    """Production configuration - strict security settings"""
    DEBUG = False
    TESTING = False
    
    # Production must have SECRET_KEY set
    SECRET_KEY = os.getenv("SECRET_KEY")
    if not SECRET_KEY or SECRET_KEY == "dev-key-change-in-production":
        raise ValueError(
            "CRITICAL: SECRET_KEY must be set in production! "
            "Generate one with: python -c \"import secrets; print(secrets.token_hex(32))\""
        )
    
    # Strict session security
    SESSION_COOKIE_SECURE = True
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Strict"
    
    # CSRF must be enabled
    WTF_CSRF_ENABLED = True
    
    # Production logging
    LOG_LEVEL = "WARNING"


class TestingConfig(Config):
    """Testing configuration"""
    DEBUG = True
    TESTING = True
    SESSION_COOKIE_SECURE = False
    WTF_CSRF_ENABLED = False  # Disable CSRF for testing
    LOG_LEVEL = "DEBUG"


def get_config():
    """
    Get the appropriate configuration based on FLASK_ENV environment variable
    
    Returns:
        Config class for the specified environment
        
    Raises:
        ValueError: If invalid FLASK_ENV is specified
    """
    env = os.getenv("FLASK_ENV", "production").lower()
    
    if env == "development":
        return DevelopmentConfig
    elif env == "testing":
        return TestingConfig
    elif env == "production":
        return ProductionConfig
    else:
        raise ValueError(
            f"Invalid FLASK_ENV: {env}. "
            f"Must be one of: development, testing, production"
        )
