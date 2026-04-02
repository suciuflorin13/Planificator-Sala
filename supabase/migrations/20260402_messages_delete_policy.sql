-- Allow sender or receiver to delete their own messages
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'messages'
      AND policyname = 'Users can delete own messages'
  ) THEN
    CREATE POLICY "Users can delete own messages"
      ON public.messages FOR DELETE
      USING (auth.uid() = sender_id OR auth.uid() = receiver_id);
  END IF;
END
$$;
