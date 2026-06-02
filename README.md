# 餐車市集排班系統 · ZN Studio

為北部 20+ 據點、900+ 餐車設計的線上排班與管理平台。

## 📁 檔案結構

```
.
├── index.html          首頁（兩端入口）
├── liff.html           LIFF 餐車主端
├── admin.html          Admin 業主後台
├── vercel.json         Vercel 路由設定
└── README.md
```

## 🌐 路由

| 路徑 | 對應頁面 | 用途 |
|---|---|---|
| `/` | index.html | 首頁，兩端入口 |
| `/liff` | liff.html | LIFF 餐車主端（部署到 LIFF App endpoint） |
| `/admin` | admin.html | Admin 後台 |

## 🚀 Vercel 部署

### 選項 A：拖曳上傳（最快）

1. 登入 https://vercel.com（用 GitHub / Google 登入即可）
2. 點 `Add New...` → `Project`
3. 點 `Import from third-party Git Repository` 旁的 `Deploy without Git`
4. 把整個資料夾拖進去
5. 等 10 秒部署完成 → 拿到 `https://xxx.vercel.app` 網址

### 選項 B：CLI 部署

```bash
npm i -g vercel
cd vercel-deploy
vercel             # 第一次會問 project 名稱，建議 foodtruck-demo
vercel --prod      # 部署到正式環境
```

### 選項 C：GitHub 連動（適合持續更新）

1. 把整個資料夾 push 到 GitHub repo
2. Vercel 連動該 repo
3. 之後每次 git push 自動部署

## 🔌 環境模式

### Demo 模式（預設）
- 不打任何 webhook
- 純前端 mock 資料
- 適合給客戶試玩

### Real API 模式
- 加 query string：`?mode=real`
- 會打 n8n webhook（`https://nickleo9.zeabur.app/webhook/foodtruck-*`）
- 真實寫入 Google Sheets

## 📱 LINE LIFF 設定

部署到 Vercel 拿到網址後（例：`https://foodtruck-demo.vercel.app`）：

1. 登入 [LINE Developers Console](https://developers.line.biz/)
2. 在你的 Provider 下建立或選擇 Channel（Messaging API）
3. 進入 LIFF 分頁 → `Add`
4. 設定如下：
   - **LIFF app name**：餐車排班
   - **Size**：Full
   - **Endpoint URL**：`https://foodtruck-demo.vercel.app/liff`
   - **Scope**：勾 `profile`、`openid`
   - **Bot link feature**：On（綁定到 OA）
5. 拿到 `liffId`（格式 `1234567890-AbCdEfGh`）
6. 在 liff.html 內找到 LIFF SDK 初始化區塊填入

## 🛠 技術棧

- **前端**：純 HTML + CSS + Vanilla JS（無框架，方便維護）
- **後端**：n8n on Zeabur（已部署）
- **資料**：Google Sheets（n8n credential 已連）
- **通知**：LINE OA push API

## 📊 系統範圍

### LIFF 餐車主端
- 月曆網格 / 列表雙視圖（桌面 / 手機自動切換）
- 5 個場地、5 種時段制（整天場、午晚場、早晚市、夜市）
- 候補佇列 + 30 分鐘倒數自動遞補
- 信用分提示（< 3 天取消扣 5 點）
- 同日同時段衝突防呆
- 新增餐車（須經審核）
- 個人資料修改

### Admin 業主後台（9 頁 sidebar）
1. **即時總覽** - 今日排班 + KPI
2. **排班月曆** - 多場地總覽 grid
3. **待審核** - 新車申請 + 暱稱修改
4. **場地管理** - 5 個據點配置
5. **餐車總覽** - 912 台車輛
6. **特殊規則** - 黑名單
7. **包場管理** - 建立 / 刪除
8. **信用觀察** - < 80 分名單
9. **報表** - 月度數據

## 📞 聯絡

**Nick Chang**
- Email: nickleo051216@gmail.com
- Tel: 0932-684-051
- Web: https://portaly.cc/zn.studio
- Threads: [@nickai216](https://www.threads.com/@nickai216)
- LINE OA: https://lin.ee/Faz0doj
