-- 007：全部球員能力值排名（第一名到最後一名，附目前所屬隊伍）
drop view if exists player_board;
create view player_board with (security_invoker = true) as
select pr.player_id, p.name, p.team, p.position, p.headshot, pr.ovr, pr.pos_2k, pr.snapshot_date,
       rank() over (order by pr.ovr desc) as ovr_rank,
       o.member_id, m.name as member_name, o.slot,
       i.status as injury_status, coalesce(ps.games, 0) as games, ps.avg_fp
from player_ratings pr
join players p on p.player_id = pr.player_id
left join lateral (
  select r.member_id, r.slot from rosters r
  where r.player_id = pr.player_id and r.start_date <= et_today() + 1 and (r.end_date is null or r.end_date >= et_today() + 1)
  limit 1) o on true
left join members m on m.id = o.member_id
left join player_injuries i on i.player_id = pr.player_id
left join player_season ps on ps.player_id = pr.player_id;
grant select on player_board to anon, authenticated;
