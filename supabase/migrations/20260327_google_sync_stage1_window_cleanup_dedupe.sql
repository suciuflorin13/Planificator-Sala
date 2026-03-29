-- Stage 1 Google sync hardening: bounded window + local dedupe support.
-- Safe additive migration.

alter table if exists public.events
  add column if not exists google_description text;

create index if not exists idx_events_scope_start_end
  on public.events(event_scope, start_time, end_time);

create index if not exists idx_events_google_source_scope
  on public.events(source_provider, event_scope, organization_id, owner_user_id);
