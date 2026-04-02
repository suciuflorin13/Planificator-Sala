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
  local_delete_event_id?: string;
  test_cleanup?: boolean;
  cleanup_start?: string;
  cleanup_end?: string;
  cleanup_local_older_than_days?: number;
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
const LOCAL_RETENTION_DAYS = 7;
const DB_PAGE_SIZE = 500;
const LINK_CHUNK_SIZE = 200;

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

function normalizeEventType(value: string | null | undefined): string {
  return normalizeDedupeValue(value);
}

function isGoogleEventType(value: string | null | undefined): boolean {
  return normalizeEventType(value) == "google";
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function stripKnownGooglePrefixes(title: string): string {
  let value = title.trim();
  // Remove repeated legacy prefixes such as "google - " or "google|".
  for (let i = 0; i < 6; i++) {
    const next = value.replace(/^google\s*[-|:]\s*/i, "").trim();
    if (next === value) break;
    value = next;
  }
  return value;
}

function composeGoogleSummary({
  type,
  title,
  composeTitle,
}: {
  type: string;
  title: string;
  composeTitle: boolean;
}): string {
  const rawType = type.trim();
  const rawTitle = title.trim();
  const cleanedTitle = stripKnownGooglePrefixes(rawTitle);

  if (!composeTitle) {
    return cleanedTitle || rawTitle || "Eveniment";
  }

  // If event type is Google, do not prefix type to avoid "google-google-title" growth.
  if (!rawType || isGoogleEventType(rawType)) {
    return cleanedTitle || rawTitle || "Eveniment";
  }

  const typePrefixRegex = new RegExp(`^${escapeRegExp(rawType)}\\s*[-|:]\\s*`, "i");
  const titleWithoutOwnPrefix = cleanedTitle.replace(typePrefixRegex, "").trim();
  const baseTitle = titleWithoutOwnPrefix || cleanedTitle || rawTitle;
  return [rawType, baseTitle].filter(Boolean).join(" - ");
}

function buildTypeTitleLocationFingerprint({
  eventType,
  title,
  location,
  startIso,
  endIso,
}: {
  eventType: string | null | undefined;
  title: string | null | undefined;
  location: string | null | undefined;
  startIso?: string | null | undefined;
  endIso?: string | null | undefined;
}): string {
  const normalizeTs = (iso: string | null | undefined): string => {
    if (!iso) return "";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return "";
    return d.toISOString().substring(0, 16);
  };

  return [
    normalizeDedupeValue(eventType),
    normalizeDedupeValue(title),
    normalizeDedupeValue(location),
    normalizeDedupeValue(normalizeTs(startIso)),
    normalizeDedupeValue(normalizeTs(endIso)),
  ].join("|");
}

// Google events are deduplicated by title + location + period.
function buildGoogleFingerprint({
  title,
  location,
  startIso,
  endIso,
}: {
  title: string | null | undefined;
  location: string | null | undefined;
  startIso?: string | null | undefined;
  endIso?: string | null | undefined;
}): string {
  const toTimeToken = (iso: string | null | undefined): string => {
    if (!iso) return "";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return "";
    return d.toISOString().substring(0, 16);
  };

  const startToken = toTimeToken(startIso);
  const endToken = toTimeToken(endIso);

  return [
    normalizeDedupeValue(title),
    normalizeDedupeValue(location),
    normalizeDedupeValue(startToken),
    normalizeDedupeValue(endToken),
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

async function refreshAccessToken({
  supabase,
  tokenRow,
  clientId,
  clientSecret,
}: {
  supabase: any;
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
  for await (const item of streamGoogleEvents({ accessToken, calendarId, timeMin, timeMax })) {
    allItems.push(item);
  }

  return allItems;
}

async function* streamGoogleEvents({
  accessToken,
  calendarId,
  timeMin,
  timeMax,
}: {
  accessToken: string;
  calendarId: string;
  timeMin: string;
  timeMax: string;
}): AsyncGenerator<Record<string, unknown>> {
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

    for (const item of payload.items ?? []) {
      yield item;
    }

    pageToken = payload.nextPageToken ?? null;
  } while (pageToken);
}

async function fetchAllPaged<T>({
  buildQuery,
  errorPrefix,
}: {
  buildQuery: () => any;
  errorPrefix: string;
}): Promise<T[]> {
  const rows: T[] = [];
  let from = 0;

  while (true) {
    const to = from + DB_PAGE_SIZE - 1;
    const { data, error } = await buildQuery().order("id", { ascending: true }).range(from, to);
    if (error) {
      throw new Error(`${errorPrefix}: ${error.message}`);
    }

    const page = (data ?? []) as T[];
    if (page.length === 0) break;
    rows.push(...page);
    if (page.length < DB_PAGE_SIZE) break;
    from += DB_PAGE_SIZE;
  }

  return rows;
}

function splitIntoChunks<T>(values: T[], size: number): T[][] {
  if (values.length === 0) return [];
  const out: T[][] = [];
  for (let i = 0; i < values.length; i += size) {
    out.push(values.slice(i, i + size));
  }
  return out;
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
  participants: string[];
  start_time: string;
  end_time: string;
  source_all_day: boolean;
  updated_at: string | null;
};

type ProfileLite = {
  id: string;
  email: string | null;
  gmail_address: string | null;
  full_name: string | null;
  first_name: string | null;
  last_name: string | null;
  organization_id: string | null;
};

type GoogleAttendeePayload = {
  email: string;
  displayName?: string;
};

type LocalDeleteCandidate = {
  id: string;
  title: string;
  event_type: string;
  location: string;
  start_time: string;
  end_time: string;
  source_provider: string | null;
  event_scope: string;
  owner_user_id: string | null;
  organization_id: string | null;
};

type GoogleEventPayload = {
  summary: string;
  location?: string;
  description?: string;
  attendees?: GoogleAttendeePayload[];
  start: { dateTime?: string; date?: string; timeZone?: string };
  end: { dateTime?: string; date?: string; timeZone?: string };
};

function normalizeEmail(value: string | null | undefined): string {
  return (value ?? "").toString().trim().toLowerCase();
}

function parseEmailCandidate(value: string | null | undefined): string {
  const raw = (value ?? "").toString().trim();
  if (!raw) return "";
  const bracketMatch = raw.match(/<([^>]+)>/);
  const candidate = bracketMatch ? bracketMatch[1] : raw;
  const emailMatch = candidate.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
  return normalizeEmail(emailMatch ? emailMatch[0] : "");
}

function profileDisplayName(profile: ProfileLite): string {
  const full = (profile.full_name ?? "").toString().trim();
  if (full) return full;
  const merged = `${(profile.first_name ?? "").toString().trim()} ${(profile.last_name ?? "").toString().trim()}`.trim();
  if (merged) return merged;
  return normalizeEmail(profile.email) || normalizeEmail(profile.gmail_address);
}

function resolveParticipantsFromGoogleItem(
  item: Record<string, unknown>,
  profileNameByEmail: Map<string, string>,
): string[] {
  const attendees = Array.isArray(item.attendees)
    ? (item.attendees as Array<Record<string, unknown>>)
    : [];

  const values: string[] = [];
  for (const attendee of attendees) {
    const email = normalizeEmail((attendee.email ?? "").toString());
    const displayNameRaw = (attendee.displayName ?? "").toString().trim();
    if (email && profileNameByEmail.has(email)) {
      values.push(profileNameByEmail.get(email)!);
      continue;
    }

    if (displayNameRaw) {
      values.push(displayNameRaw);
      continue;
    }

    if (email) {
      values.push(email.split("@")[0]);
    }
  }

  return Array.from(new Set(values)).slice(0, 40);
}

function resolveGoogleAttendeesFromLocalParticipants({
  participants,
  profileEmailByName,
  profileNameByEmail,
}: {
  participants: string[];
  profileEmailByName: Map<string, string>;
  profileNameByEmail: Map<string, string>;
}): GoogleAttendeePayload[] {
  const out: GoogleAttendeePayload[] = [];
  const seen = new Set<string>();

  for (const raw of participants) {
    const name = (raw ?? "").toString().trim();
    if (!name) continue;

    let email = "";
    const emailFromText = parseEmailCandidate(name);
    if (emailFromText) {
      email = emailFromText;
    } else {
      email = profileEmailByName.get(normalizeDedupeValue(name)) ?? "";
    }

    if (!email || seen.has(email)) continue;
    seen.add(email);

    const displayName = profileNameByEmail.get(email) ?? name;
    out.push({ email, displayName });
  }

  return out.slice(0, 100);
}

function isLocalAllDayEvent(event: LocalEvent): boolean {
  if (event.source_all_day === true) return true;

  const start = new Date(event.start_time);
  const end = new Date(event.end_time);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return false;

  const sH = start.getUTCHours();
  const sM = start.getUTCMinutes();
  const eH = end.getUTCHours();
  const eM = end.getUTCMinutes();

  // Canonical all-day local representation in app.
  if (sH === 0 && sM === 0 && eH === 23 && (eM === 59 || eM === 58)) {
    return true;
  }

  // Legacy all-day marker used in availability logic.
  if (sH === 9 && sM === 0 && eH === 23 && eM === 0) {
    return true;
  }

  return false;
}

function buildGoogleEventPayload(
  event: LocalEvent,
  composeTitle: boolean,
  attendees: GoogleAttendeePayload[],
): GoogleEventPayload {
  const rawTitle = (event.title ?? "").toString().trim();
  const type = (event.event_type ?? "").toString().trim();
  const loc = (event.location ?? "").toString().trim();

  const summary = composeGoogleSummary({
    type,
    title: rawTitle,
    composeTitle,
  });

  const isAllDay = isLocalAllDayEvent(event);
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
  if (attendees.length > 0) payload.attendees = attendees;
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

async function deleteGoogleEvent({
  accessToken,
  calendarId,
  googleEventId,
}: {
  accessToken: string;
  calendarId: string;
  googleEventId: string;
}): Promise<void> {
  const response = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(googleEventId)}`,
    {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    },
  );

  if (response.status === 404 || response.status === 410) {
    return;
  }

  if (!response.ok) {
    const payload = (await response.json().catch(() => ({}))) as Record<string, unknown>;
    throw new Error(`Failed deleting Google event ${googleEventId}: ${JSON.stringify(payload)}`);
  }
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
    const localDeleteEventId = (body.local_delete_event_id ?? "").trim();
    const isTestCleanup = body.test_cleanup === true;

    if (scope !== "organization" && scope !== "personal") {
      return json(400, { ok: false, message: "Scope invalid." });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("id, email, gmail_address, organization_id, role")
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

    if (isTestCleanup) {
      const role = (profile["role"] ?? "").toString().trim().toLowerCase();
      if (role !== "admin") {
        return json(403, {
          ok: false,
          scope,
          message: "Doar admin poate folosi curățarea de test.",
        });
      }

      const olderThanDays = Math.max(1, Math.min(30, Number(body.cleanup_local_older_than_days ?? 7)));
      const now = new Date();
      const parsedStart = body.cleanup_start ? new Date(body.cleanup_start) : null;
      const weekStartBase = parsedStart && !Number.isNaN(parsedStart.getTime()) ? parsedStart : now;
      const weekStart = startOfUtcDay(weekStartBase);

      const parsedEnd = body.cleanup_end ? new Date(body.cleanup_end) : null;
      let weekEnd = parsedEnd && !Number.isNaN(parsedEnd.getTime())
        ? endOfUtcDay(parsedEnd)
        : endOfUtcDay(new Date(weekStart.getTime() + 6 * 24 * 60 * 60 * 1000));

      const maxEnd = endOfUtcDay(new Date(weekStart.getTime() + 6 * 24 * 60 * 60 * 1000));
      if (weekEnd.getTime() > maxEnd.getTime()) {
        weekEnd = maxEnd;
      }

      if (weekEnd.getTime() < weekStart.getTime()) {
        return json(400, {
          ok: false,
          scope,
          message: "Interval cleanup invalid.",
        });
      }

      let weeklyCleanupQuery = supabase
        .from("events")
        .delete()
        .eq("event_scope", scope)
        .or("source_provider.is.null,source_provider.neq.google")
        .gte("start_time", weekStart.toISOString())
        .lte("start_time", weekEnd.toISOString());

      if (scope === "organization") {
        weeklyCleanupQuery = weeklyCleanupQuery.eq("organization_id", organizationId);
      } else {
        weeklyCleanupQuery = weeklyCleanupQuery.eq("owner_user_id", user.id);
      }

      const { data: weeklyDeletedRows, error: weeklyDeleteError } = await weeklyCleanupQuery.select("id");
      if (weeklyDeleteError) {
        throw new Error(`Failed test cleanup on selected week: ${weeklyDeleteError.message}`);
      }

      const olderCutoff = startOfUtcDay(new Date(now.getTime() - olderThanDays * 24 * 60 * 60 * 1000));
      let oldCleanupQuery = supabase
        .from("events")
        .delete()
        .eq("event_scope", scope)
        .or("source_provider.is.null,source_provider.neq.google")
        .lt("end_time", olderCutoff.toISOString());

      if (scope === "organization") {
        oldCleanupQuery = oldCleanupQuery.eq("organization_id", organizationId);
      } else {
        oldCleanupQuery = oldCleanupQuery.eq("owner_user_id", user.id);
      }

      const { data: oldDeletedRows, error: oldDeleteError } = await oldCleanupQuery.select("id");
      if (oldDeleteError) {
        throw new Error(`Failed test cleanup for older events: ${oldDeleteError.message}`);
      }

      return json(200, {
        ok: true,
        scope,
        test_cleanup: true,
        message: "Curățare de test finalizată.",
        stats: {
          cleanup_start: weekStart.toISOString(),
          cleanup_end: weekEnd.toISOString(),
          cleanup_older_than_days: olderThanDays,
          deleted_in_selected_week: (weeklyDeletedRows ?? []).length,
          deleted_older_than_cutoff: (oldDeletedRows ?? []).length,
          older_cutoff: olderCutoff.toISOString(),
        },
      });
    }

    let profileLookupQuery = supabase
      .from("profiles")
      .select("id, email, gmail_address, full_name, first_name, last_name, organization_id");

    if (scope === "organization") {
      profileLookupQuery = profileLookupQuery.eq("organization_id", organizationId);
    } else {
      const userOrgId = (profile.organization_id ?? "").toString().trim();
      if (userOrgId) {
        profileLookupQuery = profileLookupQuery.eq("organization_id", userOrgId);
      } else {
        profileLookupQuery = profileLookupQuery.eq("id", user.id);
      }
    }

    const { data: profileRows, error: profileRowsError } = await profileLookupQuery;
    if (profileRowsError) {
      throw new Error(`Failed loading profile lookup map: ${profileRowsError.message}`);
    }

    const profileNameByEmail = new Map<string, string>();
    const profileEmailByName = new Map<string, string>();
    for (const row of (profileRows ?? []) as ProfileLite[]) {
      const displayName = profileDisplayName(row);
      const displayNameKey = normalizeDedupeValue(displayName);
      const primaryEmail = normalizeEmail(row.email);
      const gmailEmail = normalizeEmail(row.gmail_address);

      if (primaryEmail) {
        profileNameByEmail.set(primaryEmail, displayName);
        if (!profileEmailByName.has(displayNameKey)) {
          profileEmailByName.set(displayNameKey, primaryEmail);
        }
      }

      if (gmailEmail) {
        profileNameByEmail.set(gmailEmail, displayName);
        if (!profileEmailByName.has(displayNameKey)) {
          profileEmailByName.set(displayNameKey, gmailEmail);
        }
      }
    }

    let localDeleteCandidate: LocalDeleteCandidate | null = null;
    if (localDeleteEventId) {
      const { data: eventForDelete, error: eventForDeleteError } = await supabase
        .from("events")
        .select("id, title, event_type, location, start_time, end_time, source_provider, event_scope, owner_user_id, organization_id")
        .eq("id", localDeleteEventId)
        .maybeSingle();

      if (eventForDeleteError) {
        throw new Error(`Failed loading local delete candidate: ${eventForDeleteError.message}`);
      }

      if (!eventForDelete?.id) {
        return json(200, {
          ok: true,
          scope,
          local_delete: true,
          skipped: true,
          message: "Evenimentul local nu mai există. Nu este necesară ștergerea în Google.",
        });
      }

      localDeleteCandidate = eventForDelete as LocalDeleteCandidate;

      const eventScope = (localDeleteCandidate.event_scope ?? "").toString();
      if (eventScope !== scope) {
        return json(400, {
          ok: false,
          scope,
          local_delete: true,
          message: "Scope-ul transmis nu corespunde evenimentului local.",
        });
      }

      if (scope === "organization") {
        const eventOrgId = (localDeleteCandidate.organization_id ?? "").toString();
        if (!eventOrgId || eventOrgId != organizationId) {
          return json(403, {
            ok: false,
            scope,
            local_delete: true,
            message: "Evenimentul nu aparține organizației selectate.",
          });
        }
      } else {
        const ownerId = (localDeleteCandidate.owner_user_id ?? "").toString();
        if (ownerId != user.id) {
          return json(403, {
            ok: false,
            scope,
            local_delete: true,
            message: "Evenimentul personal nu aparține utilizatorului curent.",
          });
        }
      }

      const sourceProvider = (localDeleteCandidate.source_provider ?? "").toString().trim().toLowerCase();
      if (sourceProvider === "google" || isGoogleEventType(localDeleteCandidate.event_type)) {
        return json(200, {
          ok: true,
          scope,
          local_delete: true,
          skipped: true,
          message: "Eveniment de tip Google: ștergerea locală nu modifică Google Calendar.",
        });
      }
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

    if (localDeleteCandidate != null) {
      const { data: linkRow, error: linkRowError } = await supabase
        .from("external_event_links")
        .select("external_event_id")
        .eq("local_event_id", localDeleteCandidate.id)
        .eq("provider", "google")
        .eq("sync_scope", scope)
        .maybeSingle();

      if (linkRowError) {
        throw new Error(`Failed loading external link for local delete: ${linkRowError.message}`);
      }

      if (linkRow?.external_event_id) {
        const externalId = linkRow.external_event_id.toString();
        const googleCalendarId = externalId.includes("::")
          ? externalId.split("::")[0]
          : calendarId;
        const googleEventId = externalId.includes("::")
          ? externalId.split("::").slice(1).join("::")
          : externalId;

        await deleteGoogleEvent({
          accessToken,
          calendarId: googleCalendarId,
          googleEventId,
        });

        return json(200, {
          ok: true,
          scope,
          local_delete: true,
          deleted_in_google: true,
          message: "Evenimentul local a fost șters și din Google Calendar.",
        });
      }

      // Fallback for older events without link rows (legacy title formats).
      const localStart = new Date(localDeleteCandidate.start_time);
      const localEnd = new Date(localDeleteCandidate.end_time);
      const timeMin = new Date(localStart.getTime() - 24 * 60 * 60 * 1000).toISOString();
      const timeMax = new Date(localEnd.getTime() + 24 * 60 * 60 * 1000).toISOString();
      const googleItems = await listGoogleEvents({
        accessToken,
        calendarId,
        timeMin,
        timeMax,
      });

      const title = (localDeleteCandidate.title ?? "").toString().trim();
      const eventType = (localDeleteCandidate.event_type ?? "").toString().trim();
      const location = (localDeleteCandidate.location ?? "").toString().trim();
      const candidateSummaries = new Set<string>([
        normalizeDedupeValue([eventType, title].filter(Boolean).join(" - ")),
        normalizeDedupeValue([title, eventType, location].filter(Boolean).join(" | ")),
        normalizeDedupeValue([title, eventType].filter(Boolean).join(" | ")),
        normalizeDedupeValue(title),
      ]);
      const locationNorm = normalizeDedupeValue(location);

      let matchedGoogleEventId = "";
      for (const item of googleItems) {
        if ((item.status ?? "").toString() === "cancelled") continue;
        const summaryNorm = normalizeDedupeValue((item.summary ?? "").toString());
        const locationItemNorm = normalizeDedupeValue((item.location ?? "").toString());
        const id = (item.id ?? "").toString().trim();
        if (!id) continue;
        if (!candidateSummaries.has(summaryNorm)) continue;
        if (locationNorm && locationItemNorm && locationNorm != locationItemNorm) continue;
        matchedGoogleEventId = id;
        break;
      }

      if (!matchedGoogleEventId) {
        return json(200, {
          ok: true,
          scope,
          local_delete: true,
          skipped: true,
          message: "Eveniment local șters. Nu a fost găsită o corespondență Google de șters.",
        });
      }

      await deleteGoogleEvent({
        accessToken,
        calendarId,
        googleEventId: matchedGoogleEventId,
      });

      return json(200, {
        ok: true,
        scope,
        local_delete: true,
        deleted_in_google: true,
        message: "Evenimentul local a fost șters și din Google Calendar (fallback legacy).",
      });
    }

    if (!doPull && !body.push) {
      return json(200, {
        ok: true,
        scope,
        message: "Token valid. Pull și push sunt dezactivate.",
      });
    }

    const now = new Date();
    // Sync window starts LOCAL_RETENTION_DAYS ago so recently-modified events are refreshed.
    const syncWindowStart = startOfUtcDay(
      new Date(now.getTime() - LOCAL_RETENTION_DAYS * 24 * 60 * 60 * 1000),
    );
    const syncWindowEnd = endOfUtcDay(
      new Date(now.getTime() + SYNC_FORWARD_DAYS * 24 * 60 * 60 * 1000),
    );
    const localRetentionCutoff = syncWindowStart;

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

      const linked = await listGoogleCalendarIds({ accessToken });
      for (const id of linked) sourceCalendarIds.add(id);

      const existingRows = await fetchAllPaged<{ id: string | null; source_external_id: string | null }>({
        buildQuery: () => {
          let q = supabase
            .from("events")
            .select("id, source_external_id")
            .eq("source_provider", "google")
            .eq("event_scope", scope);

          if (scope === "organization") {
            q = q.eq("organization_id", organizationId);
          } else {
            q = q.eq("owner_user_id", user.id);
          }

          return q;
        },
        errorPrefix: "Failed loading local events map",
      });

      // The dedupe map must only contain APP-managed events (not Google-imported ones).
      // Google events are matched exclusively by external ID; including them here would
      // incorrectly block re-import of events whose external ID format changed.
      const dedupeRows = await fetchAllPaged<{
        id: string | null;
        title: string | null;
        location: string | null;
        start_time: string | null;
        end_time: string | null;
      }>({
        buildQuery: () => {
          let q = supabase
            .from("events")
            .select("id, title, location, start_time, end_time")
            .or("source_provider.is.null,source_provider.neq.google")
            .gte("end_time", localRetentionCutoff.toISOString())
            .lte("start_time", syncWindowEnd.toISOString());

          if (scope === "organization") {
            q = q.eq("organization_id", organizationId);
          } else {
            const userOrgId = (profile.organization_id ?? "").toString().trim();
            if (userOrgId.length > 0) {
              q = q.or(`owner_user_id.eq.${user.id},organization_id.eq.${userOrgId}`);
            } else {
              q = q.eq("owner_user_id", user.id);
            }
          }

          return q;
        },
        errorPrefix: "Failed loading local dedupe map",
      });

      const localByExternalId = new Map<string, string>();
      for (const row of existingRows ?? []) {
        const externalId = (row.source_external_id ?? "").toString().trim();
        const localId = (row.id ?? "").toString().trim();
        if (externalId.length > 0 && localId.length > 0) {
          localByExternalId.set(externalId, localId);
        }
      }

      const localByGoogleFingerprint = new Map<string, string>();
      for (const row of dedupeRows ?? []) {
        const localId = (row.id ?? "").toString().trim();
        if (!localId) continue;

        const googleFp = buildGoogleFingerprint({
          title: row.title?.toString(),
          location: row.location?.toString(),
          startIso: row.start_time?.toString(),
          endIso: row.end_time?.toString(),
        });
        if (!localByGoogleFingerprint.has(googleFp)) {
          localByGoogleFingerprint.set(googleFp, localId);
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

      for (const sourceCalendarId of sourceCalendarIds) {
        for await (const item of streamGoogleEvents({
          accessToken,
          calendarId: sourceCalendarId,
          timeMin: syncWindowStart.toISOString(),
          timeMax: syncWindowEnd.toISOString(),
        })) {
          googleTotal += 1;

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

          const participants = resolveParticipantsFromGoogleItem(item, profileNameByEmail);
          const title = (item.summary ?? "Eveniment Google").toString().trim();
          const location = (item.location ?? "").toString().trim();
          const description = extractDescription(item);
          const fingerprint = buildGoogleFingerprint({
            title,
            location,
            startIso: window.startIso,
            endIso: window.endIso,
          });

          if (!localId && localByGoogleFingerprint.has(fingerprint)) {
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
            localByGoogleFingerprint.set(fingerprint, resolvedLocalId);
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
    }
    // ── END PULL PHASE ────────────────────────────────────────────────────────

    // ── PUSH PHASE ────────────────────────────────────────────────────────────
    if (body.push) {
      const composeTitle = body.compose_google_title ?? true;

      type GoogleEventEntry = {
        id: string;
        updated: string | null;
      };

      const googleByFingerprint = new Map<string, GoogleEventEntry>();
      for await (const item of streamGoogleEvents({
        accessToken,
        calendarId,
        timeMin: syncWindowStart.toISOString(),
        timeMax: syncWindowEnd.toISOString(),
      })) {
        if ((item.status ?? "").toString() === "cancelled") continue;
        const id = (item.id ?? "").toString().trim();
        if (!id) continue;
        const title = (item.summary ?? "").toString().trim();
        const location = (item.location ?? "").toString().trim();
        const window = parseGoogleEventWindow(item);
        const startIso = window?.startIso ?? "";
        const endIso = window?.endIso ?? "";
        const fp = buildGoogleFingerprint({ title, location, startIso, endIso });
        if (!googleByFingerprint.has(fp)) {
          googleByFingerprint.set(fp, {
            id,
            updated: (item.updated ?? null) as string | null,
          });
        }
      }

      // Load app-managed events in the sync window (excludes Google-sourced).
      type PushLink = {
        local_event_id: string;
        external_event_id: string;
        external_updated_at: string | null;
      };
      const localEvents = await fetchAllPaged<any>({
        buildQuery: () => {
          let q = supabase
            .from("events")
            .select("id, title, event_type, location, description, participants, start_time, end_time, source_all_day, source_provider, updated_at")
            .eq("event_scope", scope)
            .gte("end_time", syncWindowStart.toISOString())
            .lte("start_time", syncWindowEnd.toISOString());

          if (scope === "organization") {
            q = q.eq("organization_id", organizationId);
          } else {
            q = q.eq("owner_user_id", user.id);
          }

          return q;
        },
        errorPrefix: "Failed loading local events for push",
      });

      const pushLinkByLocalId = new Map<string, PushLink>();
      const localEventIds = localEvents
        .map((e) => (e.id ?? "").toString())
        .filter(Boolean);
      for (const idChunk of splitIntoChunks(localEventIds, LINK_CHUNK_SIZE)) {
        const { data: linksData, error: linksError } = await supabase
          .from("external_event_links")
          .select("local_event_id, external_event_id, external_updated_at")
          .in("local_event_id", idChunk)
          .eq("provider", "google")
          .eq("sync_scope", scope);
        if (linksError) {
          throw new Error(`Failed loading push links: ${linksError.message}`);
        }
        for (const link of (linksData ?? []) as PushLink[]) {
          const key = (link.local_event_id ?? "").toString();
          if (key) pushLinkByLocalId.set(key, link);
        }
      }

      const seenLocalTypeTitleLocation = new Set<string>();

      for (const event of localEvents ?? []) {
        const eventId = (event.id ?? "").toString();
        if (!eventId) continue;

        const localTypeTitleLocationFp = buildTypeTitleLocationFingerprint({
          eventType: (event.event_type ?? "").toString(),
          title: (event.title ?? "").toString(),
          location: (event.location ?? "").toString(),
          startIso: (event.start_time ?? "").toString(),
          endIso: (event.end_time ?? "").toString(),
        });
        if (seenLocalTypeTitleLocation.has(localTypeTitleLocationFp)) {
          pushSkipped++;
          continue;
        }
        seenLocalTypeTitleLocation.add(localTypeTitleLocationFp);

        const existingLink = pushLinkByLocalId.get(eventId);
        const sourceProvider = (event.source_provider ?? "").toString().trim().toLowerCase();
        const isGoogleTyped = isGoogleEventType((event.event_type ?? "").toString());
        const localUpdatedMs = event.updated_at ? new Date(event.updated_at).getTime() : 0;

        // Push/LWW is applied only for app events.
        if (sourceProvider === "google" || isGoogleTyped) {
          pushSkipped++;
          continue;
        }

        // Skip push if the event was already synced and the app event has not changed
        // since the last successful push (external_updated_at >= local updated_at).
        if (existingLink) {
          if (existingLink.external_updated_at) {
            const googleUpdatedMs = new Date(existingLink.external_updated_at).getTime();
            if (googleUpdatedMs >= localUpdatedMs) {
              pushSkipped++;
              continue;
            }
          }
          // existingLink exists but no timestamp → app event has never been successfully
          // round-tripped; fall through to update so the link gets a fresh timestamp.
        }

        const attendees = resolveGoogleAttendeesFromLocalParticipants({
          participants: Array.isArray(event.participants)
            ? event.participants.map((p: unknown) => (p ?? "").toString())
            : [],
          profileEmailByName,
          profileNameByEmail,
        });

        const googlePayload = buildGoogleEventPayload(event as LocalEvent, composeTitle, attendees);
        const googleFingerprint = buildGoogleFingerprint({
          title: googlePayload.summary,
          location: googlePayload.location ?? "",
          startIso: event.start_time,
          endIso: event.end_time,
        });

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

            googleByFingerprint.set(googleFingerprint, {
              id: result.id,
              updated: result.updated,
            });

            pushUpdated++;
          } else {
            const existingGoogleByFingerprint = googleByFingerprint.get(googleFingerprint);
            if (existingGoogleByFingerprint) {
              const existingExternalId = `${calendarId}::${existingGoogleByFingerprint.id}`;
              await supabase.from("external_event_links").upsert({
                local_event_id: eventId,
                provider: "google",
                external_event_id: existingExternalId,
                sync_scope: scope,
                owner_organization_id: scope === "organization" ? organizationId : null,
                owner_user_id: scope === "personal" ? user.id : null,
                external_updated_at: existingGoogleByFingerprint.updated,
                deleted_in_external: false,
                deleted_in_local: false,
                last_seen_at: new Date().toISOString(),
              }, { onConflict: "provider,external_event_id,sync_scope" });

              pushSkipped++;
              continue;
            }

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

            googleByFingerprint.set(googleFingerprint, {
              id: result.id,
              updated: result.updated,
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
