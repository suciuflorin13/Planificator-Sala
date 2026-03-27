-- =========================================================
-- Messages metadata for titles and recipient targeting
-- Created: 2026-03-22
-- =========================================================

alter table public.messages
  add column if not exists title text;

alter table public.messages
  add column if not exists recipient_scope text;

alter table public.messages
  add column if not exists recipient_role_filter text;

update public.messages
set title = coalesce(nullif(title, ''), 'Mesaj')
where title is null or title = '';

create index if not exists idx_messages_receiver_created_at
  on public.messages(receiver_id, created_at desc);

create index if not exists idx_messages_sender_created_at
  on public.messages(sender_id, created_at desc);
