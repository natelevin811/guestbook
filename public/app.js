const form = document.getElementById('guestbook-form');
const nameInput = document.getElementById('name');
const messageInput = document.getElementById('message');
const submitBtn = document.getElementById('submit-btn');
const errorMsg = document.getElementById('error-msg');
const entriesList = document.getElementById('entries-list');
const emptyState = document.getElementById('empty-state');
const entryCount = document.getElementById('entry-count');

function formatDate(iso) {
  const d = new Date(iso);
  return d.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });
}

function createEntryCard(entry) {
  const card = document.createElement('article');
  card.className = 'entry-card';
  card.dataset.id = entry.id;
  card.innerHTML = `
    <div class="entry-header">
      <span class="entry-name">${escapeHtml(entry.name)}</span>
      <time class="entry-time" datetime="${entry.created_at}">${formatDate(entry.created_at)}</time>
    </div>
    <p class="entry-message">${escapeHtml(entry.message)}</p>
  `;
  return card;
}

function escapeHtml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function updateCount(n) {
  entryCount.textContent = n === 0 ? '' : n;
}

async function loadEntries() {
  const res = await fetch('/entries');
  const entries = await res.json();
  entriesList.innerHTML = '';
  if (entries.length === 0) {
    entriesList.appendChild(emptyState);
  } else {
    entries.forEach(e => entriesList.appendChild(createEntryCard(e)));
  }
  updateCount(entries.length);
}

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  errorMsg.hidden = true;
  submitBtn.disabled = true;
  submitBtn.textContent = 'Signing…';

  try {
    const res = await fetch('/entries', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: nameInput.value, message: messageInput.value }),
    });

    if (!res.ok) {
      const data = await res.json();
      throw new Error(data.error || 'Something went wrong.');
    }

    const entry = await res.json();

    // Remove empty state if present
    emptyState.remove();

    // Prepend new card
    const card = createEntryCard(entry);
    entriesList.prepend(card);

    // Update count
    updateCount(entriesList.querySelectorAll('.entry-card').length);

    // Reset form
    form.reset();
  } catch (err) {
    errorMsg.textContent = err.message;
    errorMsg.hidden = false;
  } finally {
    submitBtn.disabled = false;
    submitBtn.textContent = 'Sign the book';
  }
});

// Load existing entries on page load
loadEntries();

// ── Auth ─────────────────────────────────────────────────────────────────────

let supabaseClient = null;

async function initAuth() {
  const res = await fetch('/config');
  const { supabaseUrl, supabaseAnonKey } = await res.json();
  supabaseClient = window.supabase.createClient(supabaseUrl, supabaseAnonKey);

  supabaseClient.auth.onAuthStateChange((_event, session) => {
    updateAuthUI(session);
  });

  const { data: { session } } = await supabaseClient.auth.getSession();
  updateAuthUI(session);
}

function updateAuthUI(session) {
  const signedOutEl = document.getElementById('auth-signed-out');
  const signedInEl = document.getElementById('auth-signed-in');
  const emailDisplay = document.getElementById('auth-email-display');
  const signinPanel = document.getElementById('signin-panel');

  if (session) {
    signedOutEl.hidden = true;
    signedInEl.hidden = false;
    emailDisplay.textContent = session.user.email;
    signinPanel.hidden = true;
    if (!nameInput.value) {
      nameInput.value = session.user.email.split('@')[0];
    }
  } else {
    signedOutEl.hidden = false;
    signedInEl.hidden = true;
  }
}

document.getElementById('show-signin-btn').addEventListener('click', () => {
  document.getElementById('signin-panel').hidden = false;
});

document.getElementById('cancel-signin').addEventListener('click', () => {
  document.getElementById('signin-panel').hidden = true;
});

document.getElementById('signout-btn').addEventListener('click', async () => {
  await supabaseClient.auth.signOut();
});

document.getElementById('signin-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const authError = document.getElementById('auth-error');
  authError.hidden = true;
  const btn = document.getElementById('signin-submit');
  btn.disabled = true;
  btn.textContent = 'Signing in…';

  const email = document.getElementById('signin-email').value;
  const password = document.getElementById('signin-password').value;
  const { error } = await supabaseClient.auth.signInWithPassword({ email, password });

  if (error) {
    authError.textContent = error.message;
    authError.hidden = false;
  }

  btn.disabled = false;
  btn.textContent = 'Sign In';
});

initAuth();
