create table entries (
  id bigint generated always as identity primary key,
  created_at timestamptz default now() not null,
  name text not null,
  message text not null
);
