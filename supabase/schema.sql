-- =============================================================
-- NBA Fantasy — Supabase schema
-- 在 Supabase Dashboard → SQL Editor 貼上整份執行一次即可。
-- 可以重複執行（會先刪除 view 再重建，資料表不會被清掉）。
-- =============================================================

-- ---------- 1. 資料表 ----------

-- 玩家（6 個人）
create table if not exists members (
  id         serial primary key,
  name       text not null unique,
  created_at timestamptz not null default now()
);

-- 陣容：誰在哪段期間擁有哪位球員
-- end_date 為 null 代表目前仍在陣中。之後要做交易 / 換人，只要把舊紀錄填上 end_date、再新增一筆即可。
create table if not exists rosters (
  id          serial primary key,
  member_id   int  not null references members(id) on delete cascade,
  player_id   text not null,               -- ESPN athlete id，例如 Jokic = 3112335
  player_name text not null,
  start_date  date not null,
  end_date    date,                         -- 含當天；null = 仍在陣中
  check (end_date is null or end_date >= start_date)
);
create index if not exists rosters_member_idx on rosters(member_id);
create index if not exists rosters_player_idx on rosters(player_id);

-- 原始球員數據（每位球員每場一列）。只存原始數字，分數由 view 計算。
create table if not exists player_game_stats (
  game_id      text not null,
  player_id    text not null,
  game_date    date not null,               -- 美東日期（與 ESPN scoreboard 的日期一致）
  player_name  text not null,
  team         text,
  opponent     text,
  did_not_play boolean not null default false,
  minutes      numeric not null default 0,
  pts  int not null default 0,
  reb  int not null default 0,
  oreb int not null default 0,
  dreb int not null default 0,
  ast  int not null default 0,
  stl  int not null default 0,
  blk  int not null default 0,
  tov  int not null default 0,
  pf   int not null default 0,
  fgm  int not null default 0,
  fga  int not null default 0,
  fg3m int not null default 0,
  fg3a int not null default 0,
  ftm  int not null default 0,
  fta  int not null default 0,
  plus_minus int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (game_id, player_id)
);
create index if not exists pgs_date_idx   on player_game_stats(game_date);
create index if not exists pgs_player_idx on player_game_stats(player_id);

-- 計分規則：一列一個項目。改規則 = 在 Table Editor 改數字，整季分數自動重算。
-- stat 可用的值：pts reb oreb dreb ast stl blk tov pf fgm fga fg3m fg3a ftm fta plus_minus
--               以及特殊項目 double_double / triple_double（達成時加的分數）
create table if not exists scoring_rules (
  stat   text primary key,
  weight numeric not null,
  note   text
);

-- 預設規則（佔位用，之後再改）：類似 ESPN / Yahoo 常見的積分制
insert into scoring_rules (stat, weight, note) values
  ('pts',            1,   '得分'),
  ('reb',            1.2, '籃板'),
  ('ast',            1.5, '助攻'),
  ('stl',            3,   '抄截'),
  ('blk',            3,   '阻攻'),
  ('tov',           -1,   '失誤'),
  ('double_double',  0,   '大兩雙加分'),
  ('triple_double',  0,   '大三元加分')
on conflict (stat) do nothing;

-- ---------- 2. 計分 view ----------
-- security_invoker = true：讓 view 也遵守下面的 RLS 規則

drop view if exists leaderboard;
drop view if exists member_daily_scores;
drop view if exists member_player_games;
drop view if exists player_game_fantasy;

-- 每位球員每場的 fantasy 分數
create view player_game_fantasy with (security_invoker = true) as
with w as (
  select
    coalesce(max(weight) filter (where stat = 'pts'),  0) as pts,
    coalesce(max(weight) filter (where stat = 'reb'),  0) as reb,
    coalesce(max(weight) filter (where stat = 'oreb'), 0) as oreb,
    coalesce(max(weight) filter (where stat = 'dreb'), 0) as dreb,
    coalesce(max(weight) filter (where stat = 'ast'),  0) as ast,
    coalesce(max(weight) filter (where stat = 'stl'),  0) as stl,
    coalesce(max(weight) filter (where stat = 'blk'),  0) as blk,
    coalesce(max(weight) filter (where stat = 'tov'),  0) as tov,
    coalesce(max(weight) filter (where stat = 'pf'),   0) as pf,
    coalesce(max(weight) filter (where stat = 'fgm'),  0) as fgm,
    coalesce(max(weight) filter (where stat = 'fga'),  0) as fga,
    coalesce(max(weight) filter (where stat = 'fg3m'), 0) as fg3m,
    coalesce(max(weight) filter (where stat = 'fg3a'), 0) as fg3a,
    coalesce(max(weight) filter (where stat = 'ftm'),  0) as ftm,
    coalesce(max(weight) filter (where stat = 'fta'),  0) as fta,
    coalesce(max(weight) filter (where stat = 'plus_minus'),    0) as plus_minus,
    coalesce(max(weight) filter (where stat = 'double_double'), 0) as double_double,
    coalesce(max(weight) filter (where stat = 'triple_double'), 0) as triple_double
  from scoring_rules
),
s as (
  select st.*,
    ((st.pts >= 10)::int + (st.reb >= 10)::int + (st.ast >= 10)::int
     + (st.stl >= 10)::int + (st.blk >= 10)::int) as cats_in_double_digits
  from player_game_stats st
)
select
  s.game_id, s.player_id, s.game_date, s.player_name, s.team, s.opponent,
  s.did_not_play, s.minutes,
  s.pts, s.reb, s.ast, s.stl, s.blk, s.tov, s.fgm, s.fga, s.fg3m, s.fg3a, s.ftm, s.fta,
  round((
      s.pts*w.pts + s.reb*w.reb + s.oreb*w.oreb + s.dreb*w.dreb + s.ast*w.ast
    + s.stl*w.stl + s.blk*w.blk + s.tov*w.tov + s.pf*w.pf
    + s.fgm*w.fgm + s.fga*w.fga + s.fg3m*w.fg3m + s.fg3a*w.fg3a
    + s.ftm*w.ftm + s.fta*w.fta + s.plus_minus*w.plus_minus
    + case when s.cats_in_double_digits >= 2 then w.double_double else 0 end
    + case when s.cats_in_double_digits >= 3 then w.triple_double else 0 end
  )::numeric, 1) as fantasy_points
from s cross join w;

-- 只保留「比賽當天這位球員在某人陣中」的場次
create view member_player_games with (security_invoker = true) as
select
  m.id   as member_id,
  m.name as member_name,
  f.*
from player_game_fantasy f
join rosters r
  on r.player_id = f.player_id
 and f.game_date >= r.start_date
 and (r.end_date is null or f.game_date <= r.end_date)
join members m on m.id = r.member_id;

-- 每人每天的總分
create view member_daily_scores with (security_invoker = true) as
select
  member_id, member_name, game_date,
  sum(fantasy_points)                          as points,
  count(*) filter (where not did_not_play)     as players_played
from member_player_games
group by member_id, member_name, game_date;

-- 總排名（含沒有任何分數的玩家）
create view leaderboard with (security_invoker = true) as
with latest as (select max(game_date) as d from player_game_stats)
select
  m.id   as member_id,
  m.name as member_name,
  coalesce(sum(d.points), 0)                                        as total_points,
  coalesce(sum(d.points) filter (where d.game_date = latest.d), 0)  as latest_day_points,
  latest.d                                                          as latest_day,
  rank() over (order by coalesce(sum(d.points), 0) desc)            as rank
from members m
cross join latest
left join member_daily_scores d on d.member_id = m.id
group by m.id, m.name, latest.d;

-- ---------- 3. 權限 ----------
-- 前端用 anon key：只能讀。寫入只由 GitHub Actions 用 service_role key 進行（會略過 RLS）。

alter table members           enable row level security;
alter table rosters           enable row level security;
alter table player_game_stats enable row level security;
alter table scoring_rules     enable row level security;

drop policy if exists "public read" on members;
drop policy if exists "public read" on rosters;
drop policy if exists "public read" on player_game_stats;
drop policy if exists "public read" on scoring_rules;

create policy "public read" on members           for select using (true);
create policy "public read" on rosters           for select using (true);
create policy "public read" on player_game_stats for select using (true);
create policy "public read" on scoring_rules     for select using (true);

grant select on members, rosters, player_game_stats, scoring_rules to anon, authenticated;
grant select on player_game_fantasy, member_player_games, member_daily_scores, leaderboard
  to anon, authenticated;
