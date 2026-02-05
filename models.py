"""
Data models for the DayPlan application.
Enhanced with calendar support and default tasks.
"""

from __future__ import annotations
from dataclasses import dataclass, field, asdict
from datetime import datetime, date as date_type, timedelta
from enum import Enum
from typing import Optional
import uuid


# Default tasks that appear on new days
DEFAULT_TASKS = [
    "🧹 Clean-up",
    "📚 Classwork", 
    "💪 Work-out"
]


class CompletionStatus(Enum):
    """Represents the completion status of a day's tasks."""
    EMPTY = "empty"      # No tasks
    NONE = "none"        # Has tasks, none completed
    PARTIAL = "partial"  # Some tasks completed
    COMPLETE = "complete"  # All tasks completed


@dataclass
class SubTask:
    """Represents a subtask within a task."""
    id: str
    title: str
    completed: bool = False
    
    @classmethod
    def create(cls, title: str) -> "SubTask":
        return cls(
            id=str(uuid.uuid4()),
            title=title.strip(),
            completed=False
        )
    
    def to_dict(self) -> dict:
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: dict) -> "SubTask":
        return cls(**data)


@dataclass
class Task:
    """Represents a single task item with optional subtasks."""
    id: str
    title: str
    completed: bool = False
    created_at: str = field(default_factory=lambda: datetime.now().isoformat())
    completed_at: Optional[str] = None
    is_default: bool = False
    is_expanded: bool = True
    subtasks: list[SubTask] = field(default_factory=list)

    @classmethod
    def create(cls, title: str, is_default: bool = False) -> "Task":
        """Factory method to create a new task."""
        return cls(
            id=str(uuid.uuid4()),
            title=title.strip(),
            completed=False,
            created_at=datetime.now().isoformat(),
            is_default=is_default,
            subtasks=[]
        )

    def toggle(self) -> None:
        """Toggle the completion status of the task."""
        self.completed = not self.completed
        self.completed_at = datetime.now().isoformat() if self.completed else None
        # If completing parent, complete all subtasks
        if self.completed:
            for st in self.subtasks:
                st.completed = True

    def add_subtask(self, title: str) -> SubTask:
        """Add a subtask to this task."""
        subtask = SubTask.create(title)
        self.subtasks.append(subtask)
        return subtask

    def get_subtask(self, subtask_id: str) -> Optional[SubTask]:
        """Find a subtask by ID."""
        for st in self.subtasks:
            if st.id == subtask_id:
                return st
        return None

    def remove_subtask(self, subtask_id: str) -> bool:
        """Remove a subtask by ID."""
        for i, st in enumerate(self.subtasks):
            if st.id == subtask_id:
                self.subtasks.pop(i)
                return True
        return False

    @property
    def subtask_progress(self) -> tuple[int, int]:
        """Get (completed, total) subtask counts."""
        if not self.subtasks:
            return (0, 0)
        completed = sum(1 for st in self.subtasks if st.completed)
        return (completed, len(self.subtasks))

    @property
    def status(self) -> CompletionStatus:
        """Get the completion status of this task."""
        if self.completed:
            return CompletionStatus.COMPLETE
        elif self.subtasks:
            completed_subtasks = sum(1 for st in self.subtasks if st.completed)
            if completed_subtasks == len(self.subtasks):
                return CompletionStatus.COMPLETE
            elif completed_subtasks > 0:
                return CompletionStatus.PARTIAL
            return CompletionStatus.NONE
        return CompletionStatus.NONE

    def to_dict(self) -> dict:
        """Convert task to dictionary for JSON serialization."""
        return {
            "id": self.id,
            "title": self.title,
            "completed": self.completed,
            "created_at": self.created_at,
            "completed_at": self.completed_at,
            "is_default": self.is_default,
            "is_expanded": self.is_expanded,
            "subtasks": [st.to_dict() for st in self.subtasks]
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Task":
        """Create a Task from a dictionary."""
        subtasks = [SubTask.from_dict(st) for st in data.get("subtasks", [])]
        return cls(
            id=data["id"],
            title=data["title"],
            completed=data.get("completed", False),
            created_at=data.get("created_at", datetime.now().isoformat()),
            completed_at=data.get("completed_at"),
            is_default=data.get("is_default", False),
            is_expanded=data.get("is_expanded", True),
            subtasks=subtasks
        )


@dataclass
class Day:
    """Represents a single day with its tasks."""
    id: str
    date: str  # ISO date string (YYYY-MM-DD)
    tasks: list[Task] = field(default_factory=list)
    is_expanded: bool = True

    @classmethod
    def create(cls, day_date: date_type, expanded: bool = True, add_defaults: bool = True) -> "Day":
        """Factory method to create a new day."""
        day = cls(
            id=str(uuid.uuid4()),
            date=day_date.isoformat(),
            tasks=[],
            is_expanded=expanded
        )
        
        if add_defaults:
            for task_title in DEFAULT_TASKS:
                day.tasks.append(Task.create(task_title, is_default=True))
        
        return day

    @property
    def completion_status(self) -> CompletionStatus:
        """Calculate the completion status of this day."""
        if not self.tasks:
            return CompletionStatus.EMPTY
        
        completed_count = sum(1 for t in self.tasks if t.completed)
        
        if completed_count == 0:
            return CompletionStatus.NONE
        elif completed_count == len(self.tasks):
            return CompletionStatus.COMPLETE
        else:
            return CompletionStatus.PARTIAL

    @property
    def completion_percentage(self) -> int:
        """Calculate the completion percentage."""
        if not self.tasks:
            return 0
        return round((sum(1 for t in self.tasks if t.completed) / len(self.tasks)) * 100)

    @property
    def completed_count(self) -> int:
        """Get count of completed tasks."""
        return sum(1 for t in self.tasks if t.completed)

    @property
    def total_count(self) -> int:
        """Get total task count."""
        return len(self.tasks)

    def add_task(self, title: str, is_default: bool = False) -> Task:
        """Add a new task to this day."""
        task = Task.create(title, is_default)
        self.tasks.append(task)
        return task

    def get_task(self, task_id: str) -> Optional[Task]:
        """Find a task by ID."""
        for task in self.tasks:
            if task.id == task_id:
                return task
        return None

    def remove_task(self, task_id: str) -> bool:
        """Remove a task by ID. Returns True if removed."""
        for i, task in enumerate(self.tasks):
            if task.id == task_id:
                self.tasks.pop(i)
                return True
        return False

    def to_dict(self) -> dict:
        """Convert day to dictionary for JSON serialization."""
        return {
            "id": self.id,
            "date": self.date,
            "tasks": [t.to_dict() for t in self.tasks],
            "is_expanded": self.is_expanded
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Day":
        """Create a Day from a dictionary."""
        tasks = [Task.from_dict(t) for t in data.get("tasks", [])]
        return cls(
            id=data["id"],
            date=data["date"],
            tasks=tasks,
            is_expanded=data.get("is_expanded", True)
        )


@dataclass
class Statistics:
    """Aggregated statistics for the planner."""
    total_days: int = 0
    total_tasks: int = 0
    completed_tasks: int = 0
    average_completion: float = 0.0
    current_streak: int = 0
    best_streak: int = 0
    perfect_days: int = 0
    
    @property
    def completion_rate(self) -> float:
        """Calculate completion rate percentage."""
        if self.total_tasks == 0:
            return 0.0
        return round((self.completed_tasks / self.total_tasks) * 100, 1)
    
    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class MonthlyStatistics:
    """Statistics for a specific month."""
    year: int
    month: int
    days_with_tasks: int = 0
    total_tasks: int = 0
    completed_tasks: int = 0
    average_completion: float = 0.0
    perfect_days: int = 0
    best_day: Optional[str] = None  # Date of best completion
    most_productive_weekday: Optional[str] = None
    
    @property
    def completion_rate(self) -> float:
        """Calculate completion rate percentage."""
        if self.total_tasks == 0:
            return 0.0
        return round((self.completed_tasks / self.total_tasks) * 100, 1)
    
    def to_dict(self) -> dict:
        return {
            "year": self.year,
            "month": self.month,
            "days_with_tasks": self.days_with_tasks,
            "total_tasks": self.total_tasks,
            "completed_tasks": self.completed_tasks,
            "average_completion": self.average_completion,
            "perfect_days": self.perfect_days,
            "best_day": self.best_day,
            "most_productive_weekday": self.most_productive_weekday,
            "completion_rate": self.completion_rate
        }


def get_display_date(date_str: str) -> str:
    """Format a date string for display."""
    day_date = date_type.fromisoformat(date_str)
    today = date_type.today()
    
    diff = (day_date - today).days
    
    if diff == 0:
        return "Today"
    elif diff == -1:
        return "Yesterday"
    elif diff == 1:
        return "Tomorrow"
    else:
        return day_date.strftime("%A, %B %d")


def get_short_date(date_str: str) -> str:
    """Get a short date format."""
    day_date = date_type.fromisoformat(date_str)
    return day_date.strftime("%b %d")


def get_day_number(date_str: str) -> int:
    """Get the day number of the month."""
    return date_type.fromisoformat(date_str).day


def get_weekday_name(date_str: str) -> str:
    """Get abbreviated weekday name."""
    return date_type.fromisoformat(date_str).strftime("%a")


def get_month_year(date_str: str) -> str:
    """Get month and year string."""
    return date_type.fromisoformat(date_str).strftime("%B %Y")


def is_today(date_input) -> bool:
    """Check if date is today. Accepts string or date object."""
    if isinstance(date_input, str):
        return date_type.fromisoformat(date_input) == date_type.today()
    return date_input == date_type.today()


def is_past(date_input) -> bool:
    """Check if date is in the past. Accepts string or date object."""
    if isinstance(date_input, str):
        return date_type.fromisoformat(date_input) < date_type.today()
    return date_input < date_type.today()


def is_future(date_str: str) -> bool:
    """Check if date is in the future."""
    return date_type.fromisoformat(date_str) > date_type.today()


def get_week_dates(reference_date: date_type = None) -> list[date_type]:
    """Get all dates in the week containing the reference date (Sunday-Saturday)."""
    if reference_date is None:
        reference_date = date_type.today()

    start = reference_date - timedelta(days=(reference_date.weekday() + 1) % 7)
    return [start + timedelta(days=i) for i in range(7)]


def get_month_bounds(year: int, month: int) -> tuple[date_type, date_type]:
    """Get the first and last dates for a given month."""
    first_day = date_type(year, month, 1)
    if month == 12:
        last_day = date_type(year + 1, 1, 1) - timedelta(days=1)
    else:
        last_day = date_type(year, month + 1, 1) - timedelta(days=1)
    return first_day, last_day


def get_month_weeks(year: int, month: int) -> list[list[Optional[date_type]]]:
    """Get all weeks in a month as a list of 7-day lists."""
    first_day, last_day = get_month_bounds(year, month)
    
    weeks = []
    # Start weeks on Sunday to align with the UI headers.
    start_offset = (first_day.weekday() + 1) % 7
    current_week: list[Optional[date_type]] = [None] * start_offset
    
    current_date = first_day
    while current_date <= last_day:
        current_week.append(current_date)
        
        if len(current_week) == 7:
            weeks.append(current_week)
            current_week = []
        
        current_date += timedelta(days=1)
    
    if current_week:
        current_week.extend([None] * (7 - len(current_week)))
        weeks.append(current_week)
    
    return weeks


@dataclass
class CollectionTask:
    """Represents a task within a collection (not tied to a specific date)."""
    id: str
    title: str
    completed: bool = False
    created_at: str = field(default_factory=lambda: datetime.now().isoformat())
    completed_at: Optional[str] = None
    priority: str = "none"  # none, low, medium, high
    tags: list[str] = field(default_factory=list)
    notes: str = ""
    
    @classmethod
    def create(cls, title: str, priority: str = "none", tags: Optional[list[str]] = None, notes: str = "") -> "CollectionTask":
        """Factory method to create a new collection task."""
        return cls(
            id=str(uuid.uuid4()),
            title=title.strip(),
            completed=False,
            created_at=datetime.now().isoformat(),
            priority=priority,
            tags=tags or [],
            notes=notes
        )
    
    def toggle(self) -> None:
        """Toggle the completion status of the task."""
        self.completed = not self.completed
        self.completed_at = datetime.now().isoformat() if self.completed else None
    
    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "id": self.id,
            "title": self.title,
            "completed": self.completed,
            "created_at": self.created_at,
            "completed_at": self.completed_at,
            "priority": self.priority,
            "tags": self.tags,
            "notes": self.notes
        }
    
    @classmethod
    def from_dict(cls, data: dict) -> "CollectionTask":
        """Create from dictionary."""
        return cls(
            id=data["id"],
            title=data["title"],
            completed=data.get("completed", False),
            created_at=data.get("created_at", datetime.now().isoformat()),
            completed_at=data.get("completed_at"),
            priority=data.get("priority", "none"),
            tags=data.get("tags", []),
            notes=data.get("notes", "")
        )


@dataclass
class Collection:
    """Represents a collection of tasks organized by topic/project (not tied to dates)."""
    id: str
    name: str
    description: str = ""
    created_at: str = field(default_factory=lambda: datetime.now().isoformat())
    color: str = "blue"  # visual identifier
    tasks: list[CollectionTask] = field(default_factory=list)
    
    @classmethod
    def create(cls, name: str, description: str = "", color: str = "blue") -> "Collection":
        """Factory method to create a new collection."""
        return cls(
            id=str(uuid.uuid4()),
            name=name.strip(),
            description=description.strip(),
            created_at=datetime.now().isoformat(),
            color=color,
            tasks=[]
        )
    
    def add_task(self, title: str, priority: str = "none", tags: Optional[list[str]] = None, notes: str = "") -> CollectionTask:
        """Add a task to this collection."""
        task = CollectionTask.create(title, priority, tags, notes)
        self.tasks.append(task)
        return task
    
    def get_task(self, task_id: str) -> Optional[CollectionTask]:
        """Find a task by ID."""
        for task in self.tasks:
            if task.id == task_id:
                return task
        return None
    
    def remove_task(self, task_id: str) -> bool:
        """Remove a task by ID."""
        for i, task in enumerate(self.tasks):
            if task.id == task_id:
                self.tasks.pop(i)
                return True
        return False
    
    @property
    def completion_percentage(self) -> int:
        """Calculate completion percentage."""
        if not self.tasks:
            return 0
        completed = sum(1 for t in self.tasks if t.completed)
        return int((completed / len(self.tasks)) * 100)
    
    @property
    def completed_count(self) -> int:
        """Get number of completed tasks."""
        return sum(1 for t in self.tasks if t.completed)
    
    @property
    def total_count(self) -> int:
        """Get total number of tasks."""
        return len(self.tasks)
    
    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "created_at": self.created_at,
            "color": self.color,
            "tasks": [t.to_dict() for t in self.tasks]
        }
    
    @classmethod
    def from_dict(cls, data: dict) -> "Collection":
        """Create from dictionary."""
        tasks = [CollectionTask.from_dict(t) for t in data.get("tasks", [])]
        return cls(
            id=data["id"],
            name=data["name"],
            description=data.get("description", ""),
            created_at=data.get("created_at", datetime.now().isoformat()),
            color=data.get("color", "blue"),
            tasks=tasks
        )
