-- =============================================================
-- 005：2K 能力值、十人名單自動遞補、揮棄、交易限制（能力值上限 + 同位置）
-- 取代 002 的手動「先發 ↔ 替補」換人。
--   rosters.slot = 'active' → 十人名單內（算分）
--   rosters.slot = 'bench'  → 十人名單外
-- =============================================================

create extension if not exists unaccent with schema extensions;

-- ---------- 設定 ----------
insert into league_settings (key, value, note) values
  ('ratings_locked',        'false', '能力值是否已鎖定（選秀當天改成 true，之後不再更新）'),
  ('cap_90',                '2',     '每隊 90 以上最多幾位'),
  ('cap_85',                '5',     '每隊 85 以上（含 90+）最多幾位'),
  ('cap_80',                '8',     '每隊 80 以上（含 85+）最多幾位'),
  ('list_positions',        'G:4,F:4,C:2', '選秀時十人名單的位置組成（ESPN G/F/C）'),
  ('waive_injured_needed',  '3',     '隊上幾人受傷（缺陣 / 禁賽）才能揮棄'),
  ('waive_rating_gap',      '5',     '揮棄撿的球員能力值至少要低幾分')
on conflict (key) do nothing;
update league_settings set note = '十人名單人數（算分）' where key = 'active_slots';
update league_settings set note = '十人名單外人數'       where key = 'bench_slots';

-- ---------- 2K 能力值 ----------
create table if not exists rating_imports (
  snapshot_date date not null,
  source_name   text not null,
  team_slug     text not null,
  ovr           int  not null,
  pos_2k        text,
  player_id     text,
  primary key (snapshot_date, source_name, team_slug)
);

create table if not exists player_ratings (
  player_id     text primary key,
  ovr           int  not null,
  pos_2k        text,
  snapshot_date date not null
);

create or replace function norm_name(n text) returns text
language sql immutable set search_path = public, extensions as $$
  select trim(regexp_replace(regexp_replace(
           regexp_replace(lower(extensions.unaccent(coalesce(n, ''))), '[^a-z ]', '', 'g'),
           '\m(jr|sr|ii|iii|iv)\M', '', 'g'), '\s+', ' ', 'g'))
$$;

-- 排程用：把某天的匯入對應到 ESPN 球員，覆蓋 player_ratings（已鎖定則拒絕）
create or replace function apply_ratings(p_snapshot date) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare n_matched int; n_total int; unmatched jsonb;
begin
  if (select value from league_settings where key = 'ratings_locked') = 'true' then
    return jsonb_build_object('ok', false, 'error', 'ratings are locked');
  end if;

  with map(slug, abbr) as (values
    ('atlanta-hawks','ATL'),('boston-celtics','BOS'),('brooklyn-nets','BKN'),('charlotte-hornets','CHA'),
    ('chicago-bulls','CHI'),('cleveland-cavaliers','CLE'),('dallas-mavericks','DAL'),('denver-nuggets','DEN'),
    ('detroit-pistons','DET'),('golden-state-warriors','GS'),('houston-rockets','HOU'),('indiana-pacers','IND'),
    ('los-angeles-clippers','LAC'),('los-angeles-lakers','LAL'),('memphis-grizzlies','MEM'),('miami-heat','MIA'),
    ('milwaukee-bucks','MIL'),('minnesota-timberwolves','MIN'),('new-orleans-pelicans','NO'),('new-york-knicks','NY'),
    ('oklahoma-city-thunder','OKC'),('orlando-magic','ORL'),('philadelphia-76ers','PHI'),('phoenix-suns','PHX'),
    ('portland-trail-blazers','POR'),('sacramento-kings','SAC'),('san-antonio-spurs','SA'),('toronto-raptors','TOR'),
    ('utah-jazz','UTAH'),('washington-wizards','WSH')),
  cand as (
    select ri.source_name, ri.team_slug, p.player_id,
           row_number() over (partition by ri.source_name, ri.team_slug
                              order by (norm_name(p.name) = norm_name(ri.source_name)) desc,
                                       (p.team = map.abbr) desc,
                                       (left(norm_name(p.name), 1) = left(norm_name(ri.source_name), 1)) desc,
                                       p.player_id) as rk
    from rating_imports ri
    join map on map.slug = ri.team_slug
    join players p on
         norm_name(p.name) = norm_name(ri.source_name)
      or (p.team = map.abbr   -- 同隊同姓（處理綽號，例如 Carlton / Bub Carrington）
          and split_part(norm_name(p.name), ' ', -1) = split_part(norm_name(ri.source_name), ' ', -1))
    where ri.snapshot_date = p_snapshot
  )
  update rating_imports ri set player_id = c.player_id
  from cand c
  where c.rk = 1 and ri.snapshot_date = p_snapshot
    and ri.source_name = c.source_name and ri.team_slug = c.team_slug;

  delete from player_ratings where true;
  insert into player_ratings (player_id, ovr, pos_2k, snapshot_date)
  select distinct on (player_id) player_id, ovr, pos_2k, p_snapshot
  from rating_imports where snapshot_date = p_snapshot and player_id is not null
  order by player_id, ovr desc;

  select count(*), count(player_id) into n_total, n_matched from rating_imports where snapshot_date = p_snapshot;
  select coalesce(jsonb_agg(source_name || ' (' || team_slug || ' ' || ovr || ')' order by ovr desc), '[]')
    into unmatched from rating_imports where snapshot_date = p_snapshot and player_id is null;
  return jsonb_build_object('ok', true, 'total', n_total, 'matched', n_matched, 'unmatched', unmatched);
end $$;

-- ---------- 傷兵每日紀錄（自動遞補用） ----------
create table if not exists injury_log (
  log_date  date not null,
  player_id text not null,
  status    text not null,
  primary key (log_date, player_id)
);

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

  -- 記錄今天（美東）出現過的狀態；同一天只要出現過缺陣 / 禁賽就保留
  insert into injury_log (log_date, player_id, status)
  select et_today(), player_id, status from player_injuries
  on conflict (log_date, player_id) do update
    set status = case when injury_log.status in ('Out', 'Suspension') then injury_log.status else excluded.status end;
  return n;
end $$;

-- ---------- 計分：十人名單 + 自動遞補 ----------
-- 某天十人名單內的球員「缺陣」（當天傷兵紀錄為 Out / Suspension，而且當天沒有上場），
-- 就由十人名單外、當天健康的球員依能力值高低遞補。
create or replace view member_player_games with (security_invoker = true) as
with d as (select distinct game_date from player_game_stats),
own as (
  select r.member_id, r.player_id, r.slot, d.game_date
  from rosters r
  join d on d.game_date >= r.start_date and (r.end_date is null or d.game_date <= r.end_date)
),
st as (
  select o.*, coalesce(pr.ovr, 0) as ovr,
    (exists (select 1 from injury_log l where l.log_date = o.game_date and l.player_id = o.player_id
                                         and l.status in ('Out', 'Suspension'))
     and not exists (select 1 from player_game_stats g where g.player_id = o.player_id
                                                    and g.game_date = o.game_date and not g.did_not_play)) as is_out
  from own o left join player_ratings pr on pr.player_id = o.player_id
),
need as (
  select member_id, game_date, count(*) filter (where slot = 'active' and is_out) as n_out
  from st group by member_id, game_date
),
ranked as (
  select st.*, row_number() over (partition by st.member_id, st.game_date, (st.slot = 'bench' and not st.is_out)
                                  order by st.ovr desc, st.player_id) as rk
  from st
),
counted as (
  select r.member_id, r.player_id, r.game_date, r.slot
  from ranked r join need n on n.member_id = r.member_id and n.game_date = r.game_date
  where (r.slot = 'active' and not r.is_out)
     or (r.slot = 'bench' and not r.is_out and r.rk <= n.n_out)
)
select m.id as member_id, m.name as member_name, c.slot, f.*, (c.slot = 'bench') as is_sub
from counted c
join player_game_fantasy f on f.player_id = c.player_id and f.game_date = c.game_date
join members m on m.id = c.member_id;

-- ---------- 陣容與自由球員 ----------
create or replace view team_rosters with (security_invoker = true) as
select
  m.id as member_id, m.name as member_name,
  r.player_id, r.player_name, r.slot, r.injury_benched,
  t.slot as today_slot,
  p.team, p.position, p.headshot,
  i.status as injury_status, i.fantasy_status, i.injury_type, i.return_date, i.comment as injury_comment,
  coalesce(ps.games, 0) as games, ps.avg_fp, coalesce(ps.total_fp, 0) as total_fp,
  pr.ovr, pr.pos_2k,
  (i.status in ('Out', 'Suspension')) as is_injured
from rosters r
join members m on m.id = r.member_id
left join rosters t
  on t.member_id = r.member_id and t.player_id = r.player_id
 and t.start_date <= et_today() and (t.end_date is null or t.end_date >= et_today())
left join players p on p.player_id = r.player_id
left join player_injuries i on i.player_id = r.player_id
left join player_season ps on ps.player_id = r.player_id
left join player_ratings pr on pr.player_id = r.player_id
where r.start_date <= et_today() + 1 and (r.end_date is null or r.end_date >= et_today() + 1);

drop view if exists free_agents;
create view free_agents with (security_invoker = true) as
select p.player_id, p.name, p.team, p.position, p.headshot, pr.ovr, pr.pos_2k,
       i.status as injury_status, coalesce(ps.games, 0) as games, ps.avg_fp
from players p
left join player_ratings pr on pr.player_id = p.player_id
left join player_injuries i on i.player_id = p.player_id
left join player_season ps on ps.player_id = p.player_id
where not exists (
  select 1 from rosters r where r.player_id = p.player_id
    and r.start_date <= et_today() + 1 and (r.end_date is null or r.end_date >= et_today() + 1));

-- 名單檢查（選秀匯入後確認用）
drop view if exists roster_check;
create view roster_check with (security_invoker = true) as
with s as (select key, value from league_settings),
t as (
  select m.id as member_id, m.name as member_name,
    count(r.*) as players,
    count(r.*) filter (where r.slot = 'active') as list_size,
    count(r.*) filter (where r.slot = 'active' and p.position = 'G') as list_g,
    count(r.*) filter (where r.slot = 'active' and p.position = 'F') as list_f,
    count(r.*) filter (where r.slot = 'active' and p.position = 'C') as list_c,
    count(r.*) filter (where pr.ovr >= 90) as n90,
    count(r.*) filter (where pr.ovr >= 85) as n85,
    count(r.*) filter (where pr.ovr >= 80) as n80,
    count(r.*) filter (where r.player_id is not null and pr.ovr is null) as unrated
  from members m
  left join rosters r on r.member_id = m.id
   and r.start_date <= et_today() + 1 and (r.end_date is null or r.end_date >= et_today() + 1)
  left join players p on p.player_id = r.player_id
  left join player_ratings pr on pr.player_id = r.player_id
  group by m.id, m.name
)
select t.*,
  array_remove(array[
    case when t.players <> 12 then '總人數 ' || t.players || '（應為 12）' end,
    case when t.list_size <> 10 then '十人名單 ' || t.list_size || ' 人' end,
    case when t.n90 > (select value::int from s where key = 'cap_90') then '90+ 有 ' || t.n90 || ' 位' end,
    case when t.n85 > (select value::int from s where key = 'cap_85') then '85+ 有 ' || t.n85 || ' 位' end,
    case when t.n80 > (select value::int from s where key = 'cap_80') then '80+ 有 ' || t.n80 || ' 位' end,
    case when t.unrated > 0 then t.unrated || ' 位沒有能力值' end
  ], null) as problems,
  array_remove(array[
    case when (t.list_g, t.list_f, t.list_c) <> (4, 4, 2)
      then '十人名單位置 G' || t.list_g || ' F' || t.list_f || ' C' || t.list_c || '（選秀時應為 G4 F4 C2）' end
  ], null) as draft_notes
from t;

-- ---------- 揮棄 ----------
create table if not exists waivers (
  id             serial primary key,
  member_id      int  not null references members(id),
  drop_player_id text not null,
  drop_player    text not null,
  drop_ovr       int,
  add_player_id  text not null,
  add_player     text not null,
  add_ovr        int,
  slot           text not null,
  effective_date date not null,
  created_at     timestamptz not null default now()
);

create or replace function waive_player(p_member int, p_pin text, p_drop text, p_add text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  e text; d date := et_today() + 1;
  need int := (select value::int from league_settings where key = 'waive_injured_needed');
  gap  int := (select value::int from league_settings where key = 'waive_rating_gap');
  hurt int; r_drop rosters; o_drop int; o_add int; add_name text;
begin
  e := _check_pin(p_member, p_pin);
  if e is not null then return _err(e); end if;
  perform pg_advisory_xact_lock(hashtext('waive:' || p_add));

  select count(*) into hurt from rosters r
  join player_injuries i on i.player_id = r.player_id and i.status in ('Out', 'Suspension')
  where r.member_id = p_member and r.start_date <= d and (r.end_date is null or r.end_date >= d);
  if hurt < need then
    return _err('隊上受傷（缺陣 / 禁賽）的球員要達 ' || need || ' 人才能揮棄，目前 ' || hurt || ' 人');
  end if;

  r_drop := _roster_row(p_member, p_drop, d);
  if r_drop.id is null then return _err('要放掉的球員不在你的隊上'); end if;
  if exists (select 1 from rosters r where r.player_id = p_add and r.start_date <= d and (r.end_date is null or r.end_date >= d)) then
    return _err('這位球員已經在其他隊上');
  end if;
  select name into add_name from players where player_id = p_add;
  if add_name is null then return _err('找不到這位球員'); end if;
  if exists (select 1 from trade_items ti join trades t on t.id = ti.trade_id
             where t.status in ('pending','voting') and ti.player_id = p_drop) then
    return _err('要放掉的球員正在交易流程中');
  end if;

  select ovr into o_drop from player_ratings where player_id = p_drop;
  select ovr into o_add  from player_ratings where player_id = p_add;
  if o_drop is null or o_add is null then return _err('球員沒有 2K 能力值，無法判斷'); end if;
  if o_add > o_drop - gap then
    return _err('撿的球員能力值要 ≤ ' || (o_drop - gap) || '（' || r_drop.player_name || ' 是 ' || o_drop || '）');
  end if;

  perform _end_row(r_drop, d);
  insert into rosters (member_id, player_id, player_name, start_date, slot, source)
    values (p_member, p_add, add_name, d, r_drop.slot, 'waiver');
  insert into waivers (member_id, drop_player_id, drop_player, drop_ovr, add_player_id, add_player, add_ovr, slot, effective_date)
    values (p_member, p_drop, r_drop.player_name, o_drop, p_add, add_name, o_add, r_drop.slot, d);
  return jsonb_build_object('ok', true, 'effective_date', d);
end $$;

-- ---------- 交易限制 ----------
-- 1) 十人名單內的球員只能換同位置（ESPN G/F/C）
-- 2) 交易後雙方都要符合能力值上限
create or replace function _team_cap_error(p_member int, p_out text[], p_in text[], p_day date) returns text
language plpgsql stable set search_path = public as $$
declare n90 int; n85 int; n80 int; nm text;
begin
  with ids as (
    select r.player_id from rosters r
    where r.member_id = p_member and r.start_date <= p_day and (r.end_date is null or r.end_date >= p_day)
      and not (r.player_id = any(p_out))
    union all select unnest(p_in)
  )
  select count(*) filter (where pr.ovr >= 90), count(*) filter (where pr.ovr >= 85), count(*) filter (where pr.ovr >= 80)
    into n90, n85, n80
  from ids left join player_ratings pr on pr.player_id = ids.player_id;
  nm := (select name from members where id = p_member);
  if n90 > (select value::int from league_settings where key = 'cap_90') then return nm || ' 交易後 90+ 會有 ' || n90 || ' 位，超過上限'; end if;
  if n85 > (select value::int from league_settings where key = 'cap_85') then return nm || ' 交易後 85+ 會有 ' || n85 || ' 位，超過上限'; end if;
  if n80 > (select value::int from league_settings where key = 'cap_80') then return nm || ' 交易後 80+ 會有 ' || n80 || ' 位，超過上限'; end if;
  return null;
end $$;

create or replace function _trade_error(p_proposer int, p_receiver int, p_give text[], p_get text[], p_day date) returns text
language plpgsql stable set search_path = public as $$
declare i int; ra rosters; rb rosters; pa text; pb text; e text;
begin
  for i in 1 .. array_length(p_give, 1) loop
    ra := _roster_row(p_proposer, p_give[i], p_day);
    rb := _roster_row(p_receiver, p_get[i], p_day);
    if ra.slot = 'active' or rb.slot = 'active' then
      select position into pa from players where player_id = p_give[i];
      select position into pb from players where player_id = p_get[i];
      if pa is distinct from pb then
        return ra.player_name || '（' || coalesce(pa, '?') || '）和 ' || rb.player_name || '（' || coalesce(pb, '?') ||
               '）位置不同：十人名單內的球員只能換同位置';
      end if;
    end if;
  end loop;
  e := _team_cap_error(p_proposer, p_give, p_get, p_day);
  if e is not null then return e; end if;
  return _team_cap_error(p_receiver, p_get, p_give, p_day);
end $$;

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
  e := _trade_error(p_member, p_to_member, p_give, p_get, d);
  if e is not null then return _err(e); end if;

  insert into trades (proposer_id, receiver_id, message) values (p_member, p_to_member, p_message)
    returning id into tid;
  for i in 1 .. array_length(p_give, 1) loop
    insert into trade_items values
      (tid, i, p_member, p_to_member, p_give[i], (_roster_row(p_member, p_give[i], d)).player_name),
      (tid, i, p_to_member, p_member, p_get[i],  (_roster_row(p_to_member, p_get[i], d)).player_name);
  end loop;
  return jsonb_build_object('ok', true, 'trade_id', tid);
end $$;

create or replace function _execute_trade(p_trade int) returns text
language plpgsql security definer set search_path = public as $$
declare
  t trades; d date := et_today() + 1;
  s int; a trade_items; b trade_items; ra rosters; rb rosters;
  give text[]; get text[];
begin
  select * into t from trades where id = p_trade for update;
  if exists (select 1 from trade_items i
             where i.trade_id = p_trade and (_roster_row(i.from_member_id, i.player_id, d)).id is null) then
    update trades set status = 'failed', decided_at = now() where id = p_trade;
    return 'failed';
  end if;
  select array_agg(player_id order by seq) into give from trade_items where trade_id = p_trade and from_member_id = t.proposer_id;
  select array_agg(player_id order by seq) into get  from trade_items where trade_id = p_trade and from_member_id = t.receiver_id;
  if _trade_error(t.proposer_id, t.receiver_id, give, get, d) is not null then
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
    insert into rosters (member_id, player_id, player_name, start_date, slot, source)
      values (b.from_member_id, a.player_id, a.player_name, d, rb.slot, 'trade'),
             (a.from_member_id, b.player_id, b.player_name, d, ra.slot, 'trade');
  end loop;
  update trades set status = 'approved', decided_at = now(), effective_date = d where id = p_trade;
  return 'approved';
end $$;

-- 手動換人取消（改為自動遞補）
drop function if exists swap_players(int, text, text, text);

-- ---------- 權限 ----------
alter table rating_imports enable row level security;
alter table player_ratings enable row level security;
alter table injury_log     enable row level security;
alter table waivers        enable row level security;
do $$ declare t text; begin
  foreach t in array array['rating_imports','player_ratings','injury_log','waivers'] loop
    execute format('drop policy if exists "public read" on %I', t);
    execute format('create policy "public read" on %I for select using (true)', t);
    execute format('grant select on %I to anon, authenticated', t);
  end loop;
end $$;
grant select on free_agents, roster_check to anon, authenticated;

revoke execute on function apply_ratings(date), _team_cap_error(int, text[], text[], date),
  _trade_error(int, int, text[], text[], date), sync_injuries(jsonb)
  from public, anon, authenticated;
grant execute on function apply_ratings(date), sync_injuries(jsonb) to service_role;
revoke execute on function _execute_trade(int) from public, anon, authenticated;
grant execute on function waive_player(int, text, text, text), propose_trade(int, text, int, text[], text[], text)
  to anon, authenticated;
