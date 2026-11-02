-- =============================================================
-- 範例：建立 6 位玩家與選秀結果
-- 把名字和球員換成你們實際的選秀結果後，在 SQL Editor 執行。
--
-- player_id 是 ESPN 的球員 ID，從球員頁網址就能看到：
--   https://www.espn.com/nba/player/_/id/3112335/nikola-jokic  →  3112335
-- 下面的 ID 只是示範，請自行到 ESPN 確認。
-- start_date 填聯盟開始計分的那一天。
-- =============================================================

insert into members (name) values
  ('Alice'), ('Bob'), ('Chris'), ('Dana'), ('Eric'), ('Fiona')
on conflict (name) do nothing;

insert into rosters (member_id, player_id, player_name, start_date)
select m.id, v.player_id, v.player_name, date '2026-11-03'
from (values
  ('Alice', '3112335', 'Nikola Jokic'),
  ('Alice', '3945274', 'Luka Doncic'),
  ('Bob',   '3032977', 'Giannis Antetokounmpo'),
  ('Bob',   '4065648', 'Jayson Tatum')
  -- ... 依此類推，把每個人的球員都列上
) as v(member_name, player_id, player_name)
join members m on m.name = v.member_name;

-- 換人範例：Bob 在 12/1 把 Tatum 換成別人
-- update rosters set end_date = date '2026-11-30'
--   where player_id = '4065648' and end_date is null;
-- insert into rosters (member_id, player_id, player_name, start_date)
--   select id, '新球員ID', '新球員名字', date '2026-12-01' from members where name = 'Bob';
