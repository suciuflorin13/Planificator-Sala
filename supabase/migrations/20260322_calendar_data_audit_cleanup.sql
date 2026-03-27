-- =========================================================
-- Calendar data audit and cleanup (safe-first)
-- Created: 2026-03-22
-- =========================================================

-- =========================================================
-- 0) AUDIT INAINTE DE CLEAN
-- =========================================================

select count(*) as total_events from public.events;
select count(*) as total_event_requests from public.event_requests;
select count(*) as total_schedule_overrides from public.schedule_overrides;
select count(*) as total_schedule_anchors from public.schedule_anchors;
select count(*) as total_project_activities from public.project_activities;

-- cereri orfane (event_id nu mai exista in events)
select count(*) as orphan_requests
from public.event_requests r
left join public.events e on e.id = r.event_id
where r.event_id is not null
  and e.id is null;

-- evenimente cu interval invalid
select count(*) as invalid_event_intervals
from public.events
where start_time is null
   or end_time is null
   or end_time <= start_time;

-- request-uri cu interval invalid
select count(*) as invalid_request_intervals
from public.event_requests
where requested_start is null
   or requested_end is null
   or requested_end <= requested_start;

-- overrides cu interval invalid
select count(*) as invalid_override_intervals
from public.schedule_overrides
where start_time is null
   or end_time is null
   or end_time <= start_time;

-- evenimente fara organizatie
select count(*) as events_without_org
from public.events
where organization_id is null;

-- request-uri fara organizatie sursa sau tinta
select count(*) as requests_without_orgs
from public.event_requests
where requested_by_org_id is null
   or target_org_id is null;

-- status-uri neobisnuite la request-uri
select status, count(*) as cnt
from public.event_requests
group by status
order by cnt desc;


-- =========================================================
-- 1) BACKUP (siguranta)
-- =========================================================

create table if not exists public.backup_events as
select * from public.events where false;

insert into public.backup_events
select * from public.events;

create table if not exists public.backup_event_requests as
select * from public.event_requests where false;

insert into public.backup_event_requests
select * from public.event_requests;

create table if not exists public.backup_schedule_overrides as
select * from public.schedule_overrides where false;

insert into public.backup_schedule_overrides
select * from public.schedule_overrides;

create table if not exists public.backup_schedule_anchors as
select * from public.schedule_anchors where false;

insert into public.backup_schedule_anchors
select * from public.schedule_anchors;

create table if not exists public.backup_project_activities as
select * from public.project_activities where false;

insert into public.backup_project_activities
select * from public.project_activities;


-- =========================================================
-- 2) SAFE CLEAN (fara reset total)
-- =========================================================

-- 2.1 sterge request-urile orfane
delete from public.event_requests r
where r.event_id is not null
  and not exists (
    select 1
    from public.events e
    where e.id = r.event_id
  );

-- 2.2 sterge evenimente cu interval invalid
delete from public.events
where start_time is null
   or end_time is null
   or end_time <= start_time;

-- 2.3 sterge request-uri cu interval invalid
delete from public.event_requests
where requested_start is null
   or requested_end is null
   or requested_end <= requested_start;

-- 2.4 sterge overrides cu interval invalid
delete from public.schedule_overrides
where start_time is null
   or end_time is null
   or end_time <= start_time;

-- 2.5 normalizeaza status null in open
update public.event_requests
set status = 'open'
where status is null;


-- =========================================================
-- 3) AUDIT DUPA CLEAN
-- =========================================================

select count(*) as total_events_after from public.events;
select count(*) as total_event_requests_after from public.event_requests;
select count(*) as total_schedule_overrides_after from public.schedule_overrides;
select count(*) as orphan_requests_after
from public.event_requests r
left join public.events e on e.id = r.event_id
where r.event_id is not null
  and e.id is null;
select count(*) as invalid_event_intervals_after
from public.events
where start_time is null
   or end_time is null
   or end_time <= start_time;
select count(*) as invalid_request_intervals_after
from public.event_requests
where requested_start is null
   or requested_end is null
   or requested_end <= requested_start;


-- =========================================================
-- 4) OPTIONAL: RESET AGRESIV (doar daca vrei calendar gol)
-- =========================================================
-- Atentie: ruleaza doar daca chiar vrei sa golesti tot.
-- Daca vrei, decomentezi blocul de mai jos.

-- truncate table public.event_requests restart identity cascade;
-- truncate table public.events restart identity cascade;
-- truncate table public.schedule_overrides restart identity cascade;
-- truncate table public.schedule_anchors restart identity cascade;
-- truncate table public.project_activities restart identity cascade;
