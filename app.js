// FreeWindow connect page.

const form = document.getElementById('connect-form');
const nameInput = document.getElementById('name');
const statusEl = document.getElementById('status');
const crewEl = document.getElementById('crew');
const crewList = document.getElementById('crew-list');

// Start OAuth: hand off to our /api/connect, which redirects to Google.
form.addEventListener('submit', (e) => {
  e.preventDefault();
  const name = nameInput.value.trim();
  if (!name) return;
  window.location.href = `/api/connect?name=${encodeURIComponent(name)}`;
});

// Surface the result of an OAuth round-trip.
function showResult() {
  const params = new URLSearchParams(window.location.search);
  if (params.get('connected') === '1') {
    statusEl.hidden = false;
    statusEl.className = 'status ok';
    statusEl.textContent = '✅ Connected! You’re all set — we’ll ping the group when everyone’s free.';
  } else if (params.get('error')) {
    statusEl.hidden = false;
    statusEl.className = 'status error';
    const err = params.get('error');
    statusEl.textContent = err === 'no_refresh_token'
      ? '⚠️ Google didn’t return offline access. Remove FreeWindow from your Google account permissions and try again.'
      : `⚠️ Something went wrong: ${err}`;
  }
}

// Show who's already connected.
async function loadCrew() {
  try {
    const res = await fetch('/api/members');
    if (!res.ok) return;
    const data = await res.json();
    if (!data.members || data.members.length === 0) return;
    crewEl.hidden = false;
    crewList.innerHTML = '';
    for (const m of data.members) {
      const li = document.createElement('li');
      li.textContent = m.name;
      crewList.appendChild(li);
    }
  } catch {
    /* non-fatal */
  }
}

showResult();
loadCrew();
