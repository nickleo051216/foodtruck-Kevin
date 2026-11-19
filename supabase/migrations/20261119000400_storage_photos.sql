-- =====================================================================
-- 餐車市集排班系統｜試用版資料庫 第 4 部分：照片空間（Supabase Storage）
--
-- 白話說明：
--   建立一個「不公開」的照片資料夾 checkin-photos。
--   路徑規則：<市集 org_id>/<車主 vendor_id>/<日期>/<檔名>
--   - 車主只能上傳到「自己的」資料夾，而且必須是已加入的市集
--   - 車主只看得到自己的照片；業主看得到自家市集的照片
--   - 上傳後不能覆蓋、不能刪除（避免報到後偷換照片）
--   - 單張上限 2 MB，只收 JPG / PNG / WebP（前端會先壓到約 150 KB）
--   90 天到期的清除排程，在第 4 步「拍照報到」時一起做（要透過 Storage API 刪檔）
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('checkin-photos', 'checkin-photos', false, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 這個路徑是不是「我在我加入的市集裡」的資料夾？
create or replace function private.photo_path_is_mine(p_name text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select (storage.foldername(p_name))[2] = (select auth.uid())::text
     and exists (select 1 from public.org_vendors ov
                  where ov.org_id::text = (storage.foldername(p_name))[1]
                    and ov.vendor_id = (select auth.uid())
                    and ov.status = 'active');
$$;

-- 業主是否管理這張照片所屬的市集？
create or replace function private.photo_path_is_admin(p_name text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.is_platform_admin()
      or exists (select 1 from public.org_admins a
                  where a.org_id::text = (storage.foldername(p_name))[1]
                    and a.user_id = (select auth.uid()));
$$;

revoke all on function private.photo_path_is_mine(text), private.photo_path_is_admin(text) from public, anon;
grant execute on function private.photo_path_is_mine(text), private.photo_path_is_admin(text) to authenticated;

create policy "checkin photos: vendor upload own folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'checkin-photos' and private.photo_path_is_mine(name));

create policy "checkin photos: read own or as org admin" on storage.objects
  for select to authenticated
  using (bucket_id = 'checkin-photos'
         and (owner = (select auth.uid()) or private.photo_path_is_admin(name)));

-- 沒有 update / delete 規則 = 上傳後不能覆蓋、不能刪除
