-- =============================================================
-- 002：先發 / 替補、傷兵、球員資料庫、每週分數、交易與投票、個人密碼
-- 依賴 schema.sql（001）。可重複執行。
-- =============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 聯盟設定 ----------
create table if not exists league_settings (
  key   text primary key,
  value text not null,
  note  text
);
insert into league_settings (key, value, note) values
  ('active_slots',           '10', '每隊先發人數（算分）'),
  ('bench_slots',            '2',  '每隊替補人數'),
  ('trade_approvals_needed', '2',  '交易需要「非交易雙方」多少票同意才成立')
on conflict (key) do nothing;

-- ---------- 球員資料庫（每天由排程更新） ----------
create table if not exists players (
  player_id  text primary key,
  name       text not null,
  team       text,
  position   text,
  headshot   text,
  updated_at timestamptz not null default now()
);

-- ---------- 傷兵（每 2 小時由排程整批更新） ----------
create table if not exists player_injuries (
  player_id      text primary key,
  player_name    text not null,
  team           text,
  status         text not null,   -- Out / Day-To-Day / Suspension ...
  fantasy_status text,            -- OUT / GTD ...
  injury_type    text,            -- Ankle / Knee ...
  return_date    date,
  comment        text,
  reported_at    timestamptz,
  updated_at     timestamptz not null default now()
);

-- ---------- 陣容：加上先發 / 替補 ----------
alter table rosters add column if not exists slot text not null default 'active';
alter table rosters add column if not exists injury_benched boolean not null default false;
alter table rosters add column if not exists source text not null default 'draft';
do $$ begin
  alter table rosters add constraint rosters_slot_chk check (slot in ('active', 'bench'));
exception when duplicate_object then null; end $$;

-- 換人紀錄
create table if not exists lineup_changes (
  id             serial primary key,
  member_id      int  not null references members(id) on delete cascade,
  out_player_id  text not null,
  out_player     text not null,
  in_player_id   text not null,
  in_player      text not null,
  reason         text not null,       -- injury / return
  effective_date date not null,
  created_at     timestamptz not null default now()
);

-- ---------- 個人密碼（不公開） ----------
create table if not exists member_auth (
  member_id       int primary key references members(id) on delete cascade,
  pin_hash        text not null,
  failed_attempts int not null default 0,
  locked_until    timestamptz
);

-- ---------- 交易 ----------
create table if not exists trades (
  id             serial primary key,
  proposer_id    int not null references members(id),
  receiver_id    int not null references members(id),
  status         text not null default 'pending',
    -- pending（等對方回覆）→ voting（投票中）→ approved / rejected
    -- 其他：declined（對方拒絕）、cancelled（提議人取消）、failed（生效時球員已不在隊上）
  message        text,
  created_at     timestamptz not null default now(),
  accepted_at    timestamptz,
  decided_at     timestamptz,
  effective_date date,
  check (proposer_id <> receiver_id),
  check (status in ('pending','voting','approved','rejected','declined','cancelled','failed'))
);

create table if not exists trade_items (
  trade_id       int  not null references trades(id) on delete cascade,
  seq            int  not null,       -- 第幾組對換（同 seq 的兩人互相交換位置）
  from_member_id int  not null references members(id),
  to_member_id   int  not null references members(id),
  player_id      text not null,
  player_name    text not null,
  primary key (trade_id, player_id)
);

create table if not exists trade_votes (
  trade_id  int not null references trades(id) on delete cascade,
  member_id int not null references members(id),
  approve   boolean not null,
  voted_at  timestamptz not null default now(),
  primary key (trade_id, member_id)
);

-- ---------- 小工具 ----------
create or replace function et_today() returns date
language sql stable as $$ select (now() at time zone 'America/New_York')::date $$;

-- 某隊在某天的陣容列
create or replace function _roster_row(p_member int, p_player text, p_day date)
returns rosters language sql stable as $$
  select * from rosters
  where member_id = p_member and player_id = p_player
    and start_date <= p_day and (end_date is null or end_date >= p_day)
  order by start_date desc limit 1
$$;

-- 從 p_day 起結束一列（若該列本來就是 p_day 才開始，直接刪掉）
create or replace function _end_row(p_row rosters, p_day date) returns void
language plpgsql as $$
begin
  if p_row.start_date >= p_day then
    delete from rosters where id = p_row.id;
  else
    update rosters set end_date = p_day - 1 where id = p_row.id;
  end if;
end $$;

-- 從 p_day 起把一列改成新的 slot
create or replace function _reslot_row(p_row rosters, p_day date, p_slot text, p_injury_benched boolean, p_source text)
returns void language plpgsql as $$
begin
  if p_row.start_date >= p_day then
    update rosters set slot = p_slot, injury_benched = p_injury_benched, source = p_source where id = p_row.id;
  else
    update rosters set end_date = p_day - 1 where id = p_row.id;
    insert into rosters (member_id, player_id, player_name, start_date, slot, injury_benched, source)
      values (p_row.member_id, p_row.player_id, p_row.player_name, p_day, p_slot, p_injury_benched, p_source);
  end if;
end $$;

-- 密碼檢查：失敗 5 次鎖 15 分鐘。回傳錯誤訊息，成功回傳 null。
-- （用回傳值而不是 raise，這樣失敗次數才會被寫入）
create or replace function _check_pin(p_member int, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare a member_auth;
begin
  select * into a from member_auth where member_id = p_member for update;
  if not found then return '這位玩家還沒有設定密碼，請聯絡管理員'; end if;
  if a.locked_until is not null and a.locked_until > now() then
    return '密碼錯誤太多次，請 15 分鐘後再試';
  end if;
  if a.pin_hash = crypt(coalesce(p_pin, ''), a.pin_hash) then
    update member_auth set failed_attempts = 0, locked_until = null where member_id = p_member;
    return null;
  end if;
  update member_auth set
    failed_attempts = a.failed_attempts + 1,
    locked_until = case when a.failed_attempts + 1 >= 5 then now() + interval '15 minutes' end
  where member_id = p_member;
  return '密碼不正確';
end $$;

create or replace function _err(msg text) returns jsonb language sql immutable as $$
  select jsonb_build_object('ok', false, 'error', msg) $$;

-- ---------- 對外 API：登入 ----------
create or replace function login(p_member int, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare e text;
begin
  e := _check_pin(p_member, p_pin);
  if e is not null then return _err(e); end if;
  return jsonb_build_object('ok', true, 'member_id', p_member,
    'name', (select name from members where id = p_member));
end $$;

-- ---------- 對外 API：先發 ↔ 替補 ----------
-- 規則：先發球員在傷兵名單上 → 可以換下；
--       或替補球員是「因傷被換下」且已不在傷兵名單 → 可以換回先發。
-- 隔天（美東）生效。
create or replace function swap_players(p_member int, p_pin text, p_out_player text, p_in_player text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  e text; d date := et_today() + 1;
  r_out rosters; r_in rosters;
  out_injured boolean; in_injured boolean; reason text;
begin
  e := _check_pin(p_member, p_pin);
  if e is not null then return _err(e); end if;

  r_out := _roster_row(p_member, p_out_player, d);
  r_in  := _roster_row(p_member, p_in_player, d);
  if r_out.id is null or r_in.id is null then return _err('球員不在你的隊上'); end if;
  if r_out.slot <> 'active' then return _err(r_out.player_name || ' 不是先發'); end if;
  if r_in.slot <> 'bench' then return _err(r_in.player_name || ' 不是替補'); end if;

  if exists (select 1 from trade_items ti join trades t on t.id = ti.trade_id
             where t.status in ('pending','voting') and ti.player_id in (p_out_player, p_in_player)) then
    return _err('球員正在交易流程中，交易結束前不能換位置');
  end if;

  out_injured := exists (select 1 from player_injuries where player_id = p_out_player);
  in_injured  := exists (select 1 from player_injuries where player_id = p_in_player);

  if out_injured then
    reason := 'injury';
  elsif r_in.injury_benched and not in_injured then
    reason := 'return';
  else
    return _err('只有先發球員受傷時才能換人（或因傷下場的球員康復後換回先發）');
  end if;

  perform _reslot_row(r_out, d, 'bench',  out_injured, 'swap');
  perform _reslot_row(r_in,  d, 'active', false,       'swap');

  insert into lineup_changes (member_id, out_player_id, out_player, in_player_id, in_player, reason, effective_date)
    values (p_member, r_out.player_id, r_out.player_name, r_in.player_id, r_in.player_name, reason, d);

  return jsonb_build_object('ok', true, 'effective_date', d, 'reason', reason);
end $$;

-- ---------- 交易：結算 ----------
create or replace function _execute_trade(p_trade int) returns text
language plpgsql security definer set search_path = public as $$
declare
  t trades; d date := et_today() + 1;
  s int; a trade_items; b trade_items; ra rosters; rb rosters;
begin
  select * into t from trades where id = p_trade for update;
  -- 先確認所有球員都還在原本的隊上
  if exists (select 1 from trade_items i
             where i.trade_id = p_trade and (_roster_row(i.from_member_id, i.player_id, d)).id is null) then
    update trades set status = 'failed', decided_at = now() where id = p_trade;
    return 'failed';
  end if;
  for s in select distinct seq from trade_items where trade_id = p_trade order by seq loop
    select * into a from trade_items where trade_id = p_trade and seq = s and from_member_id = t.proposer_id;
    select * into b from trade_items where trade_id = p_trade and seq = s and from_member_id = t.receiver_id;
    ra := _roster_row(a.from_member_id, a.player_id, d);
    rb := _roster_row(b.from_member_id, b.player_id, d);
    perform _end_row(ra, d);
    perform _end_row(rb, d);
    -- 換過去的球員接手對方原本的位置（先發或替補）
    insert into rosters (member_id, player_id, player_name, start_date, slot, source)
      values (b.from_member_id, a.player_id, a.player_name, d, rb.slot, 'trade'),
             (a.from_member_id, b.player_id, b.player_name, d, ra.slot, 'trade');
  end loop;
  update trades set status = 'approved', decided_at = now(), effective_date = d where id = p_trade;
  return 'approved';
end $$;

create or replace function _settle_trade(p_trade int) returns text
language plpgsql security definer set search_path = public as $$
declare
  needed int := (select value::int from league_settings where key = 'trade_approvals_needed');
  voters int := (select count(*) from members) - 2;
  yes int; no int;
begin
  select count(*) filter (where approve), count(*) filter (where not approve)
    into yes, no from trade_votes where trade_id = p_trade;
  if yes >= needed then
    return _execute_trade(p_trade);
  elsif no > voters - needed then
    update trades set status = 'rejected', decided_at = now() where id = p_trade;
    return 'rejected';
  end if;
  return 'voting';
end $$;

-- ---------- 對外 API：交易 ----------
create or replace function propose_trade(p_member int, p_pin text, p_to_member int,
                                         p_give text[], p_get text[], p_message text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  e text; d date := et_today() + 1; tid int; i int; rg rosters; rr rosters;
begin
  e := _check_pin(p_member, p_pin);
  if e is not null then return _err(e); end if;
  if p_to_member = p_member then return _err('不能跟自己交易'); end if;
  if not exists (select 1 from members where id = p_to_member) then return _err('找不到交易對象'); end if;
  if coalesce(array_length(p_give, 1), 0) = 0 or coalesce(array_length(p_give, 1), 0) <> coalesce(array_length(p_get, 1), 0) then
    return _err('雙方交換的球員人數必須相同（至少 1 人）');
  end if;
  if (select count(distinct x) from unnest(p_give || p_get) x) <> array_length(p_give, 1) * 2 then
    return _err('球員重複');
  end if;
  for i in 1 .. array_length(p_give, 1) loop
    rg := _roster_row(p_member, p_give[i], d);
    rr := _roster_row(p_to_member, p_get[i], d);
    if rg.id is null then return _err('你送出的球員不在你的隊上'); end if;
    if rr.id is null then return _err('你要的球員不在對方隊上'); end if;
  end loop;
  if exists (select 1 from trade_items ti join trades t on t.id = ti.trade_id
             where t.status in ('pending','voting') and ti.player_id = any(p_give || p_get)) then
    return _err('有球員已經在另一筆進行中的交易裡');
  end if;

  insert into trades (proposer_id, receiver_id, message) values (p_member, p_to_member, p_message)
    returning id into tid;
  for i in 1 .. array_length(p_give, 1) loop
    insert into trade_items values
      (tid, i, p_member, p_to_member, p_give[i], (_roster_row(p_member, p_give[i], d)).player_name),
      (tid, i, p_to_member, p_member, p_get[i],  (_roster_row(p_to_member, p_get[i], d)).player_name);
  end loop;
  return jsonb_build_object('ok', true, 'trade_id', tid);
end $$;

create or replace function respond_trade(p_member int, p_pin text, p_trade int, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare e text; t trades;
begin
  e := _check_pin(p_member, p_pin);
  if e is not null then return _err(e); end if;
  select * into t from trades where id = p_trade for update;
  if t.id is null then return _err('找不到這筆交易'); end if;
  if t.receiver_id <> p_member then return _err('只有交易對象可以回覆'); end if;
  if t.status <> 'pending' then return _err('這筆交易已經不在等待回覆的狀態'); end if;
  if p_accept then
    update trades set status = 'voting', accepted_at = now() where id = p_trade;
    return jsonb_build_object('ok', true, 'status', _settle_trade(p_trade));
  end if;
  update trades set status = 'declined', decided_at = now() where id = p_trade;
  return jsonb_build_object('ok', true, 'status', 'declined');
end $$;

create or replace function vote_trade(p_member int, p_pin text, p_trade int, p_approve boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare e text; t trades;
begin
  e := _check_pin(p_member, p_pin);
  if e is not null then return _err(e); end if;
  select * into t from trades where id = p_trade for update;
  if t.id is null then return _err('找不到這筆交易'); end if;
  if t.status <> 'voting' then return _err('這筆交易目前不在投票中'); end if;
  if p_member in (t.proposer_id, t.receiver_id) then return _err('交易雙方不能投票'); end if;
  insert into trade_votes (trade_id, member_id, approve) values (p_trade, p_member, p_approve)
    on conflict (trade_id, member_id) do update set approve = excluded.approve, voted_at = now();
  return jsonb_build_object('ok', true, 'status', _settle_trade(p_trade));
end $$;

create or replace function cancel_trade(p_member int, p_pin text, p_trade int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare e text; t trades;
begin
  e := _check_pin(p_member, p_pin);
  if e is not null then return _err(e); end if;
  select * into t from trades where id = p_trade for update;
  if t.id is null then return _err('找不到這筆交易'); end if;
  if t.proposer_id <> p_member then return _err('只有提議人可以取消'); end if;
  if t.status not in ('pending','voting') then return _err('這筆交易已經結束'); end if;
  update trades set status = 'cancelled', decided_at = now() where id = p_trade;
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

-- 排程用：整批更新傷兵名單
create or replace function sync_injuries(p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from player_injuries where true;
  insert into player_injuries (player_id, player_name, team, status, fantasy_status, injury_type, return_date, comment, reported_at)
  select distinct on (r->>'player_id')
    r->>'player_id', r->>'player_name', r->>'team', r->>'status', r->>'fantasy_status',
    r->>'injury_type', nullif(r->>'return_date', '')::date, r->>'comment', nullif(r->>'reported_at', '')::timestamptz
  from jsonb_array_elements(p_rows) r
  where coalesce(r->>'player_id', '') <> '';
  get diagnostics n = row_count;
  return n;
end $$;

-- 管理員用（只能在 SQL Editor 執行）：設定玩家密碼
create or replace function admin_set_pin(p_member int, p_pin text) returns void
language sql security definer set search_path = public, extensions as $$
  insert into member_auth (member_id, pin_hash) values (p_member, crypt(p_pin, gen_salt('bf')))
  on conflict (member_id) do update set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null
$$;

-- ---------- view ----------
drop view if exists leaderboard;
drop view if exists member_weekly_scores;
drop view if exists member_daily_scores;
drop view if exists member_player_games;
drop view if exists team_rosters;
drop view if exists player_season;

-- 只有「當天是先發」的球員才算分
create view member_player_games with (security_invoker = true) as
select m.id as member_id, m.name as member_name, r.slot, f.*
from player_game_fantasy f
join rosters r
  on r.player_id = f.player_id
 and f.game_date >= r.start_date
 and (r.end_date is null or f.game_date <= r.end_date)
 and r.slot = 'active'
join members m on m.id = r.member_id;

create view member_daily_scores with (security_invoker = true) as
select member_id, member_name, game_date,
       sum(fantasy_points) as points,
       count(*) filter (where not did_not_play) as players_played
from member_player_games
group by member_id, member_name, game_date;

-- 每週（週一到週日，美東日期）
create view member_weekly_scores with (security_invoker = true) as
with w as (
  select m.id as member_id, m.name as member_name, wk.week_start,
         coalesce(sum(d.points), 0) as points,
         count(distinct d.game_date) as days_played
  from members m
  cross join (select distinct (game_date - (extract(isodow from game_date)::int - 1))::date as week_start
              from player_game_stats) wk
  left join member_daily_scores d
    on d.member_id = m.id
   and d.game_date between wk.week_start and wk.week_start + 6
  group by m.id, m.name, wk.week_start
)
select w.*, (w.week_start + 6) as week_end,
       rank() over (partition by w.week_start order by w.points desc) as week_rank
from w;

create view leaderboard with (security_invoker = true) as
with latest as (select max(game_date) as d from player_game_stats),
     cur_week as (select (d - (extract(isodow from d)::int - 1))::date as ws from latest)
select
  m.id as member_id, m.name as member_name,
  coalesce(sum(d.points), 0)                                                  as total_points,
  coalesce(sum(d.points) filter (where d.game_date = latest.d), 0)            as latest_day_points,
  coalesce(sum(d.points) filter (where d.game_date >= cur_week.ws), 0)        as week_points,
  latest.d  as latest_day,
  cur_week.ws as week_start,
  rank() over (order by coalesce(sum(d.points), 0) desc) as rank
from members m
cross join latest cross join cur_week
left join member_daily_scores d on d.member_id = m.id
group by m.id, m.name, latest.d, cur_week.ws;

-- 球員本季表現（給交易與陣容頁參考）
create view player_season with (security_invoker = true) as
select player_id,
       count(*) filter (where not did_not_play) as games,
       round(avg(fantasy_points) filter (where not did_not_play), 1) as avg_fp,
       sum(fantasy_points) as total_fp
from player_game_fantasy
group by player_id;

-- 目前陣容（明天生效的版本，也就是現在能編輯的版本）+ 今天的位置 + 傷兵 + 本季平均
create view team_rosters with (security_invoker = true) as
select
  m.id as member_id, m.name as member_name,
  r.player_id, r.player_name, r.slot, r.injury_benched,
  t.slot as today_slot,
  p.team, p.position, p.headshot,
  i.status as injury_status, i.fantasy_status, i.injury_type, i.return_date, i.comment as injury_comment,
  coalesce(ps.games, 0) as games, ps.avg_fp, coalesce(ps.total_fp, 0) as total_fp
from rosters r
join members m on m.id = r.member_id
left join rosters t
  on t.member_id = r.member_id and t.player_id = r.player_id
 and t.start_date <= et_today() and (t.end_date is null or t.end_date >= et_today())
left join players p on p.player_id = r.player_id
left join player_injuries i on i.player_id = r.player_id
left join player_season ps on ps.player_id = r.player_id
where r.start_date <= et_today() + 1 and (r.end_date is null or r.end_date >= et_today() + 1);

-- ---------- 權限 ----------
alter table league_settings enable row level security;
alter table players         enable row level security;
alter table player_injuries enable row level security;
alter table lineup_changes  enable row level security;
alter table member_auth     enable row level security;   -- 沒有任何 policy：任何人都讀不到
alter table trades          enable row level security;
alter table trade_items     enable row level security;
alter table trade_votes     enable row level security;

do $$ declare t text; begin
  foreach t in array array['league_settings','players','player_injuries','lineup_changes','trades','trade_items','trade_votes'] loop
    execute format('drop policy if exists "public read" on %I', t);
    execute format('create policy "public read" on %I for select using (true)', t);
    execute format('grant select on %I to anon, authenticated', t);
  end loop;
end $$;

revoke all on member_auth from anon, authenticated;

grant select on member_player_games, member_daily_scores, member_weekly_scores, leaderboard,
                player_season, team_rosters to anon, authenticated;

-- 內部函式：不開放
revoke execute on function _roster_row(int, text, date), _end_row(rosters, date),
  _reslot_row(rosters, date, text, boolean, text), _check_pin(int, text),
  _execute_trade(int), _settle_trade(int), sync_injuries(jsonb), admin_set_pin(int, text)
  from public, anon, authenticated;
grant execute on function sync_injuries(jsonb) to service_role;

-- 對外 API：開放給網頁
grant execute on function login(int, text), swap_players(int, text, text, text),
  propose_trade(int, text, int, text[], text[], text), respond_trade(int, text, int, boolean),
  vote_trade(int, text, int, boolean), cancel_trade(int, text, int), et_today()
  to anon, authenticated;

-- 固定小工具函式的 search_path（Supabase 安全檢查建議）
alter function _roster_row(int, text, date) set search_path = public;
alter function _end_row(rosters, date) set search_path = public;
alter function _reslot_row(rosters, date, text, boolean, text) set search_path = public;
alter function _err(text) set search_path = public;
alter function et_today() set search_path = public;
