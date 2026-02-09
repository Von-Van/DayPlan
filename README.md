# DayPlan

A calendar-style day planner with tasks, subtasks, and completion tracking. Built with Python and Flask.

## Project Status

This repo is a **portfolio preview** and **intentionally incomplete**. Core flows are working, but some features and polish are not finished yet.
See `STATUS.md` for a concise roadmap.

**What works now**
- Monthly calendar view with navigation
- Day selection and task management
- Subtasks with progress display
- Basic statistics (all-time and monthly)
- JSON/CSV export

**Not finished (yet)**
- Auth or multi-user support
- Recurring tasks
- More robust data validation
- Tests and CI

If you are reviewing this as a portfolio piece, the focus is on clarity, structure, and end-to-end flow rather than feature completeness.

## Features

- Monthly calendar grid with task indicators
- Task and subtask management with completion tracking
- Statistics dashboard (all-time + monthly)
- JSON file persistence (no DB required)
- JSON/CSV export

## Quickstart

1. Clone the repo
   ```bash
   git clone https://github.com/yourusername/DayPlan.git
   cd DayPlan
   ```

2. Create a virtual environment
   ```bash
   python -m venv .venv
   source .venv/bin/activate  # On Windows: .venv\\Scripts\\activate
   ```

3. Install dependencies
   ```bash
   pip install -r requirements.txt
   ```

4. Run the app
   ```bash
   python app.py
   ```

5. Open in browser
   ```
   http://localhost:5000
   ```

## Data and Storage

Data is stored in a local JSON file named `dayplan_data.json`. This file is **not** committed to the repo and will be created at runtime.

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/` | Main calendar view |
| GET | `/export/json` | Export all data as JSON |
| GET | `/export/csv` | Export all data as CSV |
| GET | `/api/export/json` | Export all data as JSON (alias) |
| GET | `/api/export/csv` | Export all data as CSV (alias) |
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

## Tech Stack

- Python 3.11+
- Flask 3.0+
- Jinja2 templates
- Vanilla JS + CSS

## License

MIT. See `LICENSE`.
