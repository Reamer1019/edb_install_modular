# edb_install_modular.sh

EDB Postgres Advanced Server 標準安裝程序的模組化版本。把原本線性、由上而下執行一次的安裝文件，改寫成可以「單一步驟獨立選取執行」的互動式文字面板，每個步驟對應原文件的一個編號小節，可以單獨重跑、整章跑，也可以一次全部跑完。

## 適用範圍與前提假設

- 作業系統：RHEL 8、RHEL 9（或相容的 Rocky Linux / AlmaLinux 8/9），以 systemd 作為 init 系統。
- 部署架構：單機安裝，不涵蓋 HA / Streaming Replication / 叢集部署的額外設定。SSH 金鑰交換段落僅處理 standby/witness 主機的免密碼連線，不含 repmgr/Patroni 等 HA 工具設定。
- 磁碟配置：假設機器上除了系統碟，其餘實體硬碟均為資料庫用途。若使用 LVM 且邏輯磁區橫跨多個實體硬碟，磁碟偵測邏輯未涵蓋此情境。
- 網路/防火牆：全開，需自行依實際需求調整。
- 套件安裝均預設透過 `dnf install`（需能連到套件庫）；EDB 套件本身走離線 repo（見 6.1）。若作業系統層級套件也要離線安裝，可用 5.4 建立本機 ISO local repo，或自行另建 offline repo。5.5（必要套件安裝狀態）的 `dnf install` 需要先有套件來源，因此編號排在 5.4 之後。
- 本文件以「確保安裝結果 100% 可用」為唯一撰寫原則，不將安全性等非必要考量納入範圍（例如防火牆全開、SELinux 停用）。

## 需求

- root 權限（大多數步驟內部會呼叫 `require_root` 檢查）。
- `bash`、`systemd`、`dnf`/`yum`、`firewalld`、標準 GNU coreutils/util-linux 工具（`lsblk`、`findmnt`、`awk` 等）。
- 若要安裝 EDB 套件（6.1），需先備妥離線 repo 目錄（設定檔 `REPO_DIR`）。

## 用法

```bash
./edb_install_modular.sh            # 進入互動面板
./edb_install_modular.sh --run-all  # 非互動，依序跑完全部步驟（五 → 六 → 七）
./edb_install_modular.sh 5.7        # 非互動，只跑單一步驟後結束（步驟代號見下表）
./edb_install_modular.sh --check    # 非互動，只做當下值檢查
```

第一次執行會在腳本所在目錄自動產生設定檔 `edb_install_modular.conf`（若已存在則直接讀取，不會覆蓋），改設定不需要改程式碼，改完存檔、下次執行即生效。

執行過程會記錄到 `edb_install_logs/`（每次執行一個時間戳記檔名），每個步驟的完成/失敗狀態記錄在 `.edb_install_state`，互動面板會依此顯示「已完成 / 失敗 / 未執行」與上次執行時間。

## 互動面板

面板風格：開場清畫面、印出主機名稱與時間的 banner，接著用固定欄寬的表格列出所有步驟目前狀態（依章節分組），最後給一行「建議下一步」提示；操作完一個動作後會停下來等 Enter 才回主選單。

主選單指令：

| 輸入 | 說明 |
|---|---|
| 步驟代號（例如 `5.7`） | 執行單一步驟 |
| `5` / `6` / `7` | 整章依序執行 |
| `A`（或 `all`） | 全部依序執行 |
| `S`（或 `scope`） | 顯示「適用範圍與前提假設」 |
| `T`（或 `table`） | 顯示「參數對比」（改動前後的 OS/DB 設定值對照） |
| `P` | 參數設定（直接在面板內修改設定檔的值） |
| `F` | 最終參數成果總覽（只列已完成步驟的實際值與來源） |
| `V` | 當下值檢查（不論步驟是否執行過，讀取系統此刻的實際值並與目標值比對；查不到的項目標示「未建立 / 無法查詢」） |
| `C`（或 `conf`） | 顯示目前設定檔路徑並結束 |
| `H` | 顯示所有步驟的詳細說明 |
| `Q` | 離開 |

## 設定檔關鍵參數（`edb_install_modular.conf`）

| 參數 | 說明 |
|---|---|
| `NEED_ZH_LOCALE` | 是否需要 `zh_TW.UTF-8` locale（`yes`/`no`） |
| `EDB_VER` | 要安裝的 EDB 版本號 |
| `REPO_DIR` | EDB 離線 repo 目錄路徑（6.1 用） |
| `ISO_MOUNT_DIR` | 本機安裝 ISO 掛載路徑（5.4 用，預設 `/mnt`） |
| `MAX_CONNECTIONS` / `MAX_WORKER_PROCESSES` / `AUTOVACUUM_WORKER_SLOTS` / `MAX_WAL_SENDERS` / `MAX_FILES_PER_PROCESS` | 用於推算 ulimit（5.7）與 sysctl（5.9）數值，以及寫入 GUC（6.6） |
| `PGDATA_BASE` | 資料庫資料目錄的根路徑 |
| `LISTEN_ADDRESSES` / `PORT` / `SHARED_BUFFERS` / `MAX_PREPARED_TRANSACTIONS` / `MAX_REPLICATION_SLOTS` / `HUGE_PAGES` / `SHARED_PRELOAD_LIBRARIES` | 寫入 `postgresql.auto.conf` 的 GUC 值 |
| `REMOTE_HOSTS` | standby/witness 主機清單（`"IP 主機名稱"`，一行一台），7.1 SSH 金鑰交換用 |

## 步驟總覽

### 五、作業系統設定

| 代號 | 步驟 | 備註 |
|---|---|---|
| 5.1 | 檢查 PGDATA_BASE 是否為獨立掛載磁碟 | |
| 5.2 | SELinux 停用 | |
| 5.3 | 防火牆全開 | |
| 5.4 | 本機 ISO Repository（非必要） | 詢問式：互動執行才會問一次是否需要，非互動模式自動略過 |
| 5.5 | 必要套件安裝狀態（自動補齊） | `dnf install` 需要先有套件來源（連到套件庫，或 5.4 建好的本機 ISO local repo），故編號排在 5.4 之後 |
| 5.6 | 確認安裝媒介 / 套件庫可用 | |
| 5.7 | ulimit（NOFILE/NPROC） | |
| 5.8 | Core Dump 設定 | 與 5.9、5.10 共用 `/etc/sysctl.d/80-edb-postgres.conf` |
| 5.9 | sysctl：記憶體 overcommit 與 dirty memory | 與 5.8、5.10 共用同一設定檔 |
| 5.10 | Hugepage 設定（粗估值） | 與 5.8、5.9 共用同一設定檔；精確值由 7.2 校正 |
| 5.11 | I/O Scheduler 與 Readahead | 與 5.12 共用 `edb-os-tuning.sh`／`edb-os-tuning.service` |
| 5.12 | CPU 效能模式（Governor）設定 | 與 5.11 共用同一開機腳本 |
| 5.13 | atime（PGDATA_BASE） | |

原本獨立成章的「事前檢查：必要套件安裝狀態」已併入本章、改為 5.5：它的 `dnf install` 依賴套件來源是否備妥（5.4），單獨列一章、排在最前面反而會早於 5.4 執行，故直接安插進五、作業系統設定的正確順序位置。

5.8、5.9、5.10 共用同一份 sysctl 設定檔；5.11、5.12 共用同一支開機腳本。這五個步驟都用「區塊 marker」各自認領自己的內容片段（寫入前只清掉自己那段、不動別人的），因此**同一分類底下的步驟可以任意順序執行、也可以重複執行，彼此不會覆蓋或清掉對方已經寫好的設定**。

### 六、EDB 安裝作業

| 代號 | 步驟 |
|---|---|
| 6.1 | EDB 套件安裝（走離線 repo） |
| 6.2 | 目錄準備（含 NEW_WAL 套用 noatime） |
| 6.3 | 複製並修改 systemd Unit File |
| 6.4 | initdb 參數設定 |
| 6.5 | 執行 initdb |
| 6.6 | GUC 寫入 |

6.2~6.6 之間存在真實的先後相依（例如 6.3 需要 6.1 已安裝套件、6.5 需要 6.1 提供的執行檔）。6.5、6.6 的順序特別要注意：initdb（6.5）只能在空目錄上執行，若先跑 GUC 寫入（在 6.2 建好的空目錄裡放進一個 postgresql.auto.conf），initdb 會判定目錄非空而失敗；反過來，initdb 完成後會自動產生一份空的 postgresql.auto.conf，GUC 寫入只是對它追加內容，因此正確順序是先 initdb、後寫 GUC。對應步驟都會先檢查前置條件是否齊備，缺少時回報 `[CRIT]` 並中止，而不會盲目往下跑。

### 七、EDB 安裝後的 OS 設定

| 代號 | 步驟 |
|---|---|
| 7.1 | SSH 金鑰交換（standby/witness） |
| 7.2 | Hugepage 精確設定（校正 5.10 的粗估值） |
| 7.3 | Core Dump 更改權限 |

## 設計說明

- **狀態追蹤**：每個步驟執行後把 `完成時間 + done/fail` 寫入 `.edb_install_state`，面板據此顯示狀態、並在「建議下一步」提示第一個尚未完成或上次失敗的步驟。
- **冪等與順序無關**：涉及共用檔案的步驟（5.8/5.9/5.10、5.11/5.12）一律用 marker 區塊寫入取代整檔覆寫，確保單獨重跑、或用不同順序跑，結果都一致。
- **非必要步驟採詢問式**：5.4 僅離線環境需要，互動執行時會先問一次，非互動（`--run-all` 或排程）自動略過，不會卡住整個流程。
