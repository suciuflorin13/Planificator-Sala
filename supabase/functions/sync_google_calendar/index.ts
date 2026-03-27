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

function parseGoogleEventWindow(
  item: Record<string, unknown>,
): { startIso: string; endIso: string } | null {
  const startObj = (item.start ?? {}) as Record<string, unknown>;
  const endObj = (item.end ?? {}) as Record<string, unknown>;

  const startDateTime = (startObj.dateTime ?? null) as string | null;
  const endDateTime = (endObj.dateTime ?? null) as string | null;
  if (startDateTime && endDateTime) {
    const start = new Date(startDateTime);
    const end = new Date(endDateTime);
    if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return null;
    return { startIso: start.toISOString(), endIso: end.toISOString() };
  }

  const startDate = (startObj.date ?? null) as string | null;
  const endDate = (endObj.date ?? null) as string | null;
  if (startDate && endDate) {
    const start = new Date(`${startDate}T00:00:00Z`);
    const end = new Date(`${endDate}T00:00:00Z`);
    if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return null;
    return { startIso: start.toISOString(), endIso: end.toISOString() };
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
}: {
  accessToken: string;
  calendarId: string;
}): Promise<Array<Record<string, unknown>>> {
  const allItems: Array<Record<string, unknown>> = [];
  let pageToken: string | null = null;

  do {
    const params = new URLSearchParams({
      singleEvents: "true",
      showDeleted: "true",
      maxResults: "2500",
      orderBy: "updated",
      timeMin: new Date(Date.now() - 1000 * 60 * 60 * 24 * 120).toISOString(),
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

    if (!doPull) {
      return json(200, {
        ok: true,
        scope,
        message: "Token valid. Pull este dezactivat prin payload.",
      });
    }

    const googleItems = await listGoogleEvents({ accessToken, calendarId });

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

    const localByExternalId = new Map<string, string>();
    for (const row of existingRows ?? []) {
      const externalId = (row.source_external_id ?? "").toString().trim();
      const localId = (row.id ?? "").toString().trim();
      if (externalId.length > 0 && localId.length > 0) {
        localByExternalId.set(externalId, localId);
      }
    }

    let created = 0;
    let updated = 0;
    let deleted = 0;
    let skipped = 0;
    let conflicts = 0;
    const conflictSamples: string[] = [];

    function isOverlapConstraintError(message: string): boolean {
      const value = message.toLowerCase();
      return value.includes("prevent_overlapping_events") ||
        (value.includes("exclusion constraint") && value.includes("overlap"));
    }

    function rememberConflict(externalEventId: string, title: string) {
      conflicts += 1;
      skipped += 1;
      if (conflictSamples.length < 10) {
        conflictSamples.push(`${title || "Eveniment"} [${externalEventId}]`);
      }
    }

    for (const item of googleItems) {
      const externalEventId = (item.id ?? "").toString().trim();
      if (externalEventId.length === 0) {
        skipped += 1;
        continue;
      }
      const status = (item.status ?? "confirmed").toString();
      const localId = localByExternalId.get(externalEventId);

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

      const eventPayload = {
        title: title.length > 0 ? title : "Eveniment Google",
        event_type: "Google",
        location,
        participants,
        start_time: window.startIso,
        end_time: window.endIso,
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

    return json(200, {
      ok: true,
      scope,
      calendar_id: calendarId,
      message:
        conflicts > 0
          ? (scope === "organization"
            ? "Sincronizare organizație finalizată parțial (unele evenimente s-au suprapus cu programarea locală)."
            : "Sincronizare personală finalizată parțial (unele evenimente s-au suprapus cu programarea locală).")
          : (scope === "organization"
            ? "Sincronizare organizație finalizată."
            : "Sincronizare personală finalizată."),
      stats: {
        google_total: googleItems.length,
        created,
        updated,
        deleted,
        skipped,
        conflicts,
      },
      conflict_samples: conflictSamples,
      pull: doPull,
      push: body.push ?? false,
      delete_propagation: doDeletePropagation,
      push_note:
        body.push === true
          ? "Push local -> Google nu este implementat încă în această versiune."
          : null,
    });
  } catch (error) {
    return json(500, {
      ok: false,
      message: `Eroare funcție: ${error instanceof Error ? error.message : "unknown"}`,
    });
  }
});
