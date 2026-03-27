-- Stores Google OAuth credentials per organization or per user.
-- Safe additive migration for calendar sync authorization.

create table if not exists public.google_oauth_tokens (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null,
  organization_id uuid references public.organizations(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  google_email text,
  access_token text,
  refresh_token text,
  token_type text,
  scope text,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint google_oauth_tokens_subject_type_check
    check (subject_type in ('organization', 'personal')),
  constraint google_oauth_tokens_owner_check
    check (
      (subject_type = 'organization' and organization_id is not null and user_id is null)
      or
      (subject_type = 'personal' and user_id is not null)
    )
);

create unique index if not exists idx_google_oauth_tokens_org
  on public.google_oauth_tokens(subject_type, organization_id)
  where organization_id is not null;

create unique index if not exists idx_google_oauth_tokens_user
  on public.google_oauth_tokens(subject_type, user_id)
  where user_id is not null;

create index if not exists idx_google_oauth_tokens_email
  on public.google_oauth_tokens(google_email);

drop trigger if exists trg_google_oauth_tokens_touch_updated_at on public.google_oauth_tokens;
create trigger trg_google_oauth_tokens_touch_updated_at
before update on public.google_oauth_tokens
for each row execute function public.touch_updated_at();
