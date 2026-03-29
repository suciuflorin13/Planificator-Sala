import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

type SyncScope = "organization" | "personal";

type SyncPayload = {
  scope?: SyncScope;
  organization_id?: string;
  push?: boolean;
  pull?: boolean;
  delete_propagation?: boolean;
  compose_google_title?: boolean;
};

type GoogleTokenRow = {
  id: string;
  access_token: string | null;
  refresh_token: string | null;
  expires_at: string | null;
};

type GoogleListResponse = {
  items?: Array<Record<string, unknown>>;
  nextPageToken?: string;
};

type CalendarListResponse = {
  items?: Array<Record<string, unknown>>;
  nextPageToken?: string;
};

type GoogleEventWindow = {
  startIso: string;
  endIso: string;
  isAllDay: boolean;
};

const SYNC_FORWARD_DAYS = 60;
const LOCAL_RETENTION_DAYS = 30;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing environment variable: ${name}`);
  }
  return value;
}

function buildAuthUrl({
  subjectType,
  subjectId,
  googleEmail,
}: {
  subjectType: SyncScope;
  subjectId: string;
  googleEmail: string;
}): string {
  const clientId = requireEnv("GOOGLE_CLIENT_ID");
  const redirectUri = requireEnv("GOOGLE_REDIRECT_URI");
  const state = encodeURIComponent(
    JSON.stringify({
      subject_type: subjectType,
      subject_id: subjectId,
      google_email: googleEmail,
    }),
  );

  const scope = encodeURIComponent(
    [
      "openid",
      "email",
      "profile",
      "https://www.googleapis.com/auth/calendar",
    ].join(" "),
  );

  return [
    "https://accounts.google.com/o/oauth2/v2/auth",
    `?client_id=${encodeURIComponent(clientId)}`,
    `&redirect_uri=${encodeURIComponent(redirectUri)}`,
    "&response_type=code",
    `&scope=${scope}`,
    "&access_type=offline",
    "&prompt=consent",
    `&state=${state}`,
    `&login_hint=${encodeURIComponent(googleEmail)}`,
  ].join("");
}

function isExpired(expiresAt: string | null | undefined): boolean {
  if (!expiresAt) return true;
  const expiryMs = new Date(expiresAt).getTime();
  if (Number.isNaN(expiryMs)) return true;
  return expiryMs <= Date.now() + 60_000;
}

function startOfUtcDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), 0, 0, 0, 0));
}

function endOfUtcDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), 23, 59, 59, 999));
}

function normalizeDedupeValue(value: string | null | undefined): string {
  return (value ?? "")
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function buildDedupeFingerprint({
  title,
  location,
  description,
}: {
  title: string | null | undefined;
  location: string | null | undefined;
  description: string | null | undefined;
}): string {
  return [
    normalizeDedupeValue(title),
    normalizeDedupeValue(location),
    normalizeDedupeValue(description),
  ].join("|");
}

function extractDescription(item: Record<string, unknown>): string {
  return (item.description ?? "").toString().trim();
}

function parseGoogleEventWindow(
  item: Record<string, unknown>,
): GoogleEventWindow | null {
  const startObj = (item.start ?? {}) as Record<string, unknown>;
  const endObj = (item.end ?? {}) as Record<string, unknown>;

  const startDateTime = (startObj.dateTime ?? null) as string | null;
  const endDateTime = (endObj.dateTime ?? null) as string | null;
  if (startDateTime && endDateTime) {
    const start = new Date(startDateTime);
    const end = new Date(endDateTime);
    if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return null;
    return { startIso: start.toISOString(), endIso: end.toISOString(), isAllDay: false };
  }

  const startDate = (startObj.date ?? null) as string | null;
  const endDate = (endObj.date ?? null) as string | null;
  if (startDate && endDate) {
    const start = new Date(`${startDate}T00:00:00Z`);
    const endExclusive = new Date(`${endDate}T00:00:00Z`);
    if (Number.isNaN(start.getTime()) || Number.isNaN(endExclusive.getTime())) return null;
    const end = new Date(endExclusive.getTime() - 60_000);
    if (!end.getTime() || end <= start) {
      end.setTime(start.getTime() + (23 * 60 + 59) * 60_000);
    }
    return { startIso: start.toISOString(), endIso: end.toISOString(), isAllDay: true };
  }

  return null;
}

function extractParticipants(item: Record<string, unknown>): string[] {
  const attendees = Array.isArray(item.attendees)
    ? (item.attendees as Array<Record<string, unknown>>)
    : [];

  const values: string[] = [];
  for (const attendee of attendees) {
    const label =
      ((attendee.displayName ?? attendee.email ?? "") as string).trim();
    if (label.length > 0) {
      values.push(label);
    }
  }

  return Array.from(new Set(values)).slice(0, 20);
}

async function refreshAccessToken({
  supabase,
  tokenRow,
  clientId,
  clientSecret,
}: {
  supabase: ReturnType<typeof createClient>;
  tokenRow: GoogleTokenRow;
  clientId: string;
  clientSecret: string;
}): Promise<string> {
  if (!tokenRow.refresh_token) {
    throw new Error("Missing refresh token.");
  }

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: tokenRow.refresh_token,
      grant_type: "refresh_token",
    }),
  });

  const payload = (await response.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;

  if (!response.ok || !payload.access_token) {
    throw new Error(
      `Refresh token failed: ${JSON.stringify(payload)}`,
    );
  }

  const expiresIn = Number(payload.expires_in ?? 3600);
  const updatedAccessToken = String(payload.access_token);

  const { error: updateError } = await supabase
    .from("google_oauth_tokens")
    .update({
      access_token: updatedAccessToken,
      expires_at: new Date(Date.now() + expiresIn * 1000).toISOString(),
      token_type: payload.token_type ?? null,
      scope: payload.scope ?? null,
    })
    .eq("id", tokenRow.id);

  if (updateError) {
    throw new Error(`Failed to persist refreshed token: ${updateError.message}`);
  }

  return updatedAccessToken;
}

async function listGoogleEvents({
  accessToken,
  calendarId,
  timeMin,
  timeMax,
}: {
  accessToken: string;
  calendarId: string;
  timeMin: string;
  timeMax: string;
}): Promise<Array<Record<string, unknown>>> {
  const allItems: Array<Record<string, unknown>> = [];
  let pageToken: string | null = null;

  do {
    const params = new URLSearchParams({
      singleEvents: "true",
      showDeleted: "true",
      maxResults: "2500",
      orderBy: "updated",
      timeMin,
      timeMax,
    });

    if (pageToken) {
      params.set("pageToken", pageToken);
    }

    const response = await fetch(
      `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events?${params.toString()}`,
      {
        headers: { Authorization: `Bearer ${accessToken}` },
      },
    );

    const payload = (await response.json().catch(() => ({}))) as GoogleListResponse;
    if (!response.ok) {
      throw new Error(`Google events fetch failed: ${JSON.stringify(payload)}`);
    }

    allItems.push(...(payload.items ?? []));
    pageToken = payload.nextPageToken ?? null;
  } while (pageToken);

  return allItems;
}

async function listGoogleCalendarIds({
  accessToken,
  includeHidden = false,
}: {
  accessToken: string;
  includeHidden?: boolean;
}): Promise<string[]> {
  const ids = new Set<string>();
  let pageToken: string | null = null;

  do {
    const params = new URLSearchParams({
      minAccessRole: "reader",
      showHidden: includeHidden ? "true" : "false",
      maxResults: "250",
    });
    if (pageToken) {
      params.set("pageToken", pageToken);
    }

    const response = await fetch(
      `https://www.googleapis.com/calendar/v3/users/me/calendarList?${params.toString()}`,
      { headers: { Authorization: `Bearer ${accessToken}` } },
    );

    const payload = (await response.json().catch(() => ({}))) as CalendarListResponse;
    if (!response.ok) {
      throw new Error(`Google calendar list fetch failed: ${JSON.stringify(payload)}`);
    }

    for (const item of payload.items ?? []) {
      const id = (item.id ?? "").toString().trim();
      if (!id) continue;
      const accessRole = (item.accessRole ?? "").toString().trim().toLowerCase();
      if (!accessRole || accessRole === "none") continue;
      const selected = item.selected;
      if (selected === false) continue;
      ids.add(id);
    }

    pageToken = payload.nextPageToken ?? null;
  } while (pageToken);

  return Array.from(ids);
}

// ── Push-phase types & helpers ──────────────────────────────────────────────

type LocalEvent = {
  id: string;
  title: string;
  event_type: string;
  location: string;
  description: string | null;
  start_time: string;
  end_time: string;
  source_all_day: boolean;
  updated_at: string | null;
};

type GoogleEventPayload = {
  summary: string;
  location?: string;
  description?: string;
  start: { dateTime?: string; date?: string; timeZone?: string };
  end: { dateTime?: string; date?: string; timeZone?: string };
};

function buildGoogleEventPayload(
  event: LocalEvent,
  composeTitle: boolean,
): GoogleEventPayload {
  const rawTitle = (event.title ?? "").toString().trim();
  const type = (event.event_type ?? "").toString().trim();
  const loc = (event.location ?? "").toString().trim();

  let summary: string;
  if (composeTitle) {
    summary = [rawTitle, type, loc].filter(Boolean).join(" | ");
  } else {
    summary = rawTitle;
  }
  if (!summary) summary = "Eveniment";

  const isAllDay = event.source_all_day === true;
  let start: GoogleEventPayload["start"];
  let end: GoogleEventPayload["end"];

  if (isAllDay) {
    // Google all-day events use exclusive end date (YYYY-MM-DD).
    const startDateStr = new Date(event.start_time).toISOString().substring(0, 10);
    const endExclMs = new Date(event.end_time).getTime() + 60_000;
    const endDateStr = new Date(endExclMs).toISOString().substring(0, 10);
    start = { date: startDateStr };
    end = { date: endDateStr };
  } else {
    start = { dateTime: event.start_time, timeZone: "UTC" };
    end = { dateTime: event.end_time, timeZone: "UTC" };
  }

  const payload: GoogleEventPayload = { summary, start, end };
  if (loc) payload.location = loc;
  const desc = (event.description ?? "").toString().trim();
  if (desc) payload.description = desc;
  return payload;
}

async function createGoogleEvent({
  accessToken,
  calendarId,
  payload,
}: {
  accessToken: string;
  calendarId: string;
  payload: GoogleEventPayload;
}): Promise<{ id: string; updated: string }> {
  const response = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    },
  );
  const data = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok || !data.id) {
    throw new Error(`Failed creating Google event: ${JSON.stringify(data)}`);
  }
  return {
    id: String(data.id),
    updated: String(data.updated ?? new Date().toISOString()),
  };
}

async function updateGoogleEvent({
  accessToken,
  calendarId,
  googleEventId,
  payload,
}: {
  accessToken: string;
  calendarId: string;
  googleEventId: string;
  payload: GoogleEventPayload;
}): Promise<{ id: string; updated: string }> {
  const response = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(googleEventId)}`,
    {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    },
  );
  const data = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) {
    throw new Error(`Failed updating Google event ${googleEventId}: ${JSON.stringify(data)}`);
  }
  return {
    id: String(data.id ?? googleEventId),
    updated: String(data.updated ?? new Date().toISOString()),
  };
}

// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = requireEnv("SUPABASE_URL");
    const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
    const googleClientId = requireEnv("GOOGLE_CLIENT_ID");
    const googleClientSecret = requireEnv("GOOGLE_CLIENT_SECRET");
    requireEnv("GOOGLE_REDIRECT_URI");

    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(supabaseUrl, serviceRoleKey, {
      global: {
        headers: {
          Authorization: authHeader,
        },
      },
    });

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();

    if (userError || !user) {
      return json(401, { ok: false, message: "Utilizator neautentificat." });
    }

    const body = (await req.json().catch(() => ({}))) as SyncPayload;
    const scope = body.scope ?? "organization";
    const organizationId = (body.organization_id ?? "").trim();
    const doPull = body.pull ?? true;
    const doDeletePropagation = body.delete_propagation ?? true;

    if (scope !== "organization" && scope !== "personal") {
      return json(400, { ok: false, message: "Scope invalid." });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("id, email, gmail_address, organization_id")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      return json(404, {
        ok: false,
        message: "Profilul utilizatorului nu a fost găsit.",
      });
    }

    let subjectGoogleEmail = "";
    let tokenQuery = supabase
      .from("google_oauth_tokens")
      .select("id, access_token, refresh_token, expires_at")
      .eq("subject_type", scope);

    let calendarId = "primary";

    if (scope === "organization") {
      if (!organizationId) {
        return json(400, {
          ok: false,
          message: "Lipsește organization_id.",
        });
      }

      const { data: org, error: orgError } = await supabase
        .from("organizations")
        .select("id, name, google_email")
        .eq("id", organizationId)
        .single();

      if (orgError || !org) {
        return json(404, {
          ok: false,
          message: "Organizația nu a fost găsită.",
        });
      }

      subjectGoogleEmail = (org.google_email ?? "").toString().trim();
      if (!subjectGoogleEmail) {
        return json(400, {
          ok: false,
          message:
            "Nu se poate efectua sincronizarea din cauza mailului organizației. Contactează un admin.",
        });
      }

      tokenQuery = tokenQuery.eq("organization_id", organizationId);

      const { data: orgSettings } = await supabase
        .from("organization_settings")
        .select("google_calendar_id")
        .eq("organization_id", organizationId)
        .maybeSingle();

      const maybeOrgCalendarId = (orgSettings?.google_calendar_id ?? "").toString().trim();
      if (maybeOrgCalendarId.length > 0) {
        calendarId = maybeOrgCalendarId;
      }
    } else {
      subjectGoogleEmail =
        (profile["gmail_address"] ?? profile["email"] ?? "").toString().trim();
      if (!subjectGoogleEmail) {
        return json(400, {
          ok: false,
          message:
            "Nu se poate efectua sincronizarea din cauza mailului utilizatorului. Contactează un admin.",
        });
      }
      tokenQuery = tokenQuery.eq("user_id", user.id);
    }

    const { data: tokenRow } = await tokenQuery.maybeSingle();

    if (!tokenRow?.refresh_token) {
      return json(200, {
        ok: false,
        auth_required: true,
        auth_url: buildAuthUrl({
          subjectType: scope,
          subjectId: scope === "organization" ? organizationId : user.id,
          googleEmail: subjectGoogleEmail,
        }),
        message:
          scope === "organization"
            ? "Este necesară autorizarea Google pentru calendarul organizației."
            : "Este necesară autorizarea Google pentru calendarul personal.",
      });
    }

    let accessToken = tokenRow.access_token ?? "";
    if (accessToken.length === 0 || isExpired(tokenRow.expires_at)) {
      try {
        accessToken = await refreshAccessToken({
          supabase,
          tokenRow,
          clientId: googleClientId,
          clientSecret: googleClientSecret,
        });
      } catch (_error) {
        return json(200, {
          ok: false,
          auth_required: true,
          auth_url: buildAuthUrl({
            subjectType: scope,
            subjectId: scope === "organization" ? organizationId : user.id,
            googleEmail: subjectGoogleEmail,
          }),
          message:
            "Token-ul Google nu mai este valid. Reautorizează pentru a continua sincronizarea.",
        });
      }
    }

    if (!doPull && !body.push) {
      return json(200, {
        ok: true,
        scope,
        message: "Token valid. Pull și push sunt dezactivate.",
      });
    }

    const now = new Date();
    const syncWindowStart = startOfUtcDay(now);
    const syncWindowEnd = endOfUtcDay(
      new Date(syncWindowStart.getTime() + SYNC_FORWARD_DAYS * 24 * 60 * 60 * 1000),
    );
    const localRetentionCutoff = startOfUtcDay(
      new Date(syncWindowStart.getTime() - LOCAL_RETENTION_DAYS * 24 * 60 * 60 * 1000),
    );

    // Shared stats (pull + push)
    let staleDeleted = 0;
    let created = 0;
    let updated = 0;
    let deleted = 0;
    let skipped = 0;
    let deduplicated = 0;
    let conflicts = 0;
    const conflictSamples: string[] = [];
    let googleTotal = 0;
    const sourceCalendarIds = new Set<string>([calendarId]);
    let pushCreated = 0;
    let pushUpdated = 0;
    let pushSkipped = 0;
    let pushErrors = 0;

    // ── PULL PHASE ────────────────────────────────────────────────────────────
    if (doPull) {
      // Keep local synced data compact without touching Google history.
      let staleQuery = supabase
        .from("events")
        .delete()
        .eq("event_scope", scope)
        .eq("source_provider", "google")
        .lt("end_time", localRetentionCutoff.toISOString());

      if (scope === "organization") {
        staleQuery = staleQuery.eq("organization_id", organizationId);
      } else {
        staleQuery = staleQuery.eq("owner_user_id", user.id);
      }

      const { data: staleDeletedRows, error: staleDeleteError } = await staleQuery.select("id");
      if (staleDeleteError) {
        throw new Error(`Failed deleting stale local synced events: ${staleDeleteError.message}`);
      }
      staleDeleted = (staleDeletedRows ?? []).length;

      if (scope === "organization") {
        const linked = await listGoogleCalendarIds({ accessToken });
        for (const id of linked) sourceCalendarIds.add(id);
      }

      const googleItemsWithCalendar: Array<{ item: Record<string, unknown>; calendarId: string }> = [];
      for (const sourceCalendarId of sourceCalendarIds) {
        const items = await listGoogleEvents({
          accessToken,
          calendarId: sourceCalendarId,
          timeMin: syncWindowStart.toISOString(),
          timeMax: syncWindowEnd.toISOString(),
        });
        for (const item of items) {
          googleItemsWithCalendar.push({ item, calendarId: sourceCalendarId });
        }
      }
      googleTotal = googleItemsWithCalendar.length;

      let localQuery = supabase
        .from("events")
        .select("id, source_external_id")
        .eq("source_provider", "google")
        .eq("event_scope", scope);

      if (scope === "organization") {
        localQuery = localQuery.eq("organization_id", organizationId);
      } else {
        localQuery = localQuery.eq("owner_user_id", user.id);
      }

      const { data: existingRows, error: existingRowsError } = await localQuery;
      if (existingRowsError) {
        throw new Error(`Failed loading local events map: ${existingRowsError.message}`);
      }

      let dedupeQuery = supabase
        .from("events")
        .select("id, title, location, description, google_description")
        .eq("event_scope", scope)
        .gte("end_time", localRetentionCutoff.toISOString())
        .lte("start_time", syncWindowEnd.toISOString());

      if (scope === "organization") {
        dedupeQuery = dedupeQuery.eq("organization_id", organizationId);
      } else {
        dedupeQuery = dedupeQuery.eq("owner_user_id", user.id);
      }

      const { data: dedupeRows, error: dedupeRowsError } = await dedupeQuery;
      if (dedupeRowsError) {
        throw new Error(`Failed loading local dedupe map: ${dedupeRowsError.message}`);
      }

      const localByExternalId = new Map<string, string>();
      for (const row of existingRows ?? []) {
        const externalId = (row.source_external_id ?? "").toString().trim();
        const localId = (row.id ?? "").toString().trim();
        if (externalId.length > 0 && localId.length > 0) {
          localByExternalId.set(externalId, localId);
        }
      }

      const localByFingerprint = new Map<string, string>();
      for (const row of dedupeRows ?? []) {
        const localId = (row.id ?? "").toString().trim();
        if (!localId) continue;
        const fp = buildDedupeFingerprint({
          title: row.title?.toString(),
          location: row.location?.toString(),
          description: (row.description ?? row.google_description)?.toString(),
        });
        if (!localByFingerprint.has(fp)) {
          localByFingerprint.set(fp, localId);
        }
      }

      const isOverlapConstraintError = (message: string): boolean => {
        const value = message.toLowerCase();
        return value.includes("prevent_overlapping_events") ||
          (value.includes("exclusion constraint") && value.includes("overlap"));
      };

      const rememberConflict = (externalEventId: string, title: string) => {
        conflicts += 1;
        skipped += 1;
        if (conflictSamples.length < 10) {
          conflictSamples.push(`${title || "Eveniment"} [${externalEventId}]`);
        }
      };

      for (const packet of googleItemsWithCalendar) {
        const item = packet.item;
        const sourceCalendarId = packet.calendarId;
        const rawExternalEventId = (item.id ?? "").toString().trim();
        if (rawExternalEventId.length === 0) {
          skipped += 1;
          continue;
        }
        const externalEventId = `${sourceCalendarId}::${rawExternalEventId}`;
        const status = (item.status ?? "confirmed").toString();
        const localId = localByExternalId.get(externalEventId) ??
          localByExternalId.get(rawExternalEventId);

        if (status === "cancelled") {
          if (doDeletePropagation && localId) {
            const { error: deleteError } = await supabase
              .from("events")
              .delete()
              .eq("id", localId);
            if (deleteError) {
              throw new Error(
                `Failed deleting cancelled local event ${localId}: ${deleteError.message}`,
              );
            }
            deleted += 1;
          }
          continue;
        }

        const window = parseGoogleEventWindow(item);
        if (!window) {
          skipped += 1;
          continue;
        }

        const participants = extractParticipants(item);
        const title = (item.summary ?? "Eveniment Google").toString().trim();
        const location = (item.location ?? "").toString().trim();
        const description = extractDescription(item);
        const fingerprint = buildDedupeFingerprint({
          title,
          location,
          description,
        });

        if (!localId && localByFingerprint.has(fingerprint)) {
          deduplicated += 1;
          skipped += 1;
          continue;
        }

        const eventPayload = {
          title: title.length > 0 ? title : "Eveniment Google",
          event_type: "Google",
          location,
          description,
          google_description: description,
          participants,
          start_time: window.startIso,
          end_time: window.endIso,
          source_all_day: window.isAllDay,
          event_scope: scope,
          owner_user_id: scope === "personal" ? user.id : null,
          organization_id: scope === "organization" ? organizationId : profile.organization_id,
          created_by: user.id,
          source_provider: "google",
          source_external_id: externalEventId,
          synced_at: new Date().toISOString(),
        };

        let resolvedLocalId = localId ?? "";
        if (resolvedLocalId.length > 0) {
          const { error: updateError } = await supabase
            .from("events")
            .update(eventPayload)
            .eq("id", resolvedLocalId);

          if (updateError) {
            if (isOverlapConstraintError(updateError.message)) {
              rememberConflict(externalEventId, title);
              continue;
            }
            throw new Error(`Failed updating local event ${resolvedLocalId}: ${updateError.message}`);
          }
          updated += 1;
        } else {
          const { data: inserted, error: insertError } = await supabase
            .from("events")
            .insert(eventPayload)
            .select("id")
            .single();

          if (insertError || !inserted?.id) {
            if (insertError && isOverlapConstraintError(insertError.message)) {
              rememberConflict(externalEventId, title);
              continue;
            }
            throw new Error(`Failed inserting local event for ${externalEventId}: ${insertError?.message ?? "missing id"}`);
          }
          resolvedLocalId = inserted.id.toString();
          localByExternalId.set(externalEventId, resolvedLocalId);
          localByExternalId.set(rawExternalEventId, resolvedLocalId);
          localByFingerprint.set(fingerprint, resolvedLocalId);
          created += 1;
        }

        const linkPayload = {
          local_event_id: resolvedLocalId,
          provider: "google",
          external_event_id: externalEventId,
          sync_scope: scope,
          owner_organization_id: scope === "organization" ? organizationId : null,
          owner_user_id: scope === "personal" ? user.id : null,
          external_etag: (item.etag ?? null) as string | null,
          external_updated_at: (item.updated ?? null) as string | null,
          deleted_in_external: false,
          deleted_in_local: false,
          last_seen_at: new Date().toISOString(),
        };

        const { error: linkError } = await supabase
          .from("external_event_links")
          .upsert(linkPayload, { onConflict: "provider,external_event_id,sync_scope" });

        if (linkError) {
          throw new Error(`Failed upserting external link for ${externalEventId}: ${linkError.message}`);
        }
      }
    }
    // ── END PULL PHASE ────────────────────────────────────────────────────────

    // ── PUSH PHASE ────────────────────────────────────────────────────────────
    if (body.push) {
      const composeTitle = body.compose_google_title ?? true;

      // Load app-managed events in the sync window (excludes Google-sourced).
      let localEventsQuery = supabase
        .from("events")
        .select("id, title, event_type, location, description, start_time, end_time, source_all_day, updated_at")
        .eq("event_scope", scope)
        .or("source_provider.is.null,source_provider.neq.google")
        .gte("end_time", syncWindowStart.toISOString())
        .lte("start_time", syncWindowEnd.toISOString());

      if (scope === "organization") {
        localEventsQuery = localEventsQuery.eq("organization_id", organizationId);
      } else {
        localEventsQuery = localEventsQuery.eq("owner_user_id", user.id);
      }

      const { data: localEvents, error: localEventsError } = await localEventsQuery;
      if (localEventsError) {
        throw new Error(`Failed loading local events for push: ${localEventsError.message}`);
      }

      const localEventIds = (localEvents ?? [])
        .map((e) => (e.id ?? "").toString())
        .filter(Boolean);

      type PushLink = {
        local_event_id: string;
        external_event_id: string;
        external_updated_at: string | null;
      };
      let existingPushLinks: PushLink[] = [];
      if (localEventIds.length > 0) {
        const { data: linksData, error: linksError } = await supabase
          .from("external_event_links")
          .select("local_event_id, external_event_id, external_updated_at")
          .in("local_event_id", localEventIds)
          .eq("provider", "google")
          .eq("sync_scope", scope);
        if (linksError) {
          throw new Error(`Failed loading push links: ${linksError.message}`);
        }
        existingPushLinks = (linksData ?? []) as PushLink[];
      }

      const pushLinkByLocalId = new Map<string, PushLink>(
        existingPushLinks.map((l) => [l.local_event_id.toString(), l]),
      );

      for (const event of localEvents ?? []) {
        const eventId = (event.id ?? "").toString();
        if (!eventId) continue;

        const existingLink = pushLinkByLocalId.get(eventId);
        const localUpdatedMs = event.updated_at ? new Date(event.updated_at).getTime() : 0;

        // Last Write Wins: skip if Google was updated at the same time or more recently.
        if (existingLink?.external_updated_at) {
          const googleUpdatedMs = new Date(existingLink.external_updated_at).getTime();
          if (googleUpdatedMs >= localUpdatedMs) {
            pushSkipped++;
            continue;
          }
        }

        const googlePayload = buildGoogleEventPayload(event as LocalEvent, composeTitle);

        try {
          if (existingLink) {
            // Update existing Google event.
            const rawGoogleId = existingLink.external_event_id.includes("::")
              ? existingLink.external_event_id.split("::").slice(1).join("::")
              : existingLink.external_event_id;

            const result = await updateGoogleEvent({
              accessToken,
              calendarId,
              googleEventId: rawGoogleId,
              payload: googlePayload,
            });

            await supabase
              .from("external_event_links")
              .update({
                external_updated_at: result.updated,
                last_seen_at: new Date().toISOString(),
              })
              .eq("local_event_id", eventId)
              .eq("provider", "google")
              .eq("sync_scope", scope);

            pushUpdated++;
          } else {
            // Create new Google event.
            const result = await createGoogleEvent({
              accessToken,
              calendarId,
              payload: googlePayload,
            });

            const newExternalId = `${calendarId}::${result.id}`;

            await supabase.from("external_event_links").insert({
              local_event_id: eventId,
              provider: "google",
              external_event_id: newExternalId,
              sync_scope: scope,
              owner_organization_id: scope === "organization" ? organizationId : null,
              owner_user_id: scope === "personal" ? user.id : null,
              external_updated_at: result.updated,
              deleted_in_external: false,
              deleted_in_local: false,
              last_seen_at: new Date().toISOString(),
            });

            pushCreated++;
          }
        } catch (_pushErr) {
          // Log individual push failures without aborting the entire sync.
          pushErrors++;
        }
      }
    }
    // ── END PUSH PHASE ────────────────────────────────────────────────────────

    const msgParts: string[] = [];
    if (conflicts > 0) {
      msgParts.push(
        scope === "organization"
          ? "Sincronizare organizație finalizată parțial (unele evenimente s-au suprapus cu programarea locală)."
          : "Sincronizare personală finalizată parțial (unele evenimente s-au suprapus cu programarea locală).",
      );
    } else {
      msgParts.push(
        scope === "organization"
          ? "Sincronizare organizație finalizată."
          : "Sincronizare personală finalizată.",
      );
    }
    if (body.push) {
      const pushParts: string[] = [];
      if (pushCreated > 0) pushParts.push(`${pushCreated} creat${pushCreated > 1 ? "e" : ""}`);
      if (pushUpdated > 0) pushParts.push(`${pushUpdated} actualizat${pushUpdated > 1 ? "e" : ""}`);
      if (pushParts.length > 0) {
        msgParts.push(`Push: ${pushParts.join(", ")} în Google Calendar.`);
      } else if (pushErrors > 0) {
        msgParts.push(`Push: ${pushErrors} error${pushErrors > 1 ? "i" : ""}.`);
      }
    }

    return json(200, {
      ok: true,
      scope,
      calendar_id: calendarId,
      message: msgParts.join(" "),
      stats: {
        google_total: googleTotal,
        source_calendars: Array.from(sourceCalendarIds),
        window_start: syncWindowStart.toISOString(),
        window_end: syncWindowEnd.toISOString(),
        stale_deleted_local: staleDeleted,
        created,
        updated,
        deleted,
        deduplicated,
        skipped,
        conflicts,
        push_created: pushCreated,
        push_updated: pushUpdated,
        push_skipped: pushSkipped,
        push_errors: pushErrors,
      },
      conflict_samples: conflictSamples,
      pull: doPull,
      push: body.push ?? false,
      delete_propagation: doDeletePropagation,
    });
  } catch (error) {
    return json(500, {
      ok: false,
      message: `Eroare funcție: ${error instanceof Error ? error.message : "unknown"}`,
    });
  }
});
