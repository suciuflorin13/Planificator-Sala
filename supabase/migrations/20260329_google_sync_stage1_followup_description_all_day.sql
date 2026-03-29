-- Follow-up for Stage 1 sync:
-- 1) use canonical description column for Google content
-- 2) keep backward compatibility with google_description
-- 3) explicit all-day marker for timezone-safe rendering

alter table if exists public.events
  add column if not exists description text,
  add column if not exists source_all_day boolean not null default false;

-- Backfill both directions so existing rows remain consistent.
update public.events
set description = google_description
where coalesce(description, '') = ''
  and coalesce(google_description, '') <> '';

update public.events
set google_description = description
where coalesce(google_description, '') = ''
  and coalesce(description, '') <> '';

create index if not exists idx_events_source_all_day
  on public.events(source_provider, source_all_day, event_scope);
