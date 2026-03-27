-- Scheduler extension migration for request workflow and Google Calendar sync metadata.
-- Run this in Supabase SQL editor before enabling the new UI flows.
--
-- Schema state at 2026-03-19:
--   event_requests already has: id(uuid), event_id, requested_start, requested_end,
--     target_org_id, message, status, created_by, created_at
--   events already has: id(uuid), participants(ARRAY), status(enum), event_type, ...
--   profiles already has: gmail_address, full_name

-- Add only the columns missing from event_requests
alter table if exists public.event_requests
  add column if not exists request_type       text default 'overflow',
  add column if not exists requested_by_org_id uuid,
  add column if not exists parent_request_id  uuid,
  add column if not exists responded_by       uuid,
  add column if not exists responded_at       timestamptz,
  add column if not exists offer_payload_json jsonb default '{}'::jsonb;

-- Add only the columns missing from events
alter table if exists public.events
  add column if not exists source_request_id uuid,
  add column if not exists sync_state        text default 'pending';

-- Organization settings for Google Calendar integration
create table if not exists public.organization_settings (
  organization_id  uuid primary key references public.organizations(id) on delete cascade,
  timezone         text not null default 'Europe/Bucharest',
  google_calendar_id text,
  owner_google_email text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- events.participants is already an ARRAY column — no separate table needed.

create index if not exists idx_event_requests_status     on public.event_requests(status);
create index if not exists idx_event_requests_target_org on public.event_requests(target_org_id);
create index if not exists idx_events_sync_state         on public.events(sync_state);
