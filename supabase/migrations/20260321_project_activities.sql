-- Stores reusable activity labels per project title and organization.
CREATE TABLE IF NOT EXISTS public.project_activities (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID      NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  project_title TEXT        NOT NULL,
  activity_name TEXT        NOT NULL,
  created_by    UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, project_title, activity_name)
);

CREATE INDEX IF NOT EXISTS idx_project_activities_org_project
  ON public.project_activities(organization_id, project_title);

ALTER TABLE public.project_activities ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org users can read project activities"
  ON public.project_activities
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = auth.uid()
      AND p.organization_id = project_activities.organization_id
    )
  );

CREATE POLICY "Org users can insert project activities"
  ON public.project_activities
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = auth.uid()
      AND p.organization_id = project_activities.organization_id
    )
  );
