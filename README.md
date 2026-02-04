# DayPlan 📅

A modern, calendar-style day planner with task management, subtasks, and visual completion tracking. Built with Python and Flask.

![Python](https://img.shields.io/badge/Python-3.11+-blue.svg)
![Flask](https://img.shields.io/badge/Flask-3.0+-green.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## Features

### 📆 Calendar View
- Monthly calendar grid with intuitive navigation
- Click any day to view and manage tasks
- Today highlighted automatically
- Visual completion indicators on each day

### 📊 Statistics Dashboard
- **All-Time Stats**: Track total days, tasks, and completion rate
- **Monthly Summary**: Active days, tasks completed, and monthly progress
- Real-time updates as you complete tasks

### ✅ Task Management
- **Default Tasks**: Each day starts with customizable defaults (Clean-up, Classwork, Work-out)
- **Subtasks**: Break down tasks into smaller, manageable subtasks
- **Collapsible Tasks**: Expand/collapse tasks to show/hide subtasks
- **Progress Tracking**: Visual progress bars for subtask completion

### 🎨 Visual Completion Tracking
Color-coded indicators show task status at a glance:
- 🟢 **Green** - All tasks complete
- 🟡 **Yellow** - Some tasks complete  
- 🔴 **Red** - No tasks complete
- ⚪ **Gray** - No tasks yet

### 💾 Data Management
- **Persistent Storage**: Tasks automatically saved to JSON
- **Export Options**: Download data as JSON or CSV
- **No Database Required**: Simple file-based storage

### 🌙 Modern Dark Theme
- Clean, professional dark interface
- Smooth animations and transitions
- Responsive 3-panel layout
- Works on desktop and mobile

## Screenshots

The app features a modern 3-panel interface:
- **Left Sidebar**: All-time statistics and export options
- **Center**: Monthly calendar with navigation
- **Right Panel**: Selected day's tasks with subtask management

## Installation

### Prerequisites
- Python 3.11 or higher

### Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/DayPlan.git
   cd DayPlan
   ```

2. **Create a virtual environment**
   ```bash
   python -m venv .venv
   source .venv/bin/activate  # On Windows: .venv\Scripts\activate
   ```

3. **Install dependencies**
   ```bash
   pip install -r requirements.txt
   ```

4. **Run the application**
   ```bash
   python app.py
   ```

5. **Open in browser**
   Navigate to `http://localhost:5000`

## Usage

### Calendar Navigation
- Use the **‹** and **›** buttons to navigate between months
- Click any day to select it and view tasks in the right panel
- Today is automatically selected when viewing the current month

### Managing Tasks
- Add new tasks using the input field at the bottom of the day panel
- Click the checkbox to mark tasks complete
- Click the **▶** arrow to expand a task and see subtasks
- Click **×** to delete a task

### Working with Subtasks
- Expand a task to reveal the subtask section
- Type in the subtask input and click **+** to add
- Check off subtasks as you complete them
- Progress bar shows subtask completion percentage

### Exporting Data
- Click **📄 Export JSON** for full data backup
- Click **📊 Export CSV** for spreadsheet-compatible format

## Project Structure

```
DayPlan/
├── app.py              # Flask application & API routes
├── models.py           # Data models (Task, SubTask, Day, Statistics)
├── storage.py          # JSON persistence layer
├── requirements.txt    # Python dependencies
├── dayplan_data.json   # Data storage (auto-generated)
├── templates/
│   └── index.html      # Main Jinja2 template
└── static/
    ├── styles.css      # Dark theme styles
    └── app.js          # Client-side JavaScript
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/` | Main calendar view |
| GET | `/export/json` | Export all data as JSON |
| GET | `/export/csv` | Export all data as CSV |
| POST | `/api/days` | Create a new day |
| GET | `/api/days/<id>` | Get day details |
| DELETE | `/api/days/<id>` | Delete a day |
| POST | `/api/days/<id>/tasks` | Add task to day |
| POST | `/api/days/<id>/tasks/<task_id>/toggle` | Toggle task completion |
| DELETE | `/api/days/<id>/tasks/<task_id>` | Delete task |
| POST | `/api/days/<id>/tasks/<task_id>/expand` | Toggle task expand/collapse |
| POST | `/api/days/<id>/tasks/<task_id>/subtasks` | Add subtask |
| POST | `/api/days/<id>/tasks/<task_id>/subtasks/<subtask_id>/toggle` | Toggle subtask |
| DELETE | `/api/days/<id>/tasks/<task_id>/subtasks/<subtask_id>` | Delete subtask |

## Technology Stack

- **Backend**: Python 3.11+, Flask 3.0+
- **Frontend**: Vanilla JavaScript, CSS3 with CSS Variables
- **Storage**: JSON file (no database required)
- **Templating**: Jinja2
- **Fonts**: Inter (Google Fonts)

## Design Decisions

- **No database** - Uses JSON file storage for simplicity and portability
- **Vanilla JS** - No frontend framework for minimal complexity and fast loading
- **Dataclasses** - Clean Python data models with type hints
- **RESTful API** - Clean separation between UI and data operations
- **Dark Theme** - Modern, eye-friendly interface with CSS custom properties
- **3-Panel Layout** - Optimal information density with persistent day panel

## Customization

### Default Tasks
Edit `models.py` to customize the default tasks that appear on new days:

```python
DEFAULT_TASKS = [
    "🧹 Clean-up",
    "📚 Classwork", 
    "💪 Work-out"
]
```

### Theme Colors
Modify CSS variables in `static/styles.css` to customize the color scheme:

```css
:root {
    --bg-primary: #0d1117;
    --accent-primary: #58a6ff;
    --accent-success: #3fb950;
    /* ... */
}
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

Built with ❤️ using Python and Flask
