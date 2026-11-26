// =====================================================================
// line-auth：把「LINE 身分」換成「Supabase 登入身分」（第 2 步，方案 A）
//
// 白話流程：
//   1. 車主在 LINE 裡打開 LIFF，前端呼叫 liff.getIDToken() 拿到「LINE 簽名的身分證」
//   2. 前端把它 POST 到這支程式：{ "id_token": "..." }
//   3. 這支程式拿去問 LINE「這張是真的嗎？是發給我們 channel 的嗎？過期了沒？」
//   4. 是真的 → 找到（或建立）這位車主的帳號與 vendors 資料
//   5. 發一組 Supabase 登入身分（access_token / refresh_token）回給前端
//
// 安全原則：
//   - 絕對不相信前端直接傳來的 userId、暱稱（LINE 官方也這樣建議）
//   - 最高權限金鑰只在這支程式裡用，不會回傳給前端
//   - 只接受 foodtruck-kevin.vercel.app 與它的 Vercel 預覽網址呼叫
//
// 這個檔案只放「邏輯」，外部服務（LINE、Supabase）都從 deps 傳進來，
// 所以可以在本機用假的 LINE / Supabase 測試（見 supabase/functions/tests）。
// =====================================================================

export type LineClaims = { sub: string; name?: string; picture?: string };

export type Session = {
  access_token: string;
  refresh_token: string;
  expires_at?: number;
  expires_in?: number;
};

export interface Deps {
  /** 向 LINE 驗證 ID Token；失敗時丟出 LineVerifyError */
  verifyIdToken(idToken: string): Promise<LineClaims>;
  /** 用 LINE userId 找車主的 Supabase user id；找不到回傳 null */
  findVendorUserId(lineUserId: string): Promise<string | null>;
  /** 建立（或找回）這位車主的 auth 帳號，回傳 user id */
  ensureAuthUser(lineUserId: string, displayName: string): Promise<string>;
  /** 建立 vendors 資料（已存在就不動，保留車主自己改過的名稱） */
  ensureVendorRow(userId: string, lineUserId: string, displayName: string): Promise<void>;
  /** 發登入身分 */
  issueSession(lineUserId: string): Promise<Session>;
  log?(msg: string, extra?: Record<string, unknown>): void;
}

export class LineVerifyError extends Error {
  constructor(message: string, readonly status = 401) {
    super(message);
  }
}

// 正式網址 + Vercel 預覽網址（foodtruck-kevin-xxxx.vercel.app）
const ORIGIN_RE = /^https:\/\/foodtruck-kevin(?:-[a-z0-9-]+)?\.vercel\.app$/;

export function isAllowedOrigin(origin: string | null): boolean {
  return !!origin && ORIGIN_RE.test(origin);
}

/** 每位車主在 Supabase Auth 的內部代號（車主看不到，也不會寄信） */
export function syntheticEmail(lineUserId: string): string {
  return `line-${lineUserId.toLowerCase()}@users.foodtruck.invalid`;
}

const LINE_USER_ID_RE = /^U[0-9a-f]{32}$/;

function cleanName(name: string | undefined): string {
  const n = (name ?? "").trim().slice(0, 60);
  return n.length > 0 ? n : "車主";
}

function corsHeaders(origin: string | null): Record<string, string> {
  const h: Record<string, string> = {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Max-Age": "600",
    "Vary": "Origin",
  };
  if (isAllowedOrigin(origin)) h["Access-Control-Allow-Origin"] = origin!;
  return h;
}

function json(status: number, body: unknown, origin: string | null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json; charset=utf-8" },
  });
}

export function createHandler(deps: Deps) {
  return async (req: Request): Promise<Response> => {
    const origin = req.headers.get("origin");

    if (req.method === "OPTIONS") {
      return new Response(null, { status: isAllowedOrigin(origin) ? 204 : 403, headers: corsHeaders(origin) });
    }
    if (!isAllowedOrigin(origin)) {
      return json(403, { ok: false, code: "origin_not_allowed", message: "不允許從這個網址登入" }, origin);
    }
    if (req.method !== "POST") {
      return json(405, { ok: false, code: "method_not_allowed", message: "只接受 POST" }, origin);
    }

    let idToken: unknown;
    try {
      idToken = (await req.json())?.id_token;
    } catch {
      idToken = undefined;
    }
    if (typeof idToken !== "string" || idToken.length < 20 || idToken.length > 4096) {
      return json(400, { ok: false, code: "missing_id_token", message: "缺少 LINE 登入憑證，請重新開啟頁面" }, origin);
    }

    // 1. 問 LINE：這張身分證是真的嗎？
    let claims: LineClaims;
    try {
      claims = await deps.verifyIdToken(idToken);
    } catch (e) {
      const status = e instanceof LineVerifyError ? e.status : 502;
      deps.log?.("line verify failed", { status, error: String(e) });
      return json(status === 401 ? 401 : 502, {
        ok: false,
        code: status === 401 ? "invalid_id_token" : "line_unavailable",
        message: status === 401 ? "LINE 登入已過期，請關閉後重新開啟" : "暫時連不到 LINE，請稍後再試",
      }, origin);
    }
    if (!LINE_USER_ID_RE.test(claims.sub ?? "")) {
      return json(401, { ok: false, code: "invalid_id_token", message: "LINE 登入資料不正確" }, origin);
    }

    const lineUserId = claims.sub;
    const displayName = cleanName(claims.name);

    // 2. 找到或建立車主
    try {
      let userId = await deps.findVendorUserId(lineUserId);
      const isNew = userId === null;
      if (userId === null) {
        userId = await deps.ensureAuthUser(lineUserId, displayName);
        await deps.ensureVendorRow(userId, lineUserId, displayName);
      }

      // 3. 發登入身分
      const session = await deps.issueSession(lineUserId);
      return json(200, {
        ok: true,
        code: isNew ? "signed_up" : "signed_in",
        message: isNew ? "歡迎！已建立您的車主帳號" : "登入成功",
        user_id: userId,
        session,
      }, origin);
    } catch (e) {
      deps.log?.("sign-in failed", { error: String(e) });
      return json(500, { ok: false, code: "sign_in_failed", message: "登入失敗，請稍後再試" }, origin);
    }
  };
}
