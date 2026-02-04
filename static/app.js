// ========================================
// DayPlan - Application JavaScript
// ========================================

/**
 * Select a day and reload with the day panel showing
 */
function selectDay(dayId, date) {
    const currentUrl = new URL(window.location.href);
    currentUrl.searchParams.set('day', dayId);
    window.location.href = currentUrl.toString();
}

/**
 * Add a task from the panel
 */
async function addPanelTask(dayId) {
    const input = document.getElementById('newTaskInput');
    const title = input.value.trim();
    
    if (!title) return;
    
    try {
        const response = await fetch(`/api/days/${dayId}/tasks`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ title })
        });
        
        if (response.ok) {
            window.location.reload();
        }
    } catch (error) {
        console.error('Error adding task:', error);
    }
}

/**
 * Toggle task completion status
 */
async function toggleTask(dayId, taskId) {
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/toggle`, {
            method: 'POST'
        });
        
        if (response.ok) {
            window.location.reload();
        }
    } catch (error) {
        console.error('Error toggling task:', error);
    }
}

/**
 * Delete a task
 */
async function deleteTask(dayId, taskId) {
    if (!confirm('Delete this task?')) return;
    
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}`, {
            method: 'DELETE'
        });
        
        if (response.ok) {
            window.location.reload();
        }
    } catch (error) {
        console.error('Error deleting task:', error);
    }
}

/**
 * Toggle task expansion to show/hide subtasks
 */
async function toggleTaskExpand(dayId, taskId) {
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/expand`, {
            method: 'POST'
        });
        
        if (response.ok) {
            window.location.reload();
        }
    } catch (error) {
        console.error('Error toggling task expansion:', error);
    }
}

/**
 * Add a subtask to a task
 */
async function addSubtask(dayId, taskId) {
    const input = document.getElementById(`subtask-input-${taskId}`);
    const title = input.value.trim();
    
    if (!title) return;
    
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/subtasks`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ title })
        });
        
        if (response.ok) {
            window.location.reload();
        }
    } catch (error) {
        console.error('Error adding subtask:', error);
    }
}

/**
 * Toggle subtask completion
 */
async function toggleSubtask(dayId, taskId, subtaskId) {
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/subtasks/${subtaskId}/toggle`, {
            method: 'POST'
        });
        
        if (response.ok) {
            window.location.reload();
        }
    } catch (error) {
        console.error('Error toggling subtask:', error);
    }
}

/**
 * Delete a subtask
 */
async function deleteSubtask(dayId, taskId, subtaskId) {
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/subtasks/${subtaskId}`, {
            method: 'DELETE'
        });
        
        if (response.ok) {
            window.location.reload();
        }
    } catch (error) {
        console.error('Error deleting subtask:', error);
    }
}

// ========================================
// Mobile Sidebar Toggle
// ========================================

function toggleMobileSidebar() {
    const sidebar = document.querySelector('.sidebar-right');
    sidebar.classList.toggle('open');
}

// Close sidebar when clicking outside on mobile
document.addEventListener('click', (e) => {
    const sidebar = document.querySelector('.sidebar-right');
    if (sidebar && sidebar.classList.contains('open')) {
        if (!sidebar.contains(e.target) && !e.target.closest('.calendar-day')) {
            sidebar.classList.remove('open');
        }
    }
});

// ========================================
// Keyboard Shortcuts
// ========================================

document.addEventListener('keydown', (e) => {
    // Escape to close any open state
    if (e.key === 'Escape') {
        const sidebar = document.querySelector('.sidebar-right');
        if (sidebar) sidebar.classList.remove('open');
    }
});

// ========================================
// Initialize on page load
// ========================================

document.addEventListener('DOMContentLoaded', () => {
    // Auto-focus new task input if day panel is visible
    const newTaskInput = document.getElementById('newTaskInput');
    if (newTaskInput && window.innerWidth > 1200) {
        // Don't steal focus on larger screens - let user click
    }
    
    // Handle responsive sidebar on mobile
    if (window.innerWidth <= 1200) {
        const selectedDay = document.querySelector('.calendar-day.selected');
        if (selectedDay) {
            const sidebar = document.querySelector('.sidebar-right');
            if (sidebar) sidebar.classList.add('open');
        }
    }
});
