#!/usr/bin/env bash
# RFDD 每日训练停止脚本（由 cron 在 09:00 调用）
# 流程：SIGTERM（train.py 保存当前 epoch 的 ckpt 后退出）-> 超时 SIGKILL -> 校验进程已退出
# 目的：彻底释放 GPU 显存，并保证下次能从最新检查点续训。
set -u

PROJECT_DIR="/data/yyf/RFDD-main_v1.0"
TRAIN_PATTERN="train.py --cfg 0.1"
LOG_DIR="$PROJECT_DIR/data_outputs/train_logs"
PID_FILE="$LOG_DIR/train.pid"
LOCK_FILE="$LOG_DIR/stop.lock"
SCHED_LOG="$LOG_DIR/scheduler.log"
GRACE_SECONDS=300    # 等待 train.py 保存 ckpt 并退出的最长时间

mkdir -p "$LOG_DIR"
log() { printf '[%s] [stop]  %s\n' "$(date '+%F %T')" "$*" >> "$SCHED_LOG"; }

exec 8>"$LOCK_FILE"
if ! flock -n 8; then
    log "已有 stop 脚本在运行，跳过"
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

PIDS=$(find_train_pids | sort -u)
if [[ -f "$PID_FILE" ]]; then
    STORED=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ "$STORED" =~ ^[0-9]+$ ]] && kill -0 "$STORED" 2>/dev/null; then
        PIDS=$(printf '%s\n%s\n' "$PIDS" "$STORED" | sort -u)
    fi
fi

if [[ -z "${PIDS//[$'\n\t ']/}" ]]; then
    log "没有正在运行的训练进程，无需停止（显存应已释放）"
    rm -f "$PID_FILE"
    exit 0
fi

log "请求停止训练进程: $(echo $PIDS)  （先 SIGTERM，等待优雅保存 ckpt，最多 ${GRACE_SECONDS}s）"
kill -TERM $PIDS 2>/dev/null

ALIVE=""
for ((i = 0; i < GRACE_SECONDS / 2; i++)); do
    ALIVE=""
    for p in $PIDS; do
        kill -0 "$p" 2>/dev/null && ALIVE="$ALIVE $p"
    done
    [[ -z "$ALIVE" ]] && break
    sleep 2
done

if [[ -n "$ALIVE" ]]; then
    log "优雅退出超时（${GRACE_SECONDS}s），强制 SIGKILL:$ALIVE"
    kill -KILL $ALIVE 2>/dev/null
    sleep 2
fi

# 兜底清理：仍匹配的遗留训练进程
REMAIN=$(find_train_pids | sort -u)
if [[ -n "$REMAIN" ]]; then
    log "仍检测到训练进程: $(echo $REMAIN)，执行 SIGKILL"
    kill -KILL $REMAIN 2>/dev/null
    sleep 1
    REMAIN=$(find_train_pids | sort -u)
fi

if [[ -n "$REMAIN" ]]; then
    log "警告：仍有训练进程存活: $(echo $REMAIN)"
else
    log "训练进程已全部退出，GPU 显存已释放"
fi
rm -f "$PID_FILE"

# 记录 GPU 计算进程快照，便于核查显存释放情况
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader >> "$SCHED_LOG" 2>/dev/null || true
fi
exit 0
