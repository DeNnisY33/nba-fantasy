-- 003：每隊各球員的貢獻（給圖表用，避免前端一次抓上千筆）
drop view if exists member_player_contrib;
create view member_player_contrib with (security_invoker = true) as
select member_id, member_name, player_id, max(player_name) as player_name,
       sum(fantasy_points) as points,
       count(*) filter (where not did_not_play) as games
from member_player_games
group by member_id, member_name, player_id;

grant select on member_player_contrib to anon, authenticated;
