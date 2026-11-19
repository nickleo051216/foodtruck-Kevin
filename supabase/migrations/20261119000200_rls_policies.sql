-- =====================================================================
-- 餐車市集排班系統｜試用版資料庫 第 2 部分：權限（RLS）
--
-- 白話說明：
--   RLS 就像大樓門禁。所有表都開啟 RLS，預設全部鎖住，
--   只有下面寫出來的規則才會開門。
--   - 車主（authenticated + 有 vendors 資料）只看得到自己的東西
--   - 業主（org_admins）只看得到自己市集的東西
--   - Nick（platform_admins）全部看得到；這張名單網頁上改不到
--   - 未登入（anon）什麼都看不到
--   - 登記、取消、報到「不能直接寫表」，只能透過 0300 的 RPC
-- =====================================================================

-- ---------------------------------------------------------------------
-- 小工具：判斷「現在登入的人」是什麼身分
-- security definer = 用建立者的權限查名單，避免 RLS 自己查自己造成無限循環
-- ---------------------------------------------------------------------
create or replace function private.is_platform_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.platform_admins where user_id = (select auth.uid()));
$$;

create or replace function private.is_org_admin(p_org_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.is_platform_admin()
      or exists (select 1 from public.org_admins
                 where org_id = p_org_id and user_id = (select auth.uid()));
$$;

create or replace function private.is_org_owner(p_org_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.is_platform_admin()
      or exists (select 1 from public.org_admins
                 where org_id = p_org_id and user_id = (select auth.uid()) and role = 'owner');
$$;

create or replace function private.is_org_vendor(p_org_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.org_vendors
                 where org_id = p_org_id and vendor_id = (select auth.uid()));
$$;

grant usage on schema private to authenticated;
revoke all on all functions in schema private from public, anon;
grant execute on function private.is_platform_admin(), private.is_org_admin(uuid),
                          private.is_org_owner(uuid), private.is_org_vendor(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- 全部開啟 RLS；未登入（anon）一律沒有任何資料表權限
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['orgs','org_settings','org_admins','platform_admins','vendors','org_vendors',
                           'trucks','venues','venue_slots','venue_restrictions','sessions','registrations',
                           'photos','checkins','notification_outbox','audit_logs']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- 只能透過 RPC 寫入的表：連「寫入」的權限都先收回（雙重保險）
revoke insert, update, delete on public.registrations, public.photos, public.notification_outbox,
                                 public.audit_logs, public.platform_admins
  from authenticated;
revoke insert, delete on public.checkins from authenticated;
revoke update on public.checkins from authenticated;
grant  update (audit_status, audit_note) on public.checkins to authenticated;   -- 後台「拍照稽核」只能改這兩欄

-- 車主只能改自己的名稱、電話
revoke insert, update, delete on public.vendors from authenticated;
grant  update (display_name, phone) on public.vendors to authenticated;

-- 車主在市集的身分：業主只能改狀態（信用分試用版不開放手改，正式版走 credit_events）
revoke insert, update, delete on public.org_vendors from authenticated;
grant  update (status) on public.org_vendors to authenticated;

-- 業主不能直接改 orgs（由 Nick 在控制台建立）
revoke insert, update, delete on public.orgs from authenticated;
-- 設定：只能改，不能新增刪除（新增 org 時一起建立）
revoke insert, delete on public.org_settings from authenticated;

-- =====================================================================
-- 各表規則
-- =====================================================================

-- orgs：自己加入或管理的市集
create policy orgs_select on public.orgs for select to authenticated
  using (private.is_org_admin(id) or private.is_org_vendor(id));

-- org_settings：成員都看得到（含匯款帳號）；只有 owner 能改
create policy org_settings_select on public.org_settings for select to authenticated
  using (private.is_org_admin(org_id) or private.is_org_vendor(org_id));
create policy org_settings_update on public.org_settings for update to authenticated
  using (private.is_org_owner(org_id)) with check (private.is_org_owner(org_id));

-- org_admins：同市集管理員看得到；owner 只能新增 / 移除「小幫手」，owner 由 Nick 指定
create policy org_admins_select on public.org_admins for select to authenticated
  using (private.is_org_admin(org_id));
create policy org_admins_insert on public.org_admins for insert to authenticated
  with check (private.is_platform_admin() or (private.is_org_owner(org_id) and role = 'staff'));
create policy org_admins_update on public.org_admins for update to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());
create policy org_admins_delete on public.org_admins for delete to authenticated
  using (private.is_platform_admin() or (private.is_org_owner(org_id) and role = 'staff'));

-- platform_admins：沒有任何規則 = 網頁上誰都看不到、改不到

-- vendors：自己；業主看得到有加入自家市集的車主
create policy vendors_select on public.vendors for select to authenticated
  using (id = (select auth.uid())
         or exists (select 1 from public.org_vendors ov
                    where ov.vendor_id = vendors.id and private.is_org_admin(ov.org_id)));
create policy vendors_update_self on public.vendors for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- org_vendors：自己；業主看全部、可暫停 / 恢復
create policy org_vendors_select on public.org_vendors for select to authenticated
  using (vendor_id = (select auth.uid()) or private.is_org_admin(org_id));
create policy org_vendors_update on public.org_vendors for update to authenticated
  using (private.is_org_admin(org_id)) with check (private.is_org_admin(org_id));

-- trucks：車主看自己的、新增一律「待審核」；業主看全部、審核
create policy trucks_select on public.trucks for select to authenticated
  using (vendor_id = (select auth.uid()) or private.is_org_admin(org_id));
create policy trucks_insert_vendor on public.trucks for insert to authenticated
  with check (vendor_id = (select auth.uid())
              and status = 'pending' and reviewed_by is null and reviewed_at is null
              and exists (select 1 from public.org_vendors ov
                          where ov.org_id = trucks.org_id and ov.vendor_id = (select auth.uid())
                            and ov.status = 'active'));
create policy trucks_insert_admin on public.trucks for insert to authenticated
  with check (private.is_org_admin(org_id));
create policy trucks_update on public.trucks for update to authenticated
  using (vendor_id = (select auth.uid()) or private.is_org_admin(org_id))
  with check (vendor_id = (select auth.uid()) or private.is_org_admin(org_id));
revoke delete on public.trucks from authenticated;   -- 不刪除，改成 retired 保留歷史

-- 車主改車：只能改車牌；車名、類型、狀態要業主處理（改名審核為預留功能）
create or replace function private.trucks_guard()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or private.is_org_admin(new.org_id) then
    -- 業主審核：自動記錄審核人、時間，並通知車主
    if tg_op = 'UPDATE' and new.status is distinct from old.status
       and new.status in ('active','rejected') then
      new.reviewed_by := (select auth.uid());
      new.reviewed_at := now();
      perform private.enqueue_notification(new.org_id, new.vendor_id, 'truck_reviewed',
        jsonb_build_object('truck_id', new.id, 'truck_name', new.name,
                           'result', new.status, 'note', new.review_note));
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.org_id    is distinct from old.org_id    or new.vendor_id   is distinct from old.vendor_id
    or new.name      is distinct from old.name      or new.kind        is distinct from old.kind
    or new.food_type is distinct from old.food_type or new.status      is distinct from old.status
    or new.reviewed_by is distinct from old.reviewed_by or new.reviewed_at is distinct from old.reviewed_at
    or new.review_note is distinct from old.review_note then
      raise exception '車名、類型、狀態需由業主修改' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

-- venues / venue_slots：成員都看得到；業主（owner、staff）可改
create policy venues_select on public.venues for select to authenticated
  using (private.is_org_admin(org_id) or private.is_org_vendor(org_id));
create policy venues_write on public.venues for all to authenticated
  using (private.is_org_admin(org_id)) with check (private.is_org_admin(org_id));

create policy venue_slots_select on public.venue_slots for select to authenticated
  using (private.is_org_admin(org_id) or private.is_org_vendor(org_id));
create policy venue_slots_write on public.venue_slots for all to authenticated
  using (private.is_org_admin(org_id)) with check (private.is_org_admin(org_id));

-- venue_restrictions：車主只看得到跟自己車有關的那條（顯示中性原因）
create policy venue_restrictions_select on public.venue_restrictions for select to authenticated
  using (private.is_org_admin(org_id)
         or exists (select 1 from public.trucks t
                    where t.vendor_id = (select auth.uid()) and t.org_id = venue_restrictions.org_id
                      and (t.id = venue_restrictions.truck_id or t.food_type = venue_restrictions.food_type)));
create policy venue_restrictions_write on public.venue_restrictions for all to authenticated
  using (private.is_org_admin(org_id)) with check (private.is_org_admin(org_id));

-- sessions：成員都看得到；業主可改（名額、狀態的連動在 0300 的觸發器）
create policy sessions_select on public.sessions for select to authenticated
  using (private.is_org_admin(org_id) or private.is_org_vendor(org_id));
create policy sessions_write on public.sessions for all to authenticated
  using (private.is_org_admin(org_id)) with check (private.is_org_admin(org_id));

-- registrations：只看自己的；業主看全部。寫入只能透過 RPC。
create policy registrations_select on public.registrations for select to authenticated
  using (vendor_id = (select auth.uid()) or private.is_org_admin(org_id));

-- photos / checkins：只看自己的；業主看全部、可標記稽核
create policy photos_select on public.photos for select to authenticated
  using (vendor_id = (select auth.uid()) or private.is_org_admin(org_id));

create policy checkins_select on public.checkins for select to authenticated
  using (vendor_id = (select auth.uid()) or private.is_org_admin(org_id));
create policy checkins_audit on public.checkins for update to authenticated
  using (private.is_org_admin(org_id)) with check (private.is_org_admin(org_id));

create or replace function private.checkins_audit_stamp()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.audit_status is distinct from old.audit_status or new.audit_note is distinct from old.audit_note then
    new.audited_by := (select auth.uid());
    new.audited_at := now();
  end if;
  return new;
end;
$$;
create trigger checkins_audit_stamp before update on public.checkins
  for each row execute function private.checkins_audit_stamp();

-- notification_outbox：業主可查推播有沒有發出去
create policy outbox_select on public.notification_outbox for select to authenticated
  using (private.is_org_admin(org_id));

-- audit_logs：業主看自己市集的
create policy audit_logs_select on public.audit_logs for select to authenticated
  using (org_id is not null and private.is_org_admin(org_id));

-- =====================================================================
-- 操作紀錄觸發器：誰在什麼時候改了什麼
-- =====================================================================
create or replace function private.write_audit_log()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into public.audit_logs(org_id, actor_id, action, table_name, row_id, old_data, new_data)
  values (nullif(coalesce(v_row->>'org_id', ''), '')::uuid,
          (select auth.uid()), tg_op, tg_table_name,
          coalesce(v_row->>'id', v_row->>'org_id'),
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return null;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['org_settings','org_admins','org_vendors','trucks','venues','venue_slots',
                           'venue_restrictions','sessions','registrations','checkins']
  loop
    execute format('create trigger audit_log after insert or update or delete on public.%I
                    for each row execute function private.write_audit_log()', t);
  end loop;
end $$;
