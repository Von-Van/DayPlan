"""
Data storage and persistence for DayPlan.
Enhanced with statistics and export functionality.
"""

import json
import csv
import os
from io import StringIO
from datetime import date, datetime, timedelta
from typing import Optional
from models import Day, Statistics, MonthlyStatistics, CompletionStatus


DATA_FILE = "dayplan_data.json"


class Storage:
    """Handles data persistence for the day planner."""

    def __init__(self, data_file: str = DATA_FILE):
        self.data_file = data_file
        self._days: dict[str, Day] = {}
        self._load()

    def _load(self) -> None:
        """Load data from JSON file."""
        if os.path.exists(self.data_file):
            try:
                with open(self.data_file, "r") as f:
                    data = json.load(f)
                    for day_data in data.get("days", []):
                        day = Day.from_dict(day_data)
                        self._days[day.id] = day
            except (json.JSONDecodeError, KeyError) as e:
                print(f"Error loading data: {e}")
                self._days = {}

    def _save(self) -> None:
        """Save data to JSON file."""
        data = {
            "days": [day.to_dict() for day in self._days.values()],
            "last_updated": datetime.now().isoformat()
        }
        with open(self.data_file, "w") as f:
            json.dump(data, f, indent=2)

    def get_all_days(self) -> list[Day]:
        """Get all days sorted by date (newest first)."""
        return sorted(self._days.values(), key=lambda d: d.date, reverse=True)

    def get_days_in_range(self, start: date, end: date) -> dict[str, Day]:
        """Get all days within a date range, keyed by date string."""
        result = {}
        for day in self._days.values():
            day_date = date.fromisoformat(day.date)
            if start <= day_date <= end:
                result[day.date] = day
        return result

    def get_day(self, day_id: str) -> Optional[Day]:
        """Get a day by ID."""
        return self._days.get(day_id)

    def get_day_by_date(self, day_date: date) -> Optional[Day]:
        """Get a day by date."""
        date_str = day_date.isoformat()
        for day in self._days.values():
            if day.date == date_str:
                return day
        return None

    def add_day(self, day_date: date, add_defaults: bool = True) -> Day:
        """Add a new day or return existing one."""
        existing = self.get_day_by_date(day_date)
        if existing:
            existing.is_expanded = True
            self._save()
            return existing

        day = Day.create(day_date, add_defaults=add_defaults)
        self._days[day.id] = day
        self._save()
        return day

    def delete_day(self, day_id: str) -> bool:
        """Delete a day by ID."""
        if day_id in self._days:
            del self._days[day_id]
            self._save()
            return True
        return False

    def toggle_day_expand(self, day_id: str) -> bool:
        """Toggle a day's expanded state."""
        day = self._days.get(day_id)
        if day:
            day.is_expanded = not day.is_expanded
            self._save()
            return True
        return False

    def add_task(self, day_id: str, title: str) -> Optional[dict]:
        """Add a task to a day."""
        day = self._days.get(day_id)
        if day and title.strip():
            task = day.add_task(title)
            self._save()
            return task.to_dict()
        return None

    def toggle_task(self, day_id: str, task_id: str) -> bool:
        """Toggle a task's completion status."""
        day = self._days.get(day_id)
        if day:
            task = day.get_task(task_id)
            if task:
                task.toggle()
                self._save()
                return True
        return False

    def delete_task(self, day_id: str, task_id: str) -> bool:
        """Delete a task from a day."""
        day = self._days.get(day_id)
        if day:
            if day.remove_task(task_id):
                self._save()
                return True
        return False

    def edit_task(self, day_id: str, task_id: str, title: str) -> bool:
        """Edit a task's title."""
        day = self._days.get(day_id)
        if day and title.strip():
            task = day.get_task(task_id)
            if task:
                task.title = title.strip()
                self._save()
                return True
        return False

    def ensure_today_exists(self) -> Day:
        """Make sure today's day entry exists."""
        today = date.today()
        return self.add_day(today)

    def get_statistics(self) -> Statistics:
        """Calculate overall statistics."""
        stats = Statistics()
        
        if not self._days:
            return stats
        
        days_list = list(self._days.values())
        stats.total_days = len(days_list)
        
        # Calculate task stats
        total_tasks = 0
        completed_tasks = 0
        perfect_days = 0
        completion_rates = []
        
        for day in days_list:
            if day.tasks:
                total_tasks += len(day.tasks)
                completed_tasks += day.completed_count
                completion_rates.append(day.completion_percentage)
                if day.completion_status == CompletionStatus.COMPLETE:
                    perfect_days += 1
        
        stats.total_tasks = total_tasks
        stats.completed_tasks = completed_tasks
        stats.perfect_days = perfect_days
        
        if completion_rates:
            stats.average_completion = round(sum(completion_rates) / len(completion_rates), 1)
        
        # Calculate streaks
        sorted_days = sorted(days_list, key=lambda d: d.date, reverse=True)
        current_streak = 0
        best_streak = 0
        temp_streak = 0
        
        for day in sorted_days:
            if day.completion_status == CompletionStatus.COMPLETE:
                temp_streak += 1
                best_streak = max(best_streak, temp_streak)
            else:
                if temp_streak > 0 and current_streak == 0:
                    # Check if this was the most recent streak
                    current_streak = temp_streak
                temp_streak = 0
        
        # Handle case where streak continues to the beginning
        best_streak = max(best_streak, temp_streak)
        if current_streak == 0:
            current_streak = temp_streak
            
        stats.current_streak = current_streak
        stats.best_streak = best_streak
        
        return stats

    def get_monthly_statistics(self, year: int, month: int) -> MonthlyStatistics:
        """Calculate statistics for a specific month."""
        stats = MonthlyStatistics(year=year, month=month)
        
        # Get first and last day of month
        first_day = date(year, month, 1)
        if month == 12:
            last_day = date(year + 1, 1, 1) - timedelta(days=1)
        else:
            last_day = date(year, month + 1, 1) - timedelta(days=1)
        
        days_in_month = self.get_days_in_range(first_day, last_day)
        
        if not days_in_month:
            return stats
        
        # Track weekday productivity
        weekday_completions: dict[int, list[float]] = {i: [] for i in range(7)}
        best_completion = 0.0
        best_day_date = None
        
        for date_str, day in days_in_month.items():
            if day.tasks:
                stats.days_with_tasks += 1
                stats.total_tasks += len(day.tasks)
                stats.completed_tasks += day.completed_count
                
                completion = day.completion_percentage
                
                # Track best day
                if completion > best_completion:
                    best_completion = completion
                    best_day_date = date_str
                
                # Track weekday productivity
                day_date = date.fromisoformat(date_str)
                weekday_completions[day_date.weekday()].append(completion)
                
                if day.completion_status == CompletionStatus.COMPLETE:
                    stats.perfect_days += 1
        
        # Calculate average
        if stats.days_with_tasks > 0:
            completion_rates = [d.completion_percentage for d in days_in_month.values() if d.tasks]
            stats.average_completion = round(sum(completion_rates) / len(completion_rates), 1)
        
        stats.best_day = best_day_date
        
        # Find most productive weekday
        weekday_names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        best_weekday_avg = 0
        best_weekday = None
        for weekday, completions in weekday_completions.items():
            if completions:
                avg = sum(completions) / len(completions)
                if avg > best_weekday_avg:
                    best_weekday_avg = avg
                    best_weekday = weekday_names[weekday]
        
        stats.most_productive_weekday = best_weekday
        
        return stats

    def add_subtask(self, day_id: str, task_id: str, title: str) -> Optional[dict]:
        """Add a subtask to a task."""
        day = self._days.get(day_id)
        if day and title.strip():
            task = day.get_task(task_id)
            if task:
                subtask = task.add_subtask(title)
                self._save()
                return subtask.to_dict()
        return None

    def toggle_subtask(self, day_id: str, task_id: str, subtask_id: str) -> bool:
        """Toggle a subtask's completion status."""
        day = self._days.get(day_id)
        if day:
            task = day.get_task(task_id)
            if task:
                subtask = task.get_subtask(subtask_id)
                if subtask:
                    subtask.completed = not subtask.completed
                    self._save()
                    return True
        return False

    def delete_subtask(self, day_id: str, task_id: str, subtask_id: str) -> bool:
        """Delete a subtask."""
        day = self._days.get(day_id)
        if day:
            task = day.get_task(task_id)
            if task:
                if task.remove_subtask(subtask_id):
                    self._save()
                    return True
        return False

    def toggle_task_expand(self, day_id: str, task_id: str) -> bool:
        """Toggle a task's expanded state."""
        day = self._days.get(day_id)
        if day:
            task = day.get_task(task_id)
            if task:
                task.is_expanded = not task.is_expanded
                self._save()
                return True
        return False

    def export_json(self) -> str:
        """Export all data as JSON string."""
        data = {
            "days": [day.to_dict() for day in self.get_all_days()],
            "statistics": self.get_statistics().to_dict(),
            "exported_at": datetime.now().isoformat()
        }
        return json.dumps(data, indent=2)

    def export_csv(self) -> str:
        """Export all data as CSV string."""
        output = StringIO()
        writer = csv.writer(output)
        
        # Header
        writer.writerow([
            "Date", "Task", "Completed", "Is Default", 
            "Created At", "Completed At"
        ])
        
        # Data rows
        for day in self.get_all_days():
            for task in day.tasks:
                writer.writerow([
                    day.date,
                    task.title,
                    "Yes" if task.completed else "No",
                    "Yes" if task.is_default else "No",
                    task.created_at,
                    task.completed_at or ""
                ])
        
        return output.getvalue()


# Global storage instance
storage = Storage()
