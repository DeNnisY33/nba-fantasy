-- 004：球隊勝負加減分（避免弱隊球員刷數據）
-- 球員「有上場」且所屬球隊贏球 → 加 team_win 分；輸球 → 加 team_loss 分（通常是負數）。

alter table player_game_stats add column if not exists team_won boolean;   -- null = 尚未取得勝負

insert into scoring_rules (stat, weight, note) values
  ('team_win',   3, '所屬球隊贏球（有上場才算）'),
  ('team_loss', -3, '所屬球隊輸球（有上場才算）')
on conflict (stat) do nothing;

-- 只在最後面新增欄位，所以可以用 create or replace，不影響依賴它的其他 view
create or replace view player_game_fantasy with (security_invoker = true) as
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
    coalesce(max(weight) filter (where stat = 'triple_double'), 0) as triple_double,
    coalesce(max(weight) filter (where stat = 'team_win'),      0) as team_win,
    coalesce(max(weight) filter (where stat = 'team_loss'),     0) as team_loss
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
    + case when s.did_not_play or s.team_won is null then 0
           when s.team_won then w.team_win else w.team_loss end
  )::numeric, 1) as fantasy_points,
  s.team_won
from s cross join w;

-- 讓每日成績也拿得到勝負（f.* 會展開成包含 team_won 的新欄位，加在最後面）
create or replace view member_player_games with (security_invoker = true) as
select m.id as member_id, m.name as member_name, r.slot, f.*
from player_game_fantasy f
join rosters r
  on r.player_id = f.player_id
 and f.game_date >= r.start_date
 and (r.end_date is null or f.game_date <= r.end_date)
 and r.slot = 'active'
join members m on m.id = r.member_id;
