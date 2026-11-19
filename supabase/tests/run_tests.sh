#!/usr/bin/env bash
# =====================================================================
# 本機測試：建立一個暫時的 PostgreSQL，套用 migrations，跑功能測試與搶名額測試
# 用法：bash supabase/tests/run_tests.sh
# 不會連到 Supabase，跑完會自動刪除暫時資料庫
# =====================================================================
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PG_BIN=${PG_BIN:-/usr/lib/postgresql/16/bin}
PORT=${PGPORT_TEST:-54329}
WORK=$(mktemp -d)

as_pg() { if [ "$(id -u)" = 0 ]; then runuser -u postgres -- "$@"; else "$@"; fi; }
[ "$(id -u)" = 0 ] && chown postgres "$WORK"

as_pg "$PG_BIN/initdb" -D "$WORK/data" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null
as_pg "$PG_BIN/pg_ctl" -D "$WORK/data" -l "$WORK/server.log" -w \
  -o "-p $PORT -k $WORK -c listen_addresses='' -c timezone=UTC -c max_connections=100" start >/dev/null
cleanup() { as_pg "$PG_BIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

PSQL=("$PG_BIN/psql" -h "$WORK" -p "$PORT" -U postgres -d postgres -X -v ON_ERROR_STOP=1 -q)

echo "▶ 套用 Supabase 模擬環境 + migrations"
"${PSQL[@]}" -f "$HERE/00_supabase_stub.sql" >/dev/null
for f in "$ROOT"/migrations/*.sql; do
  case "$f" in *cron*) echo "  （略過 $(basename "$f")：本機沒有 pg_cron）"; continue;; esac
  echo "  ✓ $(basename "$f")"
  "${PSQL[@]}" -f "$f" >/dev/null
done

echo
echo "▶ 功能測試"
"${PSQL[@]}" -f "$HERE/10_functional.sql" 2>&1 | sed -n 's/^.*NOTICE:  //p; /^──/p; /^🎉/p; /FAIL/p; /ERROR/p'

echo
echo "▶ 壓力測試：20 人同時搶 5 個名額（候補上限 5）"
"${PSQL[@]}" <<'SQL'
insert into public.sessions(id, org_id, venue_id, slot_id, date, starts_at, ends_at, capacity, fee, opens_at, closes_at)
values ('99999999-0000-0000-0000-000000000009', 'dddddddd-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-000000000001', 'ffffffff-0000-0000-0000-000000000001', current_date + 20,
        now() + interval '20 days', now() + interval '20 days 5 hours', 5, 300, now() - interval '1 day', now() + interval '19 days'),
       ('99999999-0000-0000-0000-000000000010', 'dddddddd-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-000000000002', 'ffffffff-0000-0000-0000-000000000002', current_date + 22,
        now() + interval '22 days', now() + interval '22 days 5 hours', 3, 250, now() - interval '1 day', now() + interval '21 days');
SQL

# 起跑線：先由一個連線拿住鎖，大家都卡在起跑線，放開後同時衝
"${PSQL[@]}" -c "select pg_advisory_lock(4242); select pg_sleep(3);" >/dev/null &
sleep 1
race() { # $1=車主編號 $2=場次 $3=輸出檔
  local id; id=$(printf '%012d' "$1")
  "${PSQL[@]}" -At -c "select pg_advisory_lock_shared(4242); select pg_advisory_unlock_shared(4242);
     select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-$id', false);
     set role authenticated;
     select (public.register_for_session('$2', 'cccccccc-0000-0000-0000-$id'))->>'code';" | tail -1 >> "$3"
}
for n in $(seq 14 33); do race "$n" 99999999-0000-0000-0000-000000000009 "$WORK/race.txt" & done
# 連點測試：同一台車 10 次同時送出
for i in $(seq 1 10); do race 34 99999999-0000-0000-0000-000000000010 "$WORK/dbl.txt" & done
wait

echo "  20 人的結果：$(sort "$WORK/race.txt" | uniq -c | awk '{printf "%s×%s  ", $2, $1}')"
echo "  同一台車連點 10 次的結果：$(sort "$WORK/dbl.txt" | uniq -c | awk '{printf "%s×%s  ", $2, $1}')"
"${PSQL[@]}" -At <<'SQL'
select case when
  (select count(*) from public.registrations where session_id = '99999999-0000-0000-0000-000000000009' and status = 'confirmed') = 5
  and (select count(*) from public.registrations where session_id = '99999999-0000-0000-0000-000000000009' and status = 'waitlisted') = 5
  and (select count(*) from public.registrations where session_id = '99999999-0000-0000-0000-000000000009') = 10
  and (select count(*) from public.registrations where session_id = '99999999-0000-0000-0000-000000000010') = 1
then '  ✅ 沒有超賣：正取剛好 5、候補剛好 5，其餘 10 人額滿；連點只寫入 1 筆'
else '  ❌ FAIL: 名額數量不正確' end;
SQL
grep -q "✅ 沒有超賣" <("${PSQL[@]}" -At -c "select case when (select count(*) from public.registrations where session_id = '99999999-0000-0000-0000-000000000009' and status='confirmed') = 5 and (select count(*) from public.registrations where session_id = '99999999-0000-0000-0000-000000000010') = 1 then '✅ 沒有超賣' end") \
  || { echo "❌ 壓力測試失敗"; exit 1; }
echo
echo "▶ 還原測試：執行 rollback 後再重新套用一次"
"${PSQL[@]}" -f "$ROOT/rollback/20261119_trial_schema_down.sql" >/dev/null 2>&1
left=$("${PSQL[@]}" -At -c "select count(*) from pg_tables where schemaname = 'public'")
[ "$left" = "0" ] && echo "  ✅ rollback 後 public 沒有殘留資料表" || { echo "  ❌ 還有 $left 張表"; exit 1; }
for f in "$ROOT"/migrations/*.sql; do
  case "$f" in *cron*) continue;; esac
  "${PSQL[@]}" -f "$f" >/dev/null
done
echo "  ✅ 還原後可以重新套用"

echo
echo "🎉 全部測試完成"
