-- Google Calendar sync support: event scopes and external mapping.
-- Safe additive migration: does not alter existing behavior for old rows.

alter table if exists public.events
  add column if not exists event_scope text not null default 'organization',
  add column if not exists owner_user_id uuid references public.profiles(id) on delete set null,
  add column if not exists source_provider text,
  add column if not exists source_external_id text,
  add column if not exists synced_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

-- Keep scope values constrained while preserving existing rows.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'events_event_scope_check'
  ) then
    alter table public.events
      add constraint events_event_scope_check
      check (event_scope in ('organization', 'personal'));
  end if;
end
$$;

create index if not exists idx_events_scope_org
  on public.events(event_scope, organization_id);

create index if not exists idx_events_scope_owner
  on public.events(event_scope, owner_user_id);

create index if not exists idx_events_source_external
  on public.events(source_provider, source_external_id);

-- Bi-directional mapping between local events and Google events.
create table if not exists public.external_event_links (
  id uuid primary key default gen_random_uuid(),
  local_event_id uuid not null references public.events(id) on delete cascade,
  provider text not null default 'google',
  external_event_id text not null,
  sync_scope text not null,
  owner_organization_id uuid references public.organizations(id) on delete cascade,
  owner_user_id uuid references public.profiles(id) on delete cascade,
  external_etag text,
  external_updated_at timestamptz,
  deleted_in_external boolean not null default false,
  deleted_in_local boolean not null default false,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(provider, external_event_id, sync_scope)
);

create index if not exists idx_external_links_local
  on public.external_event_links(local_event_id);

create index if not exists idx_external_links_owner_org
  on public.external_event_links(sync_scope, owner_organization_id);

create index if not exists idx_external_links_owner_user
  on public.external_event_links(sync_scope, owner_user_id);

-- Auto-update updated_at for rows managed in SQL updates.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_events_touch_updated_at on public.events;
create trigger trg_events_touch_updated_at
before update on public.events
for each row execute function public.touch_updated_at();

drop trigger if exists trg_external_links_touch_updated_at on public.external_event_links;
create trigger trg_external_links_touch_updated_at
before update on public.external_event_links
for each row execute function public.touch_updated_at();
