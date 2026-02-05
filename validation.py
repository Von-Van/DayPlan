"""
DayPlan Request Validation Module
Handles input validation, sanitization, and error handling
"""

from flask import jsonify, request
from functools import wraps
import re
import logging

logger = logging.getLogger(__name__)


class ValidationError(Exception):
    """Custom validation error with field information"""
    
    def __init__(self, message, field=None, status_code=400):
        self.message = message
        self.field = field
        self.status_code = status_code
        super().__init__(self.message)


def handle_validation_error(error):
    """Convert ValidationError to JSON response"""
    response = {
        "error": error.message,
        "field": error.field
    }
    return jsonify(response), error.status_code


def validate_request_json(f):
    """Decorator to ensure request has valid JSON"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not request.is_json:
            logger.warning(f"Non-JSON request to {request.path}")
            return jsonify({"error": "Request must be JSON"}), 400
        return f(*args, **kwargs)
    return decorated_function


def validate_string(value, field_name, min_length=1, max_length=500, allow_empty=False):
    """
    Validate string input
    
    Args:
        value: String to validate
        field_name: Name of field for error messages
        min_length: Minimum length (ignored if allow_empty=True)
        max_length: Maximum length
        allow_empty: Whether empty strings are allowed
        
    Returns:
        Cleaned string
        
    Raises:
        ValidationError: If validation fails
    """
    if not isinstance(value, str):
        raise ValidationError(f"{field_name} must be a string", field_name)
    
    value = value.strip()
    
    if not allow_empty and len(value) < min_length:
        raise ValidationError(
            f"{field_name} must be at least {min_length} characters",
            field_name
        )
    
    if len(value) > max_length:
        raise ValidationError(
            f"{field_name} must be at most {max_length} characters",
            field_name
        )
    
    # Prevent common injection attacks
    dangerous_patterns = [
        r"<script",
        r"javascript:",
        r"on\w+\s*=",  # onclick, onload, etc.
        r"eval\(",
        r"expression\(",
    ]
    
    for pattern in dangerous_patterns:
        if re.search(pattern, value, re.IGNORECASE):
            logger.warning(f"Potential injection detected in {field_name}: {value[:50]}")
            raise ValidationError(
                f"{field_name} contains invalid content",
                field_name
            )
    
    return value


def validate_uuid(value, field_name):
    """
    Validate UUID format (v4)
    
    Args:
        value: UUID string to validate
        field_name: Name of field for error messages
        
    Returns:
        Validated UUID string
        
    Raises:
        ValidationError: If not a valid UUID
    """
    uuid_pattern = r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    
    if not re.match(uuid_pattern, str(value).lower()):
        logger.warning(f"Invalid UUID in {field_name}: {value}")
        raise ValidationError(
            f"{field_name} is not a valid UUID",
            field_name
        )
    
    return str(value).lower()


def validate_priority(value):
    """
    Validate priority level
    
    Args:
        value: Priority value to validate
        
    Returns:
        Validated priority string
        
    Raises:
        ValidationError: If not a valid priority
    """
    valid_priorities = ["none", "low", "medium", "high"]
    
    if value not in valid_priorities:
        raise ValidationError(
            f"Priority must be one of: {', '.join(valid_priorities)}",
            "priority"
        )
    
    return value


def validate_color(value):
    """
    Validate color value
    
    Args:
        value: Color value to validate
        
    Returns:
        Validated color string
        
    Raises:
        ValidationError: If not a valid color
    """
    valid_colors = ["blue", "red", "green", "yellow", "purple", "pink"]
    
    if value not in valid_colors:
        raise ValidationError(
            f"Color must be one of: {', '.join(valid_colors)}",
            "color"
        )
    
    return value


def validate_list_of_strings(value, field_name, max_items=10, max_item_length=50):
    """
    Validate list of strings (e.g., tags)
    
    Args:
        value: List to validate
        field_name: Name of field for error messages
        max_items: Maximum number of items
        max_item_length: Maximum length of each item
        
    Returns:
        Validated list of strings
        
    Raises:
        ValidationError: If validation fails
    """
    if not isinstance(value, list):
        raise ValidationError(f"{field_name} must be a list", field_name)
    
    if len(value) > max_items:
        raise ValidationError(
            f"{field_name} cannot have more than {max_items} items",
            field_name
        )
    
    validated = []
    for i, item in enumerate(value):
        if not isinstance(item, str):
            raise ValidationError(
                f"All {field_name} items must be strings",
                field_name
            )
        
        validated_item = validate_string(
            item,
            f"{field_name}[{i}]",
            min_length=1,
            max_length=max_item_length
        )
        validated.append(validated_item)
    
    return validated


def validate_boolean(value, field_name):
    """
    Validate boolean value
    
    Args:
        value: Value to validate
        field_name: Name of field for error messages
        
    Returns:
        Validated boolean
        
    Raises:
        ValidationError: If not a boolean
    """
    if not isinstance(value, bool):
        raise ValidationError(
            f"{field_name} must be a boolean",
            field_name
        )
    
    return value


def validate_int(value, field_name, min_value=None, max_value=None):
    """
    Validate integer value
    
    Args:
        value: Integer to validate
        field_name: Name of field for error messages
        min_value: Minimum allowed value
        max_value: Maximum allowed value
        
    Returns:
        Validated integer
        
    Raises:
        ValidationError: If not valid
    """
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValidationError(
            f"{field_name} must be an integer",
            field_name
        )
    
    if min_value is not None and value < min_value:
        raise ValidationError(
            f"{field_name} must be at least {min_value}",
            field_name
        )
    
    if max_value is not None and value > max_value:
        raise ValidationError(
            f"{field_name} must be at most {max_value}",
            field_name
        )
    
    return value


def log_validation_error(error, endpoint):
    """Log validation errors for monitoring"""
    logger.warning(
        f"Validation error on {endpoint}: {error.message} (field: {error.field})"
    )
