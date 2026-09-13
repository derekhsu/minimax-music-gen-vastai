# SPEC — MiniMax-Music3 on vast.ai

版本：v1（draft，待 review）
日期：2026-09-13

## Problem Statement

需要在雲端 GPU 上自架 MiniMax-Music3 音樂生成服務，提供可程式化呼叫的 API 與人工操作的 Web UI。本機（Apple M4）無 CUDA，無法跑此模型（模型明確要求 CUDA）；MiniMax 官方 API 無音樂生成端點（`server.py` 無 `/v1/music_generation`，mmx CLI 已移除 music）。因此選擇 vast.ai 按需租用 GPU 自架，成本可控、隨用隨停。

## Goals

1. 在 vast.ai 單卡 24GB instance 上跑起 MiniMax-Music3 inference，提供 `POST /v1/audio/speech`（相容官方 sgl-omni contract）。
2. 提供 Web UI 供人工生成/試聽/管理曲目，與 API 共用同一後端。
3. 部署可重現：所有版本 pin 死，新 instance 從零到可用不需人工介入（provisioning script 全自動）。
4. 成本可控：單次生成成本 ≈ instance 時租 × 生成耗時；閒置可 stop 保留 disk，重開免重抓權重。
5. 安全：對外只暴露一個帶 auth 的入口，inference port 不直接公開。

## Non-Goals

- **不做多副本/水平擴展**：單 instance、單 GPU、FIFO queue 一次一個 job。流量成長是 v2 問題。
- **不做 sgl-omni 路線**：官方參考配置 H200（80GB+），vast.ai 時租 $1.5–3/hr，VRAM 下限未公布。diffusers 單卡已夠用。
- **不做 GGUF/minimaxmusic.cpp 路線**：自訂 API 不相容官方 contract，社區量化非官方驗證。
- **不做 ComfyUI 路線**：純 API 用途下 moving parts 最多，無收益。
- **不自建 Docker image**：`vastai/base-image` + `PROVISIONING_SCRIPT` 已足夠；需要頻繁開新 instance 時再補（P2）。
- **不做 streaming 生成給終端使用者**：SSE stream 是 server↔UI 間的內部能力，不對外承諾。
- **不做歌詞/caption 生成輔助**：上游有 `music-caption-rewriter` skill，但那是 client 端的事，不在本服務範圍。

## User Stories

- As a **呼叫方（程式/agent）**，我想 POST 歌詞+風格描述到 `/v1/audio/speech`，拿回 WAV 檔，以便整合進其他 pipeline。
- As a **人工使用者**，我想在瀏覽器寫 style prompt + 歌詞、排隊多個 take、試聽與下載，以便快速迭代音樂方向。
- As a **維運者（自己）**，我想 instance 重開後服務自動恢復（權重已在 disk 上），以便隨用隨停控制成本。
- As a **維運者**，我想用固定 seed 重現同一首歌，以便除錯與比較 prompt 效果。

## Requirements

### P0 — Must Have

| # | 需求 | 驗收條件 |
|---|---|---|
| R1 | vast.ai instance 開機後全自動完成部署：裝依賴 → 下載權重 → 啟動服務 | 新 instance 從建立到 `/health` 回 200 無需人工介入；`PROVISIONING_SCRIPT` 指向 repo 內 `onstart.sh` |
| R2 | inference server 提供官方 contract | `POST /v1/audio/speech` 接受 `input`/`instructions`/`seed`/`max_new_tokens`/`response_format=wav`/`stream=false`，回 WAV；`GET /v1/models`、`GET /health` 可用 |
| R3 | 只下載必要權重 | `hf download --include` 只抓 7 個 subfolder（~28.5GB），跳過 `qwen_7B/`（18.5GB）與 root `.pth`（10.3GB） |
| R4 | Web UI 可用 | 瀏覽器開 UI → 建立 track → 生成完成 → 可播放可下載；UI 指向 `http://127.0.0.1:7862` |
| R5 | 對外單一入口 + auth | 只開 UI port（8787）；inference（7862）只綁 127.0.0.1；對外經 Instance Portal 或 basic auth，不裸開 |
| R6 | 版本鎖定 | model rev `fbdf52f…`、diffusers commit `dafe3733…`、UI image tag 全部 pin 死，文件記錄 |
| R7 | 權重與資料持久化 | `HF_HOME` 與 UI `DATA_DIR` 放 instance disk；stop → start 後不需重抓權重、library 保留 |
| R8 | smoke test | `smoke_test.sh`：`/health` 200 → `/v1/models` 列出模型 → 生成 10s clip → WAV header 驗證 stereo/16-bit |

### P1 — Nice to Have

| # | 需求 | 驗收條件 |
|---|---|---|
| R9 | SSE 進度串流 | UI 顯示真實進度（vendored server.py 已內建 `stream:true` 擴充） |
| R10 | `--offload` 低 VRAM 模式 | env flag 可切換，~22GB VRAM 可跑（速度變慢可接受） |
| R11 | API key 驗證 | inference `--api-key` + UI `MUSIC_API_KEY`，錯誤 key 回 401 |

### P2 — Future

- 自建 all-in-one Docker image 推 GHCR（縮短新 instance 冷啟動）
- API gateway 層（rate limit、request log、多實例導流）
- sgl-omni 路線評估（若未來需要高並發或官方效能）
- vast.ai serverless endpoint（若流量模式適合）

## 技術決策（已定）

| 項目 | 決定 | 理由 |
|---|---|---|
| 後端 | diffusers `ModularPipeline`，vendor `inference/server.py`（源自 adambenhassen/minimax-music-ui，MIT） | 單卡 24GB 可跑；上游 requirements 裝 `diffusers@main` 不鎖版，必須 vendor + 自 pin |
| 前端 | `ghcr.io/adambenhassen/minimax-music-ui:<tag>` 現成 image | 講同一個 contract，含 queue/library/player |
| 部署 | `vastai/base-image` + `PROVISIONING_SCRIPT` → `onstart.sh` | 依賴全 wheel 無編譯；disk 跨 stop/start 保留，安裝成本只付一次 |
| GPU | 1× ≥24GB（RTX 3090/4090/A5000/L40S） | ~$0.3–0.6/hr；`--offload` 可 ~22GB |
| Disk | ≥80GB | 權重 28.5GB + venv + HF cache + tracks |
| RAM | ≥32GB | offload 模式需要更多 host RAM |

## API Contract（與官方一致）

```
POST /v1/audio/speech
  input          歌詞；[Verse]/[Chorus] 等 tag 必須獨立一行（同行歌詞會被靜默丟棄）
  instructions   音樂描述（genre/BPM/key/vocal/arrangement）
  seed           固定 → byte-identical；省略 = 隨機，實際值從 X-Seed header 取回
  max_new_tokens 25fps frame 數；750=30s，上限 9000=360s（模型驗證範圍 7500=5min）
  stream         false=阻塞回 WAV；true=SSE（本 server 擴充）
→ 44.1kHz stereo 16-bit WAV（注意：官方 sgl-omni 是 32kHz，client 從 WAV header 讀 sample rate）
```

## 檔案結構

```
minimax-music-gen/
├── SPEC.md                  ← 本檔
├── PLAN.md                  ← 部署細節與調查記錄（how）
├── inference/
│   ├── server.py            ← vendored（附 MIT LICENSE 註記）
│   └── requirements.txt     ← pinned deps
├── scripts/
│   ├── onstart.sh           ← vast.ai provisioning：裝依賴→抓權重→啟動兩服務
│   └── smoke_test.sh        ← R8 驗收腳本
├── docker-compose.yml       ← 本地/單機驗證（GPU passthrough）
└── .env.example             ← HF_TOKEN, MUSIC_API_KEY
```

## Success Metrics

| 指標 | 目標 |
|---|---|
| 冷啟動（新 instance → `/health` 200） | < 30 min（含 28.5GB 下載） |
| 熱啟動（stop → start → ready） | < 5 min |
| 30s clip 生成時間 | < 90s（~3× realtime，3090 參考值） |
| smoke test | `ALL CHECKS PASSED` |
| 單次生成成本 | < $0.02/30s clip（3090 @ ~$0.4/hr） |

## 風險

| 風險 | 緩解 |
|---|---|
| diffusers PR #14456 未合併，API 可能變動 | pin commit `dafe3733`；升級需重測 |
| 上游 `server.py` 更新時 vendored 副本漂移 | 檔頭註記來源 commit；升級為顯式動作 |
| MiniMax-Music3 Community License 商業營收門檻 | 對外提供服務前確認條款（見 Open Questions） |
| 並發：server 一次一個 job；CFG 使 AR 階段每 request 佔 2× KV cache | 不調並發；文件註明 |
| vast.ai 閒置計費 | 不用時 stop（保留 disk）而非 destroy |

## Open Questions

| 問題 | 待誰回答 | 阻塞？ |
|---|---|---|
| ~~對外暴露方式~~ | **已定**：vast.ai base image 內建 Caddy + Instance Portal；`PORTAL_CONFIG` 外部≠內部 port 即自動 TLS+auth | — |
| 授權：本服務是否構成 Community License 的商業使用門檻？ | 使用者（提供給第三方前需確認） | 僅對外收費時阻塞 |
| UI image 要 pin 哪個 tag？ | 實作時查 GHCR 最新 release | 否 |
| vast.ai 上 3090 vs 4090 實際生成速度？ | M2 部署後實測 | 否 |

## 里程碑

| # | 內容 | 驗收 |
|---|---|---|
| M1 | 檔案就緒：vendored server.py + requirements + onstart.sh + smoke_test.sh + compose | 本地 code review 通過；compose 可在有 GPU 的機器起服務 |
| M2 | vast.ai 首次部署：template + instance + provisioning 全自動 | smoke test `ALL CHECKS PASSED`；UI 可生成試聽 |
| M3 | 固化：stop/start 驗證持久化、成本記錄、文件補實測數據 | 熱啟動 < 5min；PLAN.md 補實測速度/成本 |
