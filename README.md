# NBA 六人 Fantasy（方案 A：GitHub Actions + Supabase + 靜態網頁）

全部使用免費方案，費用 0 元。

```
ESPN（非官方 API）──▶ GitHub Actions（每天一次跑 Python）──▶ Supabase（Postgres）
                                                                   │
                                     GitHub Pages / Vercel 靜態網頁 ◀┘（唯讀）
```

## 檔案

| 路徑 | 用途 |
|---|---|
| `supabase/schema.sql` | 資料表、計分 view、權限。執行一次即可，可重複執行 |
| `supabase/seed_example.sql` | 建立 6 位玩家與選秀陣容的範例 |
| `scripts/fetch_stats.py` | 抓 ESPN 當日 box score，寫入 Supabase |
| `.github/workflows/daily-stats.yml` | 排程：每天一次，台灣 16:17 / 日本 17:17（同時重抓前一天，吸收數據修正） |
| `docs/index.html` | 排行榜頁面（沒填設定時會顯示示範資料） |
| `tests/test_parse.py` | 解析邏輯的離線測試 |

## 設定步驟（約 20 分鐘）

### 1. 建立 Supabase 專案
1. 到 supabase.com 註冊並建立新專案（Free plan，不需要信用卡）。
2. 左側 **SQL Editor** → 貼上 `supabase/schema.sql` 全部內容 → Run。
3. 修改 `supabase/seed_example.sql` 裡的玩家名字與球員，再到 SQL Editor 執行。
   - 球員 ID 從 ESPN 球員頁網址取得：`espn.com/nba/player/_/id/3112335/nikola-jokic` → `3112335`
   - 也可以先在本機跑 `python scripts/fetch_stats.py --dry-run --days 3`，輸出會列出球員名字和 ID。
4. **Project Settings → API**，記下：
   - `Project URL`
   - `anon public` key（給前端）
   - `service_role` key（給 GitHub Actions，**絕對不要放到前端或 commit 進 repo**）

### 2. 建立 GitHub repo
1. 把整個資料夾推到一個新的 GitHub repo（公開或私人都可以，公開的 Actions 分鐘數無上限）。
2. repo → **Settings → Secrets and variables → Actions → New repository secret**，新增兩個：
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_KEY`（填 service_role key）
3. repo → **Actions** 分頁 → 選 *Daily NBA stats* → **Run workflow**，手動跑一次確認成功。
   - 想補抓開季以來的資料：`days` 填 `14` 之類的數字。

### 3. 發布前端
1. 打開 `docs/index.html`，在 `<script>` 開頭的 `CONFIG` 填入 Project URL 和 **anon** key，commit 推上去。
2. repo → **Settings → Pages** → Source 選 *Deploy from a branch*，分支選 `main`、資料夾選 `/docs`。
3. 幾分鐘後網址會出現在同一頁，分享給大家即可。

## 改計分規則

在 Supabase **Table Editor → scoring_rules** 直接改 `weight`，或新增一列。整季分數會立刻依新規則重算，不用改程式、不用重抓資料。

可用的項目：`pts reb oreb dreb ast stl blk tov pf fgm fga fg3m fg3a ftm fta plus_minus double_double triple_double`

範例：失誤扣 2 分 → 把 `tov` 改成 `-2`；大三元加 10 分 → `triple_double` 改成 `10`。

如果之後規則需要更複雜的邏輯（例如每天只取前 N 名球員、分組對戰），改 `schema.sql` 裡的 view 即可。

## 換人 / 交易

在 `rosters` 把舊球員那筆填上 `end_date`，再新增一筆新球員並設定 `start_date`。歷史分數不會被影響。`seed_example.sql` 最下面有範例。

## 本機測試

```bash
pip install -r requirements.txt
python tests/test_parse.py                         # 解析邏輯測試
python scripts/fetch_stats.py --dry-run --days 2   # 真的打 ESPN，但不寫資料庫
```

## 需要注意的地方

- **ESPN API 是非官方的**，沒有文件，格式可能改變。Actions 失敗時 GitHub 會寄信通知你，通常是解析的欄位變了，修 `parse_summary` 即可。
- **比賽日是美東日期**。台灣早上開打的比賽，會算在美國的前一天。
- **Supabase 免費版閒置 7 天會暫停**。賽季中每天都有寫入，不會暫停；休賽期暫停的話，到 Dashboard 按 Restore 即可。
- **GitHub 公開 repo 60 天沒活動會停用排程**。workflow 裡的 `keepalive` job 已經處理。
- **排程不保證準時**，可能晚 10–30 分鐘，對每日結算沒有影響。
