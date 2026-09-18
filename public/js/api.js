const api = {
  baseUrl: '/api',

  async request(method, path, body = null) {
    const opts = {
      method,
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
    };
    if (body) opts.body = JSON.stringify(body);

    const res = await fetch(this.baseUrl + path, opts);
    const data = await res.json();

    if (!res.ok) {
      throw new Error(data.error || 'Request failed');
    }
    return data;
  },

  get(path) { return this.request('GET', path); },
  post(path, body) { return this.request('POST', path, body); },
  put(path, body) { return this.request('PUT', path, body); },
  del(path) { return this.request('DELETE', path); },

  async getCurrentUser() {
    const data = await this.get('/auth/me');
    return data.user;
  }
};

// Toast notifications
function showToast(message, type = 'success') {
  let container = document.querySelector('.toast-container');
  if (!container) {
    container = document.createElement('div');
    container.className = 'toast-container';
    document.body.appendChild(container);
  }
  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  toast.textContent = message;
  container.appendChild(toast);
  setTimeout(() => toast.remove(), 4000);
}

// Format relative time
function timeAgo(dateStr) {
  const date = new Date(dateStr + (dateStr.endsWith('Z') ? '' : 'Z'));
  const now = new Date();
  const seconds = Math.floor((now - date) / 1000);

  if (seconds < 60) return 'just now';
  if (seconds < 3600) return Math.floor(seconds / 60) + 'm ago';
  if (seconds < 86400) return Math.floor(seconds / 3600) + 'h ago';
  if (seconds < 2592000) return Math.floor(seconds / 86400) + 'd ago';
  return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

// Format event date
function formatDate(dateStr) {
  const date = new Date(dateStr);
  return date.toLocaleDateString('en-US', {
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
    hour: '2-digit', minute: '2-digit'
  });
}

// Get initials from display name
function getInitials(name) {
  return name.split(' ').map(w => w[0]).join('').toUpperCase().slice(0, 2);
}

// Escape HTML
function esc(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

// Render navbar (call on every page)
async function renderNavbar() {
  const nav = document.getElementById('navbar');
  if (!nav) return;

  const user = await api.getCurrentUser().catch(() => null);

  nav.innerHTML = `
    <div class="navbar-inner">
      <a href="/" class="navbar-logo">
        <svg viewBox="0 0 32 32" fill="none">
          <circle cx="16" cy="16" r="15" fill="#1E40AF"/>
          <path d="M16 6 L16 16 L22 22" stroke="white" stroke-width="2.5" stroke-linecap="round" fill="none"/>
          <path d="M10 12 L16 6 L22 12" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
          <path d="M8 26 C8 20 12 18 16 18 C20 18 24 20 24 26" stroke="white" stroke-width="2" fill="none"/>
        </svg>
        PeaceVoice
      </a>
      <div class="navbar-links">
        <a href="/pages/forums.html">Forums</a>
        <a href="/pages/petitions.html">Petitions</a>
        <a href="/pages/events.html">Events</a>
        <a href="/pages/resources.html">Resources</a>
        ${user ? '<a href="/pages/dashboard.html">Dashboard</a>' : ''}
        ${user && user.role === 'admin' ? '<a href="/pages/admin.html">Admin</a>' : ''}
      </div>
      <div class="navbar-auth">
        ${user ? `
          <a href="/pages/dashboard.html" class="user-info">
            <div class="avatar" style="background:${esc(user.avatar_color)}">${getInitials(user.display_name)}</div>
            <span class="text-sm" style="font-weight:500">${esc(user.display_name)}</span>
          </a>
          <button class="btn btn-outline btn-sm" onclick="doLogout()">Logout</button>
        ` : `
          <a href="/pages/login.html" class="btn btn-outline btn-sm">Log in</a>
          <a href="/pages/register.html" class="btn btn-primary btn-sm">Sign up</a>
        `}
      </div>
    </div>
  `;

  // Highlight active link
  const currentPath = window.location.pathname;
  nav.querySelectorAll('.navbar-links a').forEach(a => {
    if (currentPath.includes(a.getAttribute('href').split('/').pop())) {
      a.classList.add('active');
    }
  });

  window._currentUser = user;
}

async function doLogout() {
  await api.post('/auth/logout');
  window.location.href = '/';
}

// Render footer
function renderFooter() {
  const footer = document.getElementById('footer');
  if (!footer) return;

  footer.innerHTML = `
    <div class="footer">
      <div class="footer-inner">
        <div>
          <h3>PeaceVoice</h3>
          <p style="font-size:0.875rem;line-height:1.5;opacity:0.8">A community platform dedicated to strengthening peace, justice, and strong institutions for all.</p>
        </div>
        <div>
          <h3>Platform</h3>
          <a href="/pages/forums.html">Community Forums</a>
          <a href="/pages/petitions.html">Petitions</a>
          <a href="/pages/events.html">Events</a>
          <a href="/pages/resources.html">Resources</a>
        </div>
        <div>
          <h3>SDG 16 Goals</h3>
          <a href="#">Peace & Security</a>
          <a href="#">Access to Justice</a>
          <a href="#">Accountable Institutions</a>
          <a href="#">Human Rights</a>
        </div>
        <div>
          <h3>Get Involved</h3>
          <a href="/pages/register.html">Join the Community</a>
          <a href="/pages/petitions.html">Start a Petition</a>
          <a href="/pages/events.html">Attend an Event</a>
          <a href="/pages/forums.html">Join Discussions</a>
        </div>
      </div>
      <div class="footer-bottom">
        <p>PeaceVoice &mdash; Supporting UN Sustainable Development Goal 16: Peace, Justice and Strong Institutions</p>
      </div>
    </div>
  `;
}

// Initialize page
async function initPage() {
  await renderNavbar();
  renderFooter();
}
