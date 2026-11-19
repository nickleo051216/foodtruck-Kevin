-- =====================================================================
-- 還原（rollback）：把試用版資料庫結構全部移除
-- ⚠️ 會刪掉所有試用資料（登記、報到、照片紀錄）。執行前請先在 Supabase 備份。
-- 照片檔案本身要另外在 Storage 介面清空 checkin-photos 後，才能刪除 bucket。
-- =====================================================================
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $q$select cron.unschedule(jobid) from cron.job where jobname = 'foodtruck-expire-offers'$q$;
  end if;
end $$;

drop policy if exists "checkin photos: vendor upload own folder" on storage.objects;
drop policy if exists "checkin photos: read own or as org admin" on storage.objects;

drop table if exists
  public.audit_logs, public.notification_outbox, public.checkins, public.photos, public.registrations,
  public.sessions, public.venue_restrictions, public.venue_slots, public.venues, public.trucks,
  public.org_vendors, public.vendors, public.platform_admins, public.org_admins, public.org_settings, public.orgs
  cascade;

drop function if exists
  public.register_for_session(uuid, uuid), public.cancel_registration(uuid, text), public.accept_offer(uuid),
  public.expire_offers(), public.check_in(uuid, text, text), public.generate_sessions(uuid, date),
  public.get_sessions(uuid, date, date), public.my_registrations(uuid, date), public.join_org(text),
  public.claim_notifications(integer), public.mark_notification(bigint, boolean, text);

drop schema if exists private cascade;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'n8n_worker') then
    execute 'drop owned by n8n_worker';   -- 收回這個帳號的所有權限（它不擁有任何資料）
    execute 'drop role n8n_worker';
  end if;
end $$;
