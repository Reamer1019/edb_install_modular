#!/usr/bin/env bash
#
# edb_install_modular.sh — EDB Postgres Advanced Server 標準安裝程序（模組化版）
#
# 本文件以「確保安裝結果 100% 可用」為唯一撰寫原則，不將安全等非必要考量納入範圍。
#
# 設計原則：把原本線性、由上而下執行一次的安裝文件，改寫成可以「單一步驟獨立
# 選取執行」的互動式面板。每個步驟對應原文件的一個編號小節（5.1~5.13、
# 6.1~6.6、7.1~7.3），可以單獨重跑、也可以整章跑、也可以一次全部跑完。
#
# ────────────────────────────────────────────────────────────
# 一、適用範圍與前提假設
# ────────────────────────────────────────────────────────────
#   - 作業系統：RHEL 8、RHEL 9（或相容的 Rocky Linux / AlmaLinux 8/9），
#     並以 systemd 作為 init 系統。
#   - 部署架構：單機安裝，不涵蓋 HA / Streaming Replication / 叢集部署的
#     額外設定。SSH 金鑰交換段落僅處理 standby/witness 主機的免密碼連線，
#     不含 repmgr/Patroni 等 HA 工具設定。
#   - EDB 版本：因為要安裝套件，所以需先在參數宣告寫好要安裝的版本。
#   - 磁碟配置：假設機器上除了系統碟，其餘實體硬碟均為資料庫用途。若使用
#     LVM 且邏輯磁區橫跨多個實體硬碟，磁碟偵測邏輯未涵蓋此情境。
#   - 網路/防火牆：全開，需要自己依實際需求調整。
#   - WAL 歸檔：本文件不設定（archive_mode 維持 off），日後導入備份工具時，
#     archive_mode 需重啟資料庫方可生效。
#   - 第三節參數宣告需先向客戶確認，若客戶未提供則一律採用文件內建的預設值。
#   - 任何套件安裝均預設透過 dnf install（需要能連到套件庫），EDB 套件本身
#     則走離線 repo（見 6.1），如作業系統層級套件也要離線安裝，需自行另建
#     offline repo。
#
# 用法：
#   ./edb_install_modular.sh            # 進入互動面板
#   ./edb_install_modular.sh --run-all  # 非互動，依序跑完全部步驟
#   ./edb_install_modular.sh 5.7        # 非互動，只跑單一步驟後結束
#   ./edb_install_modular.sh 5          # 非互動，整章（5/6/7）依序執行後結束
#   ./edb_install_modular.sh --check    # 非互動，只做當下值檢查
#
set -uo pipefail

# ────────────────────────────────────────────────────────────
# 基本路徑與設定檔載入（比照 pg_healthcheck.sh 的做法：第一次執行自動產生
# 設定檔，之後每次都讀同一份，改設定不用改程式碼）
# ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/edb_install_modular.conf"
# 舊版設定檔名為 edb_install.conf，新檔不存在時直接沿用舊檔改名，設定不會遺失
if [ ! -f "$CONFIG_FILE" ] && [ -f "$SCRIPT_DIR/edb_install.conf" ]; then
  mv "$SCRIPT_DIR/edb_install.conf" "$CONFIG_FILE"
fi
STATE_FILE="$SCRIPT_DIR/.edb_install_state"
LOG_DIR="$SCRIPT_DIR/edb_install_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date '+%Y%m%d_%H%M%S').log"

create_default_config() {
  cat > "$CONFIG_FILE" <<'EOF'
# ────────────────────────────────────────
# edb_install_modular.sh 設定檔（對應原文件「三、參數宣告」）
#
# 以下除 listen_addresses 因應本文件之連線需求刻意偏離官方預設值外，
# 其餘均採用 PG/EDB 官方預設值。改完存檔，下次執行就會生效。
# ────────────────────────────────────────

NEED_ZH_LOCALE="no"           # <-- Edit this line
EDB_VER=18                    # <-- Edit this line
REPO_DIR="/pgdata/edb-offline" # <-- Edit this line
ISO_MOUNT_DIR="/mnt"          # <-- Edit this line（5.4 本機 ISO Repository 用，非必要）

MAX_CONNECTIONS=1000          # <-- Edit this line
MAX_WORKER_PROCESSES=8        # <-- Edit this line
AUTOVACUUM_WORKER_SLOTS=16    # <-- Edit this line
MAX_WAL_SENDERS=10            # <-- Edit this line
MAX_FILES_PER_PROCESS=1000    # <-- Edit this line

PGDATA_BASE="/pgdata"         # <-- Edit this line

LISTEN_ADDRESSES="*"          # <-- Edit this line
PORT="5444"                   # <-- Edit this line
SHARED_BUFFERS="4GB"          # <-- Edit this line
MAX_PREPARED_TRANSACTIONS="0" # <-- Edit this line
MAX_REPLICATION_SLOTS="10"    # <-- Edit this line
HUGE_PAGES="try"              # <-- Edit this line
SHARED_PRELOAD_LIBRARIES=""   # <-- Edit this line

# REMOTE_HOSTS：standby/witness 主機清單，格式 "IP 主機名稱"，一行一台
REMOTE_HOSTS=(
  "192.168.118.121 pgbackup01"
  "192.168.118.122 pgwitness01"
) # <-- Edit this list
EOF
}

[ -f "$CONFIG_FILE" ] || create_default_config
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# 舊版設定檔可能缺少後來才新增的變數，這裡補上預設值，避免 set -u 直接中斷
: "${REPO_DIR:=/pgdata/edb-offline}"
: "${ISO_MOUNT_DIR:=/mnt}"

# ────────────────────────────────────────────────────────────
# 衍生變數（由上面的設定值計算出來，全域只算一次，所有步驟共用）
# ────────────────────────────────────────────────────────────
resolve_derived_vars() {
  NEW_PGDATA="${PGDATA_BASE}/as${EDB_VER}/data"
  NEW_WAL="${PGDATA_BASE}/as${EDB_VER}/pg_wal"
  NEW_PGLOG="${PGDATA_BASE}/log"
  SERVICE_NAME="edb-as-${EDB_VER}"
  UNIT_SRC="/usr/lib/systemd/system/${SERVICE_NAME}.service"
  UNIT_DST="/etc/systemd/system/${SERVICE_NAME}.service"
  PG_BINDIR="/usr/edb/as${EDB_VER}/bin"
}
resolve_derived_vars

# ────────────────────────────────────────────────────────────
# 顏色（僅在互動終端機開啟，避免污染 log 檔）
# ────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_GRN='\033[0;32m'; C_CYN='\033[0;36m'; C_RST='\033[0m'
else
  C_RED=''; C_YEL=''; C_GRN=''; C_CYN=''; C_RST=''
fi

# ────────────────────────────────────────────────────────────
# 共用工具函式
# ────────────────────────────────────────────────────────────

# compute_ulimits：算出 NOFILE/NPROC。5.7、5.9、6.3 三個步驟都要用到這兩個
# 數字，而且彼此可能被「單獨」執行（不保證按順序跑），所以不倚賴前一個步驟
# 留下的全域變數，而是每次要用就重新算一次——純算術、零副作用，重算多次
# 結果一定一致，這樣不管使用者從面板挑哪一步先跑，數字都不會對不上。
compute_ulimits() {
  local bg_process_count=7  # postmaster/checkpointer/bgwriter/wal writer/
                             # autovacuum launcher/logical replication launcher/archiver
  NPROC=$((MAX_CONNECTIONS + MAX_WAL_SENDERS + MAX_WORKER_PROCESSES + AUTOVACUUM_WORKER_SLOTS + bg_process_count))
  NOFILE=$((MAX_CONNECTIONS * MAX_FILES_PER_PROCESS))
}

# apply_noatime：5.13 用來處理 PGDATA_BASE、6.2 用來處理 NEW_WAL。宣告成
# 全域函式＋全域關聯陣列，這樣不管兩個步驟誰先跑、跑幾次，NOATIME_DONE
# 都能正確記住「這個掛載點這次執行已經處理過」，不會重複改 fstab。
declare -A NOATIME_DONE
apply_noatime() {
  local TARGET_PATH="$1" MNT
  MNT=$(findmnt -no TARGET --target "$TARGET_PATH" 2>/dev/null)
  if [ -z "$MNT" ]; then
    echo -e "  ${C_YEL}[WARN]${C_RST} cannot resolve mount point for $TARGET_PATH." >&2
    return
  fi
  if [ "$MNT" = "/" ]; then
    echo -e "  ${C_YEL}[WARN]${C_RST} $TARGET_PATH is not on an independent disk (resolves to the root filesystem)." >&2
    return
  fi
  [ -n "${NOATIME_DONE[$MNT]+x}" ] && { echo "  ${MNT} 這次執行已處理過，略過。"; return; }
  NOATIME_DONE[$MNT]=1

  if findmnt -no OPTIONS --target "$TARGET_PATH" | tr ',' '\n' | grep -qx noatime; then
    echo "  $MNT already has noatime, skipped."
    return
  fi

  if awk -v m="$MNT" '$2==m{f=1} END{exit !f}' /etc/fstab; then
    sed -i "\|^[^#].*[[:space:]]${MNT}[[:space:]]|s/defaults/defaults,noatime/" /etc/fstab
    mount -o remount,noatime "$MNT"
    echo -e "  ${C_GRN}[OK]${C_RST} noatime applied to $MNT"
  else
    echo -e "  ${C_YEL}[WARN]${C_RST} $MNT has no exact match in /etc/fstab; add noatime manually." >&2
  fi
}

# write_managed_block：讓同一個檔案可以被多個「彼此獨立、任意順序執行」的
# 步驟各自認領一段內容，而不會互相覆蓋或重複疊加。做法：每個呼叫端固定用
# 同一個 marker 名稱寫自己的段落，寫之前一律先把舊的同名段落整段刪掉、再
# 重新附加一次；檔案不存在就視為空檔案處理。這樣不論同一分類底下哪個步驟
# 先執行、又被重複執行幾次，最終結果都一樣，不會像直接 cat > 覆寫整檔那樣
# 把「另一個步驟已經寫好的段落」一起清掉。
# $1=目的檔案路徑  $2=marker 名稱（同一呼叫端固定用同一個名稱）
# 內容從 stdin 讀進來。
write_managed_block() {
  local file="$1" begin="# ==== ${2} BEGIN ====" end="# ==== ${2} END ===="
  local content; content=$(cat)
  touch "$file" || return 1
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1}
    !skip {print}
    $0==e {skip=0}
  ' "$file" > "${file}.tmp" || return 1
  mv "${file}.tmp" "$file" || return 1
  {
    echo "$begin"
    printf '%s\n' "$content"
    echo "$end"
  } >> "$file" || return 1
}

# ensure_os_tuning_skeleton：5.11（I/O Scheduler）、5.12（CPU Governor）都會
# 對 edb-os-tuning.sh／edb-os-tuning.service 寫入各自的區塊，兩者誰先執行都
# 需要這支腳本與 service 已經存在。用「不存在才建立」而非覆寫，讓兩個步驟
# 彼此獨立、任意順序執行都不會清掉對方已經寫好的區塊。
ensure_os_tuning_skeleton() {
  if [ ! -f /usr/local/sbin/edb-os-tuning.sh ]; then
    printf '#!/usr/bin/env bash\nset -uo pipefail\n' > /usr/local/sbin/edb-os-tuning.sh
  fi
  chmod +x /usr/local/sbin/edb-os-tuning.sh

  if [ ! -f /etc/systemd/system/edb-os-tuning.service ]; then
    cat > /etc/systemd/system/edb-os-tuning.service << 'EOF'
[Unit]
Description=EDB pre-install OS tuning (runtime kernel/CPU parameters)
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/edb-os-tuning.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
  systemctl enable edb-os-tuning.service &>/dev/null || true
}

state_get() {  # $1=step_id -> 印出 "epoch status"
  [ -f "$STATE_FILE" ] || return 0
  awk -v m="$1" '$1==m {print $2, $3}' "$STATE_FILE" | tail -1
}
state_set() {  # $1=step_id $2=status(done|fail)
  local ts; ts=$(date +%s)
  touch "$STATE_FILE"
  grep -v "^$1 " "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "$1 $ts $2" >> "$STATE_FILE"
}
fmt_time() { date -d "@$1" '+%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%m-%d %H:%M' 2>/dev/null || echo "$1"; }
step_is_done() {  # $1=step_id -> 0=已完成 1=未完成/失敗/未執行
  local st; st=$(state_get "$1")
  [ -n "$st" ] && [ "${st#* }" = "done" ]
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${C_RED}[CRIT]${C_RST} 本步驟需要 root 權限執行，請用 sudo 或 root 重新執行本腳本。" >&2
    return 1
  fi
}

# ════════════════════════════════════════════════════════════
# 五、作業系統設定
# ════════════════════════════════════════════════════════════

# 5.1 檢查 PGDATA_BASE 是否為獨立掛載磁碟
# 不用 mount -q：那其實是「照 /etc/fstab 找到對應項目就嘗試掛載」的語意，
# 不是單純的「這個路徑現在是不是一個掛載點」判斷。改用 findmnt -T 直接問
# 「$PGDATA_BASE 這個路徑目前實際落在哪個掛載點上」，再拿回傳的掛載點跟
# $PGDATA_BASE 本身比對：兩者相同才代表它自己就是一個獨立掛載點；如果查到
# 的是它的上層目錄（常見就是查到 "/"），代表它只是根檔案系統底下的一個
# 普通資料夾，不是獨立磁碟。
step_5_1_check_pgdata_mount() {
  echo "== [5.1] 檢查 PGDATA_BASE 是否為獨立掛載磁碟 =="
  local mnt
  mnt=$(findmnt -T "$PGDATA_BASE" -no TARGET 2>/dev/null)
  if [ -n "$mnt" ] && [ "$mnt" = "$PGDATA_BASE" ]; then
    echo -e "  ${C_GRN}[OK]${C_RST} $PGDATA_BASE 是獨立掛載點"
  else
    echo -e "  ${C_YEL}[WARN]${C_RST} $PGDATA_BASE not mounted as an independent disk（findmnt 查到的實際掛載點：${mnt:-無法判斷}）." >&2
  fi
}

# 5.2 SELinux 停用
step_5_2_selinux() {
  require_root || return 1
  echo "== [5.2] SELinux 停用 =="
  if [ ! -f /etc/selinux/config ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} /etc/selinux/config 不存在，此系統可能未安裝 SELinux 相關套件。" >&2
    return 1
  fi
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || { echo -e "  ${C_RED}[CRIT]${C_RST} 修改 /etc/selinux/config 失敗" >&2; return 1; }
  setenforce 0 2>/dev/null || echo -e "  ${C_YEL}[WARN]${C_RST} setenforce 失敗（可能本來就是 disabled，或需要重開機才能完全生效）"
  echo -e "  ${C_GRN}[OK]${C_RST} SELinux 已設定為 disabled（永久生效需重開機）"
}

# 5.3 防火牆全開
step_5_3_firewall() {
  require_root || return 1
  echo "== [5.3] 防火牆全開 =="
  local nic had_fail=0
  for nic in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    firewall-cmd --permanent --zone=trusted --change-interface="$nic" || { echo -e "  ${C_RED}[CRIT]${C_RST} 將網卡 ${nic} 改到 trusted zone 失敗" >&2; had_fail=1; }
  done
  firewall-cmd --set-default-zone=trusted || { echo -e "  ${C_RED}[CRIT]${C_RST} firewall-cmd --set-default-zone=trusted 失敗" >&2; had_fail=1; }
  firewall-cmd --complete-reload || { echo -e "  ${C_RED}[CRIT]${C_RST} firewall-cmd --complete-reload 失敗" >&2; had_fail=1; }
  [ "$had_fail" -eq 0 ] || return 1
  echo -e "  ${C_GRN}[OK]${C_RST} 所有網卡已改為 trusted zone"
}

# 5.4 本機 ISO Repository（非必要，詢問式）
# 僅離線／無法連到外部套件庫的環境才需要。互動執行時會先問一次，答否或直接
# 按 Enter 就略過，不影響後續步驟；非互動（stdin 非終端機，例如 --run-all
# 或排程執行）一律自動略過，避免卡在 read 上，需要的話請在互動面板下單獨
# 執行本步驟。
# 答 y 之後的偵測／掛載邏輯：
#   1. 先看有沒有裝置的檔案系統「含 iso 字樣」已經掛載好了，有就直接沿用該
#      掛載點，不重複掛載（避免 "already mounted" 之類的錯誤）。
#   2. 沒有的話找出檔案系統「含 iso 字樣」的裝置（例如光碟機 /dev/sr0）。
#   3. 找到才 mount 到 ISO_MOUNT_DIR（預設 /mnt）；兩者都找不到就回報 WARN
#      並略過，不會硬寫一個指向空目錄的 repo 檔。
# 注意：這裡故意不要求「剛好等於 iso9660」，只要求 FSTYPE 含 iso 字樣就算
# 數——lsblk -f（預設格式化輸出，欄寬有限）在某些終端機寬度下會把
# iso9660 這種欄位截斷顯示成 iso966 之類的樣子，那只是「畫面顯示」被截斷，
# 底層實際的檔案系統名稱、以及本函式用 -r（原始、不截斷）取到的欄位其實
# 都還是完整的 iso9660，只是肉眼直接看 lsblk -f 容易被截斷的畫面搞混；
# 與其糾結要不要精準比對 iso9660，不如放寬成「含 iso 字樣即算」，各種
# 顯示/版本差異都不會影響判斷。
step_5_4_iso_local_repo() {
  require_root || return 1
  echo "== [5.4] 本機 ISO Repository 設定（非必要）=="
  if [ ! -t 0 ]; then
    echo "  非互動模式（無終端機輸入），本步驟需要人工確認是否設定，已自動略過。"
    echo "  如需設定，請在互動面板下單獨執行「5.4」。"
    return 0
  fi
  local ans iso_dir="${ISO_MOUNT_DIR:-/mnt}"
  read -erp "  是否要偵測並掛載本機安裝 ISO、建立 local repo？僅離線環境需要 (y/N)： " ans
  case "$ans" in
    y|Y|yes|YES)
      local mnt_info dev
      # 1. 有沒有裝置的檔案系統含 iso 字樣、已經掛載好了？有就直接沿用，
      #    不重複 mount。用 -r（原始欄位，不截斷）＋自己過濾含 iso 字樣，
      #    不用 findmnt -t 精準比對某個固定的檔案系統名稱。
      mnt_info=$(findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null | awk 'tolower($3) ~ /iso/{print $1, $2; exit}')
      if [ -n "$mnt_info" ]; then
        iso_dir="${mnt_info%% *}"
        dev="${mnt_info#* }"
        echo "  偵測到 ${dev} 已掛載於 ${iso_dir}（檔案系統含 iso 字樣），直接沿用。"
      else
        # 2. 找出檔案系統含 iso 字樣的裝置（例如光碟機 /dev/sr0）。
        dev=$(lsblk -rno NAME,FSTYPE | awk 'tolower($2) ~ /iso/{print "/dev/"$1; exit}')
        if [ -z "$dev" ]; then
          echo -e "  ${C_YEL}[WARN]${C_RST} 找不到檔案系統含 iso 字樣的裝置，請確認安裝 ISO 是否已插入/掛載，已略過本步驟。" >&2
          return 0
        fi
        # 3. 掛到 ISO_MOUNT_DIR。
        mkdir -p "$iso_dir"
        if mount "$dev" "$iso_dir"; then
          echo -e "  ${C_GRN}[OK]${C_RST} 已將 ${dev} 掛載到 ${iso_dir}"
        else
          echo -e "  ${C_RED}[CRIT]${C_RST} mount ${dev} ${iso_dir} 失敗" >&2
          return 1
        fi
      fi

      cat > /etc/yum.repos.d/local.repo << EOF
[local-baseos]
name=Local BaseOS
baseurl=file://${iso_dir}/BaseOS
enabled=1
gpgcheck=0

[local-appstream]
name=Local AppStream
baseurl=file://${iso_dir}/AppStream
enabled=1
gpgcheck=0
EOF
      echo -e "  ${C_GRN}[OK]${C_RST} /etc/yum.repos.d/local.repo 已建立（baseurl 指向 ${iso_dir}）"
      ;;
    *)
      echo "  已略過，未建立本機 local repo。"
      ;;
  esac
}

# 5.5 必要套件安裝狀態
# 本節檢查後續步驟所需之套件是否已安裝，若未安裝則自動補齊。編號安排在 5.4
# 之後：dnf install 需要能連到套件庫（線上）或本機 ISO local repo（離線，見
# 5.4），先確認/建立好安裝來源，這裡才有東西可裝，因此不能排在 5.4 之前。
step_5_5_prereq_packages() {
  require_root || return 1
  echo "== [5.5] 必要套件安裝狀態 =="

  if ! command -v mountpoint &>/dev/null; then
    dnf install -y util-linux || return 1
  fi

  if ! systemctl is-active --quiet firewalld; then
    dnf install -y firewalld || return 1
    systemctl enable --now firewalld || { echo -e "  ${C_RED}[CRIT]${C_RST} systemctl enable --now firewalld 失敗" >&2; return 1; }
  fi

  if ! command -v ssh-copy-id &>/dev/null; then
    dnf install -y openssh-clients || return 1
  fi

  if ! command -v mount.nfs &>/dev/null; then
    dnf install -y nfs-utils || return 1
  fi

  if ! command -v x86_energy_perf_policy &>/dev/null; then
    dnf install -y kernel-tools || return 1
  fi

  if [ "$NEED_ZH_LOCALE" = "yes" ] && ! locale -a | grep -qi '^zh_TW.utf8$'; then
    dnf install -y glibc-langpack-zh || return 1
  fi

  echo -e "  ${C_GRN}[OK]${C_RST} 必要套件檢查完成"
}

# 5.6 確認安裝媒介 / 套件庫可用
step_5_6_check_repo() {
  echo "== [5.6] 確認安裝媒介 / 套件庫可用 =="
  mount | grep -i iso || echo "  （未偵測到掛載的 ISO）"
  yum repolist
}

# 5.7 ulimit
# 依據下列官方文件計算：
#   https://www.postgresql.org/docs/current/runtime-config-resource.html#RUNTIME-CONFIG-RESOURCE-KERNEL
#   https://www.postgresql.org/docs/current/kernel-resources.html#SYSVIPC
#   https://man7.org/linux/man-pages/man5/sysctl.d.5.html
# 非官方參考文件：
#   https://oneuptime.com/blog/post/2026-03-04-configure-resource-limits-ulimit-limits-conf-rhel-9/view
#
# max_files_per_process/max_connections/max_wal_senders/max_worker_processes/
# autovacuum_worker_slots 均為 PG 官方預設值（可在設定檔修改），再加上
# postmaster/checkpointer/bgwriter/wal writer/autovacuum launcher/
# logical replication launcher/archiver 七個固定背景行程。
# 設定檔編號依 man sysctl.d(5) 建議採用 60-90 區間。
step_5_7_ulimit() {
  require_root || return 1
  echo "== [5.7] ulimit（NOFILE/NPROC）=="
  compute_ulimits
  mkdir -p /etc/security/limits.d || { echo -e "  ${C_RED}[CRIT]${C_RST} mkdir /etc/security/limits.d 失敗" >&2; return 1; }
  cat > /etc/security/limits.d/80-edb-postgres.conf << EOF
enterprisedb soft nofile ${NOFILE}
enterprisedb hard nofile ${NOFILE}
enterprisedb soft nproc  ${NPROC}
enterprisedb hard nproc  ${NPROC}
enterprisedb soft core   unlimited
enterprisedb hard core   unlimited
EOF
  [ $? -eq 0 ] || { echo -e "  ${C_RED}[CRIT]${C_RST} 寫入 /etc/security/limits.d/80-edb-postgres.conf 失敗" >&2; return 1; }
  echo -e "  ${C_GRN}[OK]${C_RST} NOFILE=${NOFILE}  NPROC=${NPROC}  已寫入 /etc/security/limits.d/80-edb-postgres.conf"
}

# 5.8 Core Dump 設定
# Coredump 的檔案並無官方文件建議的放置位置，這邊僅是遵照個人習慣。
# /etc/sysctl.d/80-edb-postgres.conf 同時也是 5.9、5.10 會寫入的檔案；三者用
# write_managed_block 各自認領一個 marker 區塊，任一步驟先執行、或重複執行，
# 都不會清掉另外兩個步驟已經寫好的內容。
step_5_8_coredump() {
  require_root || return 1
  echo "== [5.8] Core Dump 設定 =="
  if ! write_managed_block /etc/sysctl.d/80-edb-postgres.conf CORE_PATTERN << 'EOF'
kernel.core_pattern = /var/coredump/core-%e-%p-%t
EOF
  then
    echo -e "  ${C_RED}[CRIT]${C_RST} 寫入 CORE_PATTERN 區塊失敗" >&2
    return 1
  fi
  sysctl --system || { echo -e "  ${C_RED}[CRIT]${C_RST} sysctl --system 套用失敗" >&2; return 1; }
  echo -e "  ${C_GRN}[OK]${C_RST} core_pattern 已設定（存放目錄權限見 7.3）"
}

# 5.9 sysctl：記憶體 overcommit 與 dirty memory
# 參照：
#   https://www.enterprisedb.com/blog/general-configuration-and-tuning-recommendations-edb-postgres-advanced-server-and-postgresql
#   https://www.postgresql.org/docs/current/kernel-resources.html#LINUX-MEMORY-OVERCOMMIT
# overcommit_memory=2：依 PG 官方文件建議，降低 postmaster 被 OOM killer 誤殺的機率
# overcommit_kbytes：依 EDB 官方調校指南，用實際記憶體總量
# swappiness=1：同一份調校指南建議值
# dirty_bytes：無其他依據時採 1GB，dirty_background_bytes 取其 1/4
step_5_9_sysctl_mem() {
  require_root || return 1
  echo "== [5.9] sysctl：記憶體 overcommit 與 dirty memory =="
  compute_ulimits
  local MEM_TOTAL_KB DIRTY_BYTES DIRTY_BG FILE_MAX
  MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  DIRTY_BYTES=$((1024*1024*1024))
  DIRTY_BG=$((DIRTY_BYTES/4))
  FILE_MAX=$((NOFILE * 4))

  if ! write_managed_block /etc/sysctl.d/80-edb-postgres.conf MEM_OVERCOMMIT << EOF
vm.overcommit_memory = 2
vm.overcommit_kbytes = ${MEM_TOTAL_KB}
vm.swappiness = 1
vm.dirty_bytes = ${DIRTY_BYTES}
vm.dirty_background_bytes = ${DIRTY_BG}
fs.file-max = ${FILE_MAX}
EOF
  then
    echo -e "  ${C_RED}[CRIT]${C_RST} 寫入 MEM_OVERCOMMIT 區塊失敗" >&2
    return 1
  fi
  sysctl --system || { echo -e "  ${C_RED}[CRIT]${C_RST} sysctl --system 套用失敗" >&2; return 1; }
  echo -e "  ${C_GRN}[OK]${C_RST} 已寫入 /etc/sysctl.d/80-edb-postgres.conf（MEM_OVERCOMMIT 區塊）並套用"
}

# 5.10 Hugepage 設定（粗估值，EDB 安裝後由 7.2 校正為精確值）
# 參考：
#   https://www.postgresql.org/docs/current/kernel-resources.html#LINUX-HUGE-PAGES
#   https://www.postgresql.org/docs/current/runtime-config-resource.html#GUC-HUGE-PAGES
# 最精確的值需由 EDB 的 shared_memory_size_in_huge_pages 算，但此階段尚未安裝
# EDB，故先用「總 RAM 1/4 再加 10% 共用記憶體餘裕」的經驗公式估算。
# THP 停用理論上該寫在這裡，但已併入 5.11 的開機腳本一起處理（官方文件指出
# 部分 Linux 版本上 THP 會造成效能下降，不建議使用）。
# nr_hugepages 這一行寫進與 5.8/5.9 共用的 80-edb-postgres.conf，同樣用
# write_managed_block 認領獨立 marker，7.2 的精確值日後覆蓋也走同一個
# marker，彼此任意順序執行都不會互相打架。
step_5_10_hugepage_estimate() {
  require_root || return 1
  echo "== [5.10] Hugepage 設定（粗估值）=="
  local MEM_KB HP_KB NR
  MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  HP_KB=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
  NR=$(awk -v m="$MEM_KB" -v h="$HP_KB" 'BEGIN{printf "%d", (m*0.25*1.10)/h + 1}')
  echo "  nr_hugepages（粗估）= $NR"
  # sysctl -w 對 nr_hugepages 屬於盡力而為：就算實際能配置到的 hugepage 數量
  # 比要求的少，指令通常仍回傳 0，這是核心本身的行為、非本腳本可控，故此處
  # 不當作 CRIT；但寫入設定檔失敗（權限、磁碟等問題）仍視為失敗。
  sysctl -w vm.nr_hugepages="$NR" || echo -e "  ${C_YEL}[WARN]${C_RST} sysctl -w vm.nr_hugepages 回傳非 0，請執行 cat /proc/meminfo | grep HugePages 確認實際生效數量"
  write_managed_block /etc/sysctl.d/80-edb-postgres.conf NR_HUGEPAGES <<< "vm.nr_hugepages = $NR" || {
    echo -e "  ${C_RED}[CRIT]${C_RST} 寫入 NR_HUGEPAGES 區塊失敗" >&2
    return 1
  }
  echo -e "  ${C_GRN}[OK]${C_RST} 粗估值已套用，EDB 安裝完成後請執行 7.2 校正為精確值"
}

# 5.11 I/O Scheduler 與 Readahead
# 參考：https://www.enterprisedb.com/blog/general-configuration-and-tuning-recommendations-edb-postgres-advanced-server-and-postgresql
# Readahead 讓核心偵測到循序讀取模式時，一次預先多讀一段進 page cache，減少
# 實際發出的 I/O 請求次數、提升吞吐量。Linux 預設通常 128 kB，官方建議資料庫
# 磁碟改為 4096 kB。
# I/O Scheduler、Readahead、THP 停用都屬於 kernel 執行期狀態，每次開機都會
# 被還原成系統預設值，無法像 sysctl.d/fstab 一樣寫進設定檔就永久生效，因此
# 寫成一支開機執行一次的腳本，註冊為 edb-os-tuning.service。5.12 的 CPU
# Governor 設定同屬此類狀態，會附加進同一支腳本，不另開 service。腳本骨架由
# ensure_os_tuning_skeleton 用「不存在才建立」的方式準備，本步驟只用
# write_managed_block 認領自己的 IO_SCHEDULER 區塊，5.11、5.12 誰先執行、
# 重跑幾次都不會清掉對方的內容。
step_5_11_io_scheduler() {
  require_root || return 1
  echo "== [5.11] I/O Scheduler 與 Readahead =="
  ensure_os_tuning_skeleton
  if ! write_managed_block /usr/local/sbin/edb-os-tuning.sh IO_SCHEDULER << 'EOF'
echo never > /sys/kernel/mm/transparent_hugepage/enabled
RHEL_VER=$(rpm -E %rhel 2>/dev/null || echo 8)
ROOT_SRC=$(findmnt -n -o SOURCE --target /)
# 只追一層 lsblk -no PKNAME 對 LVM（RHEL 預設分割方式）不夠：root 來源常是
# /dev/mapper/vgname-lvname 這種 device-mapper 裝置，PKNAME 只會給底層 PV
# 分割區名稱（例如 sda2），對不上下面 TYPE=disk 篩出來的磁碟清單（sda），
# 導致「跳過系統碟」這段邏輯形同虛設。改成逐層往上追 PKNAME，直到追到
# 沒有上層（也就是頂層實體磁碟）為止。若同一顆 LV 橫跨多顆實體磁碟（VG
# 跨多顆 PV），這裡仍只會走到其中一條鏈，這點文件開頭「一、適用範圍與
# 前提假設」已經寫明是已知限制。
ROOT_WALK="$ROOT_SRC"
while :; do
	PK=$(lsblk -no PKNAME "$ROOT_WALK" 2>/dev/null | head -1)
	[ -z "$PK" ] && break
	ROOT_WALK="/dev/$PK"
done
ROOT_DEV=$(basename "$ROOT_WALK")
for DEVICE in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
	[ "$DEVICE" = "$ROOT_DEV" ] && continue
	[ -e "/sys/block/${DEVICE}/queue/scheduler" ] || continue

	ROTATIONAL=$(cat /sys/block/${DEVICE}/queue/rotational)
	if [ "$ROTATIONAL" = "0" ]; then
		[ "$RHEL_VER" -ge 8 ] && SCHED=none || SCHED=noop
	else
		[ "$RHEL_VER" -ge 8 ] && SCHED=mq-deadline || SCHED=deadline
	fi
	echo "$SCHED" > "/sys/block/${DEVICE}/queue/scheduler"
	echo 4096 > "/sys/block/${DEVICE}/queue/read_ahead_kb"
done
EOF
  then
    echo -e "  ${C_RED}[CRIT]${C_RST} 寫入 IO_SCHEDULER 區塊失敗" >&2
    return 1
  fi
  chmod +x /usr/local/sbin/edb-os-tuning.sh
  systemctl daemon-reload || { echo -e "  ${C_RED}[CRIT]${C_RST} systemctl daemon-reload 失敗" >&2; return 1; }
  systemctl restart edb-os-tuning.service || { echo -e "  ${C_RED}[CRIT]${C_RST} systemctl restart edb-os-tuning.service 失敗" >&2; return 1; }
  echo -e "  ${C_GRN}[OK]${C_RST} edb-os-tuning.sh 的 IO_SCHEDULER 區塊已寫入並套用"
}

# 5.12 CPU 效能模式（Governor）設定
# 參考：https://www.enterprisedb.com/blog/tuning-red-hat-enterprise-linux-family-postgresql
# powersave/ondemand/schedutil 等省電導向的 governor 會在 CPU 閒置時降頻，
# 有查詢進來才升頻，升頻時間會轉嫁成間歇性、難以追蹤的查詢回應時間。
# performance governor 讓 CPU 全程鎖定最高時脈。官方部落格建議 tuned 設定檔
# [cpu] 區塊：governor=performance / energy_perf_bias=performance /
# min_perf_pct=100。
#
# 限制：
#   - 虛擬機環境：實體 CPU 頻率控制權在 hypervisor 手上，guest OS 內設定
#     governor 可能沒有實際效果。
#   - CPU 廠牌差異：min_perf_pct 是 Intel intel_pstate 驅動專屬參數，AMD
#     平台沒有這個路徑。
#
# 跟 5.11 一樣先呼叫 ensure_os_tuning_skeleton 確保腳本/service 存在（不存在
# 才建立，不會覆寫 5.11 已寫好的 IO_SCHEDULER 區塊），再用 write_managed_block
# 認領自己的 CPU_GOVERNOR 區塊，因此不再需要「5.10 必須先跑過」的前置檢查，
# 5.11、5.12 兩步驟任意順序、單獨重跑都是安全的。
step_5_12_cpu_governor() {
  require_root || return 1
  echo "== [5.12] CPU 效能模式（Governor）設定 =="
  ensure_os_tuning_skeleton
  if ! write_managed_block /usr/local/sbin/edb-os-tuning.sh CPU_GOVERNOR << 'EOF'
VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
[ "$VIRT" != "none" ] && echo "NOTICE: virtualization detected ($VIRT); CPU governor changes may be ignored by the hypervisor." >&2

for CPU_GOV in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
	[ -e "$CPU_GOV" ] || continue
	AVAIL_FILE="$(dirname "$CPU_GOV")/scaling_available_governors"
	if [ -e "$AVAIL_FILE" ] && grep -qw performance "$AVAIL_FILE"; then
		echo performance > "$CPU_GOV"
	else
		echo "WARNING: $CPU_GOV does not support the performance governor, skipped." >&2
	fi
done

if [ -d /sys/devices/system/cpu/intel_pstate ]; then
	echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct
else
	echo "NOTICE: intel_pstate driver not present (non-Intel CPU or different driver), skipping min_perf_pct." >&2
fi
EOF
  then
    echo -e "  ${C_RED}[CRIT]${C_RST} 寫入 CPU_GOVERNOR 區塊失敗" >&2
    return 1
  fi
  chmod +x /usr/local/sbin/edb-os-tuning.sh
  systemctl daemon-reload || { echo -e "  ${C_RED}[CRIT]${C_RST} systemctl daemon-reload 失敗" >&2; return 1; }
  systemctl restart edb-os-tuning.service || { echo -e "  ${C_RED}[CRIT]${C_RST} systemctl restart edb-os-tuning.service 失敗" >&2; return 1; }
  echo -e "  ${C_GRN}[OK]${C_RST} edb-os-tuning.sh 的 CPU_GOVERNOR 區塊已寫入並套用（systemctl restart 讓本次立即生效，重開機後也會靠同一個 service 自動套用）"
}

# 5.13 atime
# 參考：https://www.enterprisedb.com/blog/tuning-red-hat-enterprise-linux-family-postgresql
# Linux 每次讀取資料都會寫一次更新 atime，資料庫每秒讀取的 page 數非常龐大，
# 累積起來是可觀的額外寫入開銷。PostgreSQL 自己完全不會看這個 atime 欄位做
# 任何判斷，因此這是純浪費的成本，應當關閉。
step_5_13_atime() {
  require_root || return 1
  echo "== [5.13] atime（PGDATA_BASE）=="
  apply_noatime "$PGDATA_BASE"
}

# ════════════════════════════════════════════════════════════
# 六、EDB 安裝作業
# ════════════════════════════════════════════════════════════

# 6.1 實際安裝（走離線 repo）
step_6_1_install_edb() {
  require_root || return 1
  echo "== [6.1] EDB 套件安裝 =="
  if [ ! -d "${REPO_DIR}/repodata" ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} ${REPO_DIR}/repodata 不存在，請確認離線 repo 已放置到位（路徑可在設定檔 REPO_DIR 調整）。" >&2
    return 1
  fi
  cat > /etc/yum.repos.d/edb-offline.repo << EOF
[edb-offline]
name=EDB Offline Repo
baseurl=file://${REPO_DIR}
enabled=1
gpgcheck=0
EOF
  if [ $? -ne 0 ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} 寫入 /etc/yum.repos.d/edb-offline.repo 失敗" >&2
    return 1
  fi
  if ! dnf install -y --disablerepo='*' --enablerepo='edb-offline' "edb-as${EDB_VER}-server"; then
    echo -e "  ${C_RED}[CRIT]${C_RST} edb-as${EDB_VER}-server 安裝失敗，請確認 REPO_DIR（${REPO_DIR}）內容是否正確" >&2
    return 1
  fi
  echo -e "  ${C_GRN}[OK]${C_RST} edb-as${EDB_VER}-server 已安裝"
}

# 6.2 目錄準備（含對 NEW_WAL 套用 noatime，沿用 5.13 定義的函式）
step_6_2_prepare_dirs() {
  require_root || return 1
  echo "== [6.2] 目錄準備 =="
  mkdir -p "$NEW_PGDATA" "$NEW_WAL" "$NEW_PGLOG" || {
    echo -e "  ${C_RED}[CRIT]${C_RST} 建立目錄失敗" >&2
    return 1
  }
  chown -R enterprisedb:enterprisedb "$PGDATA_BASE" || {
    echo -e "  ${C_RED}[CRIT]${C_RST} chown ${PGDATA_BASE} 失敗（enterprisedb 使用者是否已由 6.1 套件安裝建立？）" >&2
    return 1
  }
  echo "  WAL 路徑至此才確定，沿用 5.13 定義的 apply_noatime；若與 PGDATA_BASE 同一顆磁碟，"
  echo "  函式會自動判斷已處理過，不會重複修改 fstab 或重複 remount。"
  apply_noatime "$NEW_WAL"
  echo -e "  ${C_GRN}[OK]${C_RST} 目錄已建立並設定擁有者"
}

# 6.3 複製並修改 systemd Unit File
step_6_3_systemd_unit() {
  require_root || return 1
  echo "== [6.3] 複製並修改 systemd Unit File =="
  compute_ulimits
  if [ ! -f "$UNIT_SRC" ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} 找不到 $UNIT_SRC，請確認 6.1 是否已安裝成功。" >&2
    return 1
  fi
  cp "$UNIT_SRC" "$UNIT_DST" || { echo -e "  ${C_RED}[CRIT]${C_RST} cp ${UNIT_SRC} ${UNIT_DST} 失敗" >&2; return 1; }

  sed -i \
    -e "s|^Environment=PGDATA=.*|Environment=PGDATA=${NEW_PGDATA}|" \
    -e "s|^PIDFile=.*|PIDFile=${NEW_PGDATA}/postmaster.pid|" \
    "$UNIT_DST"
  sed -i "/^\[Service\]/a LimitNOFILE=${NOFILE}\nLimitNPROC=${NPROC}\nLimitCORE=infinity" "$UNIT_DST"

  # edb-os-tuning.service（5.11/5.12）跟 EDB service 一樣都是 WantedBy=multi-user.target，
  # 彼此沒有訂順序關係，systemd 不保證重開機時 tuning 一定跑在 EDB 之前，資料庫可能在
  # THP/IO scheduler/CPU governor 都還沒重新套用完就先啟動。比照 EDB 官方部落格建議在
  # postgresql.service 加 After=tuned.service 的做法，這裡補上對 edb-os-tuning.service 的依賴。
  if ! grep -q '^After=edb-os-tuning.service$' "$UNIT_DST"; then
    sed -i "/^\[Unit\]/a After=edb-os-tuning.service" "$UNIT_DST"
  fi

  diff -Naur "$UNIT_SRC" "$UNIT_DST" || true
  systemctl daemon-reload || { echo -e "  ${C_RED}[CRIT]${C_RST} systemctl daemon-reload 失敗" >&2; return 1; }
  echo -e "  ${C_GRN}[OK]${C_RST} Unit file 已複製並修改，NOFILE=${NOFILE} NPROC=${NPROC}"
}

# 6.4 initdb 參數
# wal-segsize：PG 官方規定 2 的 0~10 次方，本文件採官方預設值 16。
# waldir：指到 6.2 建好的獨立目錄，不然會放進 data 裡面的 wal。
# data-checksums：新版本 PG/EDB 官方預設開啟，打開可降低潛在問題。
# locale：依 NEED_ZH_LOCALE 參數決定。
# 注意：這裡用 export 設定環境變數，只在「同一個 shell 執行流程」內有效，
# 若在面板裡單獨選 6.5 而沒有先選 6.4，6.5 會自動先呼叫本函式一次，
# 確保 initdb 參數一定是齊的，不需要仰賴使用者記得順序。
step_6_4_initdb_params() {
  echo "== [6.4] initdb 參數設定 =="
  export LANG=en_US.UTF-8
  export PGDATA="$NEW_PGDATA"

  local LOCALE_OPT
  if [ "$NEED_ZH_LOCALE" = "no" ]; then
    LOCALE_OPT="en_US.UTF-8"
  else
    LOCALE_OPT="zh_TW.UTF-8"
  fi
  export PGSETUP_INITDB_OPTIONS="-E UTF-8 --wal-segsize=16 --waldir=${NEW_WAL} --data-checksums --locale=${LOCALE_OPT}"
  echo -e "  ${C_GRN}[OK]${C_RST} PGDATA=${PGDATA}　PGSETUP_INITDB_OPTIONS 已設定（本次 shell session 有效）"
}

# 6.5 initdb（因後續還需調整 Hugepage、需要 restart service，這裡不啟動 service）
# 編號安排在 GUC 寫入之前：initdb 只能在「空目錄」上執行，6.2 建好的
# NEW_PGDATA 這時還是空的，正好符合條件；GUC 寫入是用 cat >> 對
# postgresql.auto.conf 追加內容，若排在 initdb 之前執行，會先在 NEW_PGDATA
# 底下留下一個檔案，讓 initdb 一律判定「目錄非空」而失敗（或誤判成已初始化
# 過的叢集），因此兩者順序不可對調。
step_6_5_run_initdb() {
  require_root || return 1
  echo "== [6.5] 執行 initdb =="
  step_6_4_initdb_params
  if [ ! -x "${PG_BINDIR}/edb-as-${EDB_VER}-setup" ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} 找不到 ${PG_BINDIR}/edb-as-${EDB_VER}-setup，請確認 6.1 是否已安裝成功。" >&2
    return 1
  fi
  if ! "${PG_BINDIR}/edb-as-${EDB_VER}-setup" initdb; then
    echo -e "  ${C_RED}[CRIT]${C_RST} initdb 失敗，請檢查上方輸出訊息" >&2
    return 1
  fi
  echo -e "  ${C_GRN}[OK]${C_RST} initdb 完成（尚未啟動 service，待 6.6 GUC 寫入、7.2 hugepage 校正後再啟動）"
}

# 6.6 GUC 寫入
# 依 PG 官方文件 §25.3.1（Setting Up WAL Archiving）之範例：先檢查目的地檔案
# 是否已存在，存在就不覆蓋——這是官方特別強調的防呆，因為歸檔失敗會自動重試，
# 沒有這個檢查可能用不完整的檔案把已正確歸檔的檔案蓋掉。官方原文也提到嚴謹
# 作法應在檔案已存在時比對內容（相同回傳成功、不同才回傳失敗），但官方範例
# 本身只要檔案存在就一律回傳非 0，不比對內容——這是官方文件自陳的範例限制，
# 非本文件疏漏。
# 編號排在 initdb（6.5）之後：initdb 完成時會自動產生一份內容為空的
# postgresql.auto.conf，這裡是對已存在的檔案追加寫入，不會讓 initdb 因為
# 目錄非空而失敗（詳見 6.5 註解）。
# 本文件不設定 WAL 歸檔（archive_mode / archive_command 維持官方預設值 off / ''），
# 歸檔由日後導入的備份工具（Barman / pgBackRest）負責設定。
# 注意：archive_mode 變更需重啟資料庫才會生效。
step_6_6_guc_write() {
  require_root || return 1
  echo "== [6.6] GUC 寫入 =="
  if [ ! -d "$NEW_PGDATA" ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} $NEW_PGDATA 不存在，請確認 6.2/6.5 是否已完成。" >&2
    return 1
  fi
  cat >> "${NEW_PGDATA}/postgresql.auto.conf" << EOF
listen_addresses = '${LISTEN_ADDRESSES}'
port = ${PORT}
shared_buffers = ${SHARED_BUFFERS}
max_connections = ${MAX_CONNECTIONS}
max_worker_processes = ${MAX_WORKER_PROCESSES}
autovacuum_worker_slots = ${AUTOVACUUM_WORKER_SLOTS}
max_files_per_process = ${MAX_FILES_PER_PROCESS}
max_prepared_transactions = ${MAX_PREPARED_TRANSACTIONS}
max_wal_senders = ${MAX_WAL_SENDERS}
max_replication_slots = ${MAX_REPLICATION_SLOTS}
huge_pages = ${HUGE_PAGES}
shared_preload_libraries = '${SHARED_PRELOAD_LIBRARIES}'
log_directory = '${NEW_PGLOG}'
logging_collector = on
EOF
  if [ $? -ne 0 ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} 寫入 ${NEW_PGDATA}/postgresql.auto.conf 失敗" >&2
    return 1
  fi
  echo -e "  ${C_GRN}[OK]${C_RST} GUC 已寫入 ${NEW_PGDATA}/postgresql.auto.conf"
}

# ════════════════════════════════════════════════════════════
# 七、EDB 安裝後的 OS 設定
# ════════════════════════════════════════════════════════════

# 7.1 SSH 金鑰交換
step_7_1_ssh_keys() {
  require_root || return 1
  echo "== [7.1] SSH 金鑰交換 =="
  for ENTRY in "${REMOTE_HOSTS[@]}"; do
    grep -qF "$ENTRY" /etc/hosts || echo "$ENTRY" >> /etc/hosts
  done

  # su 這個 heredoc 裡串了 keygen + 每一台的 ssh-copy-id，殼層回傳的是「最後
  # 一個指令」（也就是最後一台的 ssh-copy-id）的結束碼，只能反映最後一台是否
  # 成功；只要有任何一台失敗，畫面上都會印出對應的錯誤訊息，仍請往上捲確認
  # 是否每一台都真的成功，不能只看最終狀態。
  if ! su - enterprisedb << EOF

if [ ! -f ~/.ssh/id_rsa ]; then
	mkdir -p ~/.ssh
	chmod 700 ~/.ssh
	ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa
fi
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub

$(for ENTRY in "${REMOTE_HOSTS[@]}"; do
NAME=$(awk '{print $2}' <<< "$ENTRY")
echo "ssh-copy-id -o StrictHostKeyChecking=accept-new enterprisedb@${NAME}"
done)
EOF
  then
    echo -e "  ${C_RED}[CRIT]${C_RST} SSH 金鑰交換過程中至少最後一步失敗，請往上捲確認每一台 ssh-copy-id 的結果" >&2
    return 1
  fi
  echo -e "  ${C_GRN}[OK]${C_RST} SSH 金鑰交換完成"
}

# 7.2 Hugepage 精確設定
# 用 EDB 自己的 shared_memory_size_in_huge_pages 算出精確值，取代 5.10 的粗估。
step_7_2_hugepage_precise() {
  require_root || return 1
  echo "== [7.2] Hugepage 精確設定 =="
  local SCRATCH_PGDATA NR ENGINE_BINDIR PG_ENGINE

  # 不寫死 ${PG_BINDIR}/postgres：已實測確認 EPAS 18（/usr/edb/as18/bin）底下
  # 根本沒有 postgres 這支檔案，主程式是改名成 edb-postgres（同一目錄下
  # psql/edb-psql 也是並存的兩支，是 EDB 一貫的改名慣例）。-C
  # shared_memory_size_in_huge_pages 這個查詢方式本身是 PostgreSQL 官方文件
  # 記載的算法（見 18.4.5 Linux Huge Pages：
  # https://www.postgresql.org/docs/current/kernel-resources.html#LINUX-HUGE-PAGES ，
  # 官方範例即為 `postgres -D $PGDATA -C shared_memory_size_in_huge_pages`），
  # EPAS 沿用同一組 GUC／診斷旗標，只是主程式檔名不同，故這裡先用 pg_config
  # --bindir 問一次「這套安裝實際回報的 bin 目錄」，再從裡面找真正存在的
  # 執行檔（優先 postgres、其次 edb-postgres），而不是憑經驗寫死路徑。
  if [ ! -x "${PG_BINDIR}/pg_config" ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} 找不到 ${PG_BINDIR}/pg_config，請確認 6.1 是否已安裝成功。" >&2
    return 1
  fi
  ENGINE_BINDIR=$("${PG_BINDIR}/pg_config" --bindir 2>/dev/null)
  if [ -z "$ENGINE_BINDIR" ] || [ ! -d "$ENGINE_BINDIR" ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} ${PG_BINDIR}/pg_config --bindir 取不到有效目錄。" >&2
    return 1
  fi
  if [ -x "${ENGINE_BINDIR}/postgres" ]; then
    PG_ENGINE="${ENGINE_BINDIR}/postgres"
  elif [ -x "${ENGINE_BINDIR}/edb-postgres" ]; then
    PG_ENGINE="${ENGINE_BINDIR}/edb-postgres"
  else
    echo -e "  ${C_RED}[CRIT]${C_RST} 在 ${ENGINE_BINDIR} 找不到 postgres 或 edb-postgres 可執行檔，請人工確認實際檔名後修改本函式的 PG_ENGINE 判斷。" >&2
    return 1
  fi
  if [ ! -x "${ENGINE_BINDIR}/initdb" ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} ${ENGINE_BINDIR}/initdb 不存在。" >&2
    return 1
  fi

  SCRATCH_PGDATA=$(mktemp -d)
  echo "  本次探測用的暫時目錄：${SCRATCH_PGDATA}（結束後自動刪除，跟正式的 ${NEW_PGDATA} 無關）"
  chown enterprisedb:enterprisedb "$SCRATCH_PGDATA" || {
    echo -e "  ${C_RED}[CRIT]${C_RST} chown ${SCRATCH_PGDATA} 失敗" >&2
    rm -rf "$SCRATCH_PGDATA"
    return 1
  }

  # 改回直接呼叫 initdb 二進位檔、明確帶 -D 指到暫時目錄，不透過
  # edb-as-${EDB_VER}-setup 這類包裝腳本。原因：實測改用該包裝腳本後，這裡
  # 反而報「Data directory is not empty」——研判它很可能不是看這裡 export
  # 的 PGDATA，而是直接解析「已經安裝好的 systemd unit file」裡
  # Environment=PGDATA=... 那一行來決定目標目錄（6.3 已經把正式路徑寫進
  # 那一行），也就是說它很可能忽略了我們指定的暫時路徑，改去初始化 6.3
  # 設定、6.5 可能已經初始化過的正式 PGDATA——如果 6.5 還沒跑過，這甚至會
  # 用「只有 --auth=trust」這種不完整的參數，把正式叢集初始化成錯誤設定，
  # 風險比噴錯誤訊息更嚴重。initdb 本體的 -D 是 command line 顯式參數，不
  # 受任何包裝腳本內部邏輯影響，才能保證這裡動到的一定是暫時目錄。若這裡
  # 仍然失敗，請把完整錯誤輸出（尤其是它抱怨的目錄路徑）貼出來以便確認。
  if ! su - enterprisedb << EOF
${ENGINE_BINDIR}/initdb -D ${SCRATCH_PGDATA} --auth=trust
EOF
  then
    echo -e "  ${C_RED}[CRIT]${C_RST} 用來探測 hugepage 值的暫時 initdb 失敗（目標目錄：${SCRATCH_PGDATA}）" >&2
    rm -rf "$SCRATCH_PGDATA"
    return 1
  fi

  # su - enterprisedb 是完整登入 shell，PAM（pam_lastlog 之類）常會在真正的
  # 指令輸出「之前」多印一行 "Last login: ..." 之類的登入橫幅，混進這裡要
  # 擷取的數值裡（例如變成 "Last login: ...\n2164" 這種兩行字串）。用 grep
  # 只留下「整行純數字」的那一行，橫幅本身不會是純數字，直接濾掉，不管
  # 橫幅出現在前面、後面、還是有好幾行都不受影響。
  NR=$(su - enterprisedb << EOF | grep -E '^[0-9]+$' | tail -n1
${PG_ENGINE} -D ${SCRATCH_PGDATA} -C shared_memory_size_in_huge_pages -c shared_buffers=${SHARED_BUFFERS} -c max_connections=${MAX_CONNECTIONS} -c max_wal_senders=${MAX_WAL_SENDERS} -c max_worker_processes=${MAX_WORKER_PROCESSES} -c autovacuum_worker_slots=${AUTOVACUUM_WORKER_SLOTS}
EOF
)

  rm -rf "$SCRATCH_PGDATA"

  if [ -z "$NR" ] || ! [[ "$NR" =~ ^[0-9]+$ ]]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} 取得 shared_memory_size_in_huge_pages 失敗（NR=\"$NR\"），略過套用，請人工確認。" >&2
    return 1
  fi

  sysctl -w vm.nr_hugepages="$NR" || echo -e "  ${C_YEL}[WARN]${C_RST} sysctl -w vm.nr_hugepages 回傳非 0，請確認實際生效數量"
  # 跟 5.10 共用同一個 NR_HUGEPAGES marker：不論 5.10 的粗估值有沒有跑過，
  # 這裡都會把該區塊換成精確值，不會產生兩行 vm.nr_hugepages 互相打架。
  write_managed_block /etc/sysctl.d/80-edb-postgres.conf NR_HUGEPAGES <<< "vm.nr_hugepages = $NR" || {
    echo -e "  ${C_RED}[CRIT]${C_RST} 寫入 NR_HUGEPAGES 區塊失敗" >&2
    return 1
  }

  # 動到 hugepage 需要 restart service
  systemctl restart "${SERVICE_NAME}" || {
    echo -e "  ${C_RED}[CRIT]${C_RST} systemctl restart ${SERVICE_NAME} 失敗" >&2
    return 1
  }
  systemctl status "${SERVICE_NAME}" --no-pager
  echo -e "  ${C_GRN}[OK]${C_RST} 精確值 nr_hugepages=${NR} 已套用並重啟服務（使用執行檔：${PG_ENGINE}）"
}

# 7.3 Core Dump 更改權限
step_7_3_coredump_perm() {
  require_root || return 1
  echo "== [7.3] Core Dump 更改權限 =="
  mkdir -p /var/coredump || { echo -e "  ${C_RED}[CRIT]${C_RST} mkdir /var/coredump 失敗" >&2; return 1; }
  chown enterprisedb:enterprisedb /var/coredump || { echo -e "  ${C_RED}[CRIT]${C_RST} chown /var/coredump 失敗（enterprisedb 使用者是否已由 6.1 套件安裝建立？）" >&2; return 1; }
  chmod 750 /var/coredump || { echo -e "  ${C_RED}[CRIT]${C_RST} chmod /var/coredump 失敗" >&2; return 1; }
  echo -e "  ${C_GRN}[OK]${C_RST} /var/coredump 權限已設定"
}

# ════════════════════════════════════════════════════════════
# 步驟登錄表（面板顯示順序、標題、對應函式）
# ════════════════════════════════════════════════════════════
STEP_ORDER=(5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 5.9 5.10 5.11 5.12 5.13 6.1 6.2 6.3 6.4 6.5 6.6 7.1 7.2 7.3)
declare -A STEP_TITLE=(
  [5.1]="檢查 PGDATA_BASE 是否為獨立掛載磁碟"
  [5.2]="SELinux 停用"
  [5.3]="防火牆全開"
  [5.4]="本機 ISO Repository（非必要）"
  [5.5]="必要套件安裝狀態（自動補齊）"
  [5.6]="確認安裝媒介 / 套件庫可用"
  [5.7]="ulimit（NOFILE/NPROC）"
  [5.8]="Core Dump 設定"
  [5.9]="sysctl：記憶體 overcommit 與 dirty memory"
  [5.10]="Hugepage 設定（粗估值）"
  [5.11]="I/O Scheduler 與 Readahead"
  [5.12]="CPU 效能模式（Governor）設定"
  [5.13]="atime（PGDATA_BASE）"
  [6.1]="EDB 套件安裝"
  [6.2]="目錄準備"
  [6.3]="複製並修改 systemd Unit File"
  [6.4]="initdb 參數設定"
  [6.5]="執行 initdb"
  [6.6]="GUC 寫入"
  [7.1]="SSH 金鑰交換"
  [7.2]="Hugepage 精確設定"
  [7.3]="Core Dump 更改權限"
)
declare -A STEP_FUNC=(
  [5.1]=step_5_1_check_pgdata_mount
  [5.2]=step_5_2_selinux
  [5.3]=step_5_3_firewall
  [5.4]=step_5_4_iso_local_repo
  [5.5]=step_5_5_prereq_packages
  [5.6]=step_5_6_check_repo
  [5.7]=step_5_7_ulimit
  [5.8]=step_5_8_coredump
  [5.9]=step_5_9_sysctl_mem
  [5.10]=step_5_10_hugepage_estimate
  [5.11]=step_5_11_io_scheduler
  [5.12]=step_5_12_cpu_governor
  [5.13]=step_5_13_atime
  [6.1]=step_6_1_install_edb
  [6.2]=step_6_2_prepare_dirs
  [6.3]=step_6_3_systemd_unit
  [6.4]=step_6_4_initdb_params
  [6.5]=step_6_5_run_initdb
  [6.6]=step_6_6_guc_write
  [7.1]=step_7_1_ssh_keys
  [7.2]=step_7_2_hugepage_precise
  [7.3]=step_7_3_coredump_perm
)
declare -A STEP_CHAPTER=(
  [5.1]="五、作業系統設定" [5.2]="五、作業系統設定" [5.3]="五、作業系統設定"
  [5.4]="五、作業系統設定" [5.5]="五、作業系統設定" [5.6]="五、作業系統設定"
  [5.7]="五、作業系統設定" [5.8]="五、作業系統設定" [5.9]="五、作業系統設定"
  [5.10]="五、作業系統設定" [5.11]="五、作業系統設定" [5.12]="五、作業系統設定"
  [5.13]="五、作業系統設定"
  [6.1]="六、EDB 安裝作業" [6.2]="六、EDB 安裝作業" [6.3]="六、EDB 安裝作業"
  [6.4]="六、EDB 安裝作業" [6.5]="六、EDB 安裝作業" [6.6]="六、EDB 安裝作業"
  [7.1]="七、EDB 安裝後的 OS 設定" [7.2]="七、EDB 安裝後的 OS 設定" [7.3]="七、EDB 安裝後的 OS 設定"
)

# 執行單一步驟，統一記錄 log/state
run_step() {
  local id="$1" fn ret
  fn="${STEP_FUNC[$id]:-}"
  if [ -z "$fn" ]; then
    echo -e "${C_RED}[CRIT]${C_RST} 找不到步驟 $id" >&2
    return 1
  fi
  {
    echo "─────────────────────────────────────────"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 執行步驟 $id：${STEP_TITLE[$id]}"
  } | tee -a "$LOG_FILE"

  "$fn" 2>&1 | tee -a "$LOG_FILE"
  ret="${PIPESTATUS[0]}"
  if [ "$ret" -eq 0 ]; then
    state_set "$id" "done"
  else
    state_set "$id" "fail"
    echo -e "${C_RED}[CRIT]${C_RST} 步驟 $id 執行失敗（exit=$ret），詳見 $LOG_FILE" | tee -a "$LOG_FILE"
  fi
  return "$ret"
}

run_all() {
  local id
  for id in "${STEP_ORDER[@]}"; do
    run_step "$id" || { echo -e "${C_RED}[CRIT]${C_RST} 在步驟 $id 中止，未繼續往下執行。"; return 1; }
  done
  echo
  show_final_summary
}

run_chapter() {
  local chapter="$1" id
  for id in "${STEP_ORDER[@]}"; do
    [ "${STEP_CHAPTER[$id]}" = "$chapter" ] || continue
    run_step "$id" || { echo -e "${C_RED}[CRIT]${C_RST} 在步驟 $id 中止，本章未繼續往下執行。"; return 1; }
  done
  return 0
}

# run_chapter_num：用章節編號（5/6/7）執行整章，面板與命令列共用
run_chapter_num() {
  case "$1" in
    5) run_chapter "五、作業系統設定" ;;
    6) run_chapter "六、EDB 安裝作業" ;;
    7) run_chapter "七、EDB 安裝後的 OS 設定" ;;
    *) return 1 ;;
  esac
}

show_scope() {
  cat << 'EOF'
────────────────────────────────────────
一、適用範圍與前提假設
────────────────────────────────────────
- 作業系統：RHEL 8、RHEL 9（或相容的 Rocky Linux / AlmaLinux 8/9），
  並以 systemd 作為 init 系統。
- 部署架構：單機安裝，不涵蓋 HA / Streaming Replication / 叢集部署的
  額外設定。SSH 金鑰交換段落僅處理 standby/witness 主機的免密碼連線，
  不含 repmgr/Patroni 等 HA 工具設定。
- EDB 版本：需先在設定檔（edb_install_modular.conf）寫好要安裝的版本。
- 磁碟配置：假設機器上除了系統碟，其餘實體硬碟均為資料庫用途。若使用
  LVM 且邏輯磁區橫跨多個實體硬碟，磁碟偵測邏輯未涵蓋此情境。
- 網路/防火牆：全開，需要自己依實際需求調整。
- WAL 歸檔：本文件不設定（archive_mode 維持 off），日後導入備份工具時，
  archive_mode 需重啟資料庫方可生效。
- 設定檔內容需先向客戶確認，若客戶未提供則一律採用內建預設值。
- 任何套件安裝均預設透過 dnf install，EDB 套件本身走離線 repo（6.1），
  如作業系統層級套件也要離線安裝，需自行另建 offline repo。
EOF
}

show_param_table() {
  cat << 'EOF'
────────────────────────────────────────
二、參數對比
────────────────────────────────────────
2.1 OS 設定
  SELinux                : enforcing        -> disabled
  firewalld 預設 zone     : public           -> trusted
  ulimit nofile           : 系統預設          -> max_connections * max_files_per_process
  ulimit nproc            : 系統預設          -> max_connections + max_wal_senders
                                                 + max_worker_processes + autovacuum_worker_slots + 7
  ulimit core             : 0                -> unlimited
  kernel.core_pattern     : systemd-coredump  -> /var/coredump/core-%e-%p-%t
  vm.overcommit_memory    : 0                -> 2
  vm.overcommit_kbytes    : 0(用overcommit_ratio=50) -> 實際記憶體總量
  vm.swappiness           : 60               -> 1
  vm.dirty_bytes          : 0(用dirty_ratio=20)      -> 1 GB
  vm.dirty_background_bytes: 0(用dirty_background_ratio=10) -> 256 MB
  fs.file-max             : 依記憶體動態計算   -> nofile * 4
  vm.nr_hugepages         : 0                -> 粗估後、EDB裝完再依
                                                 shared_memory_size_in_huge_pages校正
  THP                     : always           -> never
  I/O scheduler           : SSD none / HDD mq-deadline（同左，僅明確寫死設定）
  read_ahead_kb           : 128 kB           -> 4096 kB
  enterprisedb SSH 金鑰    : 無               -> RSA 4096 金鑰對 + REMOTE_HOSTS ssh-copy-id

2.2 DB 相關設定
  listen_addresses  : localhost -> *
  data-checksums    : 依版本而定 -> 開
  locale            : 跟隨 OS LANG -> 依 NEED_ZH_LOCALE 決定 en_US.UTF-8 或 zh_TW.UTF-8
  waldir            : PGDATA/pg_wal -> ${NEW_WAL}
  log_directory     : log -> ${NEW_PGLOG}
  logging_collector : off -> on
EOF
}

# show_final_summary：不再只是把設定檔裡的變數印一次，而是針對「每個已完成
# 的步驟」實際去讀回系統上真正生效的值（sysctl -n、getenforce、cat /sys/...、
# grep 設定檔本身……），並標明這個值的來源檔案／指令，讓人可以照著來源自己
# 再確認一次。尚未執行過的步驟不會出現在「已套用的設定」清單裡（動過什麼
# 才列什麼），最後仍保留一份所有步驟的完成/失敗/未執行狀態總表。
# 不清畫面：run_all 結束後接在原本的執行 log 後面印出，互動面板下用 [F]
# 呼叫時也接在目前畫面下方，跟 show_scope/show_param_table 是同一種風格。
show_final_summary() {
  compute_ulimits
  {
  echo "======================================================"
  echo " 最終參數成果總覽（設定檔：${CONFIG_FILE}）"
  echo "======================================================"
  echo "-- 已套用的設定與來源（只列出已完成的步驟；值來自系統/檔案目前的實際內容，非單純內部變數）--"
  echo

  if step_is_done 5.2; then
    echo "[5.2] SELinux 停用"
    printf "  目前生效值（getenforce）  = %s\n" "$(getenforce 2>/dev/null || echo 未知)"
    printf "  開機設定值                = %s\n" "$(grep -E '^SELINUX=' /etc/selinux/config 2>/dev/null || echo 找不到)"
    echo "  來源：/etc/selinux/config"
    echo
  fi

  if step_is_done 5.3; then
    echo "[5.3] 防火牆全開"
    printf "  目前預設 zone             = %s\n" "$(firewall-cmd --get-default-zone 2>/dev/null || echo 未知)"
    printf "  目前 active zones         = %s\n" "$(firewall-cmd --get-active-zones 2>/dev/null | tr '\n' ' ')"
    echo "  來源：firewalld 執行期狀態（持久化於 /etc/firewalld/firewalld.conf 與 /etc/firewalld/zones/）"
    echo
  fi

  if step_is_done 5.4; then
    echo "[5.4] 本機 ISO Repository"
    if [ -f /etc/yum.repos.d/local.repo ]; then
      grep -E '^baseurl' /etc/yum.repos.d/local.repo | sed 's/^/  /'
      echo "  來源：/etc/yum.repos.d/local.repo"
    else
      echo "  當時已略過，未建立 local repo。"
    fi
    echo
  fi

  if step_is_done 5.7; then
    echo "[5.7] ulimit（NOFILE/NPROC）"
    if [ -f /etc/security/limits.d/80-edb-postgres.conf ]; then
      grep enterprisedb /etc/security/limits.d/80-edb-postgres.conf | sed 's/^/  /'
    else
      echo "  找不到 /etc/security/limits.d/80-edb-postgres.conf"
    fi
    echo "  來源：/etc/security/limits.d/80-edb-postgres.conf"
    echo
  fi

  if step_is_done 5.8; then
    echo "[5.8] Core Dump 設定"
    printf "  目前生效值（sysctl）      = %s\n" "$(sysctl -n kernel.core_pattern 2>/dev/null || echo 未知)"
    echo "  來源：/etc/sysctl.d/80-edb-postgres.conf（CORE_PATTERN 區塊）"
    echo
  fi

  if step_is_done 5.9; then
    echo "[5.9] sysctl：記憶體 overcommit 與 dirty memory"
    local k
    for k in vm.overcommit_memory vm.overcommit_kbytes vm.swappiness vm.dirty_bytes vm.dirty_background_bytes fs.file-max; do
      printf "  %-28s = %s\n" "$k" "$(sysctl -n "$k" 2>/dev/null || echo 未知)"
    done
    echo "  來源：/etc/sysctl.d/80-edb-postgres.conf（MEM_OVERCOMMIT 區塊）"
    echo
  fi

  if step_is_done 5.10 || step_is_done 7.2; then
    echo "[5.10/7.2] Hugepage（vm.nr_hugepages，5.10 粗估、7.2 校正為精確值，共用同一設定區塊）"
    printf "  目前生效值（sysctl）      = %s\n" "$(sysctl -n vm.nr_hugepages 2>/dev/null || echo 未知)"
    local t510 t72 last
    t510=$(state_get 5.10); t72=$(state_get 7.2)
    if [ -n "$t72" ] && { [ -z "$t510" ] || [ "${t72%% *}" -ge "${t510%% *}" ]; }; then
      last="7.2（精確值）"
    else
      last="5.10（粗估值）"
    fi
    echo "  最後套用的步驟            = $last"
    echo "  來源：/etc/sysctl.d/80-edb-postgres.conf（NR_HUGEPAGES 區塊）"
    echo
  fi

  if step_is_done 5.11; then
    echo "[5.11] I/O Scheduler 與 Readahead"
    local dev sched
    for dev in $(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
      [ -e "/sys/block/${dev}/queue/scheduler" ] || continue
      sched=$(grep -oE '\[[a-z-]+\]' "/sys/block/${dev}/queue/scheduler" 2>/dev/null | tr -d '[]')
      printf "  %-10s scheduler=%-14s read_ahead_kb=%s\n" "$dev" "${sched:-未知}" "$(cat "/sys/block/${dev}/queue/read_ahead_kb" 2>/dev/null)"
    done
    echo "  來源：/usr/local/sbin/edb-os-tuning.sh（IO_SCHEDULER 區塊，由 edb-os-tuning.service 開機時執行套用）"
    echo
  fi

  if step_is_done 5.12; then
    echo "[5.12] CPU 效能模式（Governor）"
    printf "  cpu0 scaling_governor     = %s\n" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 未知)"
    if [ -f /sys/devices/system/cpu/intel_pstate/min_perf_pct ]; then
      printf "  intel_pstate min_perf_pct = %s\n" "$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null)"
    fi
    echo "  來源：/usr/local/sbin/edb-os-tuning.sh（CPU_GOVERNOR 區塊，由 edb-os-tuning.service 開機時執行套用）"
    echo
  fi

  if step_is_done 5.13 || step_is_done 6.2; then
    echo "[5.13/6.2] atime 與目錄擁有者"
    printf "  %s mount options = %s\n" "$PGDATA_BASE" "$(findmnt -no OPTIONS --target "$PGDATA_BASE" 2>/dev/null || echo 未知)"
    printf "  %s mount options = %s\n" "$NEW_WAL" "$(findmnt -no OPTIONS --target "$NEW_WAL" 2>/dev/null || echo 未知)"
    if step_is_done 6.2; then
      ls -ld "$NEW_PGDATA" "$NEW_WAL" "$NEW_PGLOG" 2>/dev/null | sed 's/^/  /'
    fi
    echo "  來源：/etc/fstab（noatime）；目錄擁有者見上方 ls -ld"
    echo
  fi

  if step_is_done 6.1; then
    echo "[6.1] EDB 套件安裝"
    printf "  已安裝版本                = %s\n" "$(rpm -q "edb-as${EDB_VER}-server" 2>/dev/null || echo 未知)"
    echo "  來源：/etc/yum.repos.d/edb-offline.repo（baseurl=file://${REPO_DIR}）"
    echo
  fi

  if step_is_done 6.3; then
    echo "[6.3] systemd Unit File"
    if [ -f "$UNIT_DST" ]; then
      grep -E '^(Environment=PGDATA|PIDFile|LimitNOFILE|LimitNPROC|LimitCORE|After=edb-os-tuning.service)' "$UNIT_DST" | sed 's/^/  /'
    else
      echo "  找不到 $UNIT_DST"
    fi
    echo "  來源：$UNIT_DST"
    echo
  fi

  if step_is_done 6.5; then
    echo "[6.5] 執行 initdb"
    if [ -f "${NEW_PGDATA}/PG_VERSION" ]; then
      printf "  PG_VERSION 內容           = %s\n" "$(cat "${NEW_PGDATA}/PG_VERSION" 2>/dev/null)"
    else
      echo "  找不到 ${NEW_PGDATA}/PG_VERSION"
    fi
    echo "  來源：${NEW_PGDATA}（initdb 產出的資料目錄）"
    echo
  fi

  if step_is_done 6.6; then
    echo "[6.6] GUC 寫入"
    if [ -f "${NEW_PGDATA}/postgresql.auto.conf" ]; then
      grep -E '^(listen_addresses|port|shared_buffers|max_connections|max_worker_processes|autovacuum_worker_slots|max_files_per_process|max_prepared_transactions|max_wal_senders|max_replication_slots|huge_pages|shared_preload_libraries|log_directory|logging_collector) =' "${NEW_PGDATA}/postgresql.auto.conf" | sed 's/^/  /'
    else
      echo "  找不到 ${NEW_PGDATA}/postgresql.auto.conf"
    fi
    echo "  來源：${NEW_PGDATA}/postgresql.auto.conf"
    echo
  fi

  if step_is_done 7.1; then
    echo "[7.1] SSH 金鑰交換"
    local h
    for h in "${REMOTE_HOSTS[@]}"; do
      echo "  - $h"
    done
    echo "  來源：/etc/hosts（本機端寫入）；各 standby/witness 主機的 ~enterprisedb/.ssh/authorized_keys 需至對方主機確認"
    echo
  fi

  if step_is_done 7.3; then
    echo "[7.3] Core Dump 目錄權限"
    ls -ld /var/coredump 2>/dev/null | sed 's/^/  /' || echo "  找不到 /var/coredump"
    echo "  來源：/var/coredump（chown/chmod 直接作用於目錄，無額外設定檔）"
    echo
  fi

  echo "-- 已執行、但無獨立設定值可列（安裝/檢查/暫存環境變數）的步驟 --"
  local id has_other=0
  for id in 5.1 5.5 5.6 6.4; do
    if step_is_done "$id"; then
      printf "  [%s] %s\n" "$id" "${STEP_TITLE[$id]}"
      has_other=1
    fi
  done
  [ "$has_other" -eq 0 ] && echo "  （無）"
  echo

  echo "-- 各步驟目前執行狀態 --"
  local id st ts status_str mark lasttime
  for id in "${STEP_ORDER[@]}"; do
    st=$(state_get "$id")
    mark="未執行"; lasttime="—"
    if [ -n "$st" ]; then
      ts="${st%% *}"; status_str="${st#* }"
      lasttime=$(fmt_time "$ts")
      if [ "$status_str" = "done" ]; then mark="已完成"; else mark="失敗"; fi
    fi
    printf "  %-6s %-38s %-8s %s\n" "$id" "${STEP_TITLE[$id]}" "$mark" "$lasttime"
  done
  echo "======================================================"
  } | tee -a "$LOG_FILE"
}

# ════════════════════════════════════════════════════════════
# 當下值檢查（[V] / --check）
# 跟 show_final_summary 不同：不看步驟有沒有跑過，一律直接去系統讀「此刻」
# 的實際值，並跟本腳本的目標值比對。查不到的項目（檔案不存在、服務或資料庫
# 未啟動……）標示為「未建立」或「無法查詢」，不中斷檢查。
# 終端機上「當前」值以顏色標示比對結果（綠＝一致、紅＝不一致、黃＝未建立/
# 無法查詢），寫進 log 時會去掉顏色控制碼。
# ════════════════════════════════════════════════════════════
CV_SEP="----------------------------------------"

# cv_item：印一個檢查項目
# $1=步驟代號  $2=項目名稱  $3=來源
# $4=當前值（空字串＝未建立；以「無法查詢」開頭＝查不到的原因說明）
# $5=目標值（空字串＝只列出、不比對）
# $6=（選填）正規表示式，多種值都算正確時使用
# $7=（選填）額外一行，印在「當前」與「目標」之間（例如 GUC 的執行中值）
cv_item() {
  local step="$1" label="$2" src="$3" cur="$4" tgt="$5" re="${6:-}" extra="${7:-}" color=""
  if [ -z "$cur" ]; then
    cur="未建立"; color="$C_YEL"; CV_NONE=$((CV_NONE+1))
  elif [[ "$cur" == 無法查詢* ]]; then
    color="$C_YEL"; CV_NONE=$((CV_NONE+1))
  elif [ -z "$tgt" ]; then
    :
  elif [ "$cur" = "$tgt" ] || { [ -n "$re" ] && [[ "$cur" =~ $re ]]; }; then
    color="$C_GRN"; CV_OK=$((CV_OK+1))
  else
    color="$C_RED"; CV_DIFF=$((CV_DIFF+1))
  fi
  echo "$CV_SEP"
  echo " [$step] $label"
  echo "$CV_SEP"
  echo "    來源：$src"
  echo -e "    當前：${color}${cur}${color:+$C_RST}"
  [ -n "$extra" ] && echo "    $extra"
  echo "    目標：${tgt:-—（僅列出，不比對）}"
}

# cv_note：附在上一個項目下方的補充說明
cv_note() {
  echo "    備註：$1"
}

# limits.d 檔案裡 enterprisedb 某一項的 soft/hard 值　$1=nofile|nproc|core
cv_limits_file() {
  local f=/etc/security/limits.d/80-edb-postgres.conf
  [ -f "$f" ] || return 0
  awk -v i="$1" '$1=="enterprisedb" && $3==i {v[$2]=$4} END{if (v["soft"] v["hard"] != "") print v["soft"]"/"v["hard"]}' "$f"
}

# 執行中程序實際套用的 limit（soft/hard）　$1=PID $2=/proc/PID/limits 的欄位名稱
cv_proc_limit() {
  awk -v k="$2" 'index($0,k)==1 {split(substr($0,length(k)+1),a," "); print a[1]"/"a[2]}' \
    "/proc/$1/limits" 2>/dev/null
}

# postgresql.auto.conf 裡某個 GUC 最後一次出現的值（去掉引號）
cv_autoconf() {
  grep -E "^[[:space:]]*$1[[:space:]]*=" "${NEW_PGDATA}/postgresql.auto.conf" 2>/dev/null | tail -n1 |
    sed -E "s/^[^=]*=[[:space:]]*//; s/^'//; s/'[[:space:]]*$//"
}

# 以 enterprisedb 身分對執行中的資料庫下查詢，連不上就回傳空字串
cv_psql() {
  timeout 10 runuser -u enterprisedb -- "${PG_BINDIR}/psql" -X -A -t -q -p "$PORT" -d postgres -c "$1" 2>/dev/null
}

show_current_values() {
  require_root || return 1
  compute_ulimits
  CV_OK=0; CV_DIFF=0; CV_NONE=0
  local v k f dev rota want root_src root_dev pm_pid="" db_ok=0 name val pend extra
  local LIMITS_SRC=/etc/security/limits.d/80-edb-postgres.conf
  local SYSCTL_SRC="sysctl -n (/etc/sysctl.d/80-edb-postgres.conf)"
  local AUTOCONF="${NEW_PGDATA}/postgresql.auto.conf"
  local -A LIVE PEND
  local GUC_KEYS=(listen_addresses port shared_buffers max_connections max_worker_processes
    autovacuum_worker_slots max_files_per_process max_prepared_transactions max_wal_senders
    max_replication_slots huge_pages shared_preload_libraries log_directory logging_collector)
  local -A GUC_TGT=(
    [listen_addresses]="$LISTEN_ADDRESSES" [port]="$PORT" [shared_buffers]="$SHARED_BUFFERS"
    [max_connections]="$MAX_CONNECTIONS" [max_worker_processes]="$MAX_WORKER_PROCESSES"
    [autovacuum_worker_slots]="$AUTOVACUUM_WORKER_SLOTS" [max_files_per_process]="$MAX_FILES_PER_PROCESS"
    [max_prepared_transactions]="$MAX_PREPARED_TRANSACTIONS" [max_wal_senders]="$MAX_WAL_SENDERS"
    [max_replication_slots]="$MAX_REPLICATION_SLOTS" [huge_pages]="$HUGE_PAGES"
    [shared_preload_libraries]="$SHARED_PRELOAD_LIBRARIES" [log_directory]="$NEW_PGLOG"
    [logging_collector]="on"
  )

  if [ -f "${NEW_PGDATA}/postmaster.pid" ]; then
    pm_pid=$(head -n1 "${NEW_PGDATA}/postmaster.pid" 2>/dev/null)
    kill -0 "$pm_pid" 2>/dev/null || pm_pid=""
  fi
  if [ -n "$pm_pid" ] && [ -x "${PG_BINDIR}/psql" ]; then
    local in_list; in_list=$(printf "'%s'," "${GUC_KEYS[@]}"); in_list="${in_list%,}"
    while IFS='|' read -r name val pend; do
      [ -n "$name" ] || continue
      LIVE[$name]="$val"; PEND[$name]="$pend"; db_ok=1
    done < <(cv_psql "SELECT name, current_setting(name), pending_restart FROM pg_settings WHERE name IN (${in_list})")
  fi

  {
  echo "========================================"
  echo " 當下值檢查 — $(hostname)  $(date '+%Y-%m-%d %H:%M:%S')"
  echo " 不論步驟是否執行過，一律讀取系統此刻的實際值並與目標值比對"
  echo "========================================"

  # SELinux
  cv_item "5.2" "SELinux（當前 Session）" "getenforce" \
    "$(getenforce 2>/dev/null)" "Disabled" '^(Disabled|Permissive)$'
  cv_note "setenforce 0 之後、重開機之前會顯示 Permissive，視為一致"
  cv_item "5.2" "SELinux（開機設定）" "/etc/selinux/config" \
    "$(awk -F= '/^SELINUX=/{print $2}' /etc/selinux/config 2>/dev/null)" "disabled"

  # Firewall
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    v=$(firewall-cmd --get-default-zone 2>/dev/null)
  else
    v="無法查詢（firewalld 未執行）"
  fi
  cv_item "5.3" "firewalld 預設 zone" "firewall-cmd --get-default-zone" "$v" "trusted"

  # ulimit
  cv_item "5.7" "nofile soft/hard （設定檔）" "$LIMITS_SRC" "$(cv_limits_file nofile)" "${NOFILE}/${NOFILE}"
  cv_item "5.7" "nproc soft/hard （設定檔）" "$LIMITS_SRC" "$(cv_limits_file nproc)" "${NPROC}/${NPROC}"
  cv_item "5.7" "core soft/hard （設定檔）" "$LIMITS_SRC" "$(cv_limits_file core)" "unlimited/unlimited"
  if [ -n "$pm_pid" ]; then
    cv_item "5.7/6.3" "nofile （postmaster 執行中）" "/proc/${pm_pid}/limits" \
      "$(cv_proc_limit "$pm_pid" 'Max open files')" "${NOFILE}/${NOFILE}"
    cv_item "5.7/6.3" "nproc （postmaster 執行中）" "/proc/${pm_pid}/limits" \
      "$(cv_proc_limit "$pm_pid" 'Max processes')" "${NPROC}/${NPROC}"
    cv_item "5.7/6.3" "core （postmaster 執行中）" "/proc/${pm_pid}/limits" \
      "$(cv_proc_limit "$pm_pid" 'Max core file size')" "unlimited/unlimited"
  else
    cv_item "5.7/6.3" "limit（postmaster 執行中）" "/proc/<postmaster PID>/limits" "無法查詢（資料庫未啟動）" ""
  fi
  cv_note "以 systemctl 啟動時，實際生效的是 unit file 的 LimitNOFILE/LimitNPROC/LimitCORE（見 6.3）"

  # sysctl
  cv_item "5.8" "kernel.core_pattern" "$SYSCTL_SRC" \
    "$(sysctl -n kernel.core_pattern 2>/dev/null)" "/var/coredump/core-%e-%p-%t"
  cv_item "5.9" "vm.overcommit_memory" "$SYSCTL_SRC" "$(sysctl -n vm.overcommit_memory 2>/dev/null)" "2"
  cv_item "5.9" "vm.overcommit_kbytes" "$SYSCTL_SRC" \
    "$(sysctl -n vm.overcommit_kbytes 2>/dev/null)" "$(awk '/^MemTotal/{print $2}' /proc/meminfo)"
  cv_item "5.9" "vm.swappiness" "$SYSCTL_SRC" "$(sysctl -n vm.swappiness 2>/dev/null)" "1"
  cv_item "5.9" "vm.dirty_bytes" "$SYSCTL_SRC" "$(sysctl -n vm.dirty_bytes 2>/dev/null)" "$((1024*1024*1024))"
  cv_item "5.9" "vm.dirty_background_bytes" "$SYSCTL_SRC" \
    "$(sysctl -n vm.dirty_background_bytes 2>/dev/null)" "$((1024*1024*1024/4))"
  cv_item "5.9" "fs.file-max" "$SYSCTL_SRC" "$(sysctl -n fs.file-max 2>/dev/null)" "$((NOFILE * 4))"
  cv_item "5.10/7.2" "vm.nr_hugepages" "$SYSCTL_SRC" "$(sysctl -n vm.nr_hugepages 2>/dev/null)" ""
  cv_note "目標值依 5.10 粗估或 7.2 精確計算而定，此處只列出不比對"
  cv_item "5.10/7.2" "HugePages_Total / Free" "/proc/meminfo" \
    "$(awk '/^HugePages_Total/{t=$2} /^HugePages_Free/{f=$2} END{print t" / "f}' /proc/meminfo)" ""

  # 開機調校腳本
  if [ -f /etc/systemd/system/edb-os-tuning.service ]; then
    v=$(systemctl is-enabled edb-os-tuning.service 2>/dev/null)
  else
    v=""
  fi
  cv_item "5.11/5.12" "edb-os-tuning.service" "systemctl is-enabled edb-os-tuning.service" "$v" "enabled"
  cv_item "5.11" "THP（Transparent Huge Pages）" "/sys/kernel/mm/transparent_hugepage/enabled" \
    "$(grep -oE '\[[a-z]+\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | tr -d '[]')" "never"
  root_src=$(findmnt -n -o SOURCE --target / 2>/dev/null)
  root_dev=$(lsblk -no PKNAME "$root_src" 2>/dev/null)
  [ -z "$root_dev" ] && root_dev=$(basename "$root_src" | sed -E 's/[0-9]+$//')
  for dev in $(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
    [ "$dev" = "$root_dev" ] && continue
    [ -e "/sys/block/${dev}/queue/scheduler" ] || continue
    rota=$(cat "/sys/block/${dev}/queue/rotational" 2>/dev/null)
    if [ "$rota" = "0" ]; then want=none; else want=mq-deadline; fi
    cv_item "5.11" "${dev} I/O scheduler" "/sys/block/${dev}/queue/scheduler" \
      "$(grep -oE '\[[a-z-]+\]' "/sys/block/${dev}/queue/scheduler" 2>/dev/null | tr -d '[]')" "$want"
    cv_item "5.11" "${dev} read_ahead_kb" "/sys/block/${dev}/queue/read_ahead_kb" \
      "$(cat "/sys/block/${dev}/queue/read_ahead_kb" 2>/dev/null)" "4096"
  done
  f=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
  if [ -e "$f" ]; then
    cv_item "5.12" "CPU governor（cpu0）" "$f" "$(cat "$f" 2>/dev/null)" "performance"
  else
    cv_item "5.12" "CPU governor（cpu0）" "$f" "無法查詢（無 cpufreq 介面，常見於虛擬機）" ""
  fi
  f=/sys/devices/system/cpu/intel_pstate/min_perf_pct
  if [ -e "$f" ]; then
    cv_item "5.12" "intel_pstate min_perf_pct" "$f" "$(cat "$f" 2>/dev/null)" "100"
  fi

  # 掛載與目錄
  for f in "$PGDATA_BASE" "$NEW_WAL"; do
    if [ -e "$f" ]; then
      v=$(findmnt -no OPTIONS --target "$f" 2>/dev/null | tr ',' '\n' | grep -x noatime)
      v="${v:-未設定}"
    else
      v=""
    fi
    cv_item "5.13/6.2" "${f} noatime" "findmnt -no OPTIONS --target ${f}" "$v" "noatime"
  done
  for f in "$NEW_PGDATA" "$NEW_WAL" "$NEW_PGLOG"; do
    cv_item "6.2" "${f} 擁有者" "stat -c %U:%G" "$(stat -c '%U:%G' "$f" 2>/dev/null)" "enterprisedb:enterprisedb"
  done
  cv_item "7.3" "/var/coredump 擁有者/權限" "stat -c '%U:%G %a'" \
    "$(stat -c '%U:%G %a' /var/coredump 2>/dev/null)" "enterprisedb:enterprisedb 750"

  # EDB 套件與 systemd unit
  v=$(rpm -q "edb-as${EDB_VER}-server" 2>/dev/null) || v=""
  cv_item "6.1" "edb-as${EDB_VER}-server 套件" "rpm -q" "$v" ""
  cv_item "6.1" "edb-offline repo baseurl" "/etc/yum.repos.d/edb-offline.repo" \
    "$(awk -F= '/^baseurl/{print $2}' /etc/yum.repos.d/edb-offline.repo 2>/dev/null)" "file://${REPO_DIR}"
  if [ -f "$UNIT_DST" ]; then
    cv_item "6.3" "Environment=PGDATA" "$UNIT_DST" \
      "$(awk -F'PGDATA=' '/^Environment=PGDATA=/{print $2}' "$UNIT_DST")" "$NEW_PGDATA"
    cv_item "6.3" "LimitNOFILE" "$UNIT_DST" "$(awk -F= '/^LimitNOFILE=/{print $2}' "$UNIT_DST")" "$NOFILE"
    cv_item "6.3" "LimitNPROC" "$UNIT_DST" "$(awk -F= '/^LimitNPROC=/{print $2}' "$UNIT_DST")" "$NPROC"
    cv_item "6.3" "LimitCORE" "$UNIT_DST" "$(awk -F= '/^LimitCORE=/{print $2}' "$UNIT_DST")" "infinity"
    cv_item "6.3" "After=edb-os-tuning.service" "$UNIT_DST" \
      "$(grep -qx 'After=edb-os-tuning.service' "$UNIT_DST" && echo 有)" "有"
  else
    cv_item "6.3" "systemd unit file" "$UNIT_DST" "" ""
  fi

  # initdb 結果
  if [ -f "${NEW_PGDATA}/PG_VERSION" ]; then
    v=$(LC_ALL=C "${PG_BINDIR}/pg_controldata" "$NEW_PGDATA" 2>/dev/null | awk -F: '/Data page checksum version/{gsub(/ /,"",$2); print $2}')
    case "$v" in 0) v=off ;; "") v="無法查詢（pg_controldata 讀取失敗）" ;; *) v=on ;; esac
    cv_item "6.4/6.5" "data_checksums" "pg_controldata" "$v" "on"
    cv_item "6.4/6.5" "waldir（pg_wal 指向）" "readlink ${NEW_PGDATA}/pg_wal" \
      "$(readlink "${NEW_PGDATA}/pg_wal" 2>/dev/null)" "$NEW_WAL"
    if [ "$db_ok" -eq 1 ]; then
      v=$(cv_psql "SELECT datcollate FROM pg_database WHERE datname='postgres'")
    else
      v="無法查詢（資料庫未啟動或無法連線）"
    fi
    if [ "$NEED_ZH_LOCALE" = "yes" ]; then want="zh_TW.UTF-8"; else want="en_US.UTF-8"; fi
    cv_item "6.4/6.5" "locale（datcollate）" "pg_database" "$v" "$want" '^(en_US|zh_TW)\.(UTF-8|utf8)$'
  else
    cv_item "6.5" "資料目錄（initdb）" "${NEW_PGDATA}/PG_VERSION" "" ""
  fi

  # GUC
  if [ ! -f "$AUTOCONF" ]; then
    cv_item "6.6" "postgresql.auto.conf" "$AUTOCONF" "" ""
  else
    for k in "${GUC_KEYS[@]}"; do
      if [ "$db_ok" -eq 1 ]; then
        if [ -n "${LIVE[$k]+x}" ]; then
          extra="執行中：${LIVE[$k]}"
          [ "${PEND[$k]}" = "t" ] && extra+="　※ 已修改、待重啟生效"
        else
          extra="執行中：無法查詢（此版本無此參數）"
        fi
      else
        extra="執行中：無法查詢（資料庫未啟動或無法連線）"
      fi
      cv_item "6.6" "$k" "$AUTOCONF；執行中值來自 pg_settings" \
        "$(cv_autoconf "$k")" "${GUC_TGT[$k]}" "" "$extra"
    done
  fi

  echo "========================================"
  printf " 一致 %d 項　不一致 %d 項　未建立/無法查詢 %d 項\n" "$CV_OK" "$CV_DIFF" "$CV_NONE"
  echo "========================================"
  } 2>&1 | tee >(sed -E $'s/\x1b\\[[0-9;]*m//g' >> "$LOG_FILE")
}

# ════════════════════════════════════════════════════════════
# 參數編輯（比照 pg_healthcheck.sh 的 edit_params()/update_config() 模式：
# 直接在面板裡改「三、參數宣告」的值，不用跳出去手動編輯 .conf。改完立刻
# source 設定檔＋重算衍生變數，同一次面板 session 內就會用新值。）
# ════════════════════════════════════════════════════════════

# update_config：把設定檔裡「KEY=...」那一行的值換成新值，保留行尾原本的
# # 註解（如果有的話）。只負責寫檔，呼叫端要自己再 source 設定檔才會生效。
update_config() {
  local key="$1" val="$2"
  if ! grep -q "^${key}=" "$CONFIG_FILE"; then
    echo -e "  ${C_RED}[CRIT]${C_RST} 設定檔裡找不到 ${key}=，未寫入。" >&2
    return 1
  fi
  sed -i -E "s@^(${key})=[^#]*(#.*)?\$@\1=\"${val}\" \2@" "$CONFIG_FILE"
}

# reset_remote_hosts：整批換掉 REMOTE_HOSTS 陣列的內容（保留陣列前後的宣告
# 與註解行），供 edit_remote_hosts 使用。
reset_remote_hosts() {
  local entries=("$@") tmp out line inserted=0 e
  tmp=$(mktemp); out=$(mktemp)
  awk '
    /^REMOTE_HOSTS=\(/ { print; skip=1; next }
    skip && /^\)/ { skip=0 }
    !skip { print }
  ' "$CONFIG_FILE" > "$tmp"
  while IFS= read -r line; do
    echo "$line" >> "$out"
    if [[ "$line" == "REMOTE_HOSTS=("* ]] && [ "$inserted" -eq 0 ]; then
      for e in "${entries[@]}"; do
        printf '  "%s"\n' "$e" >> "$out"
      done
      inserted=1
    fi
  done < "$tmp"
  mv "$out" "$CONFIG_FILE"
  rm -f "$tmp"
}

edit_remote_hosts() {
  local choice entry new_list i
  while true; do
    clear 2>/dev/null || true
    echo "== REMOTE_HOSTS（standby/witness 主機清單，7.1 SSH 金鑰交換用）=="
    for i in "${!REMOTE_HOSTS[@]}"; do
      echo "  [$((i+1))] ${REMOTE_HOSTS[$i]}"
    done
    [ "${#REMOTE_HOSTS[@]}" -eq 0 ] && echo "  （目前是空的）"
    echo
    echo "[A] 新增一筆   [R] 整批重新輸入   [B] 返回"
    read -erp "> " choice
    case "$choice" in
      [aA])
        read -erp "  新增一筆，格式「IP 主機名稱」： " entry
        if [ -n "$entry" ]; then
          new_list=("${REMOTE_HOSTS[@]}" "$entry")
          reset_remote_hosts "${new_list[@]}"
          source "$CONFIG_FILE"
        fi
        ;;
      [rR])
        echo "  逐行輸入「IP 主機名稱」，空白行結束："
        new_list=()
        while true; do
          read -erp "  > " entry
          [ -z "$entry" ] && break
          new_list+=("$entry")
        done
        reset_remote_hosts "${new_list[@]}"
        source "$CONFIG_FILE"
        ;;
      [bB]) return ;;
      *) echo "無效選項"; sleep 1 ;;
    esac
  done
}

edit_params() {
  local p v
  while true; do
    clear 2>/dev/null || true
    echo "== 參數設定（對應原文件「三、參數宣告」，設定檔：${CONFIG_FILE}）=="
    echo "  [1]  NEED_ZH_LOCALE            = ${NEED_ZH_LOCALE}"
    echo "  [2]  EDB_VER                   = ${EDB_VER}"
    echo "  [3]  REPO_DIR                  = ${REPO_DIR}"
    echo "  [4]  ISO_MOUNT_DIR             = ${ISO_MOUNT_DIR}"
    echo "  [5]  MAX_CONNECTIONS           = ${MAX_CONNECTIONS}"
    echo "  [6]  MAX_WORKER_PROCESSES      = ${MAX_WORKER_PROCESSES}"
    echo "  [7]  AUTOVACUUM_WORKER_SLOTS   = ${AUTOVACUUM_WORKER_SLOTS}"
    echo "  [8]  MAX_WAL_SENDERS           = ${MAX_WAL_SENDERS}"
    echo "  [9]  MAX_FILES_PER_PROCESS     = ${MAX_FILES_PER_PROCESS}"
    echo "  [10] PGDATA_BASE               = ${PGDATA_BASE}"
    echo "  [11] LISTEN_ADDRESSES          = ${LISTEN_ADDRESSES}"
    echo "  [12] PORT                      = ${PORT}"
    echo "  [13] SHARED_BUFFERS            = ${SHARED_BUFFERS}"
    echo "  [14] MAX_PREPARED_TRANSACTIONS = ${MAX_PREPARED_TRANSACTIONS}"
    echo "  [15] MAX_REPLICATION_SLOTS     = ${MAX_REPLICATION_SLOTS}"
    echo "  [16] HUGE_PAGES                = ${HUGE_PAGES}"
    echo "  [17] SHARED_PRELOAD_LIBRARIES  = ${SHARED_PRELOAD_LIBRARIES}"
    echo "  [R]  REMOTE_HOSTS（standby/witness 清單，目前 ${#REMOTE_HOSTS[@]} 筆）"
    echo "  [E]  用編輯器（\$EDITOR）開整份設定檔"
    echo "  [B]  返回主選單"
    read -erp "> " p
    case "$p" in
      1) read -erp "新值（NEED_ZH_LOCALE, yes/no）: " v; [ -n "$v" ] && update_config NEED_ZH_LOCALE "$v" ;;
      2) read -erp "新值（EDB_VER）: " v; [ -n "$v" ] && update_config EDB_VER "$v" ;;
      3) read -erp "新值（REPO_DIR）: " v; [ -n "$v" ] && update_config REPO_DIR "$v" ;;
      4) read -erp "新值（ISO_MOUNT_DIR）: " v; [ -n "$v" ] && update_config ISO_MOUNT_DIR "$v" ;;
      5) read -erp "新值（MAX_CONNECTIONS）: " v; [ -n "$v" ] && update_config MAX_CONNECTIONS "$v" ;;
      6) read -erp "新值（MAX_WORKER_PROCESSES）: " v; [ -n "$v" ] && update_config MAX_WORKER_PROCESSES "$v" ;;
      7) read -erp "新值（AUTOVACUUM_WORKER_SLOTS）: " v; [ -n "$v" ] && update_config AUTOVACUUM_WORKER_SLOTS "$v" ;;
      8) read -erp "新值（MAX_WAL_SENDERS）: " v; [ -n "$v" ] && update_config MAX_WAL_SENDERS "$v" ;;
      9) read -erp "新值（MAX_FILES_PER_PROCESS）: " v; [ -n "$v" ] && update_config MAX_FILES_PER_PROCESS "$v" ;;
      10) read -erp "新值（PGDATA_BASE）: " v; [ -n "$v" ] && update_config PGDATA_BASE "$v" ;;
      11) read -erp "新值（LISTEN_ADDRESSES）: " v; [ -n "$v" ] && update_config LISTEN_ADDRESSES "$v" ;;
      12) read -erp "新值（PORT）: " v; [ -n "$v" ] && update_config PORT "$v" ;;
      13) read -erp "新值（SHARED_BUFFERS）: " v; [ -n "$v" ] && update_config SHARED_BUFFERS "$v" ;;
      14) read -erp "新值（MAX_PREPARED_TRANSACTIONS）: " v; [ -n "$v" ] && update_config MAX_PREPARED_TRANSACTIONS "$v" ;;
      15) read -erp "新值（MAX_REPLICATION_SLOTS）: " v; [ -n "$v" ] && update_config MAX_REPLICATION_SLOTS "$v" ;;
      16) read -erp "新值（HUGE_PAGES, off/on/try）: " v; [ -n "$v" ] && update_config HUGE_PAGES "$v" ;;
      17) read -erp "新值（SHARED_PRELOAD_LIBRARIES）: " v; [ -n "$v" ] && update_config SHARED_PRELOAD_LIBRARIES "$v" ;;
      [rR]) edit_remote_hosts ;;
      [eE]) "${EDITOR:-vi}" "$CONFIG_FILE" ;;
      [bB]) source "$CONFIG_FILE"; resolve_derived_vars; return ;;
      *) echo "無效選項"; sleep 1 ;;
    esac
    source "$CONFIG_FILE"
    resolve_derived_vars
  done
}

# ════════════════════════════════════════════════════════════
# 面板 / 選單（風格比照 pg_healthcheck.sh：render_panel 一開場先清畫面、
# 印 banner，再用固定欄寬表格列出每個步驟狀態，最後給一行「建議下一步」；
# 詳細的指令說明另外收在 show_help，主選單每輪只印一行精簡指令列，操作完
# 一個動作後停下來等 Enter 才回主選單，其餘互動邏輯不變）
# ════════════════════════════════════════════════════════════
suggest_next() {
  local id st status_str
  for id in "${STEP_ORDER[@]}"; do
    st=$(state_get "$id")
    if [ -z "$st" ]; then
      echo "[$id] ${STEP_TITLE[$id]} — 尚未執行"
      return
    fi
    status_str="${st#* }"
    if [ "$status_str" != "done" ]; then
      echo "[$id] ${STEP_TITLE[$id]} — 上次執行失敗，建議重跑"
      return
    fi
  done
  echo "全部步驟皆已完成，如需重跑請直接輸入對應代號"
}

render_panel() {
  clear 2>/dev/null || true
  echo "======================================================"
  echo " EDB Postgres Advanced Server 標準安裝程序 — $(hostname)  $(date '+%Y-%m-%d %H:%M:%S')"
  echo " 設定檔：$CONFIG_FILE"
  echo "======================================================"
  printf "%-6s %-38s %-8s %s\n" "代號" "步驟" "狀態" "上次執行時間"
  local last_chapter="" id st ts status_str mark lasttime
  for id in "${STEP_ORDER[@]}"; do
    if [ "${STEP_CHAPTER[$id]}" != "$last_chapter" ]; then
      last_chapter="${STEP_CHAPTER[$id]}"
      echo "-- ${last_chapter} --"
    fi
    st=$(state_get "$id")
    mark="未執行"; lasttime="—"
    if [ -n "$st" ]; then
      ts="${st%% *}"; status_str="${st#* }"
      lasttime=$(fmt_time "$ts")
      if [ "$status_str" = "done" ]; then mark="已完成"; else mark="失敗"; fi
    fi
    printf "%-6s %-38s %-8s %s\n" "$id" "${STEP_TITLE[$id]}" "$mark" "$lasttime"
  done
  echo "------------------------------------------------------"
  echo " 建議下一步：$(suggest_next)"
  echo "======================================================"
}

show_help() {
  clear 2>/dev/null || true
  echo "== 步驟說明 =="
  local last_chapter="" id
  for id in "${STEP_ORDER[@]}"; do
    if [ "${STEP_CHAPTER[$id]}" != "$last_chapter" ]; then
      last_chapter="${STEP_CHAPTER[$id]}"
      echo
      echo "${last_chapter}"
    fi
    printf "  [%s] %s\n" "$id" "${STEP_TITLE[$id]}"
  done
  echo
  echo "== 其他指令 =="
  echo "[代號]        執行單一步驟（例如 5.7）"
  echo "[5][6][7]     整章依序執行"
  echo "[A] 全部依序執行"
  echo "[S] 顯示「一、適用範圍與前提假設」"
  echo "[T] 顯示「二、參數對比」"
  echo "[P] 參數設定（直接改「三、參數宣告」，不用跳出去編輯 .conf）"
  echo "[F] 顯示最終參數成果總覽（目前設定值＋衍生設定＋各步驟執行狀態）"
  echo "[V] 當下值檢查（不論步驟是否執行過，讀取系統此刻的實際值並與目標值比對）"
  echo "[C] 顯示目前設定檔路徑並結束（自行編輯後重新執行本腳本即可生效）"
  echo "[H] 顯示這份說明"
  echo "[Q] 離開"
}

interactive_panel() {
  local choice exit_msg="結束。設定檔：${CONFIG_FILE}　log：${LOG_FILE}"
  # 用終端機的「替代畫面緩衝區」（alternate screen buffer）——跟 vim/less/
  # htop 同一套做法：面板顯示在獨立的一塊畫面上，離開時換回原本畫面的內容，
  # 不會洗掉/蓋掉你在跑這支腳本之前，Terminal 裡原本就有的輸出。trap 是
  # 保險，就算用 Ctrl+C 中途中斷，離開時一樣會換回原本畫面。
  tput smcup 2>/dev/null || true
  trap 'tput rmcup 2>/dev/null || true' EXIT
  while true; do
    render_panel
    echo
    echo "輸入代號執行單一步驟，或 [5/6/7]整章執行 [A]全部執行 [S]適用範圍 [T]參數對比 [P]參數設定 [F]最終成果 [V]當下值檢查 [C]設定檔路徑 [H]說明 [Q]離開"
    read -erp "> " choice
    choice="${choice//-/.}"  # 5-1 視同 5.1
    case "$choice" in
      [qQ]) break ;;
      [aA]|all) run_all ;;
      5|6|7) run_chapter_num "$choice" ;;
      [sS]|scope) show_scope ;;
      [tT]|table) show_param_table ;;
      [pP]) edit_params ;;
      [fF]) show_final_summary ;;
      [vV]) show_current_values ;;
      [cC]|conf) exit_msg="設定檔：${CONFIG_FILE}"; break ;;
      [hH]) show_help ;;
      *)
        if [ -n "${STEP_FUNC[$choice]:-}" ]; then
          run_step "$choice"
        else
          echo -e "${C_YEL}[WARN]${C_RST} 無效輸入：$choice"
        fi
        ;;
    esac
    echo
    read -erp "按 Enter 返回主選單..." _
  done
  # 先換回原本畫面，訊息才會印在「使用者看得到、之後還留在 scrollback 裡」的
  # 正常畫面上，而不是印在馬上要被換掉的替代畫面裡。
  tput rmcup 2>/dev/null || true
  trap - EXIT
  echo "$exit_msg"
}

# ════════════════════════════════════════════════════════════
# 進入點
# ════════════════════════════════════════════════════════════
case "${1:-}" in
  --run-all)
    run_all
    ;;
  --check)
    show_current_values
    ;;
  5|6|7)
    run_chapter_num "$1"
    ;;
  "")
    interactive_panel
    ;;
  *)
    if [ -n "${STEP_FUNC[${1//-/.}]:-}" ]; then
      run_step "${1//-/.}"
    else
      echo "用法：$0 [--run-all | --check | 章節編號 5/6/7 | 步驟代號，例如 5.7]"
      exit 1
    fi
    ;;
esac
