-- Internal messaging between users
CREATE TABLE IF NOT EXISTS public.messages (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id   UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  receiver_id UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content     TEXT        NOT NULL,
  read        BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_receiver   ON public.messages(receiver_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender     ON public.messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON public.messages(created_at DESC);

-- Enable Row Level Security
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can see own messages"
  ON public.messages FOR SELECT
  USING (auth.uid() = sender_id OR auth.uid() = receiver_id);
CREATE POLICY "Users can insert own messages"
  ON public.messages FOR INSERT
  WITH CHECK (auth.uid() = sender_id);
CREATE POLICY "Receiver can mark as read"
  ON public.messages FOR UPDATE
  USING (auth.uid() = receiver_id);

-- In-app notifications
CREATE TABLE IF NOT EXISTS public.notifications (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type       TEXT        NOT NULL, -- 'message' | 'request' | 'invite'
  title      TEXT        NOT NULL,
  body       TEXT,
  data_json  JSONB       NOT NULL DEFAULT '{}'::JSONB,
  read       BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user   ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_unread ON public.notifications(user_id, read) WHERE read = FALSE;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can see own notifications"
  ON public.notifications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can update own notifications"
  ON public.notifications FOR UPDATE USING (auth.uid() = user_id);

-- Tracking which events have already been synced to Google Calendar (per user)
-- Prevents re-syncing unchanged events
CREATE TABLE IF NOT EXISTS public.google_calendar_syncs (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  event_id         UUID        NOT NULL REFERENCES public.events(id)   ON DELETE CASCADE,
  google_event_id  TEXT        NOT NULL,
  event_updated_at TIMESTAMPTZ,
  synced_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, event_id)
);

CREATE INDEX IF NOT EXISTS idx_gcal_syncs_user ON public.google_calendar_syncs(user_id);

-- Add gmail_address to profiles if not already present (migration guard)
ALTER TABLE IF EXISTS public.profiles
  ADD COLUMN IF NOT EXISTS gmail_address TEXT;

-- Add google_email to organizations for manager-level org calendar sync
ALTER TABLE IF EXISTS public.organizations
  ADD COLUMN IF NOT EXISTS google_email TEXT;
