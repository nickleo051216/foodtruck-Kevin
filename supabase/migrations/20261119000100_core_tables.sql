-- =====================================================================
-- 餐車市集排班系統｜試用版資料庫 第 1 部分：資料表
-- 2026-11-19  決策 D1–D9 全部照建議（見 claude/decisions-step1.md）
--
-- 白話說明：
--   這個檔案只「建表」，還沒有任何權限規則（在 0200）和功能（在 0300）。
--   每張表都帶 org_id（哪個市集業主），之後新客戶只要新增一個 org。
--   狀態欄位都用英文代碼（例如 confirmed），畫面上再翻成中文。
-- =====================================================================

create schema if not exists private;   -- 放內部用的小工具函式，不會開放給前端直接呼叫

-- ---------------------------------------------------------------------
-- 共用：自動更新 updated_at
-- ---------------------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- =====================================================================
-- 業主與權限
-- =====================================================================

-- 市集業主（租戶）
create table public.orgs (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(name) between 1 and 60),
  slug           text not null unique check (slug ~ '^[a-z0-9-]{3,40}$'),   -- 網址代號，例：north-market
  status         text not null default 'trial' check (status in ('trial','active','suspended')),
  trial_ends_at  date,
  is_demo        boolean not null default false,   -- Kevin 展示用的市集，可以一鍵清空
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- 每個業主的規則設定（一個業主一筆）。D1–D7 的數字都在這裡，業主可自己調。
create table public.org_settings (
  org_id                          uuid primary key references public.orgs(id) on delete cascade,
  timezone                        text     not null default 'Asia/Taipei',
  -- D5：每月幾號幾點開放「下個月」的登記
  open_day                        smallint not null default 15 check (open_day between 1 and 28),
  open_time                       time     not null default '12:00',
  -- D6：場次前幾天的幾點截止登記與取消（預設：前一天 20:00）
  close_days_before               smallint not null default 1 check (close_days_before between 0 and 14),
  close_time                      time     not null default '20:00',
  -- D1：遞補保留幾分鐘
  offer_minutes                   smallint not null default 30 check (offer_minutes between 1 and 1440),
  -- D2：開場前幾小時內，遞補改成直接確認（不等車主按）
  offer_skip_hours                smallint not null default 3 check (offer_skip_hours between 0 and 72),
  -- D4：候補上限 = 名額 × 這個倍數（1 = 跟名額一樣多）
  waitlist_limit_ratio            numeric(4,2) not null default 1 check (waitlist_limit_ratio >= 0),
  -- D3：同一位車主的多台車，可否登記同一場次
  allow_multi_truck_same_session  boolean  not null default false,
  -- D7：幾天內取消算「晚取消」、要扣幾點；試用版 apply_credit_penalty = false（只記錄不扣）
  late_cancel_days                smallint not null default 3 check (late_cancel_days >= 0),
  late_cancel_points              smallint not null default 5 check (late_cancel_points >= 0),
  apply_credit_penalty            boolean  not null default false,
  -- 拍照報到時間窗（分鐘），同 Demo：出攤 開場前30分～開場後60分；收攤 結束前30分～結束後60分
  checkin_in_before_min           smallint not null default 30,
  checkin_in_after_min            smallint not null default 60,
  checkin_out_before_min          smallint not null default 30,
  checkin_out_after_min           smallint not null default 60,
  photo_retention_days            smallint not null default 90 check (photo_retention_days between 1 and 365),
  bank_info                       jsonb    not null default '{}'::jsonb,   -- 匯款帳號（給車主看）
  created_at                      timestamptz not null default now(),
  updated_at                      timestamptz not null default now()
);

-- 後台管理員：owner 業主本人 / staff 小幫手
create table public.org_admins (
  org_id      uuid not null references public.orgs(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null default 'staff' check (role in ('owner','staff')),
  created_at  timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index org_admins_user_idx on public.org_admins(user_id);

-- 平台最高管理員（只有 Nick）。沒有任何 RLS 開放規則 → 網頁上改不到，只能在 Supabase 控制台改。
create table public.platform_admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  note        text,
  created_at  timestamptz not null default now()
);

-- =====================================================================
-- 車主與車輛
-- =====================================================================

-- 車主：一個 LINE 帳號 = 一位車主。由 Edge Function 驗證 LINE ID Token 後建立（第 2 步）。
create table public.vendors (
  id             uuid primary key references auth.users(id) on delete cascade,
  line_user_id   text not null unique,     -- 注意：LINE userId 依 Provider 區分
  display_name   text not null check (length(display_name) between 1 and 60),
  phone          text check (phone is null or phone ~ '^[0-9+\- ]{6,20}$'),
  is_oa_friend   boolean not null default false,   -- 有加 LINE OA 好友才收得到推播
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- 車主在某市集的身分（同一位車主可以跑多個市集，信用分分開算）
create table public.org_vendors (
  org_id        uuid not null references public.orgs(id) on delete cascade,
  vendor_id     uuid not null references public.vendors(id) on delete cascade,
  status        text not null default 'active' check (status in ('active','paused')),
  credit_score  smallint not null default 100,
  joined_at     timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  primary key (org_id, vendor_id)
);
create index org_vendors_vendor_idx on public.org_vendors(vendor_id);

-- 車輛 / 攤位
create table public.trucks (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  vendor_id    uuid not null,
  name         text not null check (length(name) between 1 and 30),
  kind         text not null default 'truck' check (kind in ('truck','stall')),   -- 餐車 / 落地攤
  food_type    text not null,
  plate        text,
  status       text not null default 'pending' check (status in ('pending','active','rejected','retired')),
  reviewed_by  uuid references auth.users(id),
  reviewed_at  timestamptz,
  review_note  text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  foreign key (org_id, vendor_id) references public.org_vendors(org_id, vendor_id) on delete cascade
);
create index trucks_vendor_idx on public.trucks(vendor_id);
create index trucks_org_status_idx on public.trucks(org_id, status);

-- =====================================================================
-- 場地與場次
-- =====================================================================

create table public.venues (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id) on delete cascade,
  name        text not null check (length(name) between 1 and 40),
  address     text,
  notes       text,                                 -- 給車主看的注意事項
  status      text not null default 'open' check (status in ('open','paused')),
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, name),
  unique (id, org_id)
);

-- 時段模板：「中央公園・午場・每天開・5 名額・NT$300」
create table public.venue_slots (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  venue_id    uuid not null,
  code        text not null check (code ~ '^[A-Z0-9]{1,6}$'),   -- AM / PM / ALL
  label       text not null,                                    -- 午場 / 晚場 / 夜市
  start_time  time not null,
  end_time    time not null,                                    -- 若 <= start_time 代表跨午夜
  weekdays    smallint[] not null check (weekdays <@ array[1,2,3,4,5,6,7]::smallint[] and cardinality(weekdays) > 0),  -- 1=週一 … 7=週日
  capacity    integer not null check (capacity between 0 and 500),
  fee         integer not null default 0 check (fee >= 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (venue_id, code),
  unique (id, org_id),
  foreign key (venue_id, org_id) references public.venues(id, org_id) on delete cascade
);

-- 「未開放」規則（全系統不出現「黑名單」）：針對某台車，或某一類餐點，二擇一
create table public.venue_restrictions (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  venue_id    uuid not null,
  truck_id    uuid references public.trucks(id) on delete cascade,
  food_type   text,
  reason      text not null check (length(reason) between 1 and 100),
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check ((truck_id is null) <> (food_type is null)),
  foreign key (venue_id, org_id) references public.venues(id, org_id) on delete cascade
);
create index venue_restrictions_venue_idx on public.venue_restrictions(venue_id);

-- 場次：真正被登記的單位。名額和場地費從模板「複製」一份，之後改模板不影響已產生的場次。
create table public.sessions (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  venue_id    uuid not null,
  slot_id     uuid not null,
  date        date not null,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  capacity    integer not null check (capacity between 0 and 500),
  fee         integer not null default 0 check (fee >= 0),
  opens_at    timestamptz not null,   -- 開放登記時間
  closes_at   timestamptz not null,   -- 截止登記與取消時間
  status      text not null default 'open' check (status in ('open','closed','private','cancelled')),
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (venue_id, slot_id, date),
  check (ends_at > starts_at),
  foreign key (venue_id, org_id) references public.venues(id, org_id) on delete restrict,
  foreign key (slot_id, org_id)  references public.venue_slots(id, org_id) on delete restrict
);
create index sessions_org_date_idx on public.sessions(org_id, date);

-- =====================================================================
-- 登記（含候補）
--   waitlisted 候補中 → offered 遞補待確認 → confirmed 已確認
--   offered 逾時 → expired；任何有效狀態 → cancelled
-- =====================================================================
create table public.registrations (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.orgs(id) on delete cascade,
  session_id        uuid not null references public.sessions(id) on delete restrict,
  truck_id          uuid not null references public.trucks(id) on delete restrict,
  vendor_id         uuid not null references public.vendors(id) on delete restrict,
  status            text not null check (status in ('confirmed','waitlisted','offered','cancelled','expired')),
  queued_at         timestamptz not null default clock_timestamp(),   -- 排隊時間：候補先到先遞補
  confirmed_at      timestamptz,
  offered_at        timestamptz,
  offer_expires_at  timestamptz,
  cancelled_at      timestamptz,
  cancelled_by      uuid references auth.users(id),
  cancel_reason     text,
  is_late_cancel    boolean not null default false,
  fee_snapshot      integer not null default 0,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (status <> 'offered' or offer_expires_at is not null)
);
-- 防重複的保險：同一台車在同一場次，只能有一筆「有效」登記
create unique index registrations_one_active_per_truck
  on public.registrations(session_id, truck_id)
  where status in ('confirmed','waitlisted','offered');
create index registrations_session_status_idx on public.registrations(session_id, status, queued_at);
create index registrations_truck_idx  on public.registrations(truck_id) where status in ('confirmed','waitlisted','offered');
create index registrations_vendor_idx on public.registrations(vendor_id);
create index registrations_offer_exp_idx on public.registrations(offer_expires_at) where status = 'offered';

-- =====================================================================
-- 照片、報到
-- =====================================================================
create table public.photos (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.orgs(id) on delete cascade,
  vendor_id     uuid not null references public.vendors(id) on delete cascade,
  storage_path  text not null unique,              -- 例：<org_id>/<vendor_id>/2026-12-05/in.jpg
  uploaded_by   uuid references auth.users(id),
  taken_at      timestamptz not null default now(),   -- 伺服器時間，避免改手機時間作弊
  expires_at    timestamptz not null,               -- 上傳後 90 天
  deleted_at    timestamptz,
  created_at    timestamptz not null default now()
);
create index photos_expires_idx on public.photos(expires_at) where deleted_at is null;

create table public.checkins (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.orgs(id) on delete cascade,
  registration_id  uuid not null references public.registrations(id) on delete cascade,
  session_id       uuid not null references public.sessions(id) on delete cascade,
  vendor_id        uuid not null references public.vendors(id) on delete cascade,
  kind             text not null check (kind in ('in','out')),   -- in 出攤 / out 收攤
  seq_no           integer not null check (seq_no > 0),
  display_code     text not null,                                -- 例：1205-AM-出03
  photo_id         uuid references public.photos(id) on delete set null,
  audit_status     text not null default 'unreviewed' check (audit_status in ('unreviewed','ok','flagged')),
  audit_note       text,
  audited_by       uuid references auth.users(id),
  audited_at       timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (registration_id, kind),
  unique (session_id, kind, seq_no)
);

-- =====================================================================
-- 待發推播：資料庫只負責「記下要發什麼」，n8n 負責實際透過 LINE OA 發送
-- =====================================================================
create table public.notification_outbox (
  id            bigint generated always as identity primary key,
  org_id        uuid not null references public.orgs(id) on delete cascade,
  vendor_id     uuid references public.vendors(id) on delete set null,
  line_user_id  text,
  kind          text not null check (kind in ('offer','offer_auto_confirmed','offer_expired',
                                              'reminder','session_cancelled','truck_reviewed','generic')),
  payload       jsonb not null default '{}'::jsonb,
  status        text not null default 'pending' check (status in ('pending','sending','sent','failed')),
  attempts      smallint not null default 0,
  claimed_at    timestamptz,
  sent_at       timestamptz,
  last_error    text,
  created_at    timestamptz not null default now()
);
create index notification_outbox_pending_idx on public.notification_outbox(id) where status in ('pending','sending');

-- =====================================================================
-- 操作紀錄（「我沒刪那台車」時的證據）
-- =====================================================================
create table public.audit_logs (
  id          bigint generated always as identity primary key,
  org_id      uuid,
  actor_id    uuid,           -- 誰做的（auth.uid()；排程或系統為 null）
  action      text not null,  -- INSERT / UPDATE / DELETE
  table_name  text not null,
  row_id      text,
  old_data    jsonb,
  new_data    jsonb,
  created_at  timestamptz not null default now()
);
create index audit_logs_org_time_idx on public.audit_logs(org_id, created_at desc);

-- updated_at 觸發器
do $$
declare t text;
begin
  foreach t in array array['orgs','org_settings','vendors','org_vendors','trucks','venues','venue_slots',
                           'venue_restrictions','sessions','registrations','checkins']
  loop
    execute format('create trigger set_updated_at before update on public.%I
                    for each row execute function private.set_updated_at()', t);
  end loop;
end $$;
