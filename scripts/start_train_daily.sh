#!/usr/bin/env bash
# RFDD 每日训练启动脚本（由 cron 在 01:00 调用）
# - 仅允许 01:00-08:59 启动
# - 已在运行则跳过（避免重复占用显存）
# - 使用最新 ckpt 续训：python train.py --cfg 0.1 --resume
# - nohup + setsid 脱离终端；timeout 8h 兜底（到 09:00 自动 SIGTERM 优雅保存退出）
set -u

PROJECT_DIR="/data/yyf/RFDD-main_v1.0"
CONDA_ENV="SEI"
CONDA_SH="/opt/miniconda3/etc/profile.d/conda.sh"
TRAIN_CMD=(python train.py --cfg 0.1 --resume)
TRAIN_PATTERN="train.py --cfg 0.1"
LOG_DIR="$PROJECT_DIR/data_outputs/train_logs"
PID_FILE="$LOG_DIR/train.pid"
LOCK_FILE="$LOG_DIR/start.lock"
SCHED_LOG="$LOG_DIR/scheduler.log"
MAX_RUNTIME="8h"     # 01:00 启动 -> 09:00 自动结束（stop 脚本之外的兜底）
STOP_GRACE=300       # timeout 发 SIGTERM 后等待优雅保存 ckpt 的时间

mkdir -p "$LOG_DIR"
log() { printf '[%s] [start] %s\n' "$(date '+%F %T')" "$*" >> "$SCHED_LOG"; }

# ---- 时段守卫：只允许 01:00-08:59 ----
HOUR=$(date +%-H)
if [[ "${FORCE_START:-0}" != "1" ]] && (( HOUR < 1 || HOUR >= 9 )); then
    log "当前 $(date +%H:%M) 不在允许时段 01:00-09:00 内，跳过启动"
    exit 0
fi

# ---- 一次性跳过标记：该日期不训练（用于 sweep 等任务独占 GPU）----
SKIP_FILE="$LOG_DIR/skip_train_$(date +%F)"
if [[ -f "$SKIP_FILE" ]]; then
    log "检测到一次性跳过标记 $SKIP_FILE，今天不启动训练"
    exit 0
fi

# ---- 防止并发启动 ----
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "已有 start 脚本在运行，跳过"
    exit 0
fi

# ---- 找出属于本项目的训练进程（按 cmdline + cwd 双重校验，避免误杀）----
find_train_pids() {
    local p comm
    for p in $(pgrep -f "$TRAIN_PATTERN" 2>/dev/null); do
        comm=$(cat "/proc/$p/comm" 2>/dev/null || true)
        case "$comm" in python*) ;; *) continue ;; esac   # 排除 timeout/setsid 等包裹进程
        [[ "$(readlink -f "/proc/$p/cwd" 2>/dev/null)" == "$PROJECT_DIR" ]] && echo "$p"
    done
}

RUNNING=$(find_train_pids | head -1)
if [[ -n "$RUNNING" ]]; then
    log "训练已在运行 (PID $RUNNING)，跳过启动"
    echo "$RUNNING" > "$PID_FILE"
    exit 0
fi

# ---- 激活 conda 环境 SEI ----
# shellcheck disable=SC1090
source "$CONDA_SH"
conda activate "$CONDA_ENV" || { log "conda activate $CONDA_ENV 失败"; exit 1; }
if [[ "$(python -c 'import sys; print(sys.prefix)' 2>/dev/null)" != *"/envs/$CONDA_ENV" ]]; then
    log "conda 环境 $CONDA_ENV 激活校验失败（python=$(command -v python)），终止"
    exit 1
fi

cd "$PROJECT_DIR" || { log "无法进入 $PROJECT_DIR"; exit 1; }
export PYTHONUNBUFFERED=1
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"

TRAIN_LOG="$LOG_DIR/train_$(date +%F).log"
log "启动训练：${TRAIN_CMD[*]}  (env=$CONDA_ENV, gpu=$CUDA_VISIBLE_DEVICES, max_runtime=$MAX_RUNTIME)"
log "训练日志 -> $TRAIN_LOG"

# 9>&-：不让后台训练进程继承 flock 锁 fd，否则锁会一直被占用到训练结束
nohup setsid timeout --signal=TERM --kill-after="${STOP_GRACE}s" "$MAX_RUNTIME" \
    "${TRAIN_CMD[@]}" >> "$TRAIN_LOG" 2>&1 9>&- &
LAUNCHER_PID=$!

# 等待真正的 python 进程出现并记录其 PID（pgrep 结果用于停止脚本；pidfile 仅作辅助）
PID=""
for _ in $(seq 1 60); do
    PID=$(find_train_pids | head -1)
    [[ -n "$PID" ]] && break
    sleep 0.5
done
PID="${PID:-$LAUNCHER_PID}"
echo "$PID" > "$PID_FILE"
log "训练进程 PID=$PID（launcher=$LAUNCHER_PID），已写入 $PID_FILE"
exit 0
