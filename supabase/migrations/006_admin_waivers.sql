-- 006：揮棄改由管理員在 SQL Editor 執行（網站上不再開放）
-- 規則檢查不變：傷兵（缺陣 / 禁賽）達門檻、撿的球員能力值至少低 waive_rating_gap、隔天生效。
-- 用法：select admin_waive((select id from members where name = 'Dennis'), '放掉的球員ID', '撿的球員ID');

drop function if exists waive_player(int, text, text, text);

create or replace function admin_waive(p_member int, p_drop text, p_add text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  d date := et_today() + 1;
  need int := (select value::int from league_settings where key = 'waive_injured_needed');
  gap  int := (select value::int from league_settings where key = 'waive_rating_gap');
  hurt int; r_drop rosters; o_drop int; o_add int; add_name text;
begin
  perform pg_advisory_xact_lock(hashtext('waive:' || p_add));

  select count(*) into hurt from rosters r
  join player_injuries i on i.player_id = r.player_id and i.status in ('Out', 'Suspension')
  where r.member_id = p_member and r.start_date <= d and (r.end_date is null or r.end_date >= d);
  if hurt < need then
    return _err('隊上受傷（缺陣 / 禁賽）的球員要達 ' || need || ' 人才能揮棄，目前 ' || hurt || ' 人');
  end if;

  r_drop := _roster_row(p_member, p_drop, d);
  if r_drop.id is null then return _err('要放掉的球員不在這隊上'); end if;
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
  return jsonb_build_object('ok', true, 'effective_date', d, 'dropped', r_drop.player_name, 'added', add_name);
end $$;

revoke execute on function admin_waive(int, text, text) from public, anon, authenticated;
