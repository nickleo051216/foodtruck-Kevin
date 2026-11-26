// line-auth 本機測試：用假的 LINE / Supabase，不會連到任何外部服務
// 執行：deno test supabase/functions/tests/
import { createHandler, type Deps, isAllowedOrigin, LineVerifyError, syntheticEmail } from "../line-auth/handler.ts";

function assertEq(a: unknown, b: unknown, msg = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const OK_ORIGIN = "https://foodtruck-kevin.vercel.app";
const GOOD_TOKEN = "good.token.value-aaaaaaaaaaaa";
const LINE_UID = "U" + "a".repeat(32);

function fakeDeps(overrides: Partial<Deps> = {}) {
  const vendors = new Map<string, string>(); // lineUserId -> userId
  const calls: string[] = [];
  const deps: Deps = {
    async verifyIdToken(t) {
      calls.push("verify");
      if (t !== GOOD_TOKEN) throw new LineVerifyError("IdToken expired.", 401);
      return { sub: LINE_UID, name: "  阿明炸雞  " };
    },
    async findVendorUserId(l) { calls.push("find"); return vendors.get(l) ?? null; },
    async ensureAuthUser(l) { calls.push("createUser"); return "user-" + l.slice(1, 5); },
    async ensureVendorRow(id, l, name) { calls.push(`vendorRow:${name}`); vendors.set(l, id); },
    async issueSession() { calls.push("session"); return { access_token: "at", refresh_token: "rt" }; },
    ...overrides,
  };
  return { deps, calls, vendors };
}

function post(body: unknown, origin: string | null = OK_ORIGIN, method = "POST") {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (origin) headers.origin = origin;
  return new Request("http://localhost/line-auth", {
    method, headers, body: method === "POST" ? JSON.stringify(body) : undefined,
  });
}

Deno.test("允許的網址：正式站與 Vercel 預覽", () => {
  assertEq(isAllowedOrigin("https://foodtruck-kevin.vercel.app"), true);
  assertEq(isAllowedOrigin("https://foodtruck-kevin-git-step2-nick.vercel.app"), true);
  assertEq(isAllowedOrigin("https://foodtruck-kevin.vercel.app.evil.com"), false);
  assertEq(isAllowedOrigin("https://evil-foodtruck-kevin.vercel.app"), false);
  assertEq(isAllowedOrigin("http://foodtruck-kevin.vercel.app"), false);
  assertEq(isAllowedOrigin(null), false);
});

Deno.test("第一次登入：驗證 → 建帳號 → 建 vendors → 發身分", async () => {
  const { deps, calls } = fakeDeps();
  const res = await createHandler(deps)(post({ id_token: GOOD_TOKEN }));
  const body = await res.json();
  assertEq(res.status, 200);
  assertEq(body.code, "signed_up");
  assertEq(body.session.access_token, "at");
  assertEq(calls, ["verify", "find", "createUser", "vendorRow:阿明炸雞", "session"], "順序");
  assertEq(res.headers.get("access-control-allow-origin"), OK_ORIGIN);
});

Deno.test("第二次登入：不重建帳號", async () => {
  const { deps, calls } = fakeDeps();
  const h = createHandler(deps);
  await h(post({ id_token: GOOD_TOKEN }));
  calls.length = 0;
  const body = await (await h(post({ id_token: GOOD_TOKEN }))).json();
  assertEq(body.code, "signed_in");
  assertEq(calls, ["verify", "find", "session"]);
});

Deno.test("假的或過期的 ID Token → 401，不會建帳號", async () => {
  const { deps, calls } = fakeDeps();
  const res = await createHandler(deps)(post({ id_token: "forged.token.value-bbbbbbbbbbb" }));
  assertEq(res.status, 401);
  assertEq((await res.json()).code, "invalid_id_token");
  assertEq(calls, ["verify"]);
});

Deno.test("前端偷塞 userId 也沒用：只看 LINE 驗證回來的 sub", async () => {
  const { deps, vendors } = fakeDeps();
  await createHandler(deps)(post({ id_token: GOOD_TOKEN, userId: "U" + "f".repeat(32), sub: "hack" }));
  assertEq([...vendors.keys()], [LINE_UID]);
});

Deno.test("LINE 回傳的 sub 格式不對 → 401", async () => {
  const { deps } = fakeDeps({ verifyIdToken: async () => ({ sub: "not-a-line-id" }) });
  assertEq((await createHandler(deps)(post({ id_token: GOOD_TOKEN }))).status, 401);
});

Deno.test("LINE 暫時掛掉 → 502", async () => {
  const { deps } = fakeDeps({ verifyIdToken: async () => { throw new LineVerifyError("HTTP 503", 502); } });
  const res = await createHandler(deps)(post({ id_token: GOOD_TOKEN }));
  assertEq(res.status, 502);
  assertEq((await res.json()).code, "line_unavailable");
});

Deno.test("其他網站呼叫 → 403，而且不會去問 LINE", async () => {
  const { deps, calls } = fakeDeps();
  const res = await createHandler(deps)(post({ id_token: GOOD_TOKEN }, "https://evil.example.com"));
  assertEq(res.status, 403);
  assertEq(res.headers.get("access-control-allow-origin"), null);
  assertEq(calls, []);
});

Deno.test("CORS 預檢（OPTIONS）", async () => {
  const { deps } = fakeDeps();
  const ok = await createHandler(deps)(post(null, OK_ORIGIN, "OPTIONS"));
  assertEq(ok.status, 204);
  const bad = await createHandler(deps)(post(null, "https://evil.example.com", "OPTIONS"));
  assertEq(bad.status, 403);
});

Deno.test("缺少 id_token / 不是 JSON → 400", async () => {
  const { deps } = fakeDeps();
  const h = createHandler(deps);
  assertEq((await h(post({}))).status, 400);
  const raw = new Request("http://localhost/", { method: "POST", headers: { origin: OK_ORIGIN }, body: "not json" });
  assertEq((await h(raw)).status, 400);
});

Deno.test("建帳號失敗 → 500，訊息不外洩內部錯誤", async () => {
  const { deps } = fakeDeps({ ensureAuthUser: async () => { throw new Error("db password=secret"); } });
  const body = await (await createHandler(deps)(post({ id_token: GOOD_TOKEN }))).json();
  assertEq(body.code, "sign_in_failed");
  assertEq(JSON.stringify(body).includes("secret"), false);
});

Deno.test("內部代號 email 固定、小寫", () => {
  assertEq(syntheticEmail("UABCDEF" + "0".repeat(26)), "line-uabcdef" + "0".repeat(26) + "@users.foodtruck.invalid");
});

Deno.test("沒有暱稱時用「車主」", async () => {
  const { deps, calls } = fakeDeps({ verifyIdToken: async () => ({ sub: LINE_UID, name: "   " }) });
  await createHandler(deps)(post({ id_token: GOOD_TOKEN }));
  assertEq(calls.includes("vendorRow:車主"), true);
});
