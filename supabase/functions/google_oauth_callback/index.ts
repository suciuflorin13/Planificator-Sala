import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const textHeaders = { "Content-Type": "text/plain; charset=utf-8" };

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing environment variable: ${name}`);
  }
  return value;
}

function renderPage(title: string, body: string) {
  const message = [
    title,
    "",
    body,
    "",
    "Poti inchide aceasta fereastra si sa revii in aplicatie.",
  ].join("\n");

  return new Response(message, { status: 200, headers: textHeaders });
}

Deno.serve(async (req: Request) => {
  try {
    const supabaseUrl = requireEnv("SUPABASE_URL");
    const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
    const clientId = requireEnv("GOOGLE_CLIENT_ID");
    const clientSecret = requireEnv("GOOGLE_CLIENT_SECRET");
    const redirectUri = requireEnv("GOOGLE_REDIRECT_URI");

    const url = new URL(req.url);
    const code = url.searchParams.get("code") ?? "";
    const stateRaw = url.searchParams.get("state") ?? "";
    const error = url.searchParams.get("error") ?? "";

    if (error.length > 0) {
      return renderPage("Autorizare anulată", `Google a returnat eroarea: ${error}.`);
    }

    if (!code || !stateRaw) {
      return renderPage("Date lipsă", "Lipsesc parametrii necesari pentru finalizarea autorizării Google.");
    }

    const state = JSON.parse(decodeURIComponent(stateRaw)) as {
      subject_type?: "organization" | "personal";
      subject_id?: string;
      google_email?: string;
    };

    if (!state.subject_type || !state.subject_id) {
      return renderPage("State invalid", "Nu s-a putut valida solicitarea de autorizare.");
    }

    const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri,
        grant_type: "authorization_code",
      }),
    });

    const tokenJson = await tokenResponse.json();
    if (!tokenResponse.ok) {
      return renderPage(
        "Token invalid",
        `Google nu a returnat un token valid: ${JSON.stringify(tokenJson)}`,
      );
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);
    let ownerQuery = supabase
      .from("google_oauth_tokens")
      .select("id, refresh_token")
      .eq("subject_type", state.subject_type);

    ownerQuery = state.subject_type === "organization"
      ? ownerQuery.eq("organization_id", state.subject_id)
      : ownerQuery.eq("user_id", state.subject_id);

    const { data: existingToken, error: existingTokenError } = await ownerQuery.maybeSingle();

    if (existingTokenError) {
      return renderPage(
        "Salvare eșuată",
        `Nu am putut verifica token-ul existent: ${existingTokenError.message}`,
      );
    }

    const tokenRow = {
      subject_type: state.subject_type,
      organization_id: state.subject_type === "organization" ? state.subject_id : null,
      user_id: state.subject_type === "personal" ? state.subject_id : null,
      google_email: state.google_email ?? null,
      access_token: tokenJson.access_token ?? null,
      // Google may omit refresh_token on subsequent consents. Keep existing one when missing.
      refresh_token: tokenJson.refresh_token ?? existingToken?.refresh_token ?? null,
      token_type: tokenJson.token_type ?? null,
      scope: tokenJson.scope ?? null,
      expires_at: tokenJson.expires_in
        ? new Date(Date.now() + Number(tokenJson.expires_in) * 1000).toISOString()
        : null,
    };

    if (existingToken?.id) {
      const { error: updateError } = await supabase
        .from("google_oauth_tokens")
        .update(tokenRow)
        .eq("id", existingToken.id);

      if (updateError) {
        return renderPage("Salvare eșuată", `Nu am putut actualiza token-ul: ${updateError.message}`);
      }
    } else {
      const { error: insertError } = await supabase
        .from("google_oauth_tokens")
        .insert(tokenRow);

      if (insertError) {
        return renderPage("Salvare eșuată", `Nu am putut salva token-ul: ${insertError.message}`);
      }
    }

    return renderPage(
      "Autorizare reușită",
      state.subject_type === "organization"
        ? "Calendarul organizației a fost conectat cu succes la Google."
        : "Calendarul personal a fost conectat cu succes la Google.",
    );
  } catch (error) {
    return renderPage(
      "Eroare",
      error instanceof Error ? error.message : "A apărut o eroare necunoscută.",
    );
  }
});
