#!/usr/bin/env bash
# ==============================================================================
# run_pipeline_cfg_sweep_once.sh
#   一次性定时任务：由 cron 在 2026-11-07 01:00 触发，
#   后台启动 /data/yyf/RFDD-main_v1.0/pipeline_cfg_sweep.sh。
#
#   特性：
#   - 启动后自动从 crontab 删除本任务条目（PIPELINE_CFG_SWEEP_ONCE），不会重跑
#   - nohup + setsid 完全脱离终端与 cron 会话：关终端 / 退 SSH 均不影响
#   - 日志 logs/pipeline_cfg_MMDD_HHMM.log，并维护 logs/pipeline_cfg_latest.log 软链
#   - 可通过 DRY_RUN=1 预演（只校验环境并打印将执行的命令，不真正启动）
# ==============================================================================
set -u

PROJECT_DIR="/data/yyf/RFDD-main_v1.0"
CONDA_ENV="SEI"
CONDA_SH="/opt/miniconda3/etc/profile.d/conda.sh"
LOG_DIR="$PROJECT_DIR/logs"
SCHED_LOG="$LOG_DIR/scheduler_pipeline_cfg.log"
CRON_MARK="PIPELINE_CFG_SWEEP_ONCE"
EXPECTED_DATE="2026-11-07"

mkdir -p "$LOG_DIR"
log() { printf '[%s] [launcher] %s\n' "$(date '+%F %T')" "$*" >> "$SCHED_LOG"; }

# ---- 自删 crontab 中的一次性条目（无论后续是否启动都先消费掉，避免重复触发）----
TMP=$(mktemp) || exit 1
if crontab -l > "$TMP" 2>/dev/null; then
    if grep -qF "$CRON_MARK" "$TMP"; then
        grep -vF "$CRON_MARK" "$TMP" | crontab -
        log "已从 crontab 移除一次性条目（$CRON_MARK）"
    else
        log "crontab 中未找到标记 $CRON_MARK，跳过清理"
    fi
else
    log "当前用户没有 crontab，跳过清理"
fi
rm -f "$TMP"

# ---- 日期守卫：防止自删失败后在未来的 11 月 7 日重跑 ----
if [[ "${FORCE_RUN:-0}" != "1" && "$(date +%F)" != "$EXPECTED_DATE" ]]; then
    log "非预期运行日期 $(date +%F)（预期 $EXPECTED_DATE），跳过启动"
    exit 0
fi

# ---- 防重复启动 ----
if pgrep -f "bash pipeline_cfg_sweep.sh" >/dev/null 2>&1; then
    log "pipeline_cfg_sweep.sh 已在运行，跳过本次启动"
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

OUT_LOG="$LOG_DIR/pipeline_cfg_$(date +%m%d_%H%M).log"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] env=$CONDA_ENV python=$(command -v python) gpu=$CUDA_VISIBLE_DEVICES"
    log "[DRY_RUN] 将执行：nohup setsid bash pipeline_cfg_sweep.sh > $OUT_LOG 2>&1 &"
    exit 0
fi

# ---- 启动：nohup + setsid 脱离终端，cron/SSH 退出都不影响 ----
log "启动 pipeline_cfg_sweep.sh（env=$CONDA_ENV, python=$(command -v python), gpu=$CUDA_VISIBLE_DEVICES）"
nohup setsid bash pipeline_cfg_sweep.sh > "$OUT_LOG" 2>&1 &
LAUNCHER_PID=$!
ln -sfn "$OUT_LOG" "$LOG_DIR/pipeline_cfg_latest.log"
log "已启动 launcher PID=$LAUNCHER_PID，日志 -> $OUT_LOG"
exit 0
