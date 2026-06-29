-- FreeWindow schema.
-- All tables have RLS enabled with NO policies: only the Supabase service role
-- (used server-side) can touch them. Refresh tokens are stored encrypted.

create extension if not exists pgcrypto;

-- Connected members of the group.
create table if not exists app_users (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  google_email  text unique,
  refresh_token text,                 -- encrypted (AES-256-GCM); null if ICS member
  ics_url       text,                 -- fallback for Apple/Outlook friends
  created_at    timestamptz not null default now()
);

-- Log of windows we've already announced, so we never re-send the same one.
create table if not exists sent_windows (
  id          uuid primary key default gen_random_uuid(),
  window_hash text unique not null,   -- hash of (start, end)
  start_at    timestamptz not null,
  end_at      timestamptz not null,
  sent_at     timestamptz not null default now()
);

-- Per-chat mute state for the opt-out path (reply /stop).
create table if not exists mutes (
  chat_id    text primary key,
  muted      boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table app_users    enable row level security;
alter table sent_windows enable row level security;
alter table mutes        enable row level security;
