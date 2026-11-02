"""離線測試：用模擬的 ESPN summary 結構驗證解析邏輯。執行：python tests/test_parse.py"""
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from fetch_stats import parse_summary  # noqa: E402

LABELS = ["MIN", "FG", "3PT", "FT", "OREB", "DREB", "REB", "AST", "STL", "BLK", "TO", "PF", "+/-", "PTS"]

SAMPLE = {
    "boxscore": {
        "players": [
            {
                "team": {"abbreviation": "DEN"},
                "statistics": [{
                    "labels": LABELS,
                    "athletes": [
                        {"athlete": {"id": "3112335", "displayName": "Nikola Jokic"},
                         "stats": ["36", "12-19", "2-4", "6-7", "3", "11", "14", "11", "2", "1", "4", "2", "+9", "32"]},
                        {"athlete": {"id": "999", "displayName": "Bench Guy"},
                         "didNotPlay": True, "reason": "COACH'S DECISION", "stats": []},
                    ],
                }],
            },
            {
                "team": {"abbreviation": "LAL"},
                "statistics": [{
                    "names": LABELS,  # 舊格式用 names
                    "athletes": [
                        {"athlete": {"id": "3945274", "displayName": "Luka Doncic"},
                         "stats": ["38:30", "10-22", "4-11", "5-6", "1", "7", "8", "9", "1", "0", "5", "3", "-9", "29"]},
                    ],
                }],
            },
        ]
    }
}


def main():
    rows = parse_summary(SAMPLE, "401700001", date(2026, 11, 1))
    by = {r["player_id"]: r for r in rows}
    assert len(rows) == 3, rows

    j = by["3112335"]
    assert (j["team"], j["opponent"]) == ("DEN", "LAL")
    assert (j["pts"], j["reb"], j["ast"], j["stl"], j["blk"], j["tov"]) == (32, 14, 11, 2, 1, 4)
    assert (j["fgm"], j["fga"], j["fg3m"], j["fg3a"], j["ftm"], j["fta"]) == (12, 19, 2, 4, 6, 7)
    assert j["plus_minus"] == 9 and j["minutes"] == 36 and not j["did_not_play"]

    assert by["999"]["did_not_play"] and by["999"]["pts"] == 0

    l = by["3945274"]
    assert l["minutes"] == 38.5 and l["plus_minus"] == -9 and l["pts"] == 29 and l["opponent"] == "DEN"

    print("parse_summary (synthetic): all checks passed")

    # 真實 ESPN 資料：2026-11-01 TOR @ LAL（欄位順序與上面的模擬資料不同）
    import json
    real = json.loads((Path(__file__).parent / "fixtures" / "espn_20261101_TOR_LAL.json").read_text())
    rows = parse_summary(real, "401909906", date(2026, 11, 1))
    by = {r["player_id"]: r for r in rows}
    assert len(rows) == 26
    l = by["3945274"]  # Luka Doncic
    assert (l["pts"], l["reb"], l["ast"], l["stl"], l["blk"], l["tov"]) == (45, 15, 6, 5, 1, 7)
    assert (l["fgm"], l["fga"], l["fg3m"], l["fg3a"], l["ftm"], l["fta"]) == (12, 23, 8, 12, 13, 13)
    assert (l["team"], l["opponent"], l["plus_minus"]) == ("LAL", "TOR", 27)
    assert by["3155535"]["did_not_play"]  # Kevon Looney DNP
    for r in rows:
        assert r["reb"] == r["oreb"] + r["dreb"], r
        assert r["did_not_play"] or r["pts"] == 2 * r["fgm"] + r["fg3m"] + r["ftm"], r
    assert all(r["team_won"] is None for r in rows), "no header → unknown result"
    # 勝負：結構取自同一場的 ESPN header（LAL 131 : TOR 125）
    real["header"] = {"competitions": [{"competitors": [
        {"homeAway": "home", "winner": True, "score": "131", "team": {"abbreviation": "LAL"}},
        {"homeAway": "away", "winner": False, "score": "125", "team": {"abbreviation": "TOR"}}]}]}
    rows = parse_summary(real, "401909906", date(2026, 11, 1))
    assert all(r["team_won"] is (r["team"] == "LAL") for r in rows), "LAL won, TOR lost"
    print("parse_summary (real ESPN 2026-11-01): all checks passed")

    # 傷兵：結構取自 2026-11-02 的 ESPN 回應（athlete 沒有 id，要從連結解析）
    from fetch_stats import parse_injuries, parse_roster
    inj = {"injuries": [{"id": "1", "displayName": "Atlanta Hawks", "injuries": [
        {"status": "Day-To-Day", "date": "2026-11-01T22:28Z",
         "shortComment": "Johnson (ankle) is questionable to play Monday.",
         "athlete": {"displayName": "Jalen Johnson",
                     "links": [{"href": "https://www.espn.com/nba/player/_/id/4701230/jalen-johnson"}]},
         "details": {"fantasyStatus": {"abbreviation": "GTD"}, "type": "Ankle", "returnDate": "2026-11-02"}},
        {"status": "Out", "athlete": {"displayName": "No Link Guy", "links": []}, "details": {}},
    ]}]}
    rows = parse_injuries(inj, {"Atlanta Hawks": "ATL"})
    assert len(rows) == 1, rows
    r = rows[0]
    assert (r["player_id"], r["team"], r["status"], r["fantasy_status"], r["injury_type"], r["return_date"]) == \
        ("4701230", "ATL", "Day-To-Day", "GTD", "Ankle", "2026-11-02"), r

    ros = {"athletes": [{"id": "3945274", "displayName": "Luka Doncic", "position": {"abbreviation": "G"},
                         "headshot": {"href": "https://a.espncdn.com/i/headshots/nba/players/full/3945274.png"}}]}
    pr = parse_roster(ros, "LAL")
    assert pr == [{"player_id": "3945274", "name": "Luka Doncic", "team": "LAL", "position": "G",
                   "headshot": "https://a.espncdn.com/i/headshots/nba/players/full/3945274.png"}], pr
    print("parse_injuries / parse_roster: all checks passed")


if __name__ == "__main__":
    main()
