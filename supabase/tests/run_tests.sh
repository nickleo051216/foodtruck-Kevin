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
echo "▶ 連點測試：同一位車主、同一台車，10 次同時按「登記」"
"${PSQL[@]}" <<'SQL'
insert into public.sessions(id, org_id, venue_id, slot_id, date, starts_at, ends_at, capacity, fee, opens_at, closes_at)
values ('99999999-0000-0000-0000-000000000010', 'dddddddd-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-000000000002', 'ffffffff-0000-0000-0000-000000000002', current_date + 22,
        now() + interval '22 days', now() + interval '22 days 5 hours', 3, 250, now() - interval '1 day', now() + interval '21 days');
SQL

# 起跑線：10 次請求都卡在同一個點，放開後同時送出（模擬網路慢、車主狂按）
"${PSQL[@]}" -c "select pg_advisory_lock(4242); select pg_sleep(2);" >/dev/null &
sleep 1
tap() {
  "${PSQL[@]}" -At -c "select pg_advisory_lock_shared(4242); select pg_advisory_unlock_shared(4242);
     select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000034', false);
     set role authenticated;
     select (public.register_for_session('99999999-0000-0000-0000-000000000010', 'cccccccc-0000-0000-0000-000000000034'))->>'code';" | tail -1 >> "$WORK/dbl.txt"
}
for i in $(seq 1 10); do tap & done
wait
echo "  結果：$(sort "$WORK/dbl.txt" | uniq -c | awk '{printf "%s×%s  ", $2, $1}')"
n=$("${PSQL[@]}" -At -c "select count(*) from public.registrations where session_id = '99999999-0000-0000-0000-000000000010'")
[ "$n" = "1" ] && echo "  ✅ 連點 10 次只寫入 1 筆" || { echo "  ❌ FAIL: 寫入了 $n 筆"; exit 1; }
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
