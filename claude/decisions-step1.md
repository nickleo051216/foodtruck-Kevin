# 第 1 步決策紀錄：Supabase Schema + RLS + 登記 RPC

> 2026-11-19（四）Nick 回覆：**D1–D9 全部照建議**
> 交接文件 `claude/foodtruck-trial-handoff.md` 含客戶與報價資訊，因 repo 為公開，暫不納入版控。
> 設計稿（含白話說明）：https://claude.ai/artifact/TAdS1grvjFNWcKS4U5Kb3w

| # | 問題 | 決定 | 實作位置 |
|---|---|---|---|
| D1 | 候補遞補上後要不要車主確認 | 保留名額 30 分鐘，按確認才算；逾時讓給下一位 | `org_settings.offer_minutes`、`accept_offer`、`expire_offers` |
| D2 | 快開場時還要等確認嗎 | 開場前 3 小時內直接遞補 | `org_settings.offer_skip_hours`、`private.fill_open_seats` |
| D3 | 同車主多台車可否登記同一場 | 預設不行，業主可在設定打開 | `org_settings.allow_multi_truck_same_session` |
| D4 | 候補上限 | 等於名額數 | `org_settings.waitlist_limit_ratio = 1` |
| D5 | 何時開放下個月登記 | 每月 15 日 12:00 | `org_settings.open_day / open_time`、`generate_sessions` |
| D6 | 何時截止登記與取消 | 場次前一天 20:00 | `org_settings.close_days_before / close_time` |
| D7 | 3 天內取消扣分 | 試用版只記錄（`is_late_cancel`），不扣分 | `org_settings.apply_credit_penalty = false` |
| D8 | 文件第 4、5 節的「Sheets」 | 全部改用 Supabase，不再寫 Google Sheets | — |
| D9 | 試用環境建在哪 | Nick 帳號下的獨立試用專案（免費方案需定時 ping 防暫停） | — |
| 附加 | 操作紀錄 audit_logs | 試用版就做 | `audit_logs` + `private.write_audit_log` |
| D10 | 20 人同時搶 5 個名額的壓力測試 | **不做**（2026-11-19 Nick）：Kevin 一次推一位業主試用，一個一個來。取代交接文件第 5 節第 1 條與第 8 節第 7 步的壓力測試。登記函式內「鎖住場次再算名額」的那一行保留，當作基本保險 | `supabase/tests/run_tests.sh` 只保留連點測試 |
| D11 | 試用版用哪個 Supabase 專案 | **Kevin'foodtest**（`qavmukksnebhjqxgudnw`，ap-northeast-2，Pro 組織）。2026-11-26 Nick 確定；5 個 migration 已套用、驗證通過、冒煙測試已回滾。之後的 Edge Function、前端、n8n 都接這個專案 | — |
| D12 | 第 2 步：LINE 身分怎麼換成 Supabase 登入 | **方案 A：Edge Function `line-auth` 換證**（2026-11-26 Nick）。前端送 `liff.getIDToken()` → 伺服器向 LINE `POST /oauth2/v2.1/verify` 驗證（client_id = 2010274155）→ 建立 / 找回帳號與 `vendors` → 伺服器端兌換一次性登入連結，回傳 Supabase 登入身分。不採用自簽 JWT（Supabase 已不建議舊的共用密鑰）；Supabase 自訂 OIDC 登入（`custom:line`）留到正式版再實測 | `supabase/functions/line-auth/` |
| D13 | LINE 設定確認 | **已確認**（2026-11-26 Nick 後台截圖）：Provider `Vegenn8n` → LINE Login channel `food-car` 已連結 LINE OA `@266rvwxa`（餐車系統小幫手）＝同一個 Provider，userId 會一致；LIFF `Food-car` Scope 有 `openid, profile`；Endpoint URL `https://foodtruck-kevin.vercel.app/liff`。沒有申請 email 權限，所以帳號用內部代號 email | — |

## 本機驗證結果（2026-11-19）

`bash supabase/tests/run_tests.sh`：功能測試 73 項全部通過；同一台車連點 10 次只寫入 1 筆；rollback 後可完整重新套用。

## 尚未處理（留給後續步驟）

- 第 2 步：`line-auth` 已寫好並通過本機測試（D12）；2026-11-26 已部署到 Kevin'foodtest（2b，v1，verify_jwt=false），外部測試擋得住其他網站、假 token、缺 token；；2c 完成：`liff.html` 在 `?mode=real` 時用 ID Token 換 Supabase 登入，左下角顯示連線檢查（LIFF / openid / OA 連結 / Supabase 登入 / 加入市集）；待 Nick 手機實測（2d）
- 第 4 步：照片 90 天清除（需透過 Storage API 刪檔）、前端壓縮照片到約 150 KB
- 第 6 步：n8n 用 `n8n_worker` 帳號呼叫 `claim_notifications` / `mark_notification` 發 LINE OA 推播；每日 ping 防止免費專案暫停
- 預留表：`credit_events`、`payments`、`private_events`、`truck_change_requests`
