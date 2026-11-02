"""
每日抓取 NBA 球員數據並寫入 Supabase。

用法：
  python scripts/fetch_stats.py                    # 抓最近 2 天（美東日期），已完賽的比賽
  python scripts/fetch_stats.py --date 2026-11-01  # 只抓指定日期
  python scripts/fetch_stats.py --days 7           # 補抓最近 7 天
  python scripts/fetch_stats.py --dry-run          # 只抓資料印出來，不寫資料庫
  python scripts/fetch_stats.py --job players      # 更新 30 隊球員名單
  python scripts/fetch_stats.py --job injuries     # 更新傷兵名單
  python scripts/fetch_stats.py --job stats --job players   # 一次跑多個

需要的環境變數（--dry-run 時不需要）：
  SUPABASE_URL          例如 https://xxxx.supabase.co
  SUPABASE_SERVICE_KEY  Supabase 的 service_role key（只放在 GitHub Secrets，不要放前端）
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import time
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import requests

ESPN_BASE = "https://site.api.espn.com/apis/site/v2/sports/basketball/nba"
ET = ZoneInfo("America/New_York")
HEADERS = {"User-Agent": "Mozilla/5.0 (nba-fantasy hobby project)"}


# ---------------------------------------------------------------- ESPN

def http_get_json(url: str, params: dict | None = None, retries: int = 3) -> dict:
    last_err: Exception | None = None
    for attempt in range(retries):
        try:
            r = requests.get(url, params=params, headers=HEADERS, timeout=20)
            r.raise_for_status()
            return r.json()
        except Exception as e:  # noqa: BLE001
            last_err = e
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"GET {url} failed: {last_err}")


def list_games(day: date) -> list[dict]:
    """回傳該美東日期的比賽清單：[{id, completed, state, name}]"""
    data = http_get_json(f"{ESPN_BASE}/scoreboard", {"dates": day.strftime("%Y%m%d")})
    games = []
    for ev in data.get("events", []):
        st = (ev.get("status") or {}).get("type") or {}
        games.append({
            "id": str(ev["id"]),
            "name": ev.get("shortName") or ev.get("name", ""),
            "completed": bool(st.get("completed")),
            "state": st.get("state", ""),  # pre / in / post
        })
    return games


def _split_made_att(v: str) -> tuple[int, int]:
    try:
        made, att = v.split("-")
        return int(made), int(att)
    except Exception:  # noqa: BLE001
        return 0, 0


def _to_int(v) -> int:
    try:
        return int(str(v).replace("+", ""))
    except Exception:  # noqa: BLE001
        return 0


def _to_minutes(v) -> float:
    s = str(v or "").strip()
    if not s or s in {"--", "-"}:
        return 0.0
    if ":" in s:  # 有時會是 "34:12"
        mm, ss = s.split(":", 1)
        return round(_to_int(mm) + _to_int(ss) / 60, 2)
    try:
        return float(s)
    except ValueError:
        return 0.0


# ESPN 欄位標籤 → 我們的欄位。標籤以 labels / names 為準，順序不寫死。
LABEL_MAP = {
    "MIN": "minutes", "PTS": "pts", "REB": "reb", "OREB": "oreb", "DREB": "dreb",
    "AST": "ast", "STL": "stl", "BLK": "blk", "TO": "tov", "PF": "pf", "+/-": "plus_minus",
    "FG": ("fgm", "fga"), "3PT": ("fg3m", "fg3a"), "FT": ("ftm", "fta"),
}


def parse_summary(summary: dict, game_id: str, game_date: date) -> list[dict]:
    """把 ESPN summary 的 boxscore.players 轉成 player_game_stats 列。"""
    rows: list[dict] = []
    teams = (summary.get("boxscore") or {}).get("players") or []
    abbrs = [((t.get("team") or {}).get("abbreviation") or "") for t in teams]

    # 勝負：header.competitions[0].competitors[].winner（比賽結束才有 true/false）
    won_by_team: dict[str, bool] = {}
    comps = ((summary.get("header") or {}).get("competitions") or [{}])[0].get("competitors") or []
    for c in comps:
        ab = (c.get("team") or {}).get("abbreviation")
        if ab and isinstance(c.get("winner"), bool):
            won_by_team[ab] = c["winner"]
    if len(won_by_team) == 2 and len(set(won_by_team.values())) != 2:
        won_by_team = {}  # 資料不完整（例如兩隊都不是贏家）就先不記錄

    for idx, team_block in enumerate(teams):
        team = abbrs[idx] if idx < len(abbrs) else ""
        opponent = abbrs[1 - idx] if len(abbrs) == 2 else ""
        for stat_group in team_block.get("statistics") or []:
            labels = stat_group.get("labels") or stat_group.get("names") or []
            for a in stat_group.get("athletes") or []:
                ath = a.get("athlete") or {}
                pid = str(ath.get("id") or "")
                if not pid:
                    continue
                row = {
                    "game_id": game_id, "player_id": pid, "game_date": game_date.isoformat(),
                    "player_name": ath.get("displayName") or ath.get("shortName") or pid,
                    "team": team, "opponent": opponent,
                    "did_not_play": bool(a.get("didNotPlay")) or not a.get("stats"),
                    "minutes": 0.0,
                    "pts": 0, "reb": 0, "oreb": 0, "dreb": 0, "ast": 0, "stl": 0, "blk": 0,
                    "tov": 0, "pf": 0, "fgm": 0, "fga": 0, "fg3m": 0, "fg3a": 0,
                    "ftm": 0, "fta": 0, "plus_minus": 0,
                    "team_won": won_by_team.get(team),
                }
                for label, value in zip(labels, a.get("stats") or []):
                    key = LABEL_MAP.get(str(label).upper())
                    if key is None:
                        continue
                    if isinstance(key, tuple):
                        row[key[0]], row[key[1]] = _split_made_att(str(value))
                    elif key == "minutes":
                        row["minutes"] = _to_minutes(value)
                    else:
                        row[key] = _to_int(value)
                rows.append(row)
    return rows


# ---------------------------------------------------------------- 球員名單 / 傷兵

def list_teams() -> list[dict]:
    data = http_get_json(f"{ESPN_BASE}/teams")
    teams = (((data.get("sports") or [{}])[0].get("leagues") or [{}])[0].get("teams")) or []
    return [{"id": str(t["team"]["id"]), "abbr": t["team"].get("abbreviation", ""),
             "name": t["team"].get("displayName", "")} for t in teams]


def parse_roster(roster: dict, team_abbr: str) -> list[dict]:
    rows = []
    for a in roster.get("athletes") or []:
        if not a.get("id"):
            continue
        rows.append({
            "player_id": str(a["id"]),
            "name": a.get("displayName") or a.get("fullName") or str(a["id"]),
            "team": team_abbr,
            "position": (a.get("position") or {}).get("abbreviation"),
            "headshot": (a.get("headshot") or {}).get("href"),
        })
    return rows


_ID_RE = re.compile(r"/id/(\d+)")


def parse_injuries(data: dict, team_abbr_by_name: dict[str, str]) -> list[dict]:
    """ESPN 傷兵資料裡的 athlete 沒有 id 欄位，要從球員頁連結解析。"""
    rows = []
    for team in data.get("injuries") or []:
        abbr = team_abbr_by_name.get(team.get("displayName", ""), "")
        for inj in team.get("injuries") or []:
            ath = inj.get("athlete") or {}
            pid = str(ath.get("id") or "")
            if not pid:
                for link in ath.get("links") or []:
                    m = _ID_RE.search(link.get("href", ""))
                    if m:
                        pid = m.group(1)
                        break
            if not pid:
                continue
            det = inj.get("details") or {}
            rows.append({
                "player_id": pid,
                "player_name": ath.get("displayName") or pid,
                "team": abbr,
                "status": inj.get("status") or "Unknown",
                "fantasy_status": (det.get("fantasyStatus") or {}).get("abbreviation"),
                "injury_type": det.get("type"),
                "return_date": det.get("returnDate") or "",
                "comment": inj.get("shortComment"),
                "reported_at": inj.get("date") or "",
            })
    return rows


# ---------------------------------------------------------------- Supabase

def _sb():
    url = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_KEY"]
    return url, {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}


def sb_upsert(table: str, rows: list[dict], on_conflict: str) -> None:
    url, headers = _sb()
    now = datetime.now(timezone.utc).isoformat()
    for r in rows:
        r["updated_at"] = now
    for i in range(0, len(rows), 500):
        resp = requests.post(
            f"{url}/rest/v1/{table}", params={"on_conflict": on_conflict},
            headers={**headers, "Prefer": "resolution=merge-duplicates,return=minimal"},
            data=json.dumps(rows[i:i + 500]), timeout=30,
        )
        if resp.status_code >= 300:
            raise RuntimeError(f"Supabase upsert {table} failed {resp.status_code}: {resp.text[:500]}")


def sb_rpc(fn: str, payload: dict):
    url, headers = _sb()
    resp = requests.post(f"{url}/rest/v1/rpc/{fn}", headers=headers, data=json.dumps(payload), timeout=30)
    if resp.status_code >= 300:
        raise RuntimeError(f"Supabase rpc {fn} failed {resp.status_code}: {resp.text[:500]}")
    return resp.json()


def upsert_stats(rows: list[dict]) -> None:
    sb_upsert("player_game_stats", rows, "game_id,player_id")


# ---------------------------------------------------------------- jobs

def target_dates(args) -> list[date]:
    if args.date:
        return [date.fromisoformat(args.date)]
    today_et = datetime.now(ET).date()
    # 最近 N 天（不含今天，因為今天的比賽通常還沒打完）
    return [today_et - timedelta(days=i) for i in range(args.days, 0, -1)]


def job_stats(args) -> None:
    total = 0
    for d in target_dates(args):
        games = list_games(d)
        done = [g for g in games if g["completed"]]
        print(f"[{d}] {len(games)} games, {len(done)} completed")
        day_rows: list[dict] = []
        for g in done:
            summary = http_get_json(f"{ESPN_BASE}/summary", {"event": g["id"]})
            rows = parse_summary(summary, g["id"], d)
            print(f"  {g['name']:<12} {len(rows)} players")
            day_rows.extend(rows)
            time.sleep(0.5)  # 對 ESPN 客氣一點
        for g in games:
            if not g["completed"]:
                print(f"  {g['name']:<12} skipped (state={g['state']}), 下次執行會再抓")
        if not day_rows:
            continue
        if args.dry_run:
            top = sorted(day_rows, key=lambda r: r["pts"], reverse=True)[:5]
            for r in top:
                print(f"    {r['player_name']:<24} {r['team']:<4} "
                      f"{r['pts']}pts {r['reb']}reb {r['ast']}ast  id={r['player_id']}")
        else:
            upsert_stats(day_rows)
        total += len(day_rows)
    print(f"Stats done. {total} player rows {'parsed' if args.dry_run else 'upserted'}.")


def job_players(args) -> None:
    rows: list[dict] = []
    for t in list_teams():
        roster = http_get_json(f"{ESPN_BASE}/teams/{t['id']}/roster")
        rows.extend(parse_roster(roster, t["abbr"]))
        time.sleep(0.3)
    print(f"Players: {len(rows)} on {len({r['team'] for r in rows})} teams")
    if rows and not args.dry_run:
        sb_upsert("players", rows, "player_id")


# ---------------------------------------------------------------- 2K 能力值（2kratings.com）

TEAM_SLUGS = {
    "atlanta-hawks": "ATL", "boston-celtics": "BOS", "brooklyn-nets": "BKN", "charlotte-hornets": "CHA",
    "chicago-bulls": "CHI", "cleveland-cavaliers": "CLE", "dallas-mavericks": "DAL", "denver-nuggets": "DEN",
    "detroit-pistons": "DET", "golden-state-warriors": "GS", "houston-rockets": "HOU", "indiana-pacers": "IND",
    "los-angeles-clippers": "LAC", "los-angeles-lakers": "LAL", "memphis-grizzlies": "MEM", "miami-heat": "MIA",
    "milwaukee-bucks": "MIL", "minnesota-timberwolves": "MIN", "new-orleans-pelicans": "NO", "new-york-knicks": "NY",
    "oklahoma-city-thunder": "OKC", "orlando-magic": "ORL", "philadelphia-76ers": "PHI", "phoenix-suns": "PHX",
    "portland-trail-blazers": "POR", "sacramento-kings": "SAC", "san-antonio-spurs": "SA", "toronto-raptors": "TOR",
    "utah-jazz": "UTAH", "washington-wizards": "WSH",
}
_POS = {"point-guard": "PG", "shooting-guard": "SG", "small-forward": "SF", "power-forward": "PF", "center": "C"}


def parse_2k_team(html_text: str, team_slug: str) -> list[dict]:
    """解析 2kratings.com 球隊頁的球員表格：名字、OVR、2K 位置。"""
    rows = []
    for seg in html_text.split("<tr ")[1:]:
        m_name = re.search(r'class="player-name" data-full="([^"]+)"', seg)
        m_ovr = re.search(r'<td data-sort="(\d+)">\s*<div class="rating-updated">', seg)
        if not m_name or not m_ovr:
            continue
        sub = seg.split("entry-subtext-font", 1)[-1].split(" | ", 1)[0]
        pos = [_POS[x] for x in re.findall(r'href="/lists/(point-guard|shooting-guard|small-forward|power-forward|center)"', sub)]
        rows.append({
            "source_name": html.unescape(m_name.group(1)).strip(),
            "team_slug": team_slug,
            "ovr": int(m_ovr.group(1)),
            "pos_2k": "/".join(pos[:2]) or None,
        })
    return rows


def job_ratings(args) -> None:
    snapshot = datetime.now(ET).date().isoformat()
    ua = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"}
    rows: list[dict] = []
    for slug in TEAM_SLUGS:
        r = requests.get(f"https://www.2kratings.com/teams/{slug}", headers=ua, timeout=30)
        r.raise_for_status()
        team_rows = parse_2k_team(r.text, slug)
        if not team_rows:
            raise RuntimeError(f"2kratings {slug}: 0 players parsed (page format changed?)")
        rows.extend(team_rows)
        time.sleep(0.5)
    tiers = {t: sum(1 for x in rows if lo <= x["ovr"] <= hi) for t, lo, hi in
             [("90+", 90, 99), ("85-89", 85, 89), ("80-84", 80, 84), ("<=79", 0, 79)]}
    print(f"2K ratings: {len(rows)} players, tiers {tiers}")
    if args.dry_run:
        return
    for r in rows:
        r["snapshot_date"] = snapshot
    url, headers = _sb()
    for i in range(0, len(rows), 500):
        resp = requests.post(f"{url}/rest/v1/rating_imports", params={"on_conflict": "snapshot_date,source_name,team_slug"},
                             headers={**headers, "Prefer": "resolution=merge-duplicates,return=minimal"},
                             data=json.dumps(rows[i:i + 500]), timeout=30)
        if resp.status_code >= 300:
            raise RuntimeError(f"rating_imports upsert failed {resp.status_code}: {resp.text[:300]}")
    result = sb_rpc("apply_ratings", {"p_snapshot": snapshot})
    print(f"  applied: {json.dumps(result, ensure_ascii=False)}")


def job_injuries(args) -> None:
    teams = {t["name"]: t["abbr"] for t in list_teams()}
    rows = parse_injuries(http_get_json(f"{ESPN_BASE}/injuries"), teams)
    print(f"Injuries: {len(rows)} players")
    if args.dry_run:
        for r in rows[:5]:
            print(f"    {r['player_name']:<24} {r['team']:<4} {r['status']}  id={r['player_id']}")
        return
    # 保險：ESPN 回傳空清單時不要把現有傷兵全部清掉
    if not rows:
        print("  ESPN 回傳 0 筆，略過更新")
        return
    print(f"  synced {sb_rpc('sync_injuries', {'p_rows': rows})} rows")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--job", choices=["stats", "players", "injuries", "ratings"], action="append",
                   help="要執行的工作，可重複指定；預設只跑 stats")
    p.add_argument("--date", help="美東日期 YYYY-MM-DD（stats）")
    p.add_argument("--days", type=int, default=2, help="往回抓幾天（stats，預設 2，可吸收數據修正）")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    for job in args.job or ["stats"]:
        {"stats": job_stats, "players": job_players, "injuries": job_injuries, "ratings": job_ratings}[job](args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
