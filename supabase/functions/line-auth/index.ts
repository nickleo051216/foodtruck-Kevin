// line-auth Edge Function 入口：把真正的 LINE 與 Supabase 接到 handler.ts
// 部署時 verify_jwt = false（車主這時還沒登入，沒有 Supabase 身分；改由 LINE ID Token 驗證）
import { createClient } from "npm:@supabase/supabase-js@2.49.4";
import { createHandler, LineVerifyError, syntheticEmail } from "./handler.ts";

// LINE Login channel ID（LIFF「Food-car」所在的 channel，Provider：Vegenn8n）
// 不是秘密，但可以用 Edge Function secret 覆蓋
const LINE_CHANNEL_ID = Deno.env.get("LINE_LOGIN_CHANNEL_ID") ?? "2010274155";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;

function pickKey(dictName: string, legacyName: string): string {
  const raw = Deno.env.get(dictName);
  if (raw) {
    try {
      const dict = JSON.parse(raw) as Record<string, string>;
      if (dict["default"]) return dict["default"];
    } catch { /* 用舊版金鑰 */ }
  }
  const legacy = Deno.env.get(legacyName);
  if (!legacy) throw new Error(`missing ${dictName} / ${legacyName}`);
  return legacy;
}

const SECRET_KEY = pickKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
const PUBLISHABLE_KEY = pickKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");

const noPersist = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(SUPABASE_URL, SECRET_KEY, noPersist);

const handler = createHandler({
  async verifyIdToken(idToken) {
    // LINE 官方驗證端點：會檢查簽章、是否過期、aud 是否等於我們的 channel ID
    const res = await fetch("https://api.line.me/oauth2/v2.1/verify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ id_token: idToken, client_id: LINE_CHANNEL_ID }),
    });
    const body = await res.json().catch(() => ({}));
    if (res.status === 400) throw new LineVerifyError(body?.error_description ?? "invalid id_token", 401);
    if (!res.ok) throw new LineVerifyError(`LINE verify HTTP ${res.status}`, 502);
    // 多一道保險：再確認一次 aud
    if (String(body.aud) !== LINE_CHANNEL_ID) throw new LineVerifyError("aud mismatch", 401);
    return { sub: body.sub, name: body.name, picture: body.picture };
  },

  async findVendorUserId(lineUserId) {
    const { data, error } = await admin.from("vendors").select("id").eq("line_user_id", lineUserId).maybeSingle();
    if (error) throw error;
    return data?.id ?? null;
  },

  async ensureAuthUser(lineUserId, displayName) {
    const email = syntheticEmail(lineUserId);
    const { data, error } = await admin.auth.admin.createUser({
      email,
      email_confirm: true,
      app_metadata: { login_via: "line", line_user_id: lineUserId },
      user_metadata: { display_name: displayName },
    });
    if (!error && data.user) return data.user.id;
    // 帳號已存在（例如上次建好帳號、但 vendors 還沒寫入就中斷）→ 找回它
    const { data: link, error: linkErr } = await admin.auth.admin.generateLink({ type: "magiclink", email });
    if (linkErr || !link.user) throw error ?? linkErr;
    return link.user.id;
  },

  async ensureVendorRow(userId, lineUserId, displayName) {
    const { error } = await admin.from("vendors").upsert(
      { id: userId, line_user_id: lineUserId, display_name: displayName },
      { onConflict: "id", ignoreDuplicates: true },
    );
    if (error) throw error;
  },

  async issueSession(lineUserId) {
    // 產生一次性登入連結（不會寄信），在伺服器端直接兌換成登入身分
    const { data: link, error } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email: syntheticEmail(lineUserId),
    });
    if (error) throw error;
    const anon = createClient(SUPABASE_URL, PUBLISHABLE_KEY, noPersist);
    const { data, error: otpErr } = await anon.auth.verifyOtp({
      type: "magiclink",
      token_hash: link.properties.hashed_token,
    });
    if (otpErr || !data.session) throw otpErr ?? new Error("no session");
    const s = data.session;
    return { access_token: s.access_token, refresh_token: s.refresh_token, expires_at: s.expires_at, expires_in: s.expires_in };
  },

  log(msg, extra) {
    // 不記錄 ID Token 或任何金鑰
    console.log(JSON.stringify({ fn: "line-auth", msg, ...extra }));
  },
});

Deno.serve(handler);
