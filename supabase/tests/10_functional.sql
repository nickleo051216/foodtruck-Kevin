-- =====================================================================
-- 功能測試：用「假身分」逐一測試權限規則與 RPC
-- 由 run_tests.sh 執行；任何一項失敗就會停下來並顯示 ❌
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;

create schema tests;
grant usage on schema tests to authenticated;
create function tests.ok(p_cond boolean, p_label text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception '❌ FAIL: %', p_label;
  end if;
  raise notice '✅ %', p_label;
end $$;
grant execute on function tests.ok(boolean, text) to authenticated;
-- 切換身分（模擬某人登入）
create function tests.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false);
$$;
set client_min_messages = notice;

-- ---------------------------------------------------------------------
-- 測試資料（以最高權限建立）
-- ---------------------------------------------------------------------
\set nick    '''aaaaaaaa-0000-0000-0000-000000000001'''
\set ownerA  '''aaaaaaaa-0000-0000-0000-000000000002'''
\set ownerB  '''aaaaaaaa-0000-0000-0000-000000000003'''
\set staffA  '''aaaaaaaa-0000-0000-0000-000000000004'''
\set orgA    '''dddddddd-0000-0000-0000-000000000001'''
\set orgB    '''dddddddd-0000-0000-0000-000000000002'''
\set venA1   '''eeeeeeee-0000-0000-0000-000000000001'''
\set venA2   '''eeeeeeee-0000-0000-0000-000000000002'''
\set slotA1  '''ffffffff-0000-0000-0000-000000000001'''
\set slotA2  '''ffffffff-0000-0000-0000-000000000002'''

insert into auth.users(id) values (:nick), (:ownerA), (:ownerB), (:staffA);
insert into auth.users(id)
  select ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid from generate_series(1, 40) n;

insert into public.platform_admins(user_id, note) values (:nick, 'Nick');
insert into public.orgs(id, name, slug) values (:orgA, '北區餐車聯盟', 'north-market'), (:orgB, '南區市集', 'south-market');
insert into public.org_settings(org_id) values (:orgA), (:orgB);
insert into public.org_admins(org_id, user_id, role) values (:orgA, :ownerA, 'owner'), (:orgB, :ownerB, 'owner');

insert into public.vendors(id, line_user_id, display_name)
  select ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'Uline' || n, '車主' || n
  from generate_series(1, 40) n;
-- 車主 1–38 加入 A 市集；39 加入 B 市集；40 什麼都沒加入
insert into public.org_vendors(org_id, vendor_id)
  select :orgA, ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid from generate_series(1, 38) n;
insert into public.org_vendors(org_id, vendor_id) values (:orgB, 'bbbbbbbb-0000-0000-0000-000000000039');

insert into public.trucks(id, org_id, vendor_id, name, food_type, status)
  select ('cccccccc-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, :orgA,
         ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '餐車' || n, '中式小吃', 'active'
  from generate_series(1, 38) n;
-- 車主 1 的第二台車；車主 2 有一台待審核的車；車主 3 的車是飲料（測未開放規則）
insert into public.trucks(id, org_id, vendor_id, name, food_type, status) values
  ('cccccccc-0000-0000-0000-000000000101', :orgA, 'bbbbbbbb-0000-0000-0000-000000000001', '第二台', '甜點', 'active'),
  ('cccccccc-0000-0000-0000-000000000102', :orgA, 'bbbbbbbb-0000-0000-0000-000000000002', '新車', '咖啡', 'pending');
update public.trucks set food_type = '飲料茶飲' where id = 'cccccccc-0000-0000-0000-000000000003';

insert into public.venues(id, org_id, name) values (:venA1, :orgA, '中央公園市集'), (:venA2, :orgA, '陽光廣場');
insert into public.venue_slots(id, org_id, venue_id, code, label, start_time, end_time, weekdays, capacity, fee) values
  (:slotA1, :orgA, :venA1, 'AM', '午場', '10:00', '15:00', '{1,2,3,4,5,6,7}', 5, 300),
  (:slotA2, :orgA, :venA2, 'AM', '午場', '10:00', '15:00', '{1,2,3,4,5}',     3, 250);
insert into public.venue_restrictions(org_id, venue_id, food_type, reason)
  values (:orgA, :venA1, '飲料茶飲', '此場地僅開放熟食類餐車，飲料車暫不適用');

-- 測試用場次（時間相對於現在）
insert into public.sessions(id, org_id, venue_id, slot_id, date, starts_at, ends_at, capacity, fee, opens_at, closes_at) values
  -- S1：4 天後，開放中
  ('99999999-0000-0000-0000-000000000001', :orgA, :venA1, :slotA1, current_date + 3,
   now() + interval '4 days', now() + interval '4 days 5 hours', 5, 300, now() - interval '1 day', now() + interval '2 days'),
  -- S2：同一時間的另一個場地
  ('99999999-0000-0000-0000-000000000002', :orgA, :venA2, :slotA2, current_date + 3,
   now() + interval '4 days 1 hour', now() + interval '4 days 4 hours', 3, 250, now() - interval '1 day', now() + interval '2 days'),
  -- S3：還沒開放
  ('99999999-0000-0000-0000-000000000003', :orgA, :venA1, :slotA1, current_date + 40,
   now() + interval '40 days', now() + interval '40 days 5 hours', 5, 300, now() + interval '5 days', now() + interval '39 days'),
  -- S4：2 小時後開始（D2：直接遞補）
  ('99999999-0000-0000-0000-000000000004', :orgA, :venA1, :slotA1, current_date,
   now() + interval '2 hours', now() + interval '7 hours', 1, 300, now() - interval '10 days', now() + interval '1 hour'),
  -- S5：10 分鐘前開始（測拍照報到）
  ('99999999-0000-0000-0000-000000000005', :orgA, :venA2, :slotA2, current_date,
   now() - interval '10 minutes', now() + interval '4 hours', 3, 250, now() - interval '10 days', now() - interval '1 day');

\set S1 '''99999999-0000-0000-0000-000000000001'''
\set S2 '''99999999-0000-0000-0000-000000000002'''
\set S3 '''99999999-0000-0000-0000-000000000003'''
\set S4 '''99999999-0000-0000-0000-000000000004'''
\set S5 '''99999999-0000-0000-0000-000000000005'''

create function tests.v(n int) returns uuid language sql immutable as $$ select ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function tests.t(n int) returns uuid language sql immutable as $$ select ('cccccccc-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function tests.v(int), tests.t(int), tests.login(uuid) to authenticated;

\echo
\echo '──── A. 登記 RPC ────'
set role authenticated;

select tests.login(null);
select tests.ok((public.register_for_session(:S1, tests.t(1)))->>'code' = 'not_authenticated', 'A1 沒登入不能登記');

select tests.login(tests.v(1));
select (public.register_for_session(:S1, tests.t(1))) as r \gset
select tests.ok((:'r'::jsonb)->>'code' = 'confirmed', 'A2 車主1 登記成功（已確認）');
select tests.ok((public.register_for_session(:S1, tests.t(1)))->>'code' = 'already_registered', 'A3 重複按 → 回傳原本那筆，不會多一筆');
select tests.ok((select count(*) from public.registrations where session_id = :S1) = 1, 'A3b 資料庫裡確實只有 1 筆');
select tests.ok((public.register_for_session(:S1, tests.t(101)))->>'code' = 'vendor_already_in_session', 'A4 D3：同車主第二台車不能登記同一場');
select tests.ok((public.register_for_session(:S2, tests.t(1)))->>'code' = 'time_conflict', 'A5 同一台車時間重疊 → 擋下');
select tests.ok((public.register_for_session(:S3, tests.t(1)))->>'code' = 'not_open_yet', 'A6 還沒開放的場次 → 擋下');
select tests.ok((public.register_for_session(:S1, tests.t(2)))->>'code' = 'truck_not_found', 'A7 用別人的車登記 → 擋下');

select tests.login(tests.v(2));
select tests.ok((public.register_for_session(:S1, tests.t(102)))->>'code' = 'truck_pending', 'A8 待審核的車不能登記');

select tests.login(tests.v(3));
select tests.ok((public.register_for_session(:S1, tests.t(3)))->>'message' = '此場地僅開放熟食類餐車，飲料車暫不適用', 'A9 未開放規則 → 顯示中性原因');

select tests.login(tests.v(39));
select tests.ok((public.register_for_session(:S1, tests.t(1)))->>'code' = 'not_member', 'A10 別的市集的車主不能登記');

-- 補滿：車主 4–7 正取（共 5 位），8–12 候補（上限 5），13 額滿
do $$ begin
  for n in 4..7 loop
    perform tests.login(tests.v(n));
    perform tests.ok((public.register_for_session('99999999-0000-0000-0000-000000000001', tests.t(n)))->>'code' = 'confirmed', format('A11 車主%s 正取', n));
  end loop;
  for n in 8..12 loop
    perform tests.login(tests.v(n));
    perform tests.ok((public.register_for_session('99999999-0000-0000-0000-000000000001', tests.t(n)))->>'waitlist_position' = (n - 7)::text, format('A12 車主%s 候補第 %s 位', n, n - 7));
  end loop;
  perform tests.login(tests.v(13));
  perform tests.ok((public.register_for_session('99999999-0000-0000-0000-000000000001', tests.t(13)))->>'code' = 'session_full', 'A13 名額＋候補都滿 → 額滿，不寫入');
end $$;

\echo
\echo '──── B. 權限（RLS） ────'
select tests.login(tests.v(4));
select tests.ok((select count(*) from public.registrations) = 1, 'B1 車主只看得到自己的 1 筆登記');
select tests.ok((select taken from public.get_sessions(:orgA, current_date, current_date + 5) where session_id = :S1) = 5
                and (select waitlisted from public.get_sessions(:orgA, current_date, current_date + 5) where session_id = :S1) = 5,
                'B2 但看得到場次的數字（5/5、候補 5）');
do $$ begin
  begin
    insert into public.registrations(org_id, session_id, truck_id, vendor_id, status)
    values ('dddddddd-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000002', tests.t(4), tests.v(4), 'confirmed');
    perform tests.ok(false, 'B3 車主直接寫登記表應該失敗');
  exception when insufficient_privilege then
    perform tests.ok(true, 'B3 車主不能繞過 RPC 直接寫登記表');
  end;
  begin
    update public.trucks set status = 'active' where id = tests.t(4);
    update public.trucks set name = '改名' where id = tests.t(4);
    perform tests.ok(false, 'B4 車主改車名應該失敗');
  exception when insufficient_privilege then
    perform tests.ok(true, 'B4 車主不能自己改車名 / 狀態');
  end;
end $$;
select tests.ok((select count(*) from public.platform_admins) = 0, 'B5 車主看不到最高管理員名單');
insert into public.trucks(org_id, vendor_id, name, food_type) values (:orgA, tests.v(4), '新申請', '炸物');
select tests.ok((select status from public.trucks where name = '新申請') = 'pending', 'B6 車主新增的車一律是「待審核」');
do $$ begin
  begin
    insert into public.trucks(org_id, vendor_id, name, food_type, status)
    values ('dddddddd-0000-0000-0000-000000000001', tests.v(4), '偷渡', '炸物', 'active');
    perform tests.ok(false, 'B7 車主新增「已通過」的車應該失敗');
  exception when insufficient_privilege then
    perform tests.ok(true, 'B7 車主不能新增「已通過」的車');
  end;
end $$;

select tests.login(tests.v(40));
select tests.ok((select count(*) from public.sessions) = 0 and (select count(*) from public.get_sessions(:orgA, current_date, current_date + 60)) = 0,
                'B8 沒加入市集的人看不到任何場次');

reset role; set role anon;
do $$ begin
  begin
    perform count(*) from public.sessions;
    perform tests.ok(false, 'B9 未登入應該讀不到');
  exception when insufficient_privilege then
    raise notice '✅ B9 未登入（anon）什麼都讀不到';
  end;
end $$;
reset role; set role authenticated;

select tests.login(:ownerB);
select tests.ok((select count(*) from public.registrations) = 0 and (select count(*) from public.trucks) = 0,
                'B10 別的業主看不到 A 市集的資料');
select tests.login(:ownerA);
select tests.ok((select count(*) from public.registrations where session_id = :S1) = 10, 'B11 業主看得到自家全部登記');
insert into public.org_admins(org_id, user_id, role) values (:orgA, :staffA, 'staff');
do $$ begin
  begin
    insert into public.org_admins(org_id, user_id, role) values ('dddddddd-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000003', 'owner');
    perform tests.ok(false, 'B12 業主新增 owner 應該失敗');
  exception when insufficient_privilege then
    perform tests.ok(true, 'B12 業主只能加小幫手，不能加 owner');
  end;
end $$;
select tests.login(:staffA);
update public.org_settings set offer_minutes = 5 where org_id = :orgA;
select tests.login(:ownerA);
select tests.ok((select offer_minutes from public.org_settings where org_id = :orgA) = 30, 'B13 小幫手改不了規則設定');
select tests.login(:nick);
select tests.ok((select count(*) from public.registrations) >= 10 and (select count(*) from public.orgs) = 2, 'B14 Nick 看得到所有市集');

\echo
\echo '──── C. 取消、遞補、確認、逾時 ────'
select tests.login(tests.v(4));
select (public.cancel_registration((select id from public.registrations where truck_id = tests.t(4) and session_id = :S1))) as r \gset
select tests.ok((:'r'::jsonb)->>'code' = 'cancelled' and ((:'r'::jsonb)->>'is_late_cancel')::boolean = false, 'C1 車主4 取消（3 天以上，不算晚取消）');
reset role;
select tests.ok((select status from public.registrations where truck_id = tests.t(8) and session_id = :S1) = 'offered', 'C2 候補第1位（車主8）自動變成「遞補待確認」');
select tests.ok((select offer_expires_at - offered_at from public.registrations where truck_id = tests.t(8) and session_id = :S1)
                between interval '29 minutes' and interval '31 minutes', 'C3 保留 30 分鐘');
select tests.ok((select count(*) from public.notification_outbox where kind = 'offer' and vendor_id = tests.v(8)) = 1, 'C4 放進一則遞補推播給車主8');
set role authenticated;

select tests.login(tests.v(8));
select tests.ok((public.accept_offer((select id from public.registrations where truck_id = tests.t(8) and session_id = :S1)))->>'code' = 'confirmed', 'C5 車主8 按確認 → 已確認');

select tests.login(tests.v(5));
select public.cancel_registration((select id from public.registrations where truck_id = tests.t(5) and session_id = :S1)) \gset
reset role;
select tests.ok((select status from public.registrations where truck_id = tests.t(9) and session_id = :S1) = 'offered', 'C6 再取消一位 → 車主9 遞補待確認');
-- 模擬 30 分鐘過去
update public.registrations set offer_expires_at = now() - interval '1 second' where truck_id = tests.t(9) and session_id = :S1;
select tests.ok(public.expire_offers() = 1, 'C7 排程：處理 1 筆逾時');
select tests.ok((select status from public.registrations where truck_id = tests.t(9) and session_id = :S1) = 'expired'
            and (select status from public.registrations where truck_id = tests.t(10) and session_id = :S1) = 'offered',
                'C8 車主9 過期，改由車主10 遞補');
select tests.ok((select count(*) from public.notification_outbox where kind = 'offer_expired' and vendor_id = tests.v(9)) = 1, 'C9 通知車主9 保留已過期');
set role authenticated;
select tests.login(tests.v(9));
select tests.ok((public.accept_offer((select id from public.registrations where truck_id = tests.t(9) and session_id = :S1)))->>'code' = 'not_offered', 'C10 過期後再按確認 → 無效');

-- 不能取消別人的
select tests.ok((public.cancel_registration((select id from public.registrations where truck_id = tests.t(10) and session_id = :S1 limit 1)))->>'code' = 'registration_not_found', 'C11 不能取消別人的登記');

-- D2：開場前 3 小時內 → 直接遞補
select tests.login(tests.v(20));
select public.register_for_session(:S4, tests.t(20)) \gset
select tests.login(tests.v(21));
select tests.ok((public.register_for_session(:S4, tests.t(21)))->>'code' = 'waitlisted', 'C12 S4（1 個名額）車主21 候補');
select tests.login(tests.v(20));
select (public.cancel_registration((select id from public.registrations where truck_id = tests.t(20) and session_id = :S4))) as r \gset
select tests.ok(((:'r'::jsonb)->>'is_late_cancel')::boolean, 'C13 D7：3 天內取消 → 記錄為晚取消（不扣分）');
reset role;
select tests.ok((select status from public.registrations where truck_id = tests.t(21) and session_id = :S4) = 'confirmed', 'C14 D2：開場前 3 小時內 → 車主21 直接確認');
select tests.ok((select credit_score from public.org_vendors where vendor_id = tests.v(20) and org_id = :orgA) = 100, 'C15 D7：信用分沒有被扣');

\echo
\echo '──── D. 業主調整場次 ────'
set role authenticated;
select tests.login(:ownerA);
update public.sessions set capacity = 6 where id = :S1;
reset role;
select tests.ok((select count(*) from public.registrations where session_id = :S1 and status = 'offered') = 2, 'D1 名額 5→6 → 自動多遞補一位');
set role authenticated;
select tests.login(:ownerA);
do $$ begin
  begin
    update public.sessions set capacity = 2 where id = '99999999-0000-0000-0000-000000000001';
    perform tests.ok(false, 'D2 名額調太低應該失敗');
  exception when check_violation then
    perform tests.ok(true, 'D2 名額不能調得比已確認人數少');
  end;
end $$;
update public.sessions set status = 'cancelled', note = '颱風停市' where id = :S2;
select tests.login(tests.v(1));
select tests.ok((public.register_for_session(:S2, tests.t(101)))->>'code' = 'session_cancelled', 'D3 已取消的場次不能登記');
reset role;
select tests.login(:ownerA);
set role authenticated;
select tests.ok((public.generate_sessions(:orgA, (date_trunc('month', now()) + interval '2 months')::date))->>'ok' = 'true', 'D4 業主產生整月場次');
select (public.generate_sessions(:orgA, (date_trunc('month', now()) + interval '2 months')::date))->>'created' as again \gset
select tests.ok(:'again' = '0', 'D5 再按一次不會重複產生');
reset role;
select tests.ok((select count(*) = count(*) filter (where to_char(starts_at at time zone 'Asia/Taipei', 'HH24:MI') = '10:00'
                                                   and to_char(closes_at at time zone 'Asia/Taipei', 'HH24:MI') = '20:00'
                                                   and closes_at::date < starts_at::date + 1
                                                   and extract(day from opens_at at time zone 'Asia/Taipei') = 15
                                                   and to_char(opens_at at time zone 'Asia/Taipei', 'HH24:MI') = '12:00')
                 from public.sessions where date >= (date_trunc('month', now()) + interval '2 months')::date),
                'D6 時區正確：10:00 開場、前一天 20:00 截止、15 日 12:00 開放（台灣時間）');
select tests.ok((select count(*) from public.sessions s where s.venue_id = :venA2 and s.date >= (date_trunc('month', now()) + interval '2 months')::date
                 and extract(isodow from s.date) in (6, 7)) = 0, 'D7 只在設定的星期幾產生（陽光廣場週末沒有場次）');

\echo
\echo '──── E. 拍照報到 ────'
select tests.login(tests.v(30));
set role authenticated;
select public.register_for_session(:S5, tests.t(30)) \gset
reset role;
-- S5 已截止，用業主身分幫車主30、31 加入
select tests.login(:ownerA);
set role authenticated;
select tests.ok((public.register_for_session(:S5, tests.t(30)))->>'code' = 'confirmed', 'E1 截止後業主仍可手動幫車主加入');
select public.register_for_session(:S5, tests.t(31)) \gset
select tests.login(tests.v(30));
select tests.ok((public.check_in((select id from public.registrations where truck_id = tests.t(30) and session_id = :S5), 'in',
                 'dddddddd-0000-0000-0000-000000000001/' || tests.v(30) || '/today/in.jpg'))->>'code' = 'photo_not_uploaded', 'E2 照片還沒上傳 → 擋下');
insert into storage.objects(bucket_id, name) values ('checkin-photos', 'dddddddd-0000-0000-0000-000000000001/' || tests.v(30) || '/today/in.jpg');
do $$ begin
  begin
    insert into storage.objects(bucket_id, name) values ('checkin-photos', 'dddddddd-0000-0000-0000-000000000001/' || tests.v(31) || '/today/fake.jpg');
    perform tests.ok(false, 'E3 上傳到別人資料夾應該失敗');
  exception when insufficient_privilege then
    perform tests.ok(true, 'E3 不能上傳到別人的照片資料夾');
  end;
end $$;
select (public.check_in((select id from public.registrations where truck_id = tests.t(30) and session_id = :S5), 'in',
        'dddddddd-0000-0000-0000-000000000001/' || tests.v(30) || '/today/in.jpg')) as r \gset
select tests.ok((:'r'::jsonb)->>'seq_no' = '1' and (:'r'::jsonb)->>'display_code' like '%-AM-出01', 'E4 出攤報到成功，序號 ' || ((:'r'::jsonb)->>'display_code'));
select tests.ok((public.check_in((select id from public.registrations where truck_id = tests.t(30) and session_id = :S5), 'in',
                 'dddddddd-0000-0000-0000-000000000001/' || tests.v(30) || '/today/in.jpg'))->>'code' = 'already_checked_in', 'E5 重複按 → 回傳同一個序號');
select tests.ok((public.check_in((select id from public.registrations where truck_id = tests.t(30) and session_id = :S5), 'out',
                 'dddddddd-0000-0000-0000-000000000001/' || tests.v(30) || '/today/in.jpg'))->>'code' = 'outside_window', 'E6 收攤照還不到時間 → 擋下');
select tests.login(tests.v(31));
insert into storage.objects(bucket_id, name) values ('checkin-photos', 'dddddddd-0000-0000-0000-000000000001/' || tests.v(31) || '/today/in.jpg');
select tests.ok((public.check_in((select id from public.registrations where truck_id = tests.t(31) and session_id = :S5), 'in',
                 'dddddddd-0000-0000-0000-000000000001/' || tests.v(31) || '/today/in.jpg'))->>'seq_no' = '2', 'E7 第二位報到拿到序號 2');
select tests.ok((select count(*) from storage.objects) = 1, 'E8 車主只看得到自己的照片');
select tests.login(:ownerA);
select tests.ok((select count(*) from storage.objects) = 2 and (select count(*) from public.checkins) = 2, 'E9 業主看得到全部報到與照片');
update public.checkins set audit_status = 'flagged', audit_note = '照片模糊' where seq_no = 2;
reset role;
select tests.ok((select audited_by from public.checkins where seq_no = 2) = :ownerA, 'E10 稽核標記會記錄是誰標的');
select tests.ok((select expires_at::date - created_at::date from public.photos limit 1) = 90, 'E11 照片 90 天後到期');

\echo
\echo '──── F. 操作紀錄、推播領取 ────'
select tests.ok((select count(*) from public.audit_logs where table_name = 'sessions' and actor_id = :ownerA
                 and new_data->>'status' = 'cancelled') = 1, 'F1 業主取消場次有留下操作紀錄');
select tests.ok((select count(*) from public.notification_outbox where kind = 'session_cancelled') = 0, 'F2 S2 沒有登記，所以沒有停市推播');
grant usage on schema tests to n8n_worker;
grant execute on function tests.ok(boolean, text) to n8n_worker;
set role n8n_worker;
select tests.ok((select count(*) from public.claim_notifications(100)) > 0, 'F3 n8n 帳號可以領取待發推播');
do $$ begin
  begin
    perform count(*) from public.registrations;
    perform tests.ok(false, 'F4 n8n 帳號不應該讀得到登記');
  exception when insufficient_privilege then
    raise notice '✅ F4 n8n 帳號讀不到其他資料';
  end;
end $$;
reset role;
select tests.ok((select count(*) from public.notification_outbox where status = 'sending') > 0, 'F5 領取後狀態變成「發送中」');

\echo
\echo '🎉 功能測試全部通過'
