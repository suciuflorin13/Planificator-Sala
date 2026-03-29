-- Overlap policy update:
-- Allow overlaps for regular events.
-- Block overlaps only for managed locations: Sala / Foaier.

create or replace function public._normalize_location(value text)
returns text
language sql
immutable
as $$
  select lower(translate(coalesce(value, ''), 'ăâîșşțţĂÂÎȘŞȚŢ', 'aaissttAAISSTT'));
$$;

create or replace function public._is_managed_location(value text)
returns boolean
language sql
immutable
as $$
  select
    position('sala' in public._normalize_location(value)) > 0
    or position('foaier' in public._normalize_location(value)) > 0;
$$;

create or replace function public._locations_conflict(a text, b text)
returns boolean
language plpgsql
immutable
as $$
declare
  la text := public._normalize_location(a);
  lb text := public._normalize_location(b);
  a_sala boolean := position('sala' in la) > 0;
  a_foaier boolean := position('foaier' in la) > 0;
  b_sala boolean := position('sala' in lb) > 0;
  b_foaier boolean := position('foaier' in lb) > 0;
  a_blocks_both boolean := a_sala and a_foaier and position('ocupat' in la) > 0;
  b_blocks_both boolean := b_sala and b_foaier and position('ocupat' in lb) > 0;
begin
  if a_blocks_both then
    return b_sala or b_foaier;
  end if;

  if b_blocks_both then
    return a_sala or a_foaier;
  end if;

  if a_sala and b_sala then
    return true;
  end if;

  if a_foaier and b_foaier then
    return true;
  end if;

  return false;
end;
$$;

create or replace function public.prevent_overlapping_events()
returns trigger
language plpgsql
as $$
begin
  if new.start_time is null or new.end_time is null then
    return new;
  end if;

  if new.end_time <= new.start_time then
    return new;
  end if;

  -- Only managed locations participate in anti-overlap rule.
  if not public._is_managed_location(new.location) then
    return new;
  end if;

  if exists (
    select 1
    from public.events e
    where e.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
      and e.start_time < new.end_time
      and e.end_time > new.start_time
      and public._locations_conflict(e.location, new.location)
  ) then
    raise exception 'Evenimentul se suprapune pe Sală/Foaier și nu poate fi salvat.'
      using errcode = '23P01';
  end if;

  return new;
end;
$$;

do $$
declare
  trg record;
begin
  for trg in
    select t.tgname
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'events'
      and not t.tgisinternal
      and pg_get_triggerdef(t.oid, true) ilike '%prevent_overlapping_events%'
  loop
    execute format('drop trigger if exists %I on public.events', trg.tgname);
  end loop;
end;
$$;

create trigger trg_events_prevent_overlapping
before insert or update of start_time, end_time, location
on public.events
for each row
execute function public.prevent_overlapping_events();
