# RFDD 每日定时训练

## 调度方式

用户 `yyf` 的 crontab（`crontab -l` 查看）：

| 时间 | 脚本 | 作用 |
| --- | --- | --- |
| 每天 01:00 | `start_train_daily.sh` | 在 conda 环境 `SEI` 中启动 `python train.py --cfg 0.1 --resume` |
| 每天 09:00 | `stop_train_daily.sh` | 先 SIGTERM 让 train.py 保存当前 epoch 的 ckpt，超时再 SIGKILL，确保释放显存 |
| 开机时 | `start_train_daily.sh` | 若开机时间在 01:00–08:59 内则恢复训练，否则跳过 |

- 启动脚本内部还有时段守卫：只有 01:00–08:59 允许启动。
- `nohup + setsid` 使训练脱离终端，关闭终端不影响运行。
- `timeout 8h` 兜底：即使 09:00 的停止任务失败，也会在启动 8 小时后 SIGTERM 优雅退出。
- `--resume` 自动选择 `data_outputs/checkpoint/` 下 epoch 编号最大的 `teacher_RFF_ckpt_*.pt` 续训；
  首次运行无 ckpt 时自动从 epoch 0 开始。

## 优雅停止（train.py 内置）

`train.py` 收到 SIGTERM/SIGINT 后置位停止标志，在当前 batch 结束后保存一个完整检查点再退出，
下次 `--resume` 从 `ckpt.epoch + 1` 继续。避免定时停止时丢失最多 10 个 epoch 的进度，
也避免杀在 `torch.save` 中途损坏检查点。

## 日志与状态

```
data_outputs/train_logs/scheduler.log         # 调度启停记录（含 GPU 占用快照）
data_outputs/train_logs/train_YYYY-MM-DD.log  # 当日训练输出
data_outputs/train_logs/train.pid             # 当前训练进程 PID
data_outputs/checkpoint/                      # 周期 ckpt（每 10 epoch）+ 停止时 ckpt + best ckpt
```

## 手动操作

```bash
# 立即停止训练（优雅保存 + 释放显存）
./scripts/stop_train_daily.sh

# 在允许时段外强制启动（仅用于测试）
FORCE_START=1 ./scripts/start_train_daily.sh

# 查看/修改调度
crontab -l
crontab -e        # 删除含 RFDD_DAILY_TRAIN 的行即可禁用

# 实时看训练日志
tail -f data_outputs/train_logs/train_$(date +%F).log
```

## 旧模型（非 CFG）

原 `teacher_RFF_ckpt_1999_.pt`（epoch 1999，`cond_drop_prob=0`，非 CFG）已归档到：

```
data_outputs/checkpoint_archive_noncfg/teacher_RFF_ckpt_1999_.pt
```

需要用它采样时：

```bash
python sample_last.py --ckpt-dir data_outputs/checkpoint_archive_noncfg
```
