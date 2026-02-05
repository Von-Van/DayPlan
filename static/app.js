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

let currentCollection = null;
let allCollections = [];

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
    
    // Load collections when collections tab is active
    const collectionsTab = document.getElementById('collections-tab');
    if (collectionsTab && collectionsTab.classList.contains('active')) {
        loadCollections();
    }
});

// ========================================
// Tab Navigation
// ========================================

function switchTab(tabName) {
    // Hide all tabs and deactivate buttons
    document.querySelectorAll('.tab-content').forEach(tab => {
        tab.classList.remove('active');
    });
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.classList.remove('active');
    });
    
    // Show selected tab and activate button
    const tab = document.getElementById(`${tabName}-tab`);
    if (tab) {
        tab.classList.add('active');
    }
    
    const btn = document.querySelector(`.tab-btn[data-tab="${tabName}"]`);
    if (btn) {
        btn.classList.add('active');
    }
    
    // Load collections if switching to collections tab
    if (tabName === 'collections') {
        loadCollections();
    }
}

// ========================================
// Collections Management
// ========================================

async function loadCollections() {
    try {
        const response = await fetch('/api/collections');
        if (!response.ok) throw new Error('Failed to load collections');
        
        allCollections = await response.json();
        renderCollections();
    } catch (error) {
        console.error('Error loading collections:', error);
        const container = document.getElementById('collectionsContainer');
        if (container) {
            container.innerHTML = '<div class="loading-message">Error loading collections</div>';
        }
    }
}

function renderCollections() {
    const container = document.getElementById('collectionsContainer');
    if (!container) return;
    
    if (allCollections.length === 0) {
        container.innerHTML = `
            <div class="empty-collections">
                <p>📚 No collections yet. Create one to get started!</p>
            </div>
        `;
        return;
    }
    
    container.innerHTML = allCollections.map(collection => `
        <div class="collection-card" onclick="selectCollection('${collection.id}')">
            <div class="collection-card-header">
                <h3 class="collection-title">${escapeHtml(collection.name)}</h3>
                <button class="btn-icon" onclick="event.stopPropagation(); showCollectionMenu('${collection.id}')" title="Options">⋮</button>
            </div>
            ${collection.description ? `<div class="collection-description">${escapeHtml(collection.description)}</div>` : ''}
            <div class="collection-meta">
                <span class="collection-meta-item">📋 ${collection.tasks.length} tasks</span>
                <span class="collection-meta-item">✅ ${collection.tasks.filter(t => t.completed).length} done</span>
            </div>
            <div class="collection-progress">
                <div class="progress-bar">
                    <div class="progress-fill" style="width: ${collection.tasks.length > 0 ? (collection.tasks.filter(t => t.completed).length / collection.tasks.length * 100) : 0}%"></div>
                </div>
                <span class="progress-text">${collection.tasks.length > 0 ? Math.round(collection.tasks.filter(t => t.completed).length / collection.tasks.length * 100) : 0}%</span>
            </div>
            <div class="collection-tasks expanded">
                <div class="collection-task-list">
                    ${collection.tasks.slice(0, 5).map(task => `
                        <div class="collection-task-item ${task.completed ? 'completed' : ''}">
                            <input type="checkbox" ${task.completed ? 'checked' : ''} 
                                   onchange="toggleCollectionTask('${collection.id}', '${task.id}')">
                            <span class="collection-task-title">${escapeHtml(task.title)}</span>
                            ${task.priority && task.priority !== 'none' ? `<span class="collection-task-priority ${task.priority}">${task.priority}</span>` : ''}
                            <button class="btn-icon-sm" onclick="deleteCollectionTask('${collection.id}', '${task.id}')" title="Delete">×</button>
                        </div>
                    `).join('')}
                    ${collection.tasks.length > 5 ? `<div class="loading-message">+${collection.tasks.length - 5} more tasks</div>` : ''}
                </div>
                <div class="add-collection-task">
                    <input type="text" placeholder="Add task..." id="task-input-${collection.id}">
                    <button onclick="addCollectionTask('${collection.id}')">+</button>
                </div>
            </div>
        </div>
    `).join('');
}

function selectCollection(collectionId) {
    currentCollection = allCollections.find(c => c.id === collectionId);
    document.querySelectorAll('.collection-card').forEach(card => {
        card.classList.remove('selected');
    });
    event.currentTarget.classList.add('selected');
}

async function createCollection() {
    const name = prompt('Collection name:');
    if (!name) return;
    
    const description = prompt('Description (optional):');
    
    try {
        const response = await fetch('/api/collections', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name, description: description || '' })
        });
        
        if (response.ok) {
            loadCollections();
        }
    } catch (error) {
        console.error('Error creating collection:', error);
    }
}

function showNewCollectionForm() {
    createCollection();
}

async function deleteCollectionTask(collectionId, taskId) {
    if (!confirm('Delete this task?')) return;
    
    try {
        const response = await fetch(`/api/collections/${collectionId}/tasks/${taskId}`, {
            method: 'DELETE'
        });
        
        if (response.ok) {
            loadCollections();
        }
    } catch (error) {
        console.error('Error deleting task:', error);
    }
}

async function toggleCollectionTask(collectionId, taskId) {
    try {
        const response = await fetch(`/api/collections/${collectionId}/tasks/${taskId}/toggle`, {
            method: 'POST'
        });
        
        if (response.ok) {
            loadCollections();
        }
    } catch (error) {
        console.error('Error toggling task:', error);
    }
}

async function addCollectionTask(collectionId) {
    const input = document.getElementById(`task-input-${collectionId}`);
    const title = input.value.trim();
    
    if (!title) return;
    
    try {
        const response = await fetch(`/api/collections/${collectionId}/tasks`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ title })
        });
        
        if (response.ok) {
            input.value = '';
            loadCollections();
        }
    } catch (error) {
        console.error('Error adding task:', error);
    }
}

function showCollectionMenu(collectionId) {
    const actions = `
        Edit: Update collection details
        Delete: Remove collection permanently
    `;
    alert('Collection options (in development)');
}

// Utility function to escape HTML
function escapeHtml(text) {
    const map = {
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#039;'
    };
    return text.replace(/[&<>"']/g, m => map[m]);
}
