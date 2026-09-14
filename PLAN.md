# MiniMax-Music3 on vast.ai — 部署規劃

## 目標

在 vast.ai 單卡 GPU instance 上部署 MiniMax-Music3 音樂生成模型，對外提供：

- `POST /v1/audio/speech` API（相容官方 sgl-omni contract）
- Suno 風格 Web UI（queue、library、waveform player）

## 決策記錄

| 項目 | 決定 | 理由 |
|---|---|---|
| 後端 | diffusers `ModularPipeline` 單卡 server | 24GB VRAM 即可（3090/4090 ~$0.3–0.6/hr）；官方 sgl-omni 參考配置是 H200，VRAM 下限未公布，成本與風險都高 |
| 前端 | adambenhassen/minimax-music-ui | 現成 GHCR image，講同一個 `/v1/audio/speech` contract，支援 SSE 進度 |
| 量化 | 不用 GGUF | minimaxmusic.cpp 是自訂 API，且社區量化非官方驗證；24GB 跑原生 BF16 沒有量化需求 |

## 參考項目（調查結果）

| 項目 | 用途 |
|---|---|
| [MiniMaxAI/MiniMax-Music3](https://huggingface.co/MiniMaxAI/MiniMax-Music3) | 官方權重 57.4GB；model card 有 diffusers 用法與 pinned commit |
| [platform.minimax.io/docs/guides/local-deploy-music-3](https://platform.minimax.io/docs/guides/local-deploy-music-3) | 官方部署指南：pinned model rev `fbdf52fbaaca799592917417eb05f1899f1255ec`、request contract、安全建議 |
| [adambenhassen/minimax-music-ui](https://github.com/adambenhassen/minimax-music-ui) | **主要參考**。`inference/server.py` = 單卡 FastAPI server（~314 行，含 SSE streaming、`--api-key`、`--offload`）；UI 有 GHCR prebuilt image `ghcr.io/adambenhassen/minimax-music-ui` |
| [ServeurpersoCom/minimaxmusic.cpp](https://github.com/ServeurpersoCom/minimaxmusic.cpp) | GGUF 替代路線（6.5–29GB VRAM），本計畫不採用 |
| [vast-ai/base-image](https://github.com/vast-ai/base-image) | vast.ai 官方 base image，支援 `provisioning.yaml` / `PROVISIONING_SCRIPT` |
| [docs.vast.ai/creating-a-custom-template](https://docs.vast.ai/creating-a-custom-template) | 自訂 template：docker image + env vars + port 映射 |

## 架構

```
internet
   │  vast.ai Caddy：TLS + auth（OPEN_BUTTON_TOKEN / WEB_PASSWORD）
   │  PORTAL_CONFIG: localhost:8787:18787:/:Music UI
   ▼
:8787 (external) → Caddy → :18787 minimax-music-ui (Express, 127.0.0.1)
   │  MUSIC_API=http://127.0.0.1:7862 + Bearer MUSIC_API_KEY
   ▼
:7862  inference server.py (FastAPI + diffusers)  ── 只綁 127.0.0.1
   │  ModularPipeline.from_pretrained(repo, revision=fbdf52f)
   ▼
GPU 0  BF16, ~24GB VRAM
```

- vast.ai base image 內建 Caddy + Instance Portal：`PORTAL_CONFIG` 外部 port ≠ 內部 port 時自動反代 + TLS + auth → **Open Question 已解：用 Portal/Caddy，不自架**。
- UI 與 inference 都只綁 127.0.0.1；對外唯一入口是 Caddy 代理的 8787。
- `MUSIC_API_KEY` 為 inference 層 auth（defense in depth），UI 自動帶 `Authorization: Bearer`。
- 服務由 Supervisor 管理（autorestart），log 進 vast.ai logging（`/dev/stdout`）。

## 硬體需求（vast.ai 篩選條件）

| 項目 | 需求 |
| Disk | ≥80GB（diffusers 只需 ~28.5GB 權重 + venv + HF cache + tracks 輸出） |
| Image | `vastai/base-image` + `PROVISIONING_SCRIPT`（見下「Image 策略」） |

## Image 策略

調查結果：**inference 端無現成 image**；UI 端有 `ghcr.io/adambenhassen/minimax-music-ui:<tag>`。

- **主路線（採用）**：`vastai/base-image` + `PROVISIONING_SCRIPT` env 指向 repo 的 `onstart.sh`。開機時 pip install（全是 wheel，無編譯）+ `hf download` + 啟動。vast.ai disk 跨 stop/start 保留 → 安裝成本只付一次。
- **備選**：自建 all-in-one Dockerfile 推 GHCR。只在需要頻繁開新 instance 時才值得（省幾分鐘冷啟動）。
- sgl-omni 有 `hongccc/sglang-omni:dev` image 但 tag 跟 main 漂、且該路線需 80GB 卡，不採用。
## 版本鎖定（reproducible）

| 元件 | Pin |
|---|---|
| Model | `MiniMaxAI/MiniMax-Music3` rev `fbdf52fbaaca799592917417eb05f1899f1255ec` |
| diffusers | commit `dafe3733fcfdbf3c48915fe77be3aef65b5d6a2d`（PR #14456 未合併，**不可**裝 main） |
| torch | 依 diffusers 相容版本，build 時驗證 `torch.cuda.is_available()` |
| UI image | `ghcr.io/adambenhassen/minimax-music-ui:<tag>`（不用 `latest`） |
| inference server | vendor `inference/server.py` 進本 repo（上游 requirements 用 `diffusers@main`，不鎖版，不能直接依賴） |

## 專案檔案規劃

```
minimax-music-gen/
├── PLAN.md                  ← 本檔
├── Dockerfile               ← 備選：all-in-one image（需要頻繁開新 instance 才做）
├── inference/
│   ├── server.py            ← vendored from adambenhassen/minimax-music-ui（附 LICENSE 註記）
│   └── requirements.txt     ← pinned deps
├── scripts/
│   ├── onstart.sh           ← vast.ai onstart：等 GPU → 啟動 inference → 啟動 UI
│   └── smoke_test.sh        ← /health → /v1/models → 10s 生成 → 驗證 WAV header
├── docker-compose.yml       ← 本地/單機驗證用（GPU passthrough）
└── .env.example             ← HF_TOKEN, MUSIC_API_KEY
```

## vast.ai 部署流程

1. Repo push GitHub → vast.ai template 設 `PROVISIONING_SCRIPT` 指向 `onstart.sh` 的 raw URL
2. vast.ai 建立 template：`vastai/base-image`、`-p 8787:8787`、env `HF_TOKEN` / `MUSIC_API_KEY` / `HF_HOME=/workspace/hf`
3. 選 instance：24GB+ VRAM、80GB+ disk、可靠網路（首次要抓 ~28.5GB）
4. 首次啟動：`hf download` pinned revision（`--include` 只抓 diffusers 需要的 7 個 subfolder，~28.5GB；跳過 `qwen_7B/` 訓練 checkpoint 18.5GB 和 root `.pth` sgl-omni 檔 10.3GB）→ load pipeline → `/health` 200
5. 驗證：`smoke_test.sh` 產 10 秒 clip，檢查 WAV = stereo/16-bit
6. 對外：Instance Portal tunnel 或 Caddy，**不裸開 port**

## API contract（與官方一致）

```
POST /v1/audio/speech
  input          歌詞，[Verse]/[Chorus] 等 tag 必須獨立一行（同行歌詞會被靜默丟棄）
  instructions   音樂描述（genre/BPM/key/vocal/arrangement）
  seed           固定 seed → byte-identical 輸出；省略 = 隨機，實際值從 X-Seed header 取回
  max_new_tokens 25fps frame 數；750=30s，上限 9000=360s（模型驗證範圍 7500=5min）
  stream         false=阻塞回 WAV；true=SSE 進度+PCM（本 server 擴充，sgl-omni 沒有）
→ 44.1kHz stereo 16-bit WAV（注意：官方 sgl-omni 是 32kHz，diffusers pipeline 輸出不同）
```

## 風險與注意事項

- **diffusers PR 未合併**：API 可能變動 → 必須 pin commit，升級要重測。
- **首次冷啟動慢**：57GB 下載 + pipeline load；`HF_HOME` 放 workspace disk 讓重開免重抓（vast.ai instance 停止/啟動保留 disk，destroy 才清掉）。
- **授權**：MiniMax-Music3 Community License 有商業營收門檻與 AUP；對外提供服務前需確認條款。
- **並發**：server 一次只跑一個 job（FIFO queue）；CFG 使 AR 階段每 request 佔兩倍 KV cache，不要調大並發。
- **成本**：3090 ~$0.3/hr 閒置也計費；不用時 stop instance（保留 disk）而非 destroy。
- **輸出差異**：diffusers 出 44.1kHz、sgl-omni 出 32kHz；client 端不要寫死 sample rate，從 WAV header 讀。

## 里程碑

1. **M1 本地驗證**：docker compose 起 inference + UI，curl 產 10s WAV 成功（需本機或暫租 GPU）
2. **M2 vast.ai 單次部署**：手動開 instance + onstart script，smoke test 通過
3. **M3 固化**：image push registry + template 文件化，一鍵重開

## M2 部署記錄（2026-09-13，instance 50900664，HK RTX 3090 $0.129/h）

### 已完成
- Instance 建立 + 完整 boot sequence 跑通（見下方坑 1）
- Provisioning 全自動：deps install → 27GB 權重下載（~15min，HK 機器網速正常）→ UI build → Supervisor 註冊
- `music-inference` RUNNING，`/health` 回 `{"status":"ready","capabilities":["stream"]}`，`/v1/models` 正常
- Caddy + Portal 修復後 RUNNING，`/etc/portal.yaml` 正確生成（8787→18787 Music UI）
- Auth 檢查通過（無 key → 401）

### 遇到的坑（已修，已 commit）
1. **SSH launch mode 不跑完整 boot**：`--ssh` 模式用精簡 `/.launch`，不執行 `/etc/vast_boot.d/*`（無 supervisor/caddy/provisioning）。解法：`--onstart-cmd 'exec /opt/instance-tools/bin/boot_default.sh'`。
2. **`@vastai-automatic-tag` 解析成裸 CUDA image**：第一次建立時拿到無 instance-tools 的 image。解法：明確指定 `vastai/pytorch:cuda-12.8.1-auto`。
3. **`PORTAL_CONFIG` 的 `|` 被 `--env` 解析截斷**：env 沒進容器 → portal.yaml 空 → caddy FATAL。解法：onstart.sh 直接寫 `/etc/environment` + 重啟 caddy（caddy_config_manager 會從 env 重新生成 portal.yaml）。
4. **`DEPLOY_REF` 未定義**：`set -u` 下直接掛。已修。
5. **`npm: command not found`**：nvm 不在 provisioning/supervisor 的 PATH。解法：onstart.sh 和 music-ui.sh wrapper 都 source `/opt/nvm/nvm.sh`。
6. **`music-ui.sh` 缺 `chmod +x`**：supervisor 報 "not executable"。已修。
7. **smoke test 401 檢查送 `{}`**：pydantic 422 先於 auth。改送合法 body。

### 未完成 / 待驗證
- **CUDA OOM @ 3090（23.56GB）**：vocoder 階段爆記憶體（22.44GB 已佔，需再 130MB）。已加 `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` 到 instance wrapper 並重啟，但**測試生成途中 instance 被 stop，結果未知**。
  - 下次 start 後第一件事：重跑 10s 生成測試
  - 若仍 OOM → `OFFLOAD=1`（CPU offload ~22GB，變慢）
  - 再不行 → 換 4090（同價位 24GB 但較快）或 48GB 卡
  - 注意：onstart.sh 的 inference wrapper **還沒**寫入 `PYTORCH_CUDA_ALLOC_CONF`——只改在 instance 上的 `/opt/supervisor-scripts/music-inference.sh`。重開機後 onstart 不會重跑（`/.provisioning_complete` 未設但 script 有冪等檢查），wrapper 是上次生成的舊版 → **下次啟動前需手動確認 wrapper 內容或重跑 onstart**
- UI 端到端（瀏覽器開 Portal → Music UI → 生成試聽）未驗證
- 外部存取（Caddy 8787 + auth）未驗證

### 成本記錄
- 本次測試約 1 小時 ≈ $0.13；instance 已 **destroy**（權重需重抓）
- 下次部署：重跑完整 provisioning（~20-30min 冷啟動）

## M2 部署記錄 #2（2026-09-14，目標 RTX 5090，中斷）

### 嘗試過的 offer（全部已 destroy，無殘留）
| Offer | 地區 | $/h | 結果 |
|---|---|---|---|
| 49700289 | 加拿大 QC | 0.428 | deverified — CDI device injection 失敗，container 拿不到 GPU |
| 32984236 | 加拿大 BC | 0.413 | deverified — 同樣 CDI 錯誤 |
| 47347947 | US | 0.473 | verified — create 回 `success:false` 但實際建了兩台（51028042/51028105），砍一台後另一台卡在 loading，用戶中斷 |

### 發現
- **deverified 5090 普遍有 CDI 問題**：`failed to inject CDI devices .../gpu=N: unknown`，host 端 NVIDIA Container Toolkit 設定壞了，租戶無法修。<$0.5 的 5090 幾乎全是 deverified，這個價位風險高。
- **亞洲 <$0.5 的 5090 只有 CN 機器**（北京/四川 $0.433，verified），但 HF 權重下載有被牆風險。TW 最便宜 verified 是 $0.601（offer 50986657）。
- `create instance` 回 `success:false` 不代表沒建——51028042 就是這樣產生的孤兒，要 `show instances` 確認。

### 下次部署選項
1. **TW 50986657（$0.601，verified，925Mbps 對稱）**— 最穩，價格可接受
2. **CN 50041177/50556739（$0.433，verified）**— 便宜但需驗證 HF 連線，可能要 `HF_ENDPOINT=https://hf-mirror.com`
3. **US 47347947（$0.473，verified）**— 非 CN 最便宜 verified，網速普通（500/423Mbps）

### 成本記錄
- 本次 3 台 instance 各存活 <10min，估計 <$0.15；全部 destroy，無殘留
- 帳戶餘額 $0（需充值才能下次部署）
