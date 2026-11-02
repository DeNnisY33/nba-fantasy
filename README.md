# 看比賽囉：NBA 六人 Fantasy 聯盟

網址：https://dennisy33.github.io/nba-fantasy/

全部使用免費方案，費用 0 元。

```
ESPN（非官方 API）──▶ GitHub Actions ──▶ Supabase（Postgres）◀──▶ GitHub Pages 網頁
   比賽數據：每天 1 次                          計分、排名、換人、交易       讀取 + 有密碼保護的操作
   球員名單：每天 1 次
   傷兵名單：每 2 小時
```

## 規則

完整規則見 [RULES.md](RULES.md)（賽季中）與 [DRAFT.md](DRAFT.md)（選秀）。

## 管理員常用操作（Supabase → SQL Editor）

```sql
-- 揮棄：放掉 / 撿進（規則檢查：缺陣 3 人以上、能力值至少低 5；隔天生效）
select admin_waive((select id from members where name = 'Dennis'), '放掉的球員ID', '撿的球員ID');
-- 找球員 ID
select player_id, name, team, position from players where name ilike '%curry%';

-- 選秀匯入後檢查每隊是否符合規定（problems、draft_notes 要是空的）
select member_name, players, list_size, list_g, list_f, list_c, n90, n85, n80, problems, draft_notes from roster_check;

-- 選秀當天：先到 GitHub Actions 執行「2K ratings」更新能力值，確認後鎖定
update league_settings set value = 'true' where key = 'ratings_locked';

-- 改計分規則（整季自動重算）
update scoring_rules set weight = -2 where stat = 'tov';

-- 改其他設定（交易票數、揮棄門檻、能力值名額…）
select * from league_settings;
update league_settings set value = '3' where key = 'trade_approvals_needed';

-- 重設某人的密碼
select admin_set_pin((select id from members where name = 'Dennis'), '新密碼');
```

計分規則可用的項目：`pts reb oreb dreb ast stl blk tov pf fgm fga fg3m fg3a ftm fta plus_minus double_double triple_double team_win team_loss`

## 檔案

| 路徑 | 用途 |
|---|---|
| `supabase/schema.sql` | 001：比賽數據、計分規則、排名 |
| `supabase/migrations/002_lineups_trades.sql` | 先發 / 替補、傷兵、球員資料庫、每週分數、交易投票、密碼 |
| `supabase/migrations/003_contrib_view.sql` | 圖表用的球員貢獻統計 |
| `supabase/migrations/004_team_result.sql` | 球隊勝負加減分 |
| `supabase/migrations/005_ratings_autosub_waivers.sql` | 2K 能力值、十人名單自動遞補、交易限制 |
| `supabase/migrations/006_admin_waivers.sql` | 揮棄（管理員執行） |
| `scripts/fetch_stats.py` | 抓資料：`--job stats / players / injuries / ratings` |
| `.github/workflows/daily-stats.yml` | 每天 台灣 16:17 / 日本 17:17：比賽數據 + 球員名單 + 傷兵 |
| `.github/workflows/injuries.yml` | 每 2 小時更新傷兵名單 |
| `.github/workflows/ratings.yml` | 手動執行：從 2kratings.com 更新 2K 能力值 |
| `docs/index.html` | 網頁：排行榜、圖表、球隊與傷兵、自由球員、交易區 |
| `tests/` | 解析測試（`test_parse.py`）、資料庫整合測試（`test_db.sql`） |

## 手動更新

repo → **Actions** → *Daily NBA stats* 或 *Injury report* → **Run workflow**。
補抓舊資料：*Daily NBA stats* 的 `days` 填大一點的數字，例如 `14`。

## 本機測試

```bash
pip install -r requirements.txt
python tests/test_parse.py                                # 解析邏輯
python scripts/fetch_stats.py --dry-run --days 2          # 真的打 ESPN，但不寫資料庫
python scripts/fetch_stats.py --dry-run --job injuries
# 資料庫：在空的 Postgres 依序執行 schema.sql、002~006，再執行 tests/test_db.sql
```

## 需要注意的地方

- **ESPN API 是非官方的**，格式可能改變。Actions 失敗時 GitHub 會寄信通知。
- **Supabase 免費版閒置 7 天會暫停**。賽季中每天都有寫入，不會暫停；休賽期暫停的話到 Dashboard 按 Restore。
- **GitHub 公開 repo 60 天沒活動會停用排程**，workflow 裡的 `keepalive` 已處理。
- **排程不保證準時**，可能晚 10–30 分鐘。
- 密碼存在各自裝置的瀏覽器裡，換手機或清除瀏覽資料後要重新登入。
