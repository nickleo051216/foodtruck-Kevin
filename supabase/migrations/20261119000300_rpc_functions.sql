-- =====================================================================
-- 餐車市集排班系統｜試用版資料庫 第 3 部分：功能（RPC）
--
-- 白話說明：
--   RPC 是寫在資料庫裡的「櫃台」。前端只要說「我要用這台車登記這個場次」，
--   櫃台依序檢查，所有檢查和寫入都在同一個交易內完成：
--   要嘛整筆成功，要嘛整筆不算，不會只做一半。
--
--   防超賣的關鍵：處理某個場次前，先「鎖住」那個場次（SELECT … FOR UPDATE）。
--   同一場次一次只處理一個人，其他人排隊等幾毫秒，
--   因此不可能兩個人同時看到「還剩 1 位」。
--
--   每支 RPC 回傳 JSON：{ ok: true/false, code: '代碼', message: '中文說明', ... }
--   前端依 ok 決定顯示成功或錯誤訊息，不需要自己判斷規則。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 小工具：組回傳結果
-- ---------------------------------------------------------------------
create or replace function private.result(p_ok boolean, p_code text, p_message text, p_extra jsonb default '{}'::jsonb)
returns jsonb
language sql immutable
set search_path = ''
as $$
  select jsonb_build_object('ok', p_ok, 'code', p_code, 'message', p_message) || coalesce(p_extra, '{}'::jsonb);
$$;

-- 時間轉成台灣時間的文字，給訊息用
create or replace function private.fmt_tw(p_ts timestamptz)
returns text
language sql stable
set search_path = ''
as $$
  select to_char(p_ts at time zone 'Asia/Taipei', 'FMMM/FMDD HH24:MI');
$$;

-- ---------------------------------------------------------------------
-- 小工具：放一則待發推播（n8n 之後取出，透過 LINE OA 發送）
-- ---------------------------------------------------------------------
create or replace function private.enqueue_notification(p_org_id uuid, p_vendor_id uuid, p_kind text, p_payload jsonb)
returns void
language sql security definer
set search_path = ''
as $$
  insert into public.notification_outbox(org_id, vendor_id, line_user_id, kind, payload)
  select p_org_id, v.id, v.line_user_id, p_kind,
         p_payload || jsonb_build_object('is_oa_friend', v.is_oa_friend, 'display_name', v.display_name)
  from public.vendors v where v.id = p_vendor_id;
$$;

-- 推播要用的場次資訊
create or replace function private.session_payload(p_session_id uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'session_id', s.id, 'date', s.date, 'venue', v.name, 'slot', sl.label,
           'starts_at', s.starts_at, 'ends_at', s.ends_at, 'fee', s.fee,
           'time_text', to_char(s.starts_at at time zone 'Asia/Taipei', 'FMMM/FMDD HH24:MI') || '–' ||
                        to_char(s.ends_at at time zone 'Asia/Taipei', 'HH24:MI'))
  from public.sessions s
  join public.venues v on v.id = s.venue_id
  join public.venue_slots sl on sl.id = s.slot_id
  where s.id = p_session_id;
$$;

-- 候補上限
create or replace function private.waitlist_limit(p_capacity integer, p_ratio numeric)
returns integer
language sql immutable
set search_path = ''
as $$
  select ceil(p_capacity * p_ratio)::integer;
$$;

-- ---------------------------------------------------------------------
-- 核心：有空位就遞補（呼叫前，呼叫者必須已經鎖住這個場次）
--   D1：一般情況 → 改成「遞補待確認」，保留 30 分鐘
--   D2：開場前 3 小時內 → 直接確認
--   排隊的車如果已經不能登記（車停用、車主被暫停），就跳過
-- ---------------------------------------------------------------------
create or replace function private.fill_open_seats(p_session_id uuid)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_s        public.sessions%rowtype;
  v_cfg      public.org_settings%rowtype;
  v_taken    integer;
  v_next     record;
  v_promoted integer := 0;
  v_direct   boolean;
  v_expires  timestamptz;
begin
  select * into v_s from public.sessions where id = p_session_id;
  if not found or v_s.status <> 'open' or now() >= v_s.ends_at then
    return 0;
  end if;
  select * into v_cfg from public.org_settings where org_id = v_s.org_id;
  v_direct := now() >= v_s.starts_at - make_interval(hours => v_cfg.offer_skip_hours);

  loop
    select count(*) into v_taken from public.registrations
     where session_id = p_session_id and status in ('confirmed','offered');
    exit when v_taken >= v_s.capacity;

    select r.id, r.vendor_id, (t.status = 'active' and ov.status = 'active') as eligible
      into v_next
      from public.registrations r
      join public.trucks t on t.id = r.truck_id
      join public.org_vendors ov on ov.org_id = r.org_id and ov.vendor_id = r.vendor_id
     where r.session_id = p_session_id and r.status = 'waitlisted'
     order by r.queued_at, r.id
     limit 1
     for update of r;
    exit when not found;

    if not v_next.eligible then
      update public.registrations
         set status = 'expired', cancel_reason = 'ineligible', cancelled_at = now()
       where id = v_next.id;
      continue;
    end if;

    if v_direct then
      update public.registrations
         set status = 'confirmed', confirmed_at = now(), offered_at = now()
       where id = v_next.id;
      perform private.enqueue_notification(v_s.org_id, v_next.vendor_id, 'offer_auto_confirmed',
        private.session_payload(p_session_id) || jsonb_build_object('registration_id', v_next.id));
    else
      v_expires := least(now() + make_interval(mins => v_cfg.offer_minutes), v_s.starts_at);
      update public.registrations
         set status = 'offered', offered_at = now(), offer_expires_at = v_expires
       where id = v_next.id;
      perform private.enqueue_notification(v_s.org_id, v_next.vendor_id, 'offer',
        private.session_payload(p_session_id) || jsonb_build_object(
          'registration_id', v_next.id,
          'offer_expires_at', v_expires,
          'offer_expires_text', private.fmt_tw(v_expires)));
    end if;
    v_promoted := v_promoted + 1;
  end loop;
  return v_promoted;
end;
$$;

-- =====================================================================
-- RPC 1：登記 register_for_session(場次, 車)
-- =====================================================================
create or replace function public.register_for_session(p_session_id uuid, p_truck_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_s         public.sessions%rowtype;
  v_cfg       public.org_settings%rowtype;
  v_truck     public.trucks%rowtype;
  v_ov        public.org_vendors%rowtype;
  v_venue     public.venues%rowtype;
  v_is_admin  boolean;
  v_existing  public.registrations%rowtype;
  v_conflict  record;
  v_reason    text;
  v_taken     integer;
  v_waiting   integer;
  v_status    text;
  v_reg_id    uuid;
begin
  -- 1. 你是誰？
  if v_uid is null then
    return private.result(false, 'not_authenticated', '請先透過 LINE 登入');
  end if;

  select * into v_s from public.sessions where id = p_session_id;
  if not found then
    return private.result(false, 'session_not_found', '找不到這個場次');
  end if;
  v_is_admin := private.is_org_admin(v_s.org_id);

  if not v_is_admin then
    select * into v_ov from public.org_vendors where org_id = v_s.org_id and vendor_id = v_uid;
    if not found then
      return private.result(false, 'not_member', '您尚未加入這個市集');
    elsif v_ov.status <> 'active' then
      return private.result(false, 'vendor_paused', '您的帳號目前暫停登記，請聯絡業主');
    end if;
  end if;

  -- 2. 這台車是你的嗎？（並鎖住這台車，避免同一台車同時登記兩個時間重疊的場次）
  select * into v_truck from public.trucks
   where id = p_truck_id and org_id = v_s.org_id
   for update;
  if not found or (not v_is_admin and v_truck.vendor_id <> v_uid) then
    return private.result(false, 'truck_not_found', '找不到這台車');
  elsif v_truck.status = 'pending' then
    return private.result(false, 'truck_pending', '「' || v_truck.name || '」還在審核中，通過後才能登記');
  elsif v_truck.status <> 'active' then
    return private.result(false, 'truck_inactive', '「' || v_truck.name || '」目前無法登記');
  end if;

  -- 7.（提早）鎖住這個場次：防超賣的關鍵。之後的檢查都在鎖裡面做。
  select * into v_s from public.sessions where id = p_session_id for update;
  select * into v_cfg from public.org_settings where org_id = v_s.org_id;
  select * into v_venue from public.venues where id = v_s.venue_id;

  -- 3. 這個場次能登記嗎？
  if v_venue.status <> 'open' then
    return private.result(false, 'venue_paused', v_venue.name || ' 目前暫停開放');
  elsif v_s.status = 'private' then
    return private.result(false, 'session_private', '此場次為包場');
  elsif v_s.status = 'cancelled' then
    return private.result(false, 'session_cancelled', '此場次已取消');
  elsif v_s.status <> 'open' then
    return private.result(false, 'session_closed', '此場次未開放登記');
  elsif now() >= v_s.ends_at then
    return private.result(false, 'session_ended', '此場次已結束');
  end if;
  if not v_is_admin then
    if now() < v_s.opens_at then
      return private.result(false, 'not_open_yet', '此場次 ' || private.fmt_tw(v_s.opens_at) || ' 才開放登記',
                            jsonb_build_object('opens_at', v_s.opens_at));
    elsif now() >= v_s.closes_at then
      return private.result(false, 'registration_closed', '此場次已於 ' || private.fmt_tw(v_s.closes_at) || ' 截止登記');
    end if;
  end if;

  -- 4. 有沒有「未開放」規則？（業主手動加入時可略過）
  if not v_is_admin then
    select reason into v_reason from public.venue_restrictions
     where venue_id = v_s.venue_id
       and (truck_id = v_truck.id or food_type = v_truck.food_type)
     limit 1;
    if found then
      return private.result(false, 'venue_restricted', v_reason);
    end if;
  end if;

  -- 5. 是不是重複按？→ 直接回傳原本那筆
  select * into v_existing from public.registrations
   where session_id = p_session_id and truck_id = p_truck_id
     and status in ('confirmed','waitlisted','offered');
  if found then
    return private.result(true, 'already_registered', '這台車已經登記過這個場次',
      jsonb_build_object('registration_id', v_existing.id, 'status', v_existing.status));
  end if;

  -- 6. 時間有沒有撞？（同一台車，時間重疊的其他有效登記，含候補）
  select v2.name as venue_name, sl2.label as slot_label, s2.date
    into v_conflict
    from public.registrations r
    join public.sessions s2 on s2.id = r.session_id
    join public.venues v2 on v2.id = s2.venue_id
    join public.venue_slots sl2 on sl2.id = s2.slot_id
   where r.truck_id = p_truck_id and r.session_id <> p_session_id
     and r.status in ('confirmed','waitlisted','offered')
     and s2.status <> 'cancelled'
     and s2.starts_at < v_s.ends_at and s2.ends_at > v_s.starts_at
   limit 1;
  if found then
    return private.result(false, 'time_conflict',
      '「' || v_truck.name || '」' || to_char(v_conflict.date, 'FMMM/FMDD') || ' 已登記 ' ||
      v_conflict.venue_name || ' ' || v_conflict.slot_label || '，時間重疊');
  end if;

  -- D3：同一位車主的其他車，已經在這個場次？
  if not v_cfg.allow_multi_truck_same_session then
    perform 1 from public.registrations
     where session_id = p_session_id and vendor_id = v_truck.vendor_id and truck_id <> p_truck_id
       and status in ('confirmed','waitlisted','offered');
    if found then
      return private.result(false, 'vendor_already_in_session', '您已有其他車登記這個場次，同一場次限一台車');
    end if;
  end if;

  -- 8. 算名額，決定結果
  select count(*) filter (where status in ('confirmed','offered')),
         count(*) filter (where status = 'waitlisted')
    into v_taken, v_waiting
    from public.registrations where session_id = p_session_id;

  if v_taken < v_s.capacity then
    v_status := 'confirmed';
  elsif v_waiting < private.waitlist_limit(v_s.capacity, v_cfg.waitlist_limit_ratio) then
    v_status := 'waitlisted';
  else
    return private.result(false, 'session_full', '此場次名額與候補都已額滿');
  end if;

  -- 9. 寫入並回傳
  insert into public.registrations(org_id, session_id, truck_id, vendor_id, status,
                                   confirmed_at, fee_snapshot, created_by)
  values (v_s.org_id, p_session_id, p_truck_id, v_truck.vendor_id, v_status,
          case when v_status = 'confirmed' then now() end, v_s.fee, v_uid)
  returning id into v_reg_id;

  if v_status = 'confirmed' then
    return private.result(true, 'confirmed', '登記成功', jsonb_build_object(
      'registration_id', v_reg_id, 'status', v_status, 'fee', v_s.fee));
  else
    return private.result(true, 'waitlisted', '名額已滿，您是候補第 ' || (v_waiting + 1) || ' 位', jsonb_build_object(
      'registration_id', v_reg_id, 'status', v_status, 'waitlist_position', v_waiting + 1, 'fee', v_s.fee));
  end if;

exception when unique_violation then
  -- 最後一道保險：萬一真的同時寫入，回傳原本那筆
  select * into v_existing from public.registrations
   where session_id = p_session_id and truck_id = p_truck_id
     and status in ('confirmed','waitlisted','offered');
  return private.result(true, 'already_registered', '這台車已經登記過這個場次',
    jsonb_build_object('registration_id', v_existing.id, 'status', v_existing.status));
end;
$$;

-- =====================================================================
-- RPC 2：取消 cancel_registration(登記, 原因)
-- =====================================================================
create or replace function public.cancel_registration(p_registration_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_r         public.registrations%rowtype;
  v_s         public.sessions%rowtype;
  v_cfg       public.org_settings%rowtype;
  v_is_admin  boolean;
  v_late      boolean;
  v_holding   boolean;
begin
  if v_uid is null then
    return private.result(false, 'not_authenticated', '請先透過 LINE 登入');
  end if;
  select * into v_r from public.registrations where id = p_registration_id;
  if not found then
    return private.result(false, 'registration_not_found', '找不到這筆登記');
  end if;
  v_is_admin := private.is_org_admin(v_r.org_id);
  if not v_is_admin and v_r.vendor_id <> v_uid then
    return private.result(false, 'registration_not_found', '找不到這筆登記');
  end if;

  -- 鎖住場次，再重新讀一次這筆登記（可能剛被別人改過）
  select * into v_s from public.sessions where id = v_r.session_id for update;
  select * into v_r from public.registrations where id = p_registration_id for update;
  select * into v_cfg from public.org_settings where org_id = v_r.org_id;

  if v_r.status not in ('confirmed','waitlisted','offered') then
    return private.result(true, 'already_inactive', '這筆登記已經不是有效狀態',
                          jsonb_build_object('registration_id', v_r.id, 'status', v_r.status));
  end if;
  if not v_is_admin and now() >= v_s.closes_at then
    return private.result(false, 'cancel_closed',
      '已超過取消期限（' || private.fmt_tw(v_s.closes_at) || '），請直接聯絡業主');
  end if;

  v_holding := v_r.status in ('confirmed','offered');
  -- D7：3 天內取消算晚取消；試用版只記錄，不扣分（只有正取 / 遞補中才算）
  v_late := v_holding and v_s.starts_at - now() < make_interval(days => v_cfg.late_cancel_days);

  update public.registrations
     set status = 'cancelled', cancelled_at = now(), cancelled_by = v_uid,
         cancel_reason = coalesce(p_reason, case when v_is_admin and v_r.vendor_id <> v_uid
                                                  then 'admin' else 'vendor' end),
         is_late_cancel = v_late
   where id = v_r.id;

  if v_holding then
    perform private.fill_open_seats(v_s.id);   -- 空出名額 → 立刻遞補下一位並推播
  end if;

  return private.result(true, 'cancelled',
    case when v_late then '已取消（距離場次不到 ' || v_cfg.late_cancel_days || ' 天，已記錄為晚取消）'
         else '已取消' end,
    jsonb_build_object('registration_id', v_r.id, 'is_late_cancel', v_late));
end;
$$;

-- =====================================================================
-- RPC 3：確認遞補 accept_offer(登記)
-- =====================================================================
create or replace function public.accept_offer(p_registration_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_r    public.registrations%rowtype;
begin
  if v_uid is null then
    return private.result(false, 'not_authenticated', '請先透過 LINE 登入');
  end if;
  select * into v_r from public.registrations where id = p_registration_id and vendor_id = v_uid;
  if not found then
    return private.result(false, 'registration_not_found', '找不到這筆登記');
  end if;

  perform 1 from public.sessions where id = v_r.session_id for update;
  select * into v_r from public.registrations where id = p_registration_id for update;

  if v_r.status = 'confirmed' then
    return private.result(true, 'already_confirmed', '已經確認過了', jsonb_build_object('registration_id', v_r.id));
  elsif v_r.status <> 'offered' then
    return private.result(false, 'not_offered', '這筆登記目前沒有遞補名額可以確認');
  elsif now() > v_r.offer_expires_at then
    update public.registrations
       set status = 'expired', cancelled_at = now(), cancel_reason = 'offer_expired'
     where id = v_r.id;
    perform private.fill_open_seats(v_r.session_id);
    return private.result(false, 'offer_expired', '保留時間已過，名額已讓給下一位');
  end if;

  update public.registrations set status = 'confirmed', confirmed_at = now() where id = v_r.id;
  return private.result(true, 'confirmed', '已確認，記得準時出攤', jsonb_build_object('registration_id', v_r.id));
end;
$$;

-- =====================================================================
-- 排程：處理逾時的遞補（pg_cron 每分鐘跑一次，見 0400）
-- =====================================================================
create or replace function public.expire_offers()
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_session  uuid;
  v_r        record;
  v_count    integer := 0;
begin
  for v_session in
    select distinct session_id from public.registrations
     where status = 'offered' and offer_expires_at < now()
  loop
    perform 1 from public.sessions where id = v_session for update;
    for v_r in
      update public.registrations
         set status = 'expired', cancelled_at = now(), cancel_reason = 'offer_expired'
       where session_id = v_session and status = 'offered' and offer_expires_at < now()
       returning id, org_id, vendor_id
    loop
      perform private.enqueue_notification(v_r.org_id, v_r.vendor_id, 'offer_expired',
        private.session_payload(v_session) || jsonb_build_object('registration_id', v_r.id));
      v_count := v_count + 1;
    end loop;
    perform private.fill_open_seats(v_session);
  end loop;
  return v_count;
end;
$$;

-- =====================================================================
-- RPC 4：拍照報到 check_in(登記, in/out, 照片路徑)
--   照片先由前端上傳到 Storage（checkin-photos/<org_id>/<vendor_id>/…），再呼叫這支
-- =====================================================================
create or replace function public.check_in(p_registration_id uuid, p_kind text, p_storage_path text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_r      public.registrations%rowtype;
  v_s      public.sessions%rowtype;
  v_cfg    public.org_settings%rowtype;
  v_slot   public.venue_slots%rowtype;
  v_from   timestamptz;
  v_to     timestamptz;
  v_exist  public.checkins%rowtype;
  v_seq    integer;
  v_code   text;
  v_photo  uuid;
begin
  if v_uid is null then
    return private.result(false, 'not_authenticated', '請先透過 LINE 登入');
  end if;
  if p_kind not in ('in','out') then
    return private.result(false, 'bad_kind', '報到類型錯誤');
  end if;
  select * into v_r from public.registrations where id = p_registration_id and vendor_id = v_uid;
  if not found then
    return private.result(false, 'registration_not_found', '找不到這筆登記');
  end if;
  if v_r.status <> 'confirmed' then
    return private.result(false, 'not_confirmed', '只有已確認的登記可以報到');
  end if;

  select * into v_s   from public.sessions where id = v_r.session_id for update;
  select * into v_cfg from public.org_settings where org_id = v_r.org_id;
  select * into v_slot from public.venue_slots where id = v_s.slot_id;

  if v_s.status = 'cancelled' then
    return private.result(false, 'session_cancelled', '此場次已取消');
  end if;

  -- 已經報到過 → 回傳原本的序號（重複按不會拿到新號碼）
  select * into v_exist from public.checkins where registration_id = v_r.id and kind = p_kind;
  if found then
    return private.result(true, 'already_checked_in', '已經報到過了',
      jsonb_build_object('seq_no', v_exist.seq_no, 'display_code', v_exist.display_code));
  end if;

  if p_kind = 'in' then
    v_from := v_s.starts_at - make_interval(mins => v_cfg.checkin_in_before_min);
    v_to   := v_s.starts_at + make_interval(mins => v_cfg.checkin_in_after_min);
  else
    v_from := v_s.ends_at - make_interval(mins => v_cfg.checkin_out_before_min);
    v_to   := v_s.ends_at + make_interval(mins => v_cfg.checkin_out_after_min);
  end if;
  if now() < v_from or now() > v_to then
    return private.result(false, 'outside_window',
      case when p_kind = 'in' then '出攤' else '收攤' end || '照請在 ' ||
      private.fmt_tw(v_from) || '～' || to_char(v_to at time zone 'Asia/Taipei', 'HH24:MI') || ' 之間拍攝');
  end if;

  -- 照片必須是本人上傳到自己資料夾的檔案
  if p_storage_path is null
     or p_storage_path not like (v_r.org_id::text || '/' || v_uid::text || '/%') then
    return private.result(false, 'bad_photo_path', '照片位置不正確，請重新拍照');
  end if;
  perform 1 from storage.objects
   where bucket_id = 'checkin-photos' and name = p_storage_path and owner = v_uid;
  if not found then
    return private.result(false, 'photo_not_uploaded', '照片還沒上傳完成，請稍候再試');
  end if;

  select coalesce(max(seq_no), 0) + 1 into v_seq
    from public.checkins where session_id = v_s.id and kind = p_kind;
  v_code := to_char(v_s.date, 'MMDD') || '-' || v_slot.code || '-' ||
            case when p_kind = 'in' then '出' else '收' end || lpad(v_seq::text, 2, '0');

  insert into public.photos(org_id, vendor_id, storage_path, uploaded_by, expires_at)
  values (v_r.org_id, v_uid, p_storage_path, v_uid, now() + make_interval(days => v_cfg.photo_retention_days))
  on conflict (storage_path) do update set storage_path = excluded.storage_path
  returning id into v_photo;

  insert into public.checkins(org_id, registration_id, session_id, vendor_id, kind, seq_no, display_code, photo_id)
  values (v_r.org_id, v_r.id, v_s.id, v_uid, p_kind, v_seq, v_code, v_photo);

  return private.result(true, 'checked_in',
    case when p_kind = 'in' then '出攤報到完成' else '收攤報到完成' end || '，序號 ' || v_code,
    jsonb_build_object('seq_no', v_seq, 'display_code', v_code));
end;
$$;

-- =====================================================================
-- 後台 RPC：依時段模板產生整個月的場次（重複按不會重複產生）
-- =====================================================================
create or replace function public.generate_sessions(p_org_id uuid, p_month date)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cfg    public.org_settings%rowtype;
  v_first  date := date_trunc('month', p_month)::date;
  v_last   date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_opens  timestamptz;
  v_count  integer;
begin
  if not private.is_org_admin(p_org_id) then
    return private.result(false, 'forbidden', '只有業主可以產生場次');
  end if;
  select * into v_cfg from public.org_settings where org_id = p_org_id;

  -- D5：上個月 15 日 12:00 開放
  v_opens := ((v_first - interval '1 month')::date + (v_cfg.open_day - 1) + v_cfg.open_time)
             at time zone v_cfg.timezone;

  with ins as (
    insert into public.sessions(org_id, venue_id, slot_id, date, starts_at, ends_at,
                                capacity, fee, opens_at, closes_at)
    select p_org_id, sl.venue_id, sl.id, d::date,
           (d::date + sl.start_time) at time zone v_cfg.timezone,
           (d::date + sl.end_time + case when sl.end_time <= sl.start_time then interval '1 day'
                                         else interval '0' end) at time zone v_cfg.timezone,
           sl.capacity, sl.fee, v_opens,
           -- D6：場次前一天 20:00 截止
           ((d::date - v_cfg.close_days_before) + v_cfg.close_time) at time zone v_cfg.timezone
      from public.venue_slots sl
      join public.venues v on v.id = sl.venue_id
      cross join generate_series(v_first, v_last, interval '1 day') d
     where sl.org_id = p_org_id and sl.is_active and v.status = 'open'
       and extract(isodow from d)::smallint = any(sl.weekdays)
    on conflict (venue_id, slot_id, date) do nothing
    returning 1)
  select count(*) into v_count from ins;

  return private.result(true, 'generated', '已產生 ' || v_count || ' 個場次',
                        jsonb_build_object('created', v_count, 'opens_at', v_opens));
end;
$$;

-- =====================================================================
-- 查詢 RPC：場次列表＋剩餘名額（車主只看得到數字，看不到別人是誰）
-- =====================================================================
create or replace function public.get_sessions(p_org_id uuid, p_from date, p_to date)
returns table (
  session_id uuid, date date, venue_id uuid, venue_name text, venue_status text,
  slot_code text, slot_label text, starts_at timestamptz, ends_at timestamptz,
  capacity integer, fee integer, status text, opens_at timestamptz, closes_at timestamptz,
  taken integer, waitlisted integer, waitlist_limit integer
)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not (private.is_org_admin(p_org_id) or private.is_org_vendor(p_org_id)) then
    return;
  end if;
  return query
  select s.id, s.date, v.id, v.name, v.status, sl.code, sl.label, s.starts_at, s.ends_at,
         s.capacity, s.fee, s.status, s.opens_at, s.closes_at,
         (count(r.id) filter (where r.status in ('confirmed','offered')))::integer,
         (count(r.id) filter (where r.status = 'waitlisted'))::integer,
         private.waitlist_limit(s.capacity, cfg.waitlist_limit_ratio)
    from public.sessions s
    join public.venues v on v.id = s.venue_id
    join public.venue_slots sl on sl.id = s.slot_id
    join public.org_settings cfg on cfg.org_id = s.org_id
    left join public.registrations r on r.session_id = s.id
   where s.org_id = p_org_id and s.date between p_from and p_to
   group by s.id, v.id, sl.id, cfg.waitlist_limit_ratio
   order by s.starts_at, v.sort_order, v.name;
end;
$$;

-- 我的登記（含候補第幾位）
create or replace function public.my_registrations(p_org_id uuid, p_from date default null)
returns table (
  registration_id uuid, session_id uuid, truck_id uuid, truck_name text, date date,
  venue_name text, slot_label text, starts_at timestamptz, ends_at timestamptz,
  status text, waitlist_position integer, offer_expires_at timestamptz, fee integer, is_late_cancel boolean
)
language sql stable security definer
set search_path = ''
as $$
  select r.id, r.session_id, r.truck_id, t.name, s.date, v.name, sl.label, s.starts_at, s.ends_at,
         r.status,
         case when r.status = 'waitlisted' then
           (select count(*)::integer + 1 from public.registrations w
             where w.session_id = r.session_id and w.status = 'waitlisted'
               and (w.queued_at, w.id) < (r.queued_at, r.id))
         end,
         r.offer_expires_at, r.fee_snapshot, r.is_late_cancel
    from public.registrations r
    join public.sessions s on s.id = r.session_id
    join public.venues v on v.id = s.venue_id
    join public.venue_slots sl on sl.id = s.slot_id
    join public.trucks t on t.id = r.truck_id
   where r.org_id = p_org_id and r.vendor_id = (select auth.uid())
     and s.date >= coalesce(p_from, (now() at time zone 'Asia/Taipei')::date - 31)
   order by s.starts_at;
$$;

-- 車主點社群貼的連結加入市集（車主資料由第 2 步的 Edge Function 先建立）
create or replace function public.join_org(p_slug text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_org  public.orgs%rowtype;
begin
  if v_uid is null or not exists (select 1 from public.vendors where id = v_uid) then
    return private.result(false, 'not_authenticated', '請先透過 LINE 登入');
  end if;
  select * into v_org from public.orgs where slug = p_slug and status in ('trial','active');
  if not found then
    return private.result(false, 'org_not_found', '找不到這個市集，請確認連結是否正確');
  end if;
  insert into public.org_vendors(org_id, vendor_id) values (v_org.id, v_uid)
  on conflict do nothing;
  return private.result(true, 'joined', '歡迎加入 ' || v_org.name,
                        jsonb_build_object('org_id', v_org.id, 'org_name', v_org.name));
end;
$$;

-- =====================================================================
-- 場次的連動規則（業主在後台改場次時自動觸發）
--   - 名額調高 → 自動遞補
--   - 名額調低到比已確認人數還少 → 不允許（請先手動取消）
--   - 場次改成「取消」（例：下雨）→ 所有有效登記取消，並推播通知
-- =====================================================================
create or replace function private.sessions_before_update()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_taken integer;
begin
  if new.capacity < old.capacity then
    select count(*) into v_taken from public.registrations
     where session_id = new.id and status in ('confirmed','offered');
    if new.capacity < v_taken then
      raise exception '名額不能少於目前已確認的 % 台，請先取消多出的登記', v_taken using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger sessions_before_update before update of capacity on public.sessions
  for each row execute function private.sessions_before_update();

create or replace function private.sessions_after_update()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_r record;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    for v_r in
      update public.registrations
         set status = 'cancelled', cancelled_at = now(), cancelled_by = (select auth.uid()),
             cancel_reason = 'session_cancelled'
       where session_id = new.id and status in ('confirmed','waitlisted','offered')
       returning id, org_id, vendor_id
    loop
      perform private.enqueue_notification(v_r.org_id, v_r.vendor_id, 'session_cancelled',
        private.session_payload(new.id) || jsonb_build_object('registration_id', v_r.id, 'note', new.note));
    end loop;
  elsif new.capacity > old.capacity and new.status = 'open' then
    perform private.fill_open_seats(new.id);
  end if;
  return null;
end;
$$;
create trigger sessions_after_update after update of capacity, status on public.sessions
  for each row execute function private.sessions_after_update();

-- 車輛修改的守門員（定義在 0200）
create trigger trucks_guard before insert or update on public.trucks
  for each row execute function private.trucks_guard();

-- =====================================================================
-- 給 n8n 用的專用小權限帳號：只能領取待發推播、回報發送結果
--   密碼不寫在這裡。建好後由 Nick 在 Supabase SQL Editor 執行：
--   alter role n8n_worker with login password '（自己產生的長密碼）';
-- =====================================================================
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'n8n_worker') then
    create role n8n_worker nologin;
  end if;
end $$;

create or replace function public.claim_notifications(p_limit integer default 50)
returns setof public.notification_outbox
language sql security definer
set search_path = ''
as $$
  update public.notification_outbox o
     set status = 'sending', claimed_at = now(), attempts = o.attempts + 1
   where o.id in (
     select id from public.notification_outbox
      where (status = 'pending' or (status = 'sending' and claimed_at < now() - interval '10 minutes'))
        and attempts < 5
      order by id
      limit least(greatest(p_limit, 1), 200)
      for update skip locked)
  returning o.*;
$$;

create or replace function public.mark_notification(p_id bigint, p_ok boolean, p_error text default null)
returns void
language sql security definer
set search_path = ''
as $$
  update public.notification_outbox
     set status = case when p_ok then 'sent' when attempts >= 5 then 'failed' else 'pending' end,
         sent_at = case when p_ok then now() end,
         last_error = p_error
   where id = p_id;
$$;

-- =====================================================================
-- 誰可以呼叫哪支 RPC
-- =====================================================================
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on function private.result(boolean, text, text, jsonb), private.fmt_tw(timestamptz),
                       private.enqueue_notification(uuid, uuid, text, jsonb), private.session_payload(uuid),
                       private.waitlist_limit(integer, numeric), private.fill_open_seats(uuid)
  from public, anon, authenticated;

grant execute on function
  public.register_for_session(uuid, uuid),
  public.cancel_registration(uuid, text),
  public.accept_offer(uuid),
  public.check_in(uuid, text, text),
  public.generate_sessions(uuid, date),
  public.get_sessions(uuid, date, date),
  public.my_registrations(uuid, date),
  public.join_org(text)
  to authenticated;

grant usage on schema public to n8n_worker;
grant execute on function public.claim_notifications(integer), public.mark_notification(bigint, boolean, text)
  to n8n_worker;
-- expire_offers 只給排程（postgres）執行，不開放給任何網頁使用者
