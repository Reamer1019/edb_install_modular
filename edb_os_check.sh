#!/usr/bin/env bash
#
# edb_install_modular.sh — EDB Postgres Advanced Server 標準安裝程序（模組化版）
#
# 本文件以「確保安裝結果 100% 可用」為唯一撰寫原則，不將安全等非必要考量納入範圍。
#
# 設計原則：把原本線性、由上而下執行一次的安裝文件，改寫成可以「單一步驟獨立
# 選取執行」的互動式面板。每個步驟對應原文件的一個編號小節（四、5.1~5.12、
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
#   - 第三節參數宣告需先向客戶確認，若客戶未提供則一律採用文件內建的預設值。
#   - 任何套件安裝均預設透過 dnf install（需要能連到套件庫），EDB 套件本身
#     則走離線 repo（見 6.1），如作業系統層級套件也要離線安裝，需自行另建
#     offline repo。
#
# 用法：
#   ./edb_install_modular.sh            # 進入互動面板
#   ./edb_install_modular.sh --run-all  # 非互動，依序跑完全部步驟
#   ./edb_install_modular.sh 5.7        # 非互動，只跑單一步驟後結束
#
set -uo pipefail

# ────────────────────────────────────────────────────────────
# 基本路徑與設定檔載入（比照 pg_healthcheck.sh 的做法：第一次執行自動產生
# 設定檔，之後每次都讀同一份，改設定不用改程式碼）
# ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/edb_install.conf"
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

# ARCHIVE_COMMAND 依賴 NEW_ARCLOG（衍生變數），所以不放進設定檔本身，
# 等衍生變數算完之後再組出來，避免使用者在設定檔裡看到一個「值還沒確定」
# 的參數而誤改。

# ────────────────────────────────────────────────────────────
# 衍生變數（由上面的設定值計算出來，全域只算一次，所有步驟共用）
# ────────────────────────────────────────────────────────────
resolve_derived_vars() {
  NEW_PGDATA="${PGDATA_BASE}/as${EDB_VER}/data"
  NEW_WAL="${PGDATA_BASE}/as${EDB_VER}/pg_wal"
  NEW_ARCLOG="${PGDATA_BASE}/arclog"
  NEW_PGLOG="${PGDATA_BASE}/log"
  ARCHIVE_COMMAND="test ! -f ${NEW_ARCLOG}/wal/%f && cp %p ${NEW_ARCLOG}/wal/%f"
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

# compute_ulimits：算出 NOFILE/NPROC。5.6、5.8、6.3 三個步驟都要用到這兩個
# 數字，而且彼此可能被「單獨」執行（不保證按順序跑），所以不倚賴前一個步驟
# 留下的全域變數，而是每次要用就重新算一次——純算術、零副作用，重算多次
# 結果一定一致，這樣不管使用者從面板挑哪一步先跑，數字都不會對不上。
compute_ulimits() {
  local bg_process_count=7  # postmaster/checkpointer/bgwriter/wal writer/
                             # autovacuum launcher/logical replication launcher/archiver
  NPROC=$((MAX_CONNECTIONS + MAX_WAL_SENDERS + MAX_WORKER_PROCESSES + AUTOVACUUM_WORKER_SLOTS + bg_process_count))
  NOFILE=$((MAX_CONNECTIONS * MAX_FILES_PER_PROCESS))
}

# apply_noatime：5.12 用來處理 PGDATA_BASE、6.2 用來處理 NEW_WAL。宣告成
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
  touch "$file"
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1}
    !skip {print}
    $0==e {skip=0}
  ' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
  {
    echo "$begin"
    printf '%s\n' "$content"
    echo "$end"
  } >> "$file"
}

# ensure_os_tuning_skeleton：5.10（I/O Scheduler）、5.11（CPU Governor）都會
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

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${C_RED}[CRIT]${C_RST} 本步驟需要 root 權限執行，請用 sudo 或 root 重新執行本腳本。" >&2
    return 1
  fi
}

# ════════════════════════════════════════════════════════════
# 四、事前檢查：必要套件安裝狀態
# ════════════════════════════════════════════════════════════
# 本節檢查後續步驟所需之套件是否已安裝，若未安裝則自動補齊。
step_4_prereq_packages() {
  require_root || return 1
  echo "== [四] 事前檢查：必要套件安裝狀態 =="

  if ! command -v mountpoint &>/dev/null; then
    dnf install -y util-linux || return 1
  fi

  if ! systemctl is-active --quiet firewalld; then
    dnf install -y firewalld || return 1
    systemctl enable --now firewalld
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

# ════════════════════════════════════════════════════════════
# 五、作業系統設定
# ════════════════════════════════════════════════════════════

# 5.1 檢查 PGDATA_BASE 是否為獨立掛載磁碟
step_5_1_check_pgdata_mount() {
  echo "== [5.1] 檢查 PGDATA_BASE 是否為獨立掛載磁碟 =="
  mount -q "$PGDATA_BASE" || echo -e "  ${C_YEL}[WARN]${C_RST} $PGDATA_BASE not mounted as an independent disk." >&2
  mount -q "$PGDATA_BASE" && echo -e "  ${C_GRN}[OK]${C_RST} $PGDATA_BASE 是獨立掛載點"
}

# 5.2 SELinux 停用
step_5_2_selinux() {
  require_root || return 1
  echo "== [5.2] SELinux 停用 =="
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
  setenforce 0 2>/dev/null || echo -e "  ${C_YEL}[WARN]${C_RST} setenforce 失敗（可能本來就是 disabled，或需要重開機才能完全生效）"
  echo -e "  ${C_GRN}[OK]${C_RST} SELinux 已設定為 disabled（永久生效需重開機）"
}

# 5.3 防火牆全開
step_5_3_firewall() {
  require_root || return 1
  echo "== [5.3] 防火牆全開 =="
  for nic in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    firewall-cmd --permanent --zone=trusted --change-interface="$nic"
  done
  firewall-cmd --set-default-zone=trusted
  firewall-cmd --complete-reload
  echo -e "  ${C_GRN}[OK]${C_RST} 所有網卡已改為 trusted zone"
}

# 5.4 本機 ISO Repository（非必要，詢問式）
# 僅離線／無法連到外部套件庫的環境才需要。互動執行時會先問一次，答否或直接
# 按 Enter 就略過，不影響後續步驟；非互動（stdin 非終端機，例如 --run-all
# 或排程執行）一律自動略過，避免卡在 read 上，需要的話請在互動面板下單獨
# 執行本步驟。
step_5_4_iso_local_repo() {
  require_root || return 1
  echo "== [5.4] 本機 ISO Repository 設定（非必要）=="
  if [ ! -t 0 ]; then
    echo "  非互動模式（無終端機輸入），本步驟需要人工確認是否設定，已自動略過。"
    echo "  如需設定，請在互動面板下單獨執行「5.4」。"
    return 0
  fi
  local ans iso_dir="${ISO_MOUNT_DIR:-/mnt}"
  read -rp "  是否要用本機掛載的安裝 ISO（掛載於 ${iso_dir}）建立 local repo？僅離線環境需要 (y/N)： " ans
  case "$ans" in
    y|Y|yes|YES)
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
      echo -e "  ${C_GRN}[OK]${C_RST} /etc/yum.repos.d/local.repo 已建立（請先確認安裝 ISO 已掛載於 ${iso_dir}，路徑可在設定檔 ISO_MOUNT_DIR 調整）"
      ;;
    *)
      echo "  已略過，未建立本機 local repo。"
      ;;
  esac
}

# 5.5 確認安裝媒介 / 套件庫可用
step_5_5_check_repo() {
  echo "== [5.5] 確認安裝媒介 / 套件庫可用 =="
  mount | grep -i iso || echo "  （未偵測到掛載的 ISO）"
  yum repolist
}

# 5.6 ulimit
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
step_5_6_ulimit() {
  require_root || return 1
  echo "== [5.6] ulimit（NOFILE/NPROC）=="
  compute_ulimits
  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/80-edb-postgres.conf << EOF
enterprisedb soft nofile ${NOFILE}
enterprisedb hard nofile ${NOFILE}
enterprisedb soft nproc  ${NPROC}
enterprisedb hard nproc  ${NPROC}
enterprisedb soft core   unlimited
enterprisedb hard core   unlimited
EOF
  echo -e "  ${C_GRN}[OK]${C_RST} NOFILE=${NOFILE}  NPROC=${NPROC}  已寫入 /etc/security/limits.d/80-edb-postgres.conf"
}

# 5.7 Core Dump 設定
# Coredump 的檔案並無官方文件建議的放置位置，這邊僅是遵照個人習慣。
# /etc/sysctl.d/80-edb-postgres.conf 同時也是 5.8、5.9 會寫入的檔案；三者用
# write_managed_block 各自認領一個 marker 區塊，任一步驟先執行、或重複執行，
# 都不會清掉另外兩個步驟已經寫好的內容。
step_5_7_coredump() {
  require_root || return 1
  echo "== [5.7] Core Dump 設定 =="
  write_managed_block /etc/sysctl.d/80-edb-postgres.conf CORE_PATTERN << 'EOF'
kernel.core_pattern = /var/coredump/core-%e-%p-%t
EOF
  sysctl --system
  echo -e "  ${C_GRN}[OK]${C_RST} core_pattern 已設定（存放目錄權限見 7.3）"
}

# 5.8 sysctl：記憶體 overcommit 與 dirty memory
# 參照：
#   https://www.enterprisedb.com/blog/general-configuration-and-tuning-recommendations-edb-postgres-advanced-server-and-postgresql
#   https://www.postgresql.org/docs/current/kernel-resources.html#LINUX-MEMORY-OVERCOMMIT
# overcommit_memory=2：依 PG 官方文件建議，降低 postmaster 被 OOM killer 誤殺的機率
# overcommit_kbytes：依 EDB 官方調校指南，用實際記憶體總量
# swappiness=1：同一份調校指南建議值
# dirty_bytes：無其他依據時採 1GB，dirty_background_bytes 取其 1/4
step_5_8_sysctl_mem() {
  require_root || return 1
  echo "== [5.8] sysctl：記憶體 overcommit 與 dirty memory =="
  compute_ulimits
  local MEM_TOTAL_KB DIRTY_BYTES DIRTY_BG FILE_MAX
  MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  DIRTY_BYTES=$((1024*1024*1024))
  DIRTY_BG=$((DIRTY_BYTES/4))
  FILE_MAX=$((NOFILE * 4))

  write_managed_block /etc/sysctl.d/80-edb-postgres.conf MEM_OVERCOMMIT << EOF
vm.overcommit_memory = 2
vm.overcommit_kbytes = ${MEM_TOTAL_KB}
vm.swappiness = 1
vm.dirty_bytes = ${DIRTY_BYTES}
vm.dirty_background_bytes = ${DIRTY_BG}
fs.file-max = ${FILE_MAX}
EOF
  sysctl --system
  echo -e "  ${C_GRN}[OK]${C_RST} 已寫入 /etc/sysctl.d/80-edb-postgres.conf（MEM_OVERCOMMIT 區塊）並套用"
}

# 5.9 Hugepage 設定（粗估值，EDB 安裝後由 7.2 校正為精確值）
# 參考：
#   https://www.postgresql.org/docs/current/kernel-resources.html#LINUX-HUGE-PAGES
#   https://www.postgresql.org/docs/current/runtime-config-resource.html#GUC-HUGE-PAGES
# 最精確的值需由 EDB 的 shared_memory_size_in_huge_pages 算，但此階段尚未安裝
# EDB，故先用「總 RAM 1/4 再加 10% 共用記憶體餘裕」的經驗公式估算。
# THP 停用理論上該寫在這裡，但已併入 5.10 的開機腳本一起處理（官方文件指出
# 部分 Linux 版本上 THP 會造成效能下降，不建議使用）。
# nr_hugepages 這一行寫進與 5.7/5.8 共用的 80-edb-postgres.conf，同樣用
# write_managed_block 認領獨立 marker，7.2 的精確值日後覆蓋也走同一個
# marker，彼此任意順序執行都不會互相打架。
step_5_9_hugepage_estimate() {
  require_root || return 1
  echo "== [5.9] Hugepage 設定（粗估值）=="
  local MEM_KB HP_KB NR
  MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  HP_KB=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
  NR=$(awk -v m="$MEM_KB" -v h="$HP_KB" 'BEGIN{printf "%d", (m*0.25*1.10)/h + 1}')
  echo "  nr_hugepages（粗估）= $NR"
  sysctl -w vm.nr_hugepages="$NR"
  write_managed_block /etc/sysctl.d/80-edb-postgres.conf NR_HUGEPAGES <<< "vm.nr_hugepages = $NR"
  echo -e "  ${C_GRN}[OK]${C_RST} 粗估值已套用，EDB 安裝完成後請執行 7.2 校正為精確值"
}

# 5.10 I/O Scheduler 與 Readahead
# 參考：https://www.enterprisedb.com/blog/general-configuration-and-tuning-recommendations-edb-postgres-advanced-server-and-postgresql
# Readahead 讓核心偵測到循序讀取模式時，一次預先多讀一段進 page cache，減少
# 實際發出的 I/O 請求次數、提升吞吐量。Linux 預設通常 128 kB，官方建議資料庫
# 磁碟改為 4096 kB。
# I/O Scheduler、Readahead、THP 停用都屬於 kernel 執行期狀態，每次開機都會
# 被還原成系統預設值，無法像 sysctl.d/fstab 一樣寫進設定檔就永久生效，因此
# 寫成一支開機執行一次的腳本，註冊為 edb-os-tuning.service。5.11 的 CPU
# Governor 設定同屬此類狀態，會附加進同一支腳本，不另開 service。腳本骨架由
# ensure_os_tuning_skeleton 用「不存在才建立」的方式準備，本步驟只用
# write_managed_block 認領自己的 IO_SCHEDULER 區塊，5.10、5.11 誰先執行、
# 重跑幾次都不會清掉對方的內容。
step_5_10_io_scheduler() {
  require_root || return 1
  echo "== [5.10] I/O Scheduler 與 Readahead =="
  ensure_os_tuning_skeleton
  write_managed_block /usr/local/sbin/edb-os-tuning.sh IO_SCHEDULER << 'EOF'
echo never > /sys/kernel/mm/transparent_hugepage/enabled
RHEL_VER=$(rpm -E %rhel 2>/dev/null || echo 8)
ROOT_SRC=$(findmnt -n -o SOURCE --target /)
ROOT_DEV=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null)
[ -z "$ROOT_DEV" ] && ROOT_DEV=$(basename "$ROOT_SRC" | sed -E 's/[0-9]+$//')
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
  chmod +x /usr/local/sbin/edb-os-tuning.sh
  systemctl daemon-reload
  systemctl restart edb-os-tuning.service
  echo -e "  ${C_GRN}[OK]${C_RST} edb-os-tuning.sh 的 IO_SCHEDULER 區塊已寫入並套用"
}

# 5.11 CPU 效能模式（Governor）設定
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
# 跟 5.10 一樣先呼叫 ensure_os_tuning_skeleton 確保腳本/service 存在（不存在
# 才建立，不會覆寫 5.10 已寫好的 IO_SCHEDULER 區塊），再用 write_managed_block
# 認領自己的 CPU_GOVERNOR 區塊，因此不再需要「5.9 必須先跑過」的前置檢查，
# 5.10、5.11 兩步驟任意順序、單獨重跑都是安全的。
step_5_11_cpu_governor() {
  require_root || return 1
  echo "== [5.11] CPU 效能模式（Governor）設定 =="
  ensure_os_tuning_skeleton
  write_managed_block /usr/local/sbin/edb-os-tuning.sh CPU_GOVERNOR << 'EOF'
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
  chmod +x /usr/local/sbin/edb-os-tuning.sh
  systemctl daemon-reload
  systemctl restart edb-os-tuning.service
  echo -e "  ${C_GRN}[OK]${C_RST} edb-os-tuning.sh 的 CPU_GOVERNOR 區塊已寫入並套用（systemctl restart 讓本次立即生效，重開機後也會靠同一個 service 自動套用）"
}

# 5.12 atime
# 參考：https://www.enterprisedb.com/blog/tuning-red-hat-enterprise-linux-family-postgresql
# Linux 每次讀取資料都會寫一次更新 atime，資料庫每秒讀取的 page 數非常龐大，
# 累積起來是可觀的額外寫入開銷。PostgreSQL 自己完全不會看這個 atime 欄位做
# 任何判斷，因此這是純浪費的成本，應當關閉。
step_5_12_atime() {
  require_root || return 1
  echo "== [5.12] atime（PGDATA_BASE）=="
  apply_noatime "$PGDATA_BASE"
}

# ════════════════════════════════════════════════════════════
# 六、EDB 安裝作業
# ════════════════════════════════════════════════════════════

# 6.1 實際安裝（走離線 repo）
step_6_1_install_edb() {
  require_root || return 1
  echo "== [6.1] EDB 套件安裝 =="
  cat > /etc/yum.repos.d/edb-offline.repo << EOF
[edb-offline]
name=EDB Offline Repo
baseurl=file://${REPO_DIR}
enabled=1
gpgcheck=0
EOF
  dnf install -y --disablerepo='*' --enablerepo='edb-offline' "edb-as${EDB_VER}-server"
  echo -e "  ${C_GRN}[OK]${C_RST} edb-as${EDB_VER}-server 已安裝"
}

# 6.2 目錄準備（含對 NEW_WAL 套用 noatime，沿用 5.12 定義的函式）
step_6_2_prepare_dirs() {
  require_root || return 1
  echo "== [6.2] 目錄準備 =="
  mkdir -p "$NEW_PGDATA" "$NEW_WAL" "$NEW_ARCLOG" "$NEW_PGLOG"
  chown -R enterprisedb:enterprisedb "$PGDATA_BASE"
  echo "  WAL 路徑至此才確定，沿用 5.12 定義的 apply_noatime；若與 PGDATA_BASE 同一顆磁碟，"
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
  cp "$UNIT_SRC" "$UNIT_DST"

  sed -i \
    -e "s|^Environment=PGDATA=.*|Environment=PGDATA=${NEW_PGDATA}|" \
    -e "s|^PIDFile=.*|PIDFile=${NEW_PGDATA}/postmaster.pid|" \
    "$UNIT_DST"
  sed -i "/^\[Service\]/a LimitNOFILE=${NOFILE}\nLimitNPROC=${NPROC}\nLimitCORE=infinity" "$UNIT_DST"

  # edb-os-tuning.service（5.10/5.11）跟 EDB service 一樣都是 WantedBy=multi-user.target，
  # 彼此沒有訂順序關係，systemd 不保證重開機時 tuning 一定跑在 EDB 之前，資料庫可能在
  # THP/IO scheduler/CPU governor 都還沒重新套用完就先啟動。比照 EDB 官方部落格建議在
  # postgresql.service 加 After=tuned.service 的做法，這裡補上對 edb-os-tuning.service 的依賴。
  if ! grep -q '^After=edb-os-tuning.service$' "$UNIT_DST"; then
    sed -i "/^\[Unit\]/a After=edb-os-tuning.service" "$UNIT_DST"
  fi

  diff -Naur "$UNIT_SRC" "$UNIT_DST" || true
  systemctl daemon-reload
  echo -e "  ${C_GRN}[OK]${C_RST} Unit file 已複製並修改，NOFILE=${NOFILE} NPROC=${NPROC}"
}

# 6.4 initdb 參數
# wal-segsize：PG 官方規定 2 的 0~10 次方，本文件採官方預設值 16。
# waldir：指到 6.2 建好的獨立目錄，不然會放進 data 裡面的 wal。
# data-checksums：新版本 PG/EDB 官方預設開啟，打開可降低潛在問題。
# locale：依 NEED_ZH_LOCALE 參數決定。
# 注意：這裡用 export 設定環境變數，只在「同一個 shell 執行流程」內有效，
# 若在面板裡單獨選 6.6 而沒有先選 6.4，6.6 會自動先呼叫本函式一次，
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

# 6.5 GUC 寫入
# 依 PG 官方文件 §25.3.1（Setting Up WAL Archiving）之範例：先檢查目的地檔案
# 是否已存在，存在就不覆蓋——這是官方特別強調的防呆，因為歸檔失敗會自動重試，
# 沒有這個檢查可能用不完整的檔案把已正確歸檔的檔案蓋掉。官方原文也提到嚴謹
# 作法應在檔案已存在時比對內容（相同回傳成功、不同才回傳失敗），但官方範例
# 本身只要檔案存在就一律回傳非 0，不比對內容——這是官方文件自陳的範例限制，
# 非本文件疏漏。
step_6_5_guc_write() {
  require_root || return 1
  echo "== [6.5] GUC 寫入 =="
  if [ ! -d "$NEW_PGDATA" ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} $NEW_PGDATA 不存在，請確認 6.2/6.6 是否已完成。" >&2
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
archive_mode = on
archive_command = '${ARCHIVE_COMMAND}'
EOF
  echo -e "  ${C_GRN}[OK]${C_RST} GUC 已寫入 ${NEW_PGDATA}/postgresql.auto.conf"
}

# 6.6 initdb（因後續還需調整 Hugepage、需要 restart service，這裡不啟動 service）
step_6_6_run_initdb() {
  require_root || return 1
  echo "== [6.6] 執行 initdb =="
  step_6_4_initdb_params
  if [ ! -x "${PG_BINDIR}/edb-as-${EDB_VER}-setup" ]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} 找不到 ${PG_BINDIR}/edb-as-${EDB_VER}-setup，請確認 6.1 是否已安裝成功。" >&2
    return 1
  fi
  "${PG_BINDIR}/edb-as-${EDB_VER}-setup" initdb
  echo -e "  ${C_GRN}[OK]${C_RST} initdb 完成（尚未啟動 service，待 6.5 GUC 寫入、7.2 hugepage 校正後再啟動）"
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

  su - enterprisedb << EOF

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
  echo -e "  ${C_GRN}[OK]${C_RST} SSH 金鑰交換完成"
}

# 7.2 Hugepage 精確設定
# 用 EDB 自己的 shared_memory_size_in_huge_pages 算出精確值，取代 5.8 的粗估。
step_7_2_hugepage_precise() {
  require_root || return 1
  echo "== [7.2] Hugepage 精確設定 =="
  local SCRATCH_PGDATA NR
  SCRATCH_PGDATA=$(mktemp -d)
  chown enterprisedb:enterprisedb "$SCRATCH_PGDATA"

  su - enterprisedb << EOF
${PG_BINDIR}/initdb -D ${SCRATCH_PGDATA} --auth=trust >/dev/null
EOF

  NR=$(su - enterprisedb << EOF
${PG_BINDIR}/postgres -D ${SCRATCH_PGDATA} -C shared_memory_size_in_huge_pages -c shared_buffers=${SHARED_BUFFERS} -c max_connections=${MAX_CONNECTIONS} -c max_wal_senders=${MAX_WAL_SENDERS} -c max_worker_processes=${MAX_WORKER_PROCESSES} -c autovacuum_worker_slots=${AUTOVACUUM_WORKER_SLOTS}
EOF
)

  rm -rf "$SCRATCH_PGDATA"

  if [ -z "$NR" ] || ! [[ "$NR" =~ ^[0-9]+$ ]]; then
    echo -e "  ${C_RED}[CRIT]${C_RST} 取得 shared_memory_size_in_huge_pages 失敗（NR=\"$NR\"），略過套用，請人工確認。" >&2
    return 1
  fi

  sysctl -w vm.nr_hugepages="$NR"
  # 跟 5.9 共用同一個 NR_HUGEPAGES marker：不論 5.9 的粗估值有沒有跑過，
  # 這裡都會把該區塊換成精確值，不會產生兩行 vm.nr_hugepages 互相打架。
  write_managed_block /etc/sysctl.d/80-edb-postgres.conf NR_HUGEPAGES <<< "vm.nr_hugepages = $NR"

  # 動到 hugepage 需要 restart service
  systemctl restart "${SERVICE_NAME}"
  systemctl status "${SERVICE_NAME}" --no-pager
  echo -e "  ${C_GRN}[OK]${C_RST} 精確值 nr_hugepages=${NR} 已套用並重啟服務"
}

# 7.3 Core Dump 更改權限
step_7_3_coredump_perm() {
  require_root || return 1
  echo "== [7.3] Core Dump 更改權限 =="
  mkdir -p /var/coredump
  chown enterprisedb:enterprisedb /var/coredump
  chmod 750 /var/coredump
  echo -e "  ${C_GRN}[OK]${C_RST} /var/coredump 權限已設定"
}

# ════════════════════════════════════════════════════════════
# 步驟登錄表（面板顯示順序、標題、對應函式）
# ════════════════════════════════════════════════════════════
STEP_ORDER=(4 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 5.9 5.10 5.11 5.12 6.1 6.2 6.3 6.4 6.5 6.6 7.1 7.2 7.3)
declare -A STEP_TITLE=(
  [4]="事前檢查：必要套件安裝狀態"
  [5.1]="檢查 PGDATA_BASE 是否為獨立掛載磁碟"
  [5.2]="SELinux 停用"
  [5.3]="防火牆全開"
  [5.4]="本機 ISO Repository（非必要）"
  [5.5]="確認安裝媒介 / 套件庫可用"
  [5.6]="ulimit（NOFILE/NPROC）"
  [5.7]="Core Dump 設定"
  [5.8]="sysctl：記憶體 overcommit 與 dirty memory"
  [5.9]="Hugepage 設定（粗估值）"
  [5.10]="I/O Scheduler 與 Readahead"
  [5.11]="CPU 效能模式（Governor）設定"
  [5.12]="atime（PGDATA_BASE）"
  [6.1]="EDB 套件安裝"
  [6.2]="目錄準備"
  [6.3]="複製並修改 systemd Unit File"
  [6.4]="initdb 參數設定"
  [6.5]="GUC 寫入"
  [6.6]="執行 initdb"
  [7.1]="SSH 金鑰交換"
  [7.2]="Hugepage 精確設定"
  [7.3]="Core Dump 更改權限"
)
declare -A STEP_FUNC=(
  [4]=step_4_prereq_packages
  [5.1]=step_5_1_check_pgdata_mount
  [5.2]=step_5_2_selinux
  [5.3]=step_5_3_firewall
  [5.4]=step_5_4_iso_local_repo
  [5.5]=step_5_5_check_repo
  [5.6]=step_5_6_ulimit
  [5.7]=step_5_7_coredump
  [5.8]=step_5_8_sysctl_mem
  [5.9]=step_5_9_hugepage_estimate
  [5.10]=step_5_10_io_scheduler
  [5.11]=step_5_11_cpu_governor
  [5.12]=step_5_12_atime
  [6.1]=step_6_1_install_edb
  [6.2]=step_6_2_prepare_dirs
  [6.3]=step_6_3_systemd_unit
  [6.4]=step_6_4_initdb_params
  [6.5]=step_6_5_guc_write
  [6.6]=step_6_6_run_initdb
  [7.1]=step_7_1_ssh_keys
  [7.2]=step_7_2_hugepage_precise
  [7.3]=step_7_3_coredump_perm
)
declare -A STEP_CHAPTER=(
  [4]="四、事前檢查"
  [5.1]="五、作業系統設定" [5.2]="五、作業系統設定" [5.3]="五、作業系統設定"
  [5.4]="五、作業系統設定" [5.5]="五、作業系統設定" [5.6]="五、作業系統設定"
  [5.7]="五、作業系統設定" [5.8]="五、作業系統設定" [5.9]="五、作業系統設定"
  [5.10]="五、作業系統設定" [5.11]="五、作業系統設定" [5.12]="五、作業系統設定"
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
}

run_chapter() {
  local chapter="$1" id
  for id in "${STEP_ORDER[@]}"; do
    [ "${STEP_CHAPTER[$id]}" = "$chapter" ] && { run_step "$id" || return 1; }
  done
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
- EDB 版本：需先在設定檔（edb_install.conf）寫好要安裝的版本。
- 磁碟配置：假設機器上除了系統碟，其餘實體硬碟均為資料庫用途。若使用
  LVM 且邏輯磁區橫跨多個實體硬碟，磁碟偵測邏輯未涵蓋此情境。
- 網路/防火牆：全開，需要自己依實際需求調整。
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
  archive_mode      : off -> on
  archive_command   : 無 -> test ! -f ${NEW_ARCLOG}/wal/%f && cp %p ${NEW_ARCLOG}/wal/%f
  data-checksums    : 依版本而定 -> 開
  locale            : 跟隨 OS LANG -> 依 NEED_ZH_LOCALE 決定 en_US.UTF-8 或 zh_TW.UTF-8
  waldir            : PGDATA/pg_wal -> ${NEW_WAL}
  log_directory     : log -> ${NEW_PGLOG}
  logging_collector : off -> on
EOF
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
  echo "[4][5][6][7]  整章依序執行"
  echo "[A] 全部依序執行"
  echo "[S] 顯示「一、適用範圍與前提假設」"
  echo "[T] 顯示「二、參數對比」"
  echo "[C] 顯示目前設定檔路徑並結束（自行編輯後重新執行本腳本即可生效）"
  echo "[H] 顯示這份說明"
  echo "[Q] 離開"
}

interactive_panel() {
  local choice
  while true; do
    render_panel
    echo
    echo "輸入代號執行單一步驟，或 [4/5/6/7]整章執行 [A]全部執行 [S]適用範圍 [T]參數對比 [C]設定檔路徑 [H]說明 [Q]離開"
    read -rp "> " choice
    case "$choice" in
      [qQ]) break ;;
      [aA]|all) run_all ;;
      4|5|6|7)
        case "$choice" in
          4) run_chapter "四、事前檢查" ;;
          5) run_chapter "五、作業系統設定" ;;
          6) run_chapter "六、EDB 安裝作業" ;;
          7) run_chapter "七、EDB 安裝後的 OS 設定" ;;
        esac
        ;;
      [sS]|scope) show_scope ;;
      [tT]|table) show_param_table ;;
      [cC]|conf) echo "設定檔：$CONFIG_FILE"; break ;;
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
    read -rp "按 Enter 返回主選單..." _
  done
  echo "結束。設定檔：${CONFIG_FILE}　log：${LOG_FILE}"
}

# ════════════════════════════════════════════════════════════
# 進入點
# ════════════════════════════════════════════════════════════
case "${1:-}" in
  --run-all)
    run_all
    ;;
  "")
    interactive_panel
    ;;
  *)
    if [ -n "${STEP_FUNC[$1]:-}" ]; then
      run_step "$1"
    else
      echo "用法：$0 [--run-all | 步驟代號，例如 5.7]"
      exit 1
    fi
    ;;
esac
