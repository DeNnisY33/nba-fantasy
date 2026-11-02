# NBA 六人 Fantasy 聯盟

網址：https://dennisy33.github.io/nba-fantasy/

全部使用免費方案，費用 0 元。

```
ESPN（非官方 API）──▶ GitHub Actions ──▶ Supabase（Postgres）◀──▶ GitHub Pages 網頁
   比賽數據：每天 1 次                          計分、排名、換人、交易       讀取 + 有密碼保護的操作
   球員名單：每天 1 次
   傷兵名單：每 2 小時
```

## 聯盟規則（程式裡實際執行的）

| 項目 | 規則 |
|---|---|
| 陣容 | 每隊 12 人：10 位先發（算分）+ 2 位替補 |
| 日期 | 一律用美東日期；每週是週一到週日 |
| 換人 | 先發球員在傷兵名單上，才能跟替補互換；因傷換下的球員康復後可以換回先發 |
| 交易 | 雙方人數相同 → 對方接受 → 其他 4 人投票，**2 票同意**成交、3 票反對否決 |
| 生效 | 換人和交易都是**隔天（美東）**生效，當天的分數不受影響 |
| 換位置 | 交易換過去的球員，接手對方那位球員原本的先發 / 替補位置 |
| 密碼 | 每人一組；連續錯 5 次鎖 15 分鐘 |

## 管理員常用操作（Supabase → SQL Editor）

```sql
-- 改計分規則（整季自動重算）
update scoring_rules set weight = -2 where stat = 'tov';

-- 改交易需要的同意票數
update league_settings set value = '3' where key = 'trade_approvals_needed';

-- 重設某人的密碼
select admin_set_pin((select id from members where name = 'Dennis'), '新密碼');

-- 改玩家名字
update members set name = '新名字' where name = '舊名字';
```

計分規則可用的項目：`pts reb oreb dreb ast stl blk tov pf fgm fga fg3m fg3a ftm fta plus_minus double_double triple_double`

## 檔案

| 路徑 | 用途 |
|---|---|
| `supabase/schema.sql` | 001：比賽數據、計分規則、排名 |
| `supabase/migrations/002_lineups_trades.sql` | 先發 / 替補、傷兵、球員資料庫、每週分數、交易投票、密碼 |
| `supabase/migrations/003_contrib_view.sql` | 圖表用的球員貢獻統計 |
| `scripts/fetch_stats.py` | 抓 ESPN 數據：`--job stats / players / injuries` |
| `.github/workflows/daily-stats.yml` | 每天 台灣 16:17 / 日本 17:17：比賽數據 + 球員名單 + 傷兵 |
| `.github/workflows/injuries.yml` | 每 2 小時更新傷兵名單 |
| `docs/index.html` | 網頁：排行榜、圖表、球隊與傷兵、交易區 |
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
# 資料庫：在空的 Postgres 依序執行 schema.sql、002、003，再執行 tests/test_db.sql
```

## 需要注意的地方

- **ESPN API 是非官方的**，格式可能改變。Actions 失敗時 GitHub 會寄信通知。
- **Supabase 免費版閒置 7 天會暫停**。賽季中每天都有寫入，不會暫停；休賽期暫停的話到 Dashboard 按 Restore。
- **GitHub 公開 repo 60 天沒活動會停用排程**，workflow 裡的 `keepalive` 已處理。
- **排程不保證準時**，可能晚 10–30 分鐘。
- 密碼存在各自裝置的瀏覽器裡，換手機或清除瀏覽資料後要重新登入。
