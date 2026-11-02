-- 本機整合測試：依序跑 schema.sql、002、003、004、005 後再執行這支。任何 assert 失敗都會中止。
\set ON_ERROR_STOP 1
set client_min_messages = warning;

insert into members (name) values ('A'),('B'),('C'),('D'),('E'),('F');
select admin_set_pin(id, '1111') from members;

-- 球員資料庫：A 隊 a1..a12、B 隊 b1..b12、自由球員 fa1..fa3
-- 位置：1-4 G、5-8 F、9-10 C、11 G、12 F
insert into players (player_id, name, team, position)
select x || g, upper(x) || g, 'TST', case when g <= 4 or g = 11 then 'G' when g <= 8 or g = 12 then 'F' else 'C' end
from unnest(array['a','b']) x, generate_series(1,12) g;
insert into players (player_id, name, team, position) values ('fa1','FA1','TST','G'),('fa2','FA2','TST','F'),('fa3','FA3','TST','C');

-- 能力值：a1=92 a2=90（兩位 90+）a3..a5=86（85+ 共 5）a6..a8=82（80+ 共 8）其餘 75；b 隊同樣結構；
-- 自由球員 fa1=80、fa2=70、fa3=76
insert into player_ratings (player_id, ovr, snapshot_date)
select x || g, case when g = 1 then 92 when g = 2 then 90 when g <= 5 then 86 when g <= 8 then 82 else 75 end, current_date
from unnest(array['a','b']) x, generate_series(1,12) g;
insert into player_ratings values ('fa1', 80, null, current_date), ('fa2', 70, null, current_date), ('fa3', 76, null, current_date);

-- 陣容：1..10 十人名單內，11、12 名單外
insert into rosters (member_id, player_id, player_name, start_date, slot)
select (select id from members where name = upper(x)), x || g, upper(x) || g, et_today() - 10,
       case when g <= 10 then 'active' else 'bench' end
from unnest(array['a','b']) x, generate_series(1,12) g;

do $$ begin
  assert (select problems from roster_check where member_name = 'A') = '{}', 'A roster valid';
  assert (select draft_notes from roster_check where member_name = 'A') = '{}', 'A positions G4 F4 C2';
end $$;

-- ===== 自動遞補 =====
-- 昨天：a1 有登記缺陣且沒上場 → 由名單外能力值較高的 a11/a12（都是 75）中的一位遞補；a2 缺陣但其實有上場 → 照算
insert into injury_log values (et_today() - 1, 'a1', 'Out'), (et_today() - 1, 'a2', 'Out'), (et_today() - 1, 'a3', 'Day-To-Day');
insert into player_game_stats (game_id, player_id, game_date, player_name, pts, did_not_play) values
  ('y','a1', et_today() - 1, 'A1', 0, true),
  ('y','a2', et_today() - 1, 'A2', 10, false),
  ('y','a3', et_today() - 1, 'A3', 10, false),
  ('y','a11', et_today() - 1, 'A11', 7, false),
  ('y','a12', et_today() - 1, 'A12', 5, false);
-- 今天：沒有人缺陣 → 名單外的 a11 不算分
insert into player_game_stats (game_id, player_id, game_date, player_name, pts, did_not_play) values
  ('t','a1', et_today(), 'A1', 20, false), ('t','a11', et_today(), 'A11', 50, false);

do $$ declare A int := (select id from members where name='A'); begin
  -- 昨天：a2 10 + a3 10 + 一位遞補（a11 與 a12 能力值相同，依 player_id 排序取 a11 = 7）
  assert (select points from member_daily_scores where member_id = A and game_date = et_today() - 1) = 27,
    'yesterday autosub: ' || (select points from member_daily_scores where member_id = A and game_date = et_today() - 1);
  assert (select count(*) from member_player_games where member_id = A and game_date = et_today() - 1 and is_sub) = 1, 'one sub';
  assert not exists (select 1 from member_player_games where player_id = 'a1' and game_date = et_today() - 1), 'out player not counted';
  -- 今天：只有 a1 算分
  assert (select points from member_daily_scores where member_id = A and game_date = et_today()) = 20, 'no sub today';
end $$;

-- 傷兵同步會寫入當天紀錄，同一天出現過 Out 就保留 Out
select sync_injuries('[{"player_id":"b1","player_name":"B1","status":"Out"}]');
select sync_injuries('[{"player_id":"b1","player_name":"B1","status":"Day-To-Day"}]');
do $$ begin
  assert (select status from injury_log where log_date = et_today() and player_id = 'b1') = 'Out', 'injury log keeps Out';
  assert (select status from player_injuries where player_id = 'b1') = 'Day-To-Day', 'current status updated';
end $$;

-- ===== 揮棄 =====
do $$ declare A int := (select id from members where name='A'); r jsonb; begin
  -- 受傷不到 3 人不能揮棄
  delete from player_injuries where true;
  insert into player_injuries (player_id, player_name, status) values ('a1','A1','Out'), ('a2','A2','Out'), ('a3','A3','Day-To-Day');
  r := admin_waive(A, 'a9', 'fa2');
  assert not (r->>'ok')::bool and r->>'error' like '%目前 2 人%', 'need 3 injured: ' || r::text;

  -- 第 3 人缺陣 → 可以揮棄
  update player_injuries set status = 'Out' where player_id = 'a3';
  -- 能力值差距不足：a9=75，撿 fa3=76 不行、撿 fa1=80 不行
  assert not (admin_waive(A, 'a9', 'fa3')->>'ok')::bool, 'gap too small';
  -- 撿已經在別隊的人不行
  assert not (admin_waive(A, 'a9', 'b12')->>'ok')::bool, 'owned';
  -- 放掉 a9（75，十人名單內 C）撿 fa2（70）→ OK，接手十人名單位置
  r := admin_waive(A, 'a9', 'fa2');
  assert (r->>'ok')::bool, 'waive ok: ' || r::text;
  assert (select slot from team_rosters where player_id = 'fa2') = 'active', 'fa2 takes list slot';
  assert (select member_name from team_rosters where player_id = 'fa2') = 'A';
  assert not exists (select 1 from team_rosters where player_id = 'a9'), 'a9 dropped';
  assert exists (select 1 from free_agents where player_id = 'a9'), 'a9 back to free agents';
  assert not exists (select 1 from free_agents where player_id = 'fa2'), 'fa2 no longer free';
  assert (select count(*) from waivers) = 1;
  -- 放掉的人以前的分數照算（a3 昨天 10 分還在）
  assert (select points from member_daily_scores where member_id = A and game_date = et_today() - 1) = 27, 'history kept';
  -- 放掉 a1（92）撿 fa1（80）也可以（低 12）
  assert (admin_waive(A, 'a1', 'fa1')->>'ok')::bool, 'waive star';
  -- 別隊可以撿回被放掉的 a9（需要先有 3 位傷兵）
  insert into player_injuries (player_id, player_name, status) values ('b2','B2','Out'),('b3','B3','Out'),('b4','B4','Suspension');
  r := admin_waive((select id from members where name='B'), 'b1', 'a9');
  assert (r->>'ok')::bool, 'B picks up a9: ' || r::text;
  delete from player_injuries where true;
end $$;

-- ===== 交易限制 =====
do $$ declare A int := (select id from members where name='A'); B int := (select id from members where name='B');
             r jsonb; tid int; begin
  -- 十人名單內不同位置不能換：a2（G, 名單內）換 b5（F, 名單內）
  r := propose_trade(A, '1111', B, array['a2'], array['b5']);
  assert not (r->>'ok')::bool and r->>'error' like '%位置不同%', 'position rule: ' || r::text;
  -- 名單外對名單外不限位置：a11（G）換 b12（F）
  r := propose_trade(A, '1111', B, array['a11'], array['b12']);
  assert (r->>'ok')::bool, 'bench swap any pos: ' || r::text;
  perform cancel_trade(A, '1111', (r->>'trade_id')::int);
  -- 能力值上限：A 已有 a2（90）+ 撿來的 fa1(80)… B 的 b2 是 90。A 拿 fa2（70, F 名單內）換 b2（90, G 名單內）→ 位置不同先擋
  -- 改用同位置：A 用 a10（C, 75, 名單內）換 B 的 b2（G）→ 位置不同；用 a4（G, 86）換 b2（G, 90）→ A 的 90+ 變 2 位 OK、85+ 不變
  r := propose_trade(A, '1111', B, array['a4'], array['b2']);
  assert (r->>'ok')::bool, 'same pos, caps ok: ' || r::text;
  perform cancel_trade(A, '1111', (r->>'trade_id')::int);
  -- 超過 90+ 上限：A 把 fa1（80, 名單內 G 位置）換成 B 的 b1（92, G）→ A 90+ = a2 + b1 = 2 OK；再加一筆 a3→b2 會變 3
  r := propose_trade(A, '1111', B, array['fa1','a3'], array['b2','b3']);
  -- fa1(G) 換 b2(G)：A 的 90+ 變 a2+b2 = 2；a3(G? 不，a3 是 G) 換 b3(G)：86↔86 不變 → OK
  assert (r->>'ok')::bool, 'two pairs ok: ' || r::text; tid := (r->>'trade_id')::int;
  perform cancel_trade(A, '1111', tid);
  -- A 的 90+ 目前只有 a2（a1 已被揮棄、撿了 80 分的 fa1，所以 80+ 已滿 8 位）
  -- 名單外 a11（75）換 b2（90）會讓 80+ 變 9 位 → 擋下
  r := propose_trade(A, '1111', B, array['a11'], array['b2']);
  assert not (r->>'ok')::bool and r->>'error' like '%80+%', 'cap 80: ' || r::text;
  -- 改用 a4（G, 86, 名單內）換 b2（G, 90, 名單內）→ 90+ = 2、85+ = 4、80+ = 8 → OK，走完整流程
  r := propose_trade(A, '1111', B, array['a4'], array['b2']);
  assert (r->>'ok')::bool, 'get second 90: ' || r::text; tid := (r->>'trade_id')::int;
  perform respond_trade(B, '1111', tid, true);
  perform vote_trade((select id from members where name='C'), '1111', tid, true);
  r := vote_trade((select id from members where name='D'), '1111', tid, true);
  assert r->>'status' = 'approved', 'approved: ' || r::text;
  assert (select slot from team_rosters where player_id = 'b2') = 'active', 'b2 inherits a4 list slot';
  assert (select member_name from team_rosters where player_id = 'a4') = 'B';
  -- A 現在 90+ = a2 + b2 = 2，若再多一位 92 分的 b1（已被 B 揮棄）就會超標
  assert _team_cap_error(A, array['a11'], array['b1'], et_today() + 1) like '%90+%', 'cap 90';
  assert _team_cap_error(A, array['a2'], array['b1'], et_today() + 1) is null, 'swap 90 for 90 ok';
end $$;

-- 密碼鎖定
select login((select id from members where name='F'), 'x') from generate_series(1,5);
do $$ begin
  assert (login((select id from members where name='F'), '1111')->>'error') like '密碼錯誤太多次%', 'lockout';
end $$;

-- 權限
set role anon;
do $$ begin
  begin perform * from member_auth; raise exception 'anon read member_auth';
  exception when insufficient_privilege then null; end;
  begin insert into waivers (member_id, drop_player_id, drop_player, add_player_id, add_player, slot, effective_date)
        values (1,'x','x','y','y','active',current_date); raise exception 'anon wrote waivers';
  exception when insufficient_privilege then null; end;
  begin perform admin_waive(1, 'a', 'b'); raise exception 'anon ran admin_waive';
  exception when insufficient_privilege then null; end;
  begin perform apply_ratings(current_date); raise exception 'anon ran apply_ratings';
  exception when insufficient_privilege then null; end;
  begin perform _trade_error(1, 2, array['a'], array['b'], current_date); raise exception 'anon ran _trade_error';
  exception when insufficient_privilege then null; end;
  perform count(*) from free_agents;
  perform count(*) from roster_check;
end $$;
reset role;

-- 能力值匯入與名字對應
insert into players (player_id, name, team, position) values
  ('p1', 'Nikola Jokić', 'DEN', 'C'), ('p2', 'RJ Barrett', 'TOR', 'G'), ('p3', 'Alex Sarr', 'WSH', 'C'),
  ('p4', 'Jaren Jackson Jr.', 'UTAH', 'F'), ('p5', 'Ron Harper Jr.', 'BOS', 'G');
insert into rating_imports (snapshot_date, source_name, team_slug, ovr, pos_2k) values
  ('2026-11-02', 'Nikola Jokic', 'denver-nuggets', 97, 'C'),
  ('2026-11-02', 'R.J. Barrett', 'toronto-raptors', 82, 'SG/SF'),
  ('2026-11-02', 'Alexandre Sarr', 'washington-wizards', 83, 'C/PF'),
  ('2026-11-02', 'Jaren Jackson Jr.', 'utah-jazz', 86, 'PF/C'),
  ('2026-11-02', 'Ron Harper Jr.', 'boston-celtics', 71, 'SF/SG'),
  ('2026-11-02', 'Nobody Real', 'boston-celtics', 60, 'C');
do $$ declare r jsonb; begin
  r := apply_ratings('2026-11-02');
  assert (r->>'matched')::int = 5, 'matched 5: ' || r::text;
  assert r->'unmatched' = '["Nobody Real (boston-celtics 60)"]'::jsonb, 'unmatched: ' || r::text;
  assert (select ovr from player_ratings where player_id = 'p3') = 83, 'Sarr matched by team + last name';
  update league_settings set value = 'true' where key = 'ratings_locked';
  assert not (apply_ratings('2026-11-02')->>'ok')::bool, 'locked';
end $$;

select 'ALL DB TESTS PASSED' as result;
