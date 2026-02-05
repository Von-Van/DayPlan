"""
DayPlan - A calendar-style day planner with task completion tracking.
"""

import os
import logging
from datetime import date
from flask import Flask, render_template, request, jsonify, Response
from flask_wtf.csrf import CSRFProtect
from dotenv import load_dotenv

from config import get_config
from models import (
    get_display_date, get_short_date, get_day_number, get_weekday_name,
    get_month_year, get_month_weeks, get_month_bounds, is_today, is_past, is_future,
    CompletionStatus
)
from storage import storage
from validation import (
    ValidationError, handle_validation_error, validate_request_json,
    validate_string, validate_uuid, validate_priority, validate_color,
    validate_list_of_strings, log_validation_error
)

# Load environment variables from .env file
load_dotenv()

app = Flask(__name__)

# Load configuration based on FLASK_ENV
app.config.from_object(get_config())

# Validate production configuration
if app.config.get('ENV') == 'production':
    secret_key = app.config.get('SECRET_KEY')
    if not secret_key or secret_key == 'dev-key-change-in-production':
        raise ValueError(
            "CRITICAL: SECRET_KEY must be set in production! "
            "Generate one with: python -c \"import secrets; print(secrets.token_hex(32))\""
        )

# Initialize CSRF protection
csrf = CSRFProtect(app)

# Setup logging
logging.basicConfig(
    level=app.config["LOG_LEVEL"],
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def _day_metrics(day) -> dict:
    """Build a consistent completion payload for a day."""
    if not day:
        return {
            "completion_status": None,
            "completion_percentage": 0,
            "completed_count": 0,
            "total_count": 0
        }
    return {
        "completion_status": day.completion_status.value,
        "completion_percentage": day.completion_percentage,
        "completed_count": day.completed_count,
        "total_count": day.total_count
    }


@app.context_processor
def utility_processor():
    """Add utility functions to Jinja2 templates."""
    today = date.today()
    return {
        "get_display_date": get_display_date,
        "get_short_date": get_short_date,
        "get_day_number": get_day_number,
        "get_weekday_name": get_weekday_name,
        "get_month_year": get_month_year,
        "is_today": is_today,
        "is_past": is_past,
        "is_future": is_future,
        "CompletionStatus": CompletionStatus,
        "today": today.isoformat(),
        "today_date": today
    }


# ========================================
# Error Handlers
# ========================================

@app.errorhandler(400)
def bad_request(error):
    """Handle 400 Bad Request errors"""
    return jsonify({"error": "Bad request"}), 400


@app.errorhandler(404)
def not_found(error):
    """Handle 404 Not Found errors"""
    return jsonify({"error": "Resource not found"}), 404


@app.errorhandler(500)
def internal_error(error):
    """Handle 500 Internal Server errors"""
    logger.error(f"Internal server error: {error}", exc_info=True)
    return jsonify({"error": "Internal server error"}), 500


@app.after_request
def set_security_headers(response):
    """Add security headers to all responses."""
    # Prevent MIME type sniffing
    response.headers['X-Content-Type-Options'] = 'nosniff'
    # Prevent clickjacking
    response.headers['X-Frame-Options'] = 'SAMEORIGIN'
    # Enable browser XSS protection
    response.headers['X-XSS-Protection'] = '1; mode=block'
    # Content Security Policy
    response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
    # HTTPS only (for production)
    if app.config.get('ENV') == 'production':
        response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    
    return response


@app.route("/")
def index():
    """Main calendar view."""
    today = date.today()
    # Get current month/year from query params or use today
    year = request.args.get("year", today.year, type=int)
    month = request.args.get("month", today.month, type=int)
    
    # Handle month overflow
    if month < 1:
        month = 12
        year -= 1
    elif month > 12:
        month = 1
        year += 1
    
    # Ensure today exists
    storage.ensure_today_exists()
    
    # Get calendar weeks
    weeks = get_month_weeks(year, month)
    
    # Get all days in month range
    first_date, last_date = get_month_bounds(year, month)
    
    days_data = storage.get_days_in_range(first_date, last_date)
    
    # Build calendar_days list for template
    # Each cell is either None (empty) or a dict with day info
    calendar_days = []
    for week in weeks:
        for day_date in week:
            if day_date is None:
                calendar_days.append(None)
            else:
                day_obj = days_data.get(day_date.isoformat())
                if not day_obj:
                    # Create the day if it doesn't exist
                    day_obj = storage.add_day(day_date)
                calendar_days.append({
                    "day": day_obj,
                    "day_num": day_date.day,
                    "is_today": is_today(day_date)
                })
    
    # Get statistics
    stats = storage.get_statistics()
    
    # Navigation dates
    prev_month_val = month - 1 if month > 1 else 12
    prev_year_val = year if month > 1 else year - 1
    next_month_val = month + 1 if month < 12 else 1
    next_year_val = year if month < 12 else year + 1
    
    month_name = date(year, month, 1).strftime("%B")
    
    # Get monthly statistics
    monthly_stats = storage.get_monthly_statistics(year, month)
    
    # Get selected day by ID or default to today if in current month
    selected_day_id = request.args.get("day")
    selected_day = None
    selected_date_display = None
    
    if selected_day_id:
        selected_day = storage.get_day(selected_day_id)
        if selected_day:
            selected_date_display = get_display_date(selected_day.date)
    elif today.year == year and today.month == month:
        selected_day = storage.get_day_by_date(today)
        if selected_day:
            selected_date_display = get_display_date(selected_day.date)
    
    return render_template(
        "index.html",
        calendar_days=calendar_days,
        stats=stats,
        monthly_stats=monthly_stats,
        year=year,
        month=month,
        month_name=month_name,
        prev_month={"year": prev_year_val, "month": prev_month_val},
        next_month={"year": next_year_val, "month": next_month_val},
        selected_day=selected_day,
        selected_date=selected_date_display
    )


@app.route("/api/days", methods=["POST"])
def add_day():
    """Add a new day."""
    data = request.get_json(silent=True) or {}
    date_str = data.get("date")
    
    if date_str:
        try:
            day_date = date.fromisoformat(date_str)
            day = storage.add_day(day_date)
            return jsonify({
                "success": True, 
                "day_id": day.id,
                "day": day.to_dict()
            })
        except ValueError:
            return jsonify({"success": False, "error": "Invalid date"}), 400
    
    return jsonify({"success": False, "error": "Date required"}), 400


@app.route("/api/days/<day_id>", methods=["GET"])
def get_day(day_id: str):
    """Get a day's details."""
    try:
        validate_uuid(day_id, "day_id")
        day = storage.get_day(day_id)
        if day:
            return jsonify({
                "success": True,
                "day": day.to_dict(),
                "completion_status": day.completion_status.value,
                "completion_percentage": day.completion_percentage,
                "completed_count": day.completed_count,
                "total_count": day.total_count,
                "display_date": get_display_date(day.date)
            })
        return jsonify({"success": False, "error": "Day not found"}), 404
    except ValidationError as e:
        return handle_validation_error(e)


@app.route("/api/days/<day_id>", methods=["DELETE"])
def delete_day(day_id: str):
    """Delete a day."""
    try:
        validate_uuid(day_id, "day_id")
        if storage.delete_day(day_id):
            logger.info(f"Day deleted: {day_id}")
            return jsonify({"success": True})
        return jsonify({"success": False, "error": "Day not found"}), 404
    except ValidationError as e:
        return handle_validation_error(e)


@app.route("/api/days/<day_id>/tasks", methods=["POST"])
@validate_request_json
def add_task(day_id: str):
    """Add a task to a day."""
    try:
        validate_uuid(day_id, "day_id")
        data = request.json
        title = validate_string(data.get("title", ""), "title", min_length=1, max_length=500)
        
        task = storage.add_task(day_id, title)
        if task:
            day = storage.get_day(day_id)
            logger.info(f"Task added to day {day_id}: {task}")
            return jsonify({
                "success": True, 
                "task": task,
                **_day_metrics(day)
            })
        
        return jsonify({"success": False, "error": "Day not found"}), 404
    except ValidationError as e:
        log_validation_error(e, f"/api/days/{day_id}/tasks [POST]")
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error adding task: {e}", exc_info=True)
        return jsonify({"success": False, "error": "Internal server error"}), 500


@app.route("/api/days/<day_id>/tasks/<task_id>/toggle", methods=["POST"])
def toggle_task(day_id: str, task_id: str):
    """Toggle a task's completion status."""
    try:
        validate_uuid(day_id, "day_id")
        validate_uuid(task_id, "task_id")
        
        if storage.toggle_task(day_id, task_id):
            day = storage.get_day(day_id)
            task = day.get_task(task_id) if day else None
            stats = storage.get_statistics()
            logger.info(f"Task toggled: {task_id} in day {day_id}")
            return jsonify({
                "success": True,
                "completed": task.completed if task else False,
                **_day_metrics(day),
                "stats": stats.to_dict()
            })
        return jsonify({"success": False, "error": "Task not found"}), 404
    except ValidationError as e:
        return handle_validation_error(e)


@app.route("/api/days/<day_id>/tasks/<task_id>", methods=["DELETE"])
def delete_task(day_id: str, task_id: str):
    """Delete a task."""
    try:
        validate_uuid(day_id, "day_id")
        validate_uuid(task_id, "task_id")
        
        if storage.delete_task(day_id, task_id):
            day = storage.get_day(day_id)
            logger.info(f"Task deleted: {task_id} from day {day_id}")
            return jsonify({
                "success": True,
                **_day_metrics(day)
            })
        return jsonify({"success": False, "error": "Task not found"}), 404
    except ValidationError as e:
        return handle_validation_error(e)


@app.route("/api/days/<day_id>/tasks/<task_id>", methods=["PUT"])
@validate_request_json
def edit_task(day_id: str, task_id: str):
    """Edit a task's title."""
    try:
        validate_uuid(day_id, "day_id")
        validate_uuid(task_id, "task_id")
        data = request.json
        
        title = validate_string(data.get("title", ""), "title", min_length=1, max_length=500)
        
        if storage.edit_task(day_id, task_id, title):
            logger.info(f"Task edited: {task_id} in day {day_id}")
            return jsonify({"success": True})
        
        return jsonify({"success": False, "error": "Task not found"}), 404
    except ValidationError as e:
        log_validation_error(e, f"/api/days/{day_id}/tasks/{task_id} [PUT]")
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error editing task: {e}", exc_info=True)
        return jsonify({"success": False, "error": "Internal server error"}), 500


@app.route("/api/days/<day_id>/tasks/<task_id>/expand", methods=["POST"])
def toggle_task_expand(day_id: str, task_id: str):
    """Toggle a task's expanded state."""
    try:
        validate_uuid(day_id, "day_id")
        validate_uuid(task_id, "task_id")
        
        if storage.toggle_task_expand(day_id, task_id):
            day = storage.get_day(day_id)
            task = day.get_task(task_id) if day else None
            logger.info(f"Task expand toggled: {task_id} in day {day_id}")
            return jsonify({
                "success": True,
                "is_expanded": task.is_expanded if task else False
            })
        return jsonify({"success": False, "error": "Task not found"}), 404
    except ValidationError as e:
        return handle_validation_error(e)


@app.route("/api/days/<day_id>/tasks/<task_id>/subtasks", methods=["POST"])
@validate_request_json
def add_subtask(day_id: str, task_id: str):
    """Add a subtask to a task."""
    try:
        validate_uuid(day_id, "day_id")
        validate_uuid(task_id, "task_id")
        data = request.json
        
        title = validate_string(data.get("title", ""), "title", min_length=1, max_length=500)
        
        subtask = storage.add_subtask(day_id, task_id, title)
        if subtask:
            day = storage.get_day(day_id)
            task = day.get_task(task_id) if day else None
            logger.info(f"Subtask added: {subtask} to task {task_id}")
            return jsonify({
                "success": True,
                "subtask": subtask,
                "subtask_progress": task.subtask_progress if task else (0, 0)
            })
        
        return jsonify({"success": False, "error": "Task not found"}), 404
    except ValidationError as e:
        log_validation_error(e, f"/api/days/{day_id}/tasks/{task_id}/subtasks [POST]")
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error adding subtask: {e}", exc_info=True)
        return jsonify({"success": False, "error": "Internal server error"}), 500


@app.route("/api/days/<day_id>/tasks/<task_id>/subtasks/<subtask_id>/toggle", methods=["POST"])
def toggle_subtask(day_id: str, task_id: str, subtask_id: str):
    """Toggle a subtask's completion status."""
    try:
        validate_uuid(day_id, "day_id")
        validate_uuid(task_id, "task_id")
        validate_uuid(subtask_id, "subtask_id")
        
        if storage.toggle_subtask(day_id, task_id, subtask_id):
            day = storage.get_day(day_id)
            task = day.get_task(task_id) if day else None
            subtask = task.get_subtask(subtask_id) if task else None
            logger.info(f"Subtask toggled: {subtask_id} in task {task_id}")
            return jsonify({
                "success": True,
                "completed": subtask.completed if subtask else False,
                "subtask_progress": task.subtask_progress if task else (0, 0)
            })
        return jsonify({"success": False, "error": "Subtask not found"}), 404
    except ValidationError as e:
        return handle_validation_error(e)


@app.route("/api/days/<day_id>/tasks/<task_id>/subtasks/<subtask_id>", methods=["DELETE"])
def delete_subtask(day_id: str, task_id: str, subtask_id: str):
    """Delete a subtask."""
    try:
        validate_uuid(day_id, "day_id")
        validate_uuid(task_id, "task_id")
        validate_uuid(subtask_id, "subtask_id")
        
        if storage.delete_subtask(day_id, task_id, subtask_id):
            day = storage.get_day(day_id)
            task = day.get_task(task_id) if day else None
            logger.info(f"Subtask deleted: {subtask_id} from task {task_id}")
            return jsonify({
                "success": True,
                "subtask_progress": task.subtask_progress if task else (0, 0)
            })
        return jsonify({"success": False, "error": "Subtask not found"}), 404
    except ValidationError as e:
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error deleting subtask: {e}", exc_info=True)
        return jsonify({"success": False, "error": "Internal server error"}), 500


@app.route("/api/statistics")
def get_statistics():
    """Get overall statistics."""
    stats = storage.get_statistics()
    return jsonify(stats.to_dict())


# ========================
# Collection Routes
# ========================

@app.route("/api/collections", methods=["GET"])
def get_collections():
    """Get all collections."""
    collections = storage.get_all_collections()
    return jsonify([c.to_dict() for c in collections])


@app.route("/api/collections", methods=["POST"])
@validate_request_json
def create_collection():
    """Create a new collection."""
    try:
        data = request.json
        
        # Validate required fields
        name = validate_string(
            data.get("name", ""),
            "name",
            min_length=1,
            max_length=200
        )
        
        # Validate optional fields
        description = validate_string(
            data.get("description", ""),
            "description",
            min_length=0,
            max_length=500,
            allow_empty=True
        )
        
        color = validate_color(data.get("color", "blue"))
        
        collection = storage.create_collection(name, description, color)
        logger.info(f"Collection created: {collection.id} - {name}")
        return jsonify(collection.to_dict()), 201
    
    except ValidationError as e:
        log_validation_error(e, "/api/collections [POST]")
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error creating collection: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/collections/<collection_id>", methods=["GET"])
def get_collection(collection_id):
    """Get a specific collection."""
    try:
        validate_uuid(collection_id, "collection_id")
        collection = storage.get_collection(collection_id)
        if not collection:
            return jsonify({"error": "Collection not found"}), 404
        return jsonify(collection.to_dict())
    except ValidationError as e:
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error getting collection: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/collections/<collection_id>", methods=["PUT"])
@validate_request_json
def update_collection(collection_id):
    """Update a collection."""
    try:
        validate_uuid(collection_id, "collection_id")
        data = request.json
        
        # Validate optional fields
        name = None
        if "name" in data:
            name = validate_string(data["name"], "name", min_length=1, max_length=200)
        
        description = None
        if "description" in data:
            description = validate_string(data["description"], "description", max_length=500, allow_empty=True)
        
        color = None
        if "color" in data:
            color = validate_color(data["color"])
        
        collection = storage.update_collection(collection_id, name=name, description=description, color=color)
        if not collection:
            return jsonify({"error": "Collection not found"}), 404
        
        logger.info(f"Collection updated: {collection_id}")
        return jsonify(collection.to_dict())
    
    except ValidationError as e:
        log_validation_error(e, f"/api/collections/{collection_id} [PUT]")
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error updating collection: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/collections/<collection_id>", methods=["DELETE"])
def delete_collection(collection_id):
    """Delete a collection."""
    try:
        validate_uuid(collection_id, "collection_id")
        if storage.delete_collection(collection_id):
            logger.info(f"Collection deleted: {collection_id}")
            return jsonify({"success": True})
        return jsonify({"error": "Collection not found"}), 404
    except ValidationError as e:
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error deleting collection: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/collections/<collection_id>/tasks", methods=["POST"])
@validate_request_json
def add_collection_task(collection_id):
    """Add a task to a collection."""
    try:
        validate_uuid(collection_id, "collection_id")
        data = request.json
        
        title = validate_string(data.get("title", ""), "title", min_length=1, max_length=500)
        priority = validate_priority(data.get("priority", "none"))
        tags = validate_list_of_strings(data.get("tags", []), "tags", max_items=10)
        notes = validate_string(data.get("notes", ""), "notes", max_length=1000, allow_empty=True)
        
        task = storage.add_collection_task(collection_id, title, priority, tags, notes)
        if not task:
            return jsonify({"error": "Collection not found"}), 404
        
        logger.info(f"Task added to collection {collection_id}: {task.id}")
        return jsonify(task.to_dict()), 201
    
    except ValidationError as e:
        log_validation_error(e, f"/api/collections/{collection_id}/tasks [POST]")
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error adding task to collection: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/collections/<collection_id>/tasks/<task_id>", methods=["PUT"])
@validate_request_json
def update_collection_task(collection_id, task_id):
    """Update a collection task."""
    try:
        validate_uuid(collection_id, "collection_id")
        validate_uuid(task_id, "task_id")
        data = request.json
        
        # Validate optional fields
        title = None
        if "title" in data:
            title = validate_string(data["title"], "title", min_length=1, max_length=500)
        
        priority = None
        if "priority" in data:
            priority = validate_priority(data["priority"])
        
        tags = None
        if "tags" in data:
            tags = validate_list_of_strings(data["tags"], "tags", max_items=10)
        
        notes = None
        if "notes" in data:
            notes = validate_string(data["notes"], "notes", max_length=1000, allow_empty=True)
        
        task = storage.update_collection_task(collection_id, task_id, title=title, priority=priority, tags=tags, notes=notes)
        if not task:
            return jsonify({"error": "Task or collection not found"}), 404
        
        logger.info(f"Task updated: {task_id} in collection {collection_id}")
        return jsonify(task.to_dict())
    
    except ValidationError as e:
        log_validation_error(e, f"/api/collections/{collection_id}/tasks/{task_id} [PUT]")
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error updating collection task: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/collections/<collection_id>/tasks/<task_id>/toggle", methods=["POST"])
def toggle_collection_task(collection_id, task_id):
    """Toggle a collection task's completion status."""
    try:
        validate_uuid(collection_id, "collection_id")
        validate_uuid(task_id, "task_id")
        
        task = storage.toggle_collection_task(collection_id, task_id)
        if not task:
            return jsonify({"error": "Task or collection not found"}), 404
        
        logger.info(f"Task toggled: {task_id} in collection {collection_id}")
        return jsonify(task.to_dict())
    
    except ValidationError as e:
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error toggling collection task: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/collections/<collection_id>/tasks/<task_id>", methods=["DELETE"])
def delete_collection_task(collection_id, task_id):
    """Delete a collection task."""
    try:
        validate_uuid(collection_id, "collection_id")
        validate_uuid(task_id, "task_id")
        
        if storage.delete_collection_task(collection_id, task_id):
            logger.info(f"Task deleted: {task_id} from collection {collection_id}")
            return jsonify({"success": True})
        return jsonify({"error": "Task or collection not found"}), 404
    
    except ValidationError as e:
        return handle_validation_error(e)
    except Exception as e:
        logger.error(f"Error deleting collection task: {e}", exc_info=True)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/export/json")
@app.route("/export/json")
def export_json():
    """Export data as JSON file."""
    data = storage.export_json()
    return Response(
        data,
        mimetype="application/json",
        headers={"Content-Disposition": "attachment;filename=dayplan_export.json"}
    )


@app.route("/api/export/csv")
@app.route("/export/csv")
def export_csv():
    """Export data as CSV file."""
    data = storage.export_csv()
    return Response(
        data,
        mimetype="text/csv",
        headers={"Content-Disposition": "attachment;filename=dayplan_export.csv"}
    )


if __name__ == "__main__":
    debug = app.config["DEBUG"]
    port = int(os.getenv("FLASK_PORT", 5000))
    host = os.getenv("FLASK_HOST", "127.0.0.1")
    
    env_name = os.getenv("FLASK_ENV", "production")
    print(f"\n{'='*60}")
    print(f"Starting DayPlan - {env_name.upper()} mode")
    print(f"Running on {host}:{port}")
    print(f"Debug: {debug}")
    print(f"{'='*60}\n")
    
    app.run(debug=debug, port=port, host=host)
