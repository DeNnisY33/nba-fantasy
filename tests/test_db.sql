-- 本機整合測試：先跑 schema.sql 與 002，再執行這支。任何 assert 失敗都會中止。
\set ON_ERROR_STOP 1
set client_min_messages = warning;

insert into members (name) values ('A'),('B'),('C'),('D'),('E'),('F');
select admin_set_pin(id, '1111') from members;

-- A：p1..p10 先發、p11 p12 替補；B：q1..q10 先發、q11 q12 替補
insert into rosters (member_id, player_id, player_name, start_date, slot)
select (select id from members where name='A'), 'p'||g, 'P'||g, et_today() - 10, case when g <= 10 then 'active' else 'bench' end
from generate_series(1,12) g;
insert into rosters (member_id, player_id, player_name, start_date, slot)
select (select id from members where name='B'), 'q'||g, 'Q'||g, et_today() - 10, case when g <= 10 then 'active' else 'bench' end
from generate_series(1,12) g;

-- 今天 p1 打了一場（先發），p11 也打了（替補，不該算分）
insert into player_game_stats (game_id, player_id, game_date, player_name, pts) values
  ('g1','p1', et_today(), 'P1', 30), ('g1','p11', et_today(), 'P11', 50);

do $$ declare A int := (select id from members where name='A');
              B int := (select id from members where name='B');
              C int := (select id from members where name='C');
              D int := (select id from members where name='D');
              E int := (select id from members where name='E');
              r jsonb; tid int;
begin
  -- 只算先發
  assert (select points from member_daily_scores where member_id = A) = 30, 'bench should not score';
  assert (select week_points from leaderboard where member_id = A) = 30, 'week points';

  -- 登入
  assert (login(A, '1111')->>'ok')::bool, 'login ok';
  assert not (login(A, '9999')->>'ok')::bool, 'wrong pin';

  -- 沒受傷不能換
  r := swap_players(A, '1111', 'p1', 'p11');
  assert not (r->>'ok')::bool and r->>'error' like '只有先發%', 'healthy swap blocked: ' || r;

  -- p1 受傷 → 可以換
  insert into player_injuries (player_id, player_name, status) values ('p1','P1','Out');
  r := swap_players(A, '1111', 'p1', 'p11');
  assert (r->>'ok')::bool, 'injury swap: ' || r;
  assert (select slot from team_rosters where player_id='p1') = 'bench';
  assert (select injury_benched from team_rosters where player_id='p1');
  assert (select slot from team_rosters where player_id='p11') = 'active';
  assert (select today_slot from team_rosters where player_id='p1') = 'active', 'today unchanged';
  -- 今天的分數不受影響（隔天生效）
  assert (select points from member_daily_scores where member_id = A) = 30, 'swap is next-day';

  -- 傷還沒好，不能換回
  r := swap_players(A, '1111', 'p11', 'p1');
  assert not (r->>'ok')::bool, 'still injured';
  -- 傷好了 → 可以換回
  delete from player_injuries where player_id = 'p1';
  r := swap_players(A, '1111', 'p11', 'p1');
  assert (r->>'ok')::bool, 'return swap: ' || r;
  assert (select slot from team_rosters where player_id='p1') = 'active';
  -- 第一次換人：2 筆舊紀錄保留到今天 + 2 筆明天生效；同一天第二次換人直接改明天那 2 筆
  assert (select count(*) from rosters where member_id = A) = 14, 'same-day swaps edit in place';
  assert (select count(*) from team_rosters where member_id = A) = 12, 'still 12 players';
  assert (select count(*) from lineup_changes) = 2;

  -- 交易：A 的 p2（先發）+ p12（替補） 換 B 的 q3（先發）+ q12（替補）
  r := propose_trade(A, '1111', B, array['p2','p12'], array['q3','q12'], '試試看');
  assert (r->>'ok')::bool, 'propose: ' || r; tid := (r->>'trade_id')::int;
  -- 重複的球員不能再提
  assert not (propose_trade(A, '1111', B, array['p2'], array['q4'])->>'ok')::bool, 'dup trade';
  -- 人數不同不行
  assert not (propose_trade(A, '1111', B, array['p5'], array['q4','q5'])->>'ok')::bool, 'uneven';
  -- 交易中的球員不能換位置
  insert into player_injuries (player_id, player_name, status) values ('p2','P2','Out');
  assert not (swap_players(A, '1111', 'p2', 'p11')->>'ok')::bool, 'locked by trade';
  delete from player_injuries where player_id = 'p2';

  -- 投票前不能投
  assert not (vote_trade(C, '1111', tid, true)->>'ok')::bool, 'not voting yet';
  -- 只有 B 能回覆
  assert not (respond_trade(C, '1111', tid, true)->>'ok')::bool, 'only receiver';
  r := respond_trade(B, '1111', tid, true);
  assert r->>'status' = 'voting', 'accepted: ' || r;
  -- 當事人不能投
  assert not (vote_trade(A, '1111', tid, true)->>'ok')::bool, 'party cannot vote';
  r := vote_trade(C, '1111', tid, true);
  assert r->>'status' = 'voting', 'one yes: ' || r;
  r := vote_trade(D, '1111', tid, true);
  assert r->>'status' = 'approved', 'two yes: ' || r;

  assert (select member_name from team_rosters where player_id='q3') = 'A', 'q3 moved to A';
  assert (select slot from team_rosters where player_id='q3') = 'active', 'q3 takes p2 slot';
  assert (select slot from team_rosters where player_id='q12') = 'bench', 'q12 takes p12 slot';
  assert (select member_name from team_rosters where player_id='p2') = 'B';
  assert (select slot from team_rosters where player_id='p2') = 'active';
  assert (select count(*) from team_rosters where member_id = A) = 12;
  assert (select count(*) from team_rosters where member_id = B) = 12;
  assert (select count(*) from team_rosters where member_id = A and slot='active') = 10;
  -- 今天 p1 的分數仍歸 A
  assert (select points from member_daily_scores where member_id = A) = 30;

  -- 否決：3 票反對
  r := propose_trade(A, '1111', B, array['p5'], array['q5']); tid := (r->>'trade_id')::int;
  perform respond_trade(B, '1111', tid, true);
  perform vote_trade(C, '1111', tid, false);
  perform vote_trade(D, '1111', tid, false);
  r := vote_trade(E, '1111', tid, false);
  assert r->>'status' = 'rejected', 'rejected: ' || r;
  assert (select member_name from team_rosters where player_id='p5') = 'A';

  -- 拒絕與取消
  r := propose_trade(A, '1111', B, array['p6'], array['q6']); tid := (r->>'trade_id')::int;
  assert (respond_trade(B, '1111', tid, false)->>'status') = 'declined';
  r := propose_trade(A, '1111', B, array['p6'], array['q6']); tid := (r->>'trade_id')::int;
  assert not (cancel_trade(B, '1111', tid)->>'ok')::bool, 'only proposer cancels';
  assert (cancel_trade(A, '1111', tid)->>'status') = 'cancelled';
end $$;

-- 密碼鎖定（要分開 transaction，才能看到失敗次數被寫入）
select login((select id from members where name='F'), 'x') from generate_series(1,5);
select (login((select id from members where name='F'), '1111')->>'error') as locked_msg;
do $$ begin
  assert (login((select id from members where name='F'), '1111')->>'error') like '密碼錯誤太多次%', 'lockout';
end $$;

-- 權限：anon 讀得到公開資料，讀不到密碼，不能直接寫入，不能呼叫內部函式
set role anon;
select count(*) as anon_can_read_rosters from team_rosters;
do $$ begin
  begin perform * from member_auth; raise exception 'anon read member_auth';
  exception when insufficient_privilege then null; end;
  begin insert into trades (proposer_id, receiver_id) values (1, 2); raise exception 'anon wrote trades';
  exception when insufficient_privilege then null; end;
  begin perform _execute_trade(1); raise exception 'anon ran internal fn';
  exception when insufficient_privilege then null; end;
  begin perform sync_injuries('[]'); raise exception 'anon ran sync_injuries';
  exception when insufficient_privilege then null; end;
  assert (login(1, '1111')->>'ok')::bool, 'anon can login';
end $$;
reset role;

select 'ALL DB TESTS PASSED' as result;
