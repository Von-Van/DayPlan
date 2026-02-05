// ========================================
// DayPlan - Application JavaScript
// ========================================

// ========================================
// Toast Notification System
// ========================================

/**
 * Toast notification for user feedback
 */
class Toast {
    constructor(message, type = 'info', duration = 3000) {
        this.message = message;
        this.type = type; // 'success', 'error', 'info', 'warning'
        this.duration = duration;
        this.create();
    }
    
    create() {
        const toast = document.createElement('div');
        toast.className = `toast toast-${this.type}`;
        toast.textContent = this.message;
        toast.setAttribute('role', 'alert');
        toast.setAttribute('aria-live', 'polite');
        
        const container = document.getElementById('toastContainer') || this.createContainer();
        container.appendChild(toast);
        
        // Trigger animation
        requestAnimationFrame(() => {
            toast.classList.add('show');
        });
        
        // Auto-remove
        setTimeout(() => {
            toast.classList.remove('show');
            setTimeout(() => toast.remove(), 300);
        }, this.duration);
    }
    
    createContainer() {
        const container = document.createElement('div');
        container.id = 'toastContainer';
        container.className = 'toast-container';
        container.setAttribute('role', 'region');
        container.setAttribute('aria-label', 'Notifications');
        document.body.appendChild(container);
        return container;
    }
    
    static success(message) {
        return new Toast(message, 'success', 3000);
    }
    
    static error(message) {
        return new Toast(message, 'error', 5000);
    }
    
    static info(message) {
        return new Toast(message, 'info', 3000);
    }
    
    static warning(message) {
        return new Toast(message, 'warning', 4000);
    }
}

// ========================================
// DOM Manipulation Helpers
// ========================================

/**
 * Update task in DOM without full reload
 */
function updateTaskInDOM(dayId, task) {
    const taskElement = document.querySelector(`[data-task-id="${task.id}"]`);
    if (!taskElement) return;
    
    // Update completion state
    const checkbox = taskElement.querySelector('.task-checkbox');
    if (checkbox) {
        checkbox.checked = task.completed;
    }
    
    // Update visual state
    taskElement.classList.remove('completed', 'pending');
    if (task.completed) {
        taskElement.classList.add('completed');
    } else {
        taskElement.classList.add('pending');
    }
}

/**
 * Add task to DOM without full reload
 */
function addTaskToDOM(dayId, task) {
    const taskList = document.getElementById('taskList');
    if (!taskList) return;
    
    // Remove empty state if present
    removeEmptyTaskState();
    
    const taskHTML = `
        <div class="task-item pending" data-task-id="${task.id}">
            <div class="task-header">
                <input type="checkbox" 
                       class="task-checkbox"
                       id="task-${task.id}"
                       ${task.completed ? 'checked' : ''} 
                       onchange="toggleTask('${dayId}', '${task.id}')"
                       aria-label="Mark '${escapeHtml(task.title)}' as complete">
                <label for="task-${task.id}" class="task-title" data-editable="true" onclick="enableTaskEdit(event, '${dayId}', '${task.id}')">${escapeHtml(task.title)}</label>
                <button class="btn-icon delete-btn" 
                        onclick="deleteTask('${dayId}', '${task.id}')" 
                        aria-label="Delete task '${escapeHtml(task.title)}'"
                        title="Delete task">×</button>
            </div>
        </div>
    `;
    
    taskList.insertAdjacentHTML('beforeend', taskHTML);
    
    // Animate in
    const newTask = taskList.lastElementChild;
    newTask.style.opacity = '0';
    newTask.style.transform = 'translateY(-10px)';
    
    requestAnimationFrame(() => {
        newTask.style.opacity = '1';
        newTask.style.transform = 'translateY(0)';
        newTask.style.transition = 'all 0.2s ease';
    });
}

/**
 * Remove task from DOM
 */
function removeTaskFromDOM(taskId) {
    const taskElement = document.querySelector(`[data-task-id="${taskId}"]`);
    if (!taskElement) return;
    
    taskElement.style.opacity = '0';
    taskElement.style.transform = 'translateX(-20px)';
    taskElement.style.transition = 'all 0.2s ease';
    
    setTimeout(() => {
        taskElement.remove();
        
        // Show empty state if no tasks remain
        const taskList = document.getElementById('taskList');
        if (taskList && taskList.children.length === 0) {
            showEmptyTaskState(taskList);
        }
    }, 200);
}

/**
 * Show empty state in task list
 */
function showEmptyTaskState(taskList) {
    taskList.innerHTML = `
        <div class="empty-tasks" aria-label="No tasks">
            <span class="empty-icon">✨</span>
            <p>No tasks yet</p>
            <p class="empty-hint">Add a task below to get started</p>
        </div>
    `;
}

/**
 * Remove empty state when adding first task
 */
function removeEmptyTaskState() {
    const emptyState = document.querySelector('#taskList .empty-tasks');
    if (emptyState) emptyState.remove();
}

/**
 * Get CSRF token from the meta tag
 */
function getCSRFToken() {
    return document.querySelector('meta[name="csrf-token"]').getAttribute('content');
}

/**
 * Create fetch headers with CSRF token for state-changing requests
 */
function getAuthHeaders(includeCSRF = true) {
    const headers = { 'Content-Type': 'application/json' };
    if (includeCSRF) {
        headers['X-CSRFToken'] = getCSRFToken();
    }
    return headers;
}

// ========================================
// Modal Dialog System
// ========================================

/**
 * Show a custom confirmation dialog (replaces native confirm())
 * Returns a Promise that resolves true/false
 */
function showConfirmation(title, message, confirmLabel = 'Delete') {
    return new Promise((resolve) => {
        const titleEl = document.getElementById('confirmTitle');
        const messageEl = document.getElementById('confirmMessage');
        const okBtn = document.getElementById('confirmOkBtn');
        const cancelBtn = document.getElementById('confirmCancelBtn');
        
        titleEl.textContent = title;
        messageEl.textContent = message;
        okBtn.textContent = confirmLabel;
        
        // Clean up previous handlers
        const newOkBtn = okBtn.cloneNode(true);
        const newCancelBtn = cancelBtn.cloneNode(true);
        okBtn.parentNode.replaceChild(newOkBtn, okBtn);
        cancelBtn.parentNode.replaceChild(newCancelBtn, cancelBtn);
        
        newOkBtn.addEventListener('click', () => {
            closeModal('confirmModal');
            resolve(true);
        });
        
        newCancelBtn.addEventListener('click', () => {
            closeModal('confirmModal');
            resolve(false);
        });
        
        openModal('confirmModal');
        
        // Focus the cancel button by default (safer option)
        setTimeout(() => newCancelBtn.focus(), 100);
    });
}

/**
 * Set loading state on a button
 */
function setButtonLoading(button, loadingText = 'Loading...') {
    if (!button) return;
    button._originalText = button.textContent;
    button._originalDisabled = button.disabled;
    button.textContent = loadingText;
    button.classList.add('loading');
    button.disabled = true;
}

/**
 * Reset button from loading state
 */
function resetButton(button) {
    if (!button) return;
    button.textContent = button._originalText || button.textContent;
    button.classList.remove('loading');
    button.disabled = button._originalDisabled || false;
}

/**
 * Open a modal dialog
 */
function openModal(modalId) {
    const modal = document.getElementById(modalId);
    const backdrop = document.getElementById('modalBackdrop');
    
    if (modal && backdrop) {
        modal.classList.add('active');
        backdrop.classList.add('active');
        document.body.style.overflow = 'hidden';
        
        // Focus first input
        const firstInput = modal.querySelector('input, textarea, select');
        if (firstInput) setTimeout(() => firstInput.focus(), 100);
    }
}

/**
 * Close a specific modal
 */
function closeModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) modal.classList.remove('active');
    closeBackdropIfAllModalsClosed();
}

/**
 * Close active modal when clicking backdrop
 */
function closeActiveModal() {
    const modals = document.querySelectorAll('.modal.active');
    modals.forEach(modal => modal.classList.remove('active'));
    closeBackdropIfAllModalsClosed();
}

/**
 * Hide backdrop if no modals are open
 */
function closeBackdropIfAllModalsClosed() {
    const modals = document.querySelectorAll('.modal.active');
    const backdrop = document.getElementById('modalBackdrop');
    
    if (modals.length === 0 && backdrop) {
        backdrop.classList.remove('active');
        document.body.style.overflow = '';
    }
}

/**
 * Close modal with Escape key
 */
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        closeActiveModal();
    }
});

/**
 * Updated collection creation to use modal
 */
function showNewCollectionForm() {
    openModal('collectionModal');
}

/**
 * Handle collection form submission
 */
async function handleCollectionFormSubmit(event) {
    event.preventDefault();
    
    const form = document.getElementById('collectionForm');
    const name = document.getElementById('collectionName').value.trim();
    const description = document.getElementById('collectionDescription').value.trim();
    const submitBtn = form.querySelector('button[type="submit"]');
    
    // Clear previous errors
    document.getElementById('nameError').textContent = '';
    
    // Validation
    if (!name) {
        document.getElementById('nameError').textContent = 'Collection name is required';
        return;
    }
    
    setButtonLoading(submitBtn, 'Creating...');
    
    try {
        const response = await fetch('/api/collections', {
            method: 'POST',
            headers: getAuthHeaders(),
            body: JSON.stringify({ name, description })
        });
        
        if (response.ok) {
            closeModal('collectionModal');
            form.reset();
            Toast.success('Collection created');
            loadCollections();
        } else {
            const error = await response.json();
            document.getElementById('nameError').textContent = error.error || 'Failed to create collection';
        }
    } catch (error) {
        console.error('Error creating collection:', error);
        Toast.error('Network error');
    } finally {
        resetButton(submitBtn);
    }
}

/**
 * Select a day and reload with the day panel showing
 */
function selectDay(dayId, date) {
    const currentUrl = new URL(window.location.href);
    currentUrl.searchParams.set('day', dayId);
    window.location.href = currentUrl.toString();
}

/**
 * Add a task from the panel (AJAX version)
 */
async function addPanelTask(dayId) {
    const input = document.getElementById('newTaskInput');
    const title = input.value.trim();
    
    if (!title) {
        Toast.info('Task title cannot be empty');
        return;
    }
    
    const addBtn = document.getElementById('addTaskBtn');
    setButtonLoading(addBtn, 'Adding...');
    
    try {
        const response = await fetch(`/api/days/${dayId}/tasks`, {
            method: 'POST',
            headers: getAuthHeaders(),
            body: JSON.stringify({ title })
        });
        
        if (response.ok) {
            const data = await response.json();
            const task = data.task;
            addTaskToDOM(dayId, task);
            input.value = '';
            input.focus();
            Toast.success('Task added');
        } else {
            const error = await response.json();
            Toast.error(error.error || 'Failed to add task');
        }
    } catch (error) {
        console.error('Error adding task:', error);
        Toast.error('Network error');
    } finally {
        resetButton(addBtn);
    }
}

/**
 * Toggle task completion status (AJAX version)
 */
async function toggleTask(dayId, taskId) {
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/toggle`, {
            method: 'POST',
            headers: getAuthHeaders()
        });
        
        if (response.ok) {
            const data = await response.json();
            const task = { id: taskId, completed: data.completed };
            updateTaskInDOM(dayId, task);
            Toast.success(data.completed ? 'Task completed ✓' : 'Task marked incomplete');
        } else {
            Toast.error('Failed to toggle task');
        }
    } catch (error) {
        console.error('Error toggling task:', error);
        Toast.error('Network error');
    }
}

/**
 * Delete a task (AJAX version)
 */
async function deleteTask(dayId, taskId) {
    const confirmed = await showConfirmation(
        'Delete Task',
        'Are you sure you want to delete this task? This action cannot be undone.',
        'Delete'
    );
    if (!confirmed) return;
    
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}`, {
            method: 'DELETE',
            headers: getAuthHeaders()
        });
        
        if (response.ok) {
            removeTaskFromDOM(taskId);
            Toast.success('Task deleted');
        } else {
            Toast.error('Failed to delete task');
        }
    } catch (error) {
        console.error('Error deleting task:', error);
        Toast.error('Network error');
    }
}

/**
 * Edit a task's title (AJAX version)
 */
async function editTask(dayId, taskId, newTitle) {
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}`, {
            method: 'PUT',
            headers: getAuthHeaders(),
            body: JSON.stringify({ title: newTitle })
        });
        
        if (response.ok) {
            Toast.success('Task updated');
            return true;
        } else {
            const error = await response.json();
            Toast.error(error.error || 'Failed to update task');
            return false;
        }
    } catch (error) {
        console.error('Error editing task:', error);
        Toast.error('Network error');
        return false;
    }
}

/**
 * Enable inline editing for task title
 */
function enableTaskEdit(event, dayId, taskId) {
    if (event.target.classList.contains('editing')) return;
    
    const titleLabel = event.target;
    if (!titleLabel.dataset.editable) return;
    
    const originalText = titleLabel.textContent.trim();
    
    // Make editable
    titleLabel.contentEditable = true;
    titleLabel.classList.add('editing');
    titleLabel.focus();
    
    // Select all text
    const range = document.createRange();
    range.selectNodeContents(titleLabel);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    
    // Save on blur or Enter
    const saveEdit = async () => {
        titleLabel.contentEditable = false;
        titleLabel.classList.remove('editing');
        
        const newText = titleLabel.textContent.trim();
        
        if (!newText) {
            titleLabel.textContent = originalText;
            Toast.warning('Task title cannot be empty');
            return;
        }
        
        if (newText === originalText) return;
        
        const success = await editTask(dayId, taskId, newText);
        if (!success) {
            titleLabel.textContent = originalText;
        }
    };
    
    const cancelEdit = () => {
        titleLabel.contentEditable = false;
        titleLabel.classList.remove('editing');
        titleLabel.textContent = originalText;
    };
    
    titleLabel.onblur = saveEdit;
    titleLabel.onkeydown = (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            saveEdit();
        } else if (e.key === 'Escape') {
            cancelEdit();
        }
    };
}

/**
 * Toggle task expansion to show/hide subtasks (AJAX version)
 */
async function toggleTaskExpand(dayId, taskId) {
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/expand`, {
            method: 'POST',
            headers: getAuthHeaders()
        });
        
        if (response.ok) {
            Toast.info('Task expanded/collapsed');
        } else {
            Toast.error('Failed to toggle expansion');
        }
    } catch (error) {
        console.error('Error toggling task expansion:', error);
        Toast.error('Network error');
    }
}

/**
 * Add a subtask to a task (AJAX version)
 */
async function addSubtask(dayId, taskId) {
    const input = document.getElementById(`subtask-input-${taskId}`);
    const title = input.value.trim();
    
    if (!title) {
        Toast.info('Subtask title cannot be empty');
        return;
    }
    
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/subtasks`, {
            method: 'POST',
            headers: getAuthHeaders(),
            body: JSON.stringify({ title })
        });
        
        if (response.ok) {
            input.value = '';
            input.focus();
            Toast.success('Subtask added');
            window.location.reload();
        } else {
            const error = await response.json();
            Toast.error(error.error || 'Failed to add subtask');
        }
    } catch (error) {
        console.error('Error adding subtask:', error);
        Toast.error('Network error');
    }
}

/**
 * Toggle subtask completion (AJAX version)
 */
async function toggleSubtask(dayId, taskId, subtaskId) {
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/subtasks/${subtaskId}/toggle`, {
            method: 'POST',
            headers: getAuthHeaders()
        });
        
        if (response.ok) {
            Toast.success('Subtask toggled');
            window.location.reload();
        } else {
            Toast.error('Failed to toggle subtask');
        }
    } catch (error) {
        console.error('Error toggling subtask:', error);
        Toast.error('Network error');
    }
}

/**
 * Delete a subtask (AJAX version)
 */
async function deleteSubtask(dayId, taskId, subtaskId) {
    try {
        const response = await fetch(`/api/days/${dayId}/tasks/${taskId}/subtasks/${subtaskId}`, {
            method: 'DELETE',
            headers: getAuthHeaders()
        });
        
        if (response.ok) {
            Toast.success('Subtask deleted');
            window.location.reload();
        } else {
            Toast.error('Failed to delete subtask');
        }
    } catch (error) {
        console.error('Error deleting subtask:', error);
        Toast.error('Network error');
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
        btn.setAttribute('aria-selected', 'false');
    });
    
    // Show selected tab and activate button
    const tab = document.getElementById(`${tabName}-tab`);
    if (tab) {
        tab.classList.add('active');
    }
    
    const btn = document.querySelector(`.tab-btn[data-tab="${tabName}"]`);
    if (btn) {
        btn.classList.add('active');
        btn.setAttribute('aria-selected', 'true');
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
            <div class="empty-collections" aria-label="No collections">
                <span class="empty-icon">📚</span>
                <p>No collections yet</p>
                <p class="empty-hint">Create a collection to organize tasks by project or category</p>
            </div>
        `;
        return;
    }
    
    container.innerHTML = allCollections.map(collection => {
        const completedCount = collection.tasks.filter(t => t.completed).length;
        const totalCount = collection.tasks.length;
        const pct = totalCount > 0 ? Math.round(completedCount / totalCount * 100) : 0;
        const fillWidth = totalCount > 0 ? (completedCount / totalCount * 100) : 0;
        
        return `
        <div class="collection-card" onclick="selectCollection('${collection.id}')" role="article" aria-label="Collection: ${escapeHtml(collection.name)}">
            <div class="collection-card-header">
                <h3 class="collection-title">${escapeHtml(collection.name)}</h3>
                <button class="btn-icon" onclick="event.stopPropagation(); showCollectionMenu('${collection.id}')" title="Options for ${escapeHtml(collection.name)}" aria-label="Options for '${escapeHtml(collection.name)}'">⋮</button>
            </div>
            ${collection.description ? `<div class="collection-description">${escapeHtml(collection.description)}</div>` : ''}
            <div class="collection-meta">
                <span class="collection-meta-item">📋 ${totalCount} task${totalCount !== 1 ? 's' : ''}</span>
                <span class="collection-meta-item">✅ ${completedCount} done</span>
            </div>
            <div class="collection-progress">
                <div class="progress-bar" role="progressbar" aria-valuenow="${completedCount}" aria-valuemin="0" aria-valuemax="${totalCount}" aria-label="${completedCount} of ${totalCount} tasks completed">
                    <div class="progress-fill" style="width: ${fillWidth}%"></div>
                </div>
                <span class="progress-text">${completedCount} of ${totalCount}</span>
            </div>
            <div class="collection-tasks expanded">
                <div class="collection-task-list" role="list" aria-label="Tasks in ${escapeHtml(collection.name)}">
                    ${collection.tasks.slice(0, 5).map(task => `
                        <div class="collection-task-item ${task.completed ? 'completed' : ''}" role="listitem">
                            <input type="checkbox" ${task.completed ? 'checked' : ''} 
                                   onchange="toggleCollectionTask('${collection.id}', '${task.id}')"
                                   aria-label="Mark '${escapeHtml(task.title)}' as ${task.completed ? 'incomplete' : 'complete'}">
                            <span class="collection-task-title">${escapeHtml(task.title)}</span>
                            ${task.priority && task.priority !== 'none' ? `<span class="collection-task-priority ${task.priority}" aria-label="Priority: ${task.priority}">${task.priority}</span>` : ''}
                            <button class="btn-icon-sm" onclick="deleteCollectionTask('${collection.id}', '${task.id}')" title="Delete task" aria-label="Delete task '${escapeHtml(task.title)}'">×</button>
                        </div>
                    `).join('')}
                    ${collection.tasks.length > 5 ? `<div class="loading-message">+${collection.tasks.length - 5} more tasks</div>` : ''}
                </div>
                <div class="add-collection-task">
                    <input type="text" placeholder="Add task..." id="task-input-${collection.id}" aria-label="Add task to '${escapeHtml(collection.name)}'">
                    <button onclick="addCollectionTask('${collection.id}')" aria-label="Add task">+</button>
                </div>
            </div>
        </div>
    `}).join('');
}

function selectCollection(collectionId) {
    currentCollection = allCollections.find(c => c.id === collectionId);
    document.querySelectorAll('.collection-card').forEach(card => {
        card.classList.remove('selected');
    });
    event.currentTarget.classList.add('selected');
}

// showNewCollectionForm() is defined above in the Modal Dialog System section

async function deleteCollectionTask(collectionId, taskId) {
    const confirmed = await showConfirmation(
        'Delete Task',
        'Are you sure you want to delete this task from the collection?',
        'Delete'
    );
    if (!confirmed) return;
    
    try {
        const response = await fetch(`/api/collections/${collectionId}/tasks/${taskId}`, {
            method: 'DELETE',
            headers: getAuthHeaders()
        });
        
        if (response.ok) {
            Toast.success('Task deleted');
            loadCollections();
        } else {
            Toast.error('Failed to delete task');
        }
    } catch (error) {
        console.error('Error deleting task:', error);
        Toast.error('Network error');
    }
}

async function toggleCollectionTask(collectionId, taskId) {
    try {
        const response = await fetch(`/api/collections/${collectionId}/tasks/${taskId}/toggle`, {
            method: 'POST',
            headers: getAuthHeaders()
        });
        
        if (response.ok) {
            Toast.success('Task updated');
            loadCollections();
        } else {
            Toast.error('Failed to toggle task');
        }
    } catch (error) {
        console.error('Error toggling task:', error);
        Toast.error('Network error');
    }
}

async function addCollectionTask(collectionId) {
    const input = document.getElementById(`task-input-${collectionId}`);
    const title = input.value.trim();
    
    if (!title) {
        Toast.info('Task title cannot be empty');
        return;
    }
    
    try {
        const response = await fetch(`/api/collections/${collectionId}/tasks`, {
            method: 'POST',
            headers: getAuthHeaders(),
            body: JSON.stringify({ title })
        });
        
        if (response.ok) {
            Toast.success('Task added');
            input.value = '';
            loadCollections();
        } else {
            const error = await response.json();
            Toast.error(error.error || 'Failed to add task');
        }
    } catch (error) {
        console.error('Error adding task:', error);
        Toast.error('Network error');
    }
}

async function showCollectionMenu(collectionId) {
    const collection = allCollections.find(c => c.id === collectionId);
    if (!collection) return;
    
    const confirmed = await showConfirmation(
        'Delete Collection',
        `Are you sure you want to delete "${collection.name}"? All tasks in this collection will be lost.`,
        'Delete Collection'
    );
    
    if (!confirmed) return;
    
    try {
        const response = await fetch(`/api/collections/${collectionId}`, {
            method: 'DELETE',
            headers: getAuthHeaders()
        });
        
        if (response.ok) {
            Toast.success('Collection deleted');
            loadCollections();
        } else {
            Toast.error('Failed to delete collection');
        }
    } catch (error) {
        console.error('Error deleting collection:', error);
        Toast.error('Network error');
    }
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
