"""
DayPlan - A calendar-style day planner with task completion tracking.
"""

from datetime import date
from flask import Flask, render_template, request, jsonify, Response

from models import (
    get_display_date, get_short_date, get_day_number, get_weekday_name,
    get_month_year, get_month_weeks, get_month_bounds, is_today, is_past, is_future,
    CompletionStatus
)
from storage import storage


app = Flask(__name__)


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


@app.route("/api/days/<day_id>", methods=["DELETE"])
def delete_day(day_id: str):
    """Delete a day."""
    if storage.delete_day(day_id):
        return jsonify({"success": True})
    return jsonify({"success": False, "error": "Day not found"}), 404


@app.route("/api/days/<day_id>/tasks", methods=["POST"])
def add_task(day_id: str):
    """Add a task to a day."""
    data = request.get_json(silent=True) or {}
    title = data.get("title", "").strip()
    
    if not title:
        return jsonify({"success": False, "error": "Title required"}), 400
    
    task = storage.add_task(day_id, title)
    if task:
        day = storage.get_day(day_id)
        return jsonify({
            "success": True, 
            "task": task,
            **_day_metrics(day)
        })
    
    return jsonify({"success": False, "error": "Day not found"}), 404


@app.route("/api/days/<day_id>/tasks/<task_id>/toggle", methods=["POST"])
def toggle_task(day_id: str, task_id: str):
    """Toggle a task's completion status."""
    if storage.toggle_task(day_id, task_id):
        day = storage.get_day(day_id)
        task = day.get_task(task_id) if day else None
        stats = storage.get_statistics()
        return jsonify({
            "success": True,
            "completed": task.completed if task else False,
            **_day_metrics(day),
            "stats": stats.to_dict()
        })
    return jsonify({"success": False, "error": "Task not found"}), 404


@app.route("/api/days/<day_id>/tasks/<task_id>", methods=["DELETE"])
def delete_task(day_id: str, task_id: str):
    """Delete a task."""
    if storage.delete_task(day_id, task_id):
        day = storage.get_day(day_id)
        return jsonify({
            "success": True,
            **_day_metrics(day)
        })
    return jsonify({"success": False, "error": "Task not found"}), 404


@app.route("/api/days/<day_id>/tasks/<task_id>", methods=["PUT"])
def edit_task(day_id: str, task_id: str):
    """Edit a task's title."""
    data = request.get_json(silent=True) or {}
    title = data.get("title", "").strip()
    
    if not title:
        return jsonify({"success": False, "error": "Title required"}), 400
    
    if storage.edit_task(day_id, task_id, title):
        return jsonify({"success": True})
    
    return jsonify({"success": False, "error": "Task not found"}), 404


@app.route("/api/days/<day_id>/tasks/<task_id>/expand", methods=["POST"])
def toggle_task_expand(day_id: str, task_id: str):
    """Toggle a task's expanded state."""
    if storage.toggle_task_expand(day_id, task_id):
        day = storage.get_day(day_id)
        task = day.get_task(task_id) if day else None
        return jsonify({
            "success": True,
            "is_expanded": task.is_expanded if task else False
        })
    return jsonify({"success": False, "error": "Task not found"}), 404


@app.route("/api/days/<day_id>/tasks/<task_id>/subtasks", methods=["POST"])
def add_subtask(day_id: str, task_id: str):
    """Add a subtask to a task."""
    data = request.get_json(silent=True) or {}
    title = data.get("title", "").strip()
    
    if not title:
        return jsonify({"success": False, "error": "Title required"}), 400
    
    subtask = storage.add_subtask(day_id, task_id, title)
    if subtask:
        day = storage.get_day(day_id)
        task = day.get_task(task_id) if day else None
        return jsonify({
            "success": True,
            "subtask": subtask,
            "subtask_progress": task.subtask_progress if task else (0, 0)
        })
    
    return jsonify({"success": False, "error": "Task not found"}), 404


@app.route("/api/days/<day_id>/tasks/<task_id>/subtasks/<subtask_id>/toggle", methods=["POST"])
def toggle_subtask(day_id: str, task_id: str, subtask_id: str):
    """Toggle a subtask's completion status."""
    if storage.toggle_subtask(day_id, task_id, subtask_id):
        day = storage.get_day(day_id)
        task = day.get_task(task_id) if day else None
        subtask = task.get_subtask(subtask_id) if task else None
        return jsonify({
            "success": True,
            "completed": subtask.completed if subtask else False,
            "subtask_progress": task.subtask_progress if task else (0, 0)
        })
    return jsonify({"success": False, "error": "Subtask not found"}), 404


@app.route("/api/days/<day_id>/tasks/<task_id>/subtasks/<subtask_id>", methods=["DELETE"])
def delete_subtask(day_id: str, task_id: str, subtask_id: str):
    """Delete a subtask."""
    if storage.delete_subtask(day_id, task_id, subtask_id):
        day = storage.get_day(day_id)
        task = day.get_task(task_id) if day else None
        return jsonify({
            "success": True,
            "subtask_progress": task.subtask_progress if task else (0, 0)
        })
    return jsonify({"success": False, "error": "Subtask not found"}), 404


@app.route("/api/statistics")
def get_statistics():
    """Get overall statistics."""
    stats = storage.get_statistics()
    return jsonify(stats.to_dict())


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
    app.run(debug=True, port=5000)
