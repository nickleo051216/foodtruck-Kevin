# Supabase 試用版資料庫

> 2026-11-19｜交接文件第 8 節「第 1 步」：Schema + RLS + 登記 RPC
> 決策紀錄：[`claude/decisions-step1.md`](../claude/decisions-step1.md)（交接文件第 8 節第 1 步）

## 資料夾內容

| 路徑 | 內容 |
|---|---|
| `migrations/…0100_core_tables.sql` | 15 張資料表 + 操作紀錄表 |
| `migrations/…0200_rls_policies.sql` | 權限規則（RLS）、操作紀錄觸發器 |
| `migrations/…0300_rpc_functions.sql` | 登記、取消、確認遞補、逾時處理、拍照報到、產生場次、查詢、n8n 推播領取 |
| `migrations/…0400_storage_photos.sql` | 照片空間 `checkin-photos` 與權限 |
| `migrations/…0500_cron_jobs.sql` | 每分鐘處理逾時遞補（需要 pg_cron） |
| `tests/run_tests.sh` | 本機測試（功能測試 + 連點測試 + 還原測試） |
| `rollback/…_down.sql` | 全部還原 |

## 本機測試（不會連到 Supabase）

```bash
bash supabase/tests/run_tests.sh
```

需要本機有 PostgreSQL 16（`PG_BIN` 可指定路徑）。腳本會建立暫時的資料庫，跑完自動刪除。

## 套用到 Supabase（下一步，Nick 確認後才做）

1. 用 **Nick 的帳號**建立獨立的試用專案（D9），區域選 Tokyo 或 Singapore
2. Database → Extensions 開啟 `pg_cron`
3. 依檔名順序在 SQL Editor 執行 `migrations/` 五個檔案（或用 Supabase CLI `supabase db push`）
4. 在 Authentication 建立 Nick 的帳號，然後執行：
   ```sql
   insert into public.platform_admins(user_id, note) values ('<Nick 的 user id>', 'Nick');
   ```
5. 幫 n8n 設密碼（密碼不要存進 Git）：
   ```sql
   alter role n8n_worker with login password '<自己產生的長密碼>';
   ```

## 還原

在 SQL Editor 執行 `rollback/20261119_trial_schema_down.sql`。會刪除所有試用資料，請先備份。

---

## 第 2 步：LINE 登入 → Supabase 身分（Edge Function `line-auth`）

> 決策：D12（方案 A）、D13（LINE 設定已確認）

| 路徑 | 內容 |
|---|---|
| `functions/line-auth/handler.ts` | 邏輯：檢查網址 → 向 LINE 驗證 ID Token → 找 / 建車主 → 發登入身分 |
| `functions/line-auth/index.ts` | 把真正的 LINE、Supabase 接上去 |
| `functions/tests/line-auth.test.ts` | 本機測試（假的 LINE / Supabase，13 項） |

### 本機測試

```bash
deno test supabase/functions/tests/
```

### 前端怎麼用（2c 已接到 `liff.html` 的 `runRealAuth()`，只在 `?mode=real` 執行；加 `&org=市集代號` 會自動加入市集）

```js
const idToken = liff.getIDToken();               // LIFF 已 init 且已登入
const r = await fetch(`${SUPABASE_URL}/functions/v1/line-auth`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY },
  body: JSON.stringify({ id_token: idToken }),
}).then(r => r.json());
if (r.ok) await supabase.auth.setSession(r.session); // 之後就能呼叫 join_org / register_for_session
```

### 部署（2b：2026-11-26 已部署到 Kevin'foodtest，v1）

- 函式名稱 `line-auth`，**verify_jwt = false**（車主這時還沒有 Supabase 身分，改由 LINE ID Token 驗證）
- 不需要另外設定 secret：`SUPABASE_URL`、金鑰由 Supabase 自動提供；LINE channel ID 預設 `2010274155`，可用 secret `LINE_LOGIN_CHANNEL_ID` 覆蓋
- 只接受 `https://foodtruck-kevin.vercel.app` 與 Nick 帳號底下的預覽網址 `https://foodtruck-kevin-*-nickleo051216s-projects.vercel.app` 呼叫

### 還原

在 Supabase → Edge Functions 刪除 `line-auth`。前端預設就是 Demo 模式，不受影響。
已建立的車主帳號可在 Authentication → Users 刪除（`vendors` 會跟著刪除）。
