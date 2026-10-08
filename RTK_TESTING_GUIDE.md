# rtk Agent 端到端测试指导文档

> 适用场景：在 SWE-bench 任务上对 rtk（Rust Token Killer，LLM Agent 命令输出压缩器）做
> 端到端 A/B 测试，度量其对 token 消耗 / 轮数 / 解题率的影响。
> 本文档基于 2026-09 在 WSL2 (Ubuntu, x86_64) + jiuwenswarm agent server + deepseek-v4-flash
> 上的完整实验链路整理，**重点收录实际踩过的坑**（第 5 章），在新机器上复现前务必通读。

---

## 1. 测试目标与核心指标

| 指标 | 来源 | 说明 |
|------|------|------|
| resolved | SWE-bench 官方评测 (docker) | 解题率，能力底线（不能被 rtk 损伤） |
| rounds | agent server usage_metadata 事件数 | 模型推理轮数，轮数多=成本高+耗时高 |
| total_tokens | usage_summary | 总 token（含 cache），主成本指标 |
| output_tokens | usage_summary | 输出 token，反映"压缩后模型话变多"的行为扰动 |
| wall_s | driver 计时 | 端到端耗时 |

**实验设计铁律**：同一实例各臂同批交错跑（臂序轮转），同参数（temperature=0）、
同 prompt、同超时；每 run 之间做完整环境隔离（见第 5 章——这是本测试体系最大的坑群）。

---

## 2. 架构与组件

```
                        ┌─ SWE-bench 数据集 (HF) + 44 实例清单 (manifest json)
                        │
  driver (swebench_driver_v6.py, WSL) ── WS ──► agent server × 3 (jiuwenswarm)
        │                                          │
        │  每 run:                                   ├─ rtk 臂  (18092, hook 开, PATH 默认)
        │   1. prepare_repo (git 重置+refs 检测)      ├─ rtkv0 臂 (18096, hook 开, PATH=/opt/rtk-v0/bin 前置)
        │   2. prewarm (pip install -e)              └─ nortk 臂 (18093, 无 hook, RTK_DISABLED=1)
        │   3. 驱动 agent 会话 (全量 WS 录音)              │
        │   4. extract_patch (git diff --cached)     hook: rtk-rewrite-hook.py
        │   5. _tmp_sweep + _server_sweep            (PreToolUse, 调 rtk rewrite)
        ▼
  preds.jsonl ──► swebench eval (docker, x86 镜像) ──► results.json (resolved_ids)
        ▲
  analysis_3arm.py (轮数/token/配对差值/Mann-Whitney)
```

关键机制：**hook 在 PreToolUse 拦截 bash 命令**，调 `rtk rewrite` 把 `ls/grep/pytest/git…`
改写为 `rtk ls/...` 等价形式，模型读到的是压缩输出。`rtk rewrite` 退出码协议：
`0`=改写+放行，`1`=透传（无 rtk 等价），`2`=拦截，`3`=改写+询问（**3 不是错误！**）。

---

## 3. 新机器环境搭建

### 3.1 依赖清单

- WSL2 Ubuntu (x86_64；**SWE-bench Lite 镜像硬编码 `linux/amd64`，ARM 机器无法评测**)
- Rust 工具链（WSL 内：`~/.cargo/bin/cargo`；**Windows 侧 rustup 可能因网络下不动，直接在 WSL 编译**）
- Python 3.12 venv：`jiuwenswarm`（源码安装）+ `swebench` + `datasets` + `websockets`
- Docker（评测用，需预拉取实例镜像）
- 模型网关：agent server 的 `config.yaml → models.defaults` 配置（API key 自备）

### 3.2 编译 rtk

```bash
# 优化版（feat/swe-bench-optimization 分支, P1-P8）
cd <rtk 源码> && ~/.cargo/bin/cargo build --release
cp target/release/rtk /usr/local/bin/rtk

# 原版 v0（对照臂）— 用干净 worktree，避免与未提交改动互染
cd <rtk 源码>
git worktree add --detach /tmp/rtk-v0-src v0.49.0
cd /tmp/rtk-v0-src && ~/.cargo/bin/cargo build --release
mkdir -p /opt/rtk-v0/bin && cp target/release/rtk /opt/rtk-v0/bin/rtk
```

两个二进制版本号都是 0.49.0，**必须用 md5sum 区分**，验证部署正确：
`md5sum /usr/local/bin/rtk /opt/rtk-v0/bin/rtk`（哈希应不同）。

### 3.3 三个 agent server（臂间 PATH 隔离的核心）

工作区各一份（`cp -a` 后**清空** `.agent_history/ agent/sessions/ config/runtime_state/ logs/`）：

| 臂 | 端口 | 工作区 | 关键环境 |
|----|------|--------|---------|
| rtk（优化版） | 18092 | `/root/.jiuwenswarm` | `RTK_DISABLED=0`，默认 PATH（rtk→/usr/local/bin） |
| rtkv0（原版） | 18096 | `/root/.jiuwenswarm-v0` | `RTK_DISABLED=0`，`PATH=/opt/rtk-v0/bin:...` **前置** |
| nortk | 18093 | `/root/.jiuwenswarm-nortk` | `RTK_DISABLED=1`，config.yaml 无 hooks 段 |

systemd unit 模板（rtkv0 臂为例）：

```ini
[Service]
Type=simple
WorkingDirectory=/home/<user>/jiuwenswarm
Environment=JIUWENSWARM_DATA_DIR=/root/.jiuwenswarm-v0
Environment=JIUWENSWARM_CONFIG_DIR=/root/.jiuwenswarm-v0/config
Environment=AGENT_SERVER_PORT=18096
Environment=RTK_DISABLED=0
Environment=PATH=/opt/rtk-v0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/home/<user>/jiuwenswarm/.venv/bin/jiuwenswarm-agentserver
Restart=always
```

rtk / rtkv0 两臂工作区的 `config.yaml` 需含 hook（两臂用**同一个脚本**，靠 PATH 区分 rtk 二进制）：

```yaml
hooks:
  PreToolUse:
    - matcher: "bash|mcp_exec_command"
      hooks:
        - type: command
          command: "python3 /home/<user>/jiuwenswarm/scripts/rtk-rewrite-hook.py"
          timeout: 10
          shell: "bash"
```

**为什么 PATH 隔离有效**：agent server 的 bash 工具用 `subprocess.Popen(无 env=)` 起 shell，
hook 子进程同理——两者都继承 server 进程环境（已用 `/proc/<pid>/environ` + 真实会话
`which rtk` 验证）。模型自写的 `rtk ...`（模仿效应）同样按该 PATH 解析，行为一致。

**隔离验证三件套**（每次开实验前做）：

```bash
# 1. 进程环境
tr '\0' '\n' < /proc/$(systemctl show jw-agentserver-v0 -p MainPID --value)/environ | grep ^PATH=
# 2. 端到端：在 v0 server 上跑一个真会话，执行 `which rtk`，应返回 /opt/rtk-v0/bin/rtk
# 3. 行为差异：v0 臂 piped pytest 应被改写，优化臂应透传
echo '{"tool_name":"bash","tool_input":{"command":"pytest x | tail -5"}}' \
  | PATH=/opt/rtk-v0/bin:$PATH python3 <hook路径>   # → modifiedInput: rtk pytest ... | tail
echo '{"tool_name":"bash","tool_input":{"command":"pytest x | tail -5"}}' \
  | python3 <hook路径>                                # → 无输出(透传)
```

### 3.4 SWE-bench 数据与镜像

```bash
export HF_ENDPOINT=https://hf-mirror.com        # HF 镜像
# 实例清单（本机参考）: /root/swebench-run/experiment/instances_go50.json (44 实例)
# 镜像预拉: python prebuild_images.py / prebuild_pool.py
# 评测: swebench eval lite -p preds.jsonl --run-id <id> -j 3
```

---

## 4. 运行实验

### 4.1 driver v6 用法

```bash
# 三臂 × 44 实例 × 1 次，带全量录音，含升级黑窗
systemd-run --unit=sweb-3arm --working-directory=/root/swebench-run \
  /root/swebench-venv/bin/python swebench_driver_v6.py \
    --arm rtk --three-arm \
    --instances-file experiment/instances_go50.json \
    --run-root /root/swebench-run/runs_3arm \
    --repeats 1 --record [--blackout 22:50-23:25]
```

v6 内置（都是踩坑后加的，**别用旧版 driver 裸跑**）：
- `prepare_repo`：checkout/reset/clean + **额外 refs 检测→整库重克隆** + stash clear + reflog expire
- `_tmp_sweep`：每 run 后清理实验启动以来新增的 /tmp 条目（含隐藏条目，系统 keep-list 除外）
- `_server_sweep`：每 run 前清理三个 server 工作区的会话残留（详见 5.2）
- 失败 run 自动重试一次（重试记录替换 preds 中的失败记录）
- `--record`：全量 WS 帧落盘（`records/<arm>_<iid>_r<k>_<stamp>.jsonl`），后续逐轮分析必备

### 4.2 启动前检查单

```bash
pgrep -af swebench_driver        # 必须为空（防双开，见 5.5）
systemctl is-active jw-agentserver-rtk jw-agentserver-nortk jw-agentserver-v0
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18092/health   # 426 = WS 正常
# WSL 保活（Windows 侧，防 WSL 空闲自杀，见 5.6）:
# Start-Process -WindowStyle Hidden wsl.exe -ArgumentList '-d','Ubuntu','-e','bash','-c','sleep infinity'
df -h /root                      # 录音 ~20MB/run，预留空间
```

### 4.3 评测与分析

```bash
# 评测（三臂并行，每臂 j3 容器）
/root/swebench-run/eval_3arm_v2.sh    # → /root/swebench-run/logs/evaluation/3arm-<arm>/results.json
# 分析（轮数/token/配对差值/显著性/逐实例表）
/root/swebench-venv/bin/python /root/swebench-run/analysis_3arm.py
```

### 4.4 录音分析（信息损失/补偿行为研究）

参考 `runs_s11870/RTK_VS_NORTK_COMPARE.md` 的生成链路：
1. **必须用 `tool_call_id` 配对命令与输出**（见 5.8 的乱序坑）
2. native 对照 = nortk 臂同命令实录（归一化精确匹配，优先编辑前状态）+ 原生重放
  （base-commit 干净仓库重跑；grep/ls/git log 状态无关可靠；pytest 重放=基线状态；
   git diff/python 脚本状态相关不可重放）
3. 补偿判定要**以"确实丢了信息"为前提**（折叠标记/行数少于 native），否则把
   "grep 定位→sed 读代码"的自然工作流误判为补偿

---

## 5. 关键坑与规避（重点，全部实测踩过）

### 5.1 /tmp 共享污染（严重度 ★★★★★）

- **现象**：某次 run 的模型在 /tmp 发现了历史 run 留下的 `/tmp/pr11870.patch`（即
  gold patch）、上游仓库克隆（`/tmp/sympy-upstream`，含修复代码）等 30+ 文件，直接翻宝抄答案。
- **根因**：所有 run（同臂/对臂）共享主机 /tmp；模型习惯性往 /tmp 写脚本、克隆上游、
  下载 PR diff，产物跨 run 存活。
- **后果**：基线虚高——被污染的 nortk 基线 30 轮/1.34M tokens，干净环境实测 34 轮/1.82M。
  **你以为的对照组优势可能来自泄漏**。
- **修复**：driver 每 run 后 `_tmp_sweep`（时间戳 marker 之后新增的条目全删）；
  重跑前手工清空实验相关 /tmp 残留。
- **残余风险**：`/tmp/sitecustomize.py` 这类历史 shim 会在 `python3 /tmp/xx.py` 时自动
  import（sys.path[0]=脚本目录），注意排查。

### 5.2 agent server 会话残留（严重度 ★★★★★）

- **现象**：server 工作区累积 `.agent_history/file_ops_*.json`（**含模型编辑的
  old/new 全文 = 解法**）、`agent/sessions/`（完整对话，本机曾积 266 个）、
  `config/runtime_state/*.yaml`（会话元数据）、`logs/llm.log`（19MB 请求日志）。
- **根因**：模型以 root 运行 bash，`ls /root/` 就能看到**所有臂**的 server 工作区并读取。
  同实例多臂/多次重复实验中，后面的 run 可以读到前面 run 的完整解题过程。
- **修复**：driver `_server_sweep`——每 run 前清 `.agent_history/*`、`agent/sessions/*`、
  `config/runtime_state/*.yaml`、`.trace/*`；`logs/*.log` 用 truncate 保 FD 删内容，轮转
  文件 `*.log.[0-9]` 直接删。
- **验证方法**：全量录音 grep `.jiuwenswarm|.agent_history|recall --list`，确认 0 命中。

### 5.3 git 仓库额外 refs（严重度 ★★★★）

- **现象**：sympy 仓库里发现 `refs/remotes/origin/pr-11870`（某 run 中模型执行了
  `git fetch origin pull/11870/head`，把 **gold patch 分支** 拉进了仓库）和 50 个 tags。
- **根因**：常规的 `checkout --force + reset --hard + clean -fdx` **清不掉 refs**；
  stash、reflog 同理残留（`git log -g` 仍可达）。
- **修复**：`git for-each-ref` 检测到任何额外 refs → **整库重新浅克隆**（网络成本 ~10s，
  值得）；每 run 附加 `git stash clear` + `git reflog expire --expire=now --all`。
- **提示**：模型在 run 内主动 fetch 网络 PR 是无法阻止的（模型有网），能做的只是
  **run 间清残留**，保证后跑的臂不能捡前跑的臂留下的 refs。

### 5.4 端口占用：agentserver 会绑 N+1（严重度 ★★★）

- **现象**：v0 臂起在 18094 报 `address already in use`——排查发现 nortk server（18093）
  同时监听 18093 **和 18094**（fd=10/11）。rtk server 却只绑 18092，无规律可循。
- **修复**：选端口前 `ss -tlnp | grep 1809` 确认 N 和 N+1 都空闲；v0 臂最终用 18096。

### 5.5 后台进程管理 & 双开事故（严重度 ★★★★）

- **现象 A**：`bash.exe -c "nohup ... &"` 起的进程随会话退出**时灵时不灵**地被杀，
  driver.log 莫名消失。
- **现象 B（事故）**：一次 setsid 启动的 driver 其实活着，又用 systemd-run 起了第二个——
  **两个 driver 并行跑同一 run-root**，互相 reset 对方的仓库，导致 patch=0B 假象，
  整批实验作废重跑。
- **修复**：一律 `systemd-run --unit=<name>` 启动；启动后 `pgrep -af swebench_driver`
  **确认有且仅有一个进程**再离开。

### 5.6 WSL 空闲自动关机（严重度 ★★★）

- **现象**：长实验跑到一半 WSL 整体静默（无前台会话 ~10 分钟即触发自动停止），三个
  server + driver 全灭。
- **修复**：Windows 侧常驻保活：
  `Start-Process -WindowStyle Hidden wsl.exe -ArgumentList '-d','Ubuntu','-e','bash','-c','sleep infinity'`

### 5.7 LLM 网关升级窗口（严重度 ★★）

- **现象**：升级期间 in-flight run 的流式调用超时失败，run 报错作废。
- **修复**：driver `--blackout HH:MM-HH:MM`（窗口内不起新 run）+ 失败自动重试兜底。

### 5.8 录音解析：结果乱序（严重度 ★★★，分析正确性）

- **现象**：解析出的"模型命令→输出"错位（模型明明写 `sed`，配到的是 `grep` 的输出），
  导致早期分析全部失真。
- **根因**：模型一轮可发**多个并行 tool_call**，tool_result **乱序返回**；按顺序配对必错。
- **修复**：必须用 `tool_call.tool_call_id` ↔ `tool_result.tool_call_id` 配对；
  轮次边界用 `chat.usage_metadata` 事件切分。

### 5.9 模型模仿 rtk 前缀（严重度 ★★★，行为效应）

- **现象**：模型看到历史里的 `rtk grep ...` 后开始自写 `rtk python`、`rtk pytest`；
  `rtk python` 转发给不存在的 `python` 二进制 → exit 127，v0 报错 `[rtk: No such file
  or directory (os error 2)]` **不含命令名**，模型要浪费 1-2 轮诊断。
- **修复（P8）**：报错带命令名 `[rtk: python: ...]`；nortk 臂永远不会模仿（看不到 rtk），
  这是 rtk 的系统性成本之一，分析时要意识到。

### 5.10 `pytest | tail` 摘要被切（严重度 ★★★★★，已修 P7）

- **现象**：模型习惯 `pytest ... 2>&1 | tail -N` 取**末尾**摘要；hook 改写成
  `rtk pytest ... | tail -N` 后，rtk pytest 的摘要在**顶部**，tail 切片恰好把摘要切掉，
  超预算时还弹 recall 标记 → 模型连续重试 3-5 轮（10 runs 里 28 次异常）。
- **修复（P7）**：`rules.rs` 中 pytest 规则 `PipelineSafety::ProducerOnly → None`——
  **管道中的 pytest 不再改写**（模型自己的 pipe 就是天然的截断控制），独立 pytest 仍压缩。
- **通用教训**：改写"管道生产者"要极度小心——模型的 pipe 表达的是它想要的视图，
  rtk 改变输出结构会击穿这个意图。多级管道（`| grep | head`）在 v0 里本来就透传，
  这是排查时容易混淆的点（不是污染，是 v0 自身规则）。

### 5.11 Python 3.12 `import a.b.c as d` 陷阱（严重度 ★★，分析干扰项）

- `import sympy.simplify.trigsimp as ts` 在 Py3.12 走 getattr 语义 + sympy `__init__`
  把子模块名遮蔽成函数 → `ImportError: cannot import name ... (unknown location)`。
  模型会连跑 2-3 轮排错。**与 rtk 无关**，两臂随机命中；分析轮数差异时要剔除这类环境噪音
  （还有 `python` vs `python3` exit 127，两臂对称）。

### 5.12 模型可访问外网 → gold patch 可被直接下载（严重度 ★★，效度边界）

- `fetch_webpage`/`curl` 可直接拉 GitHub PR。sympy-11870 这类 **issue 号 = PR 号** 的实例，
  模型两臂都能拿到标准答案 → resolution 不能作为独立解题能力指标（成本对比仍有效，两臂对称）。
- SWE-bench 官方评测在 docker 容器内离线执行，不受影响。

### 5.13 其他

- **Windows 侧 rustup 下载失败**（网络不通）→ 一律在 WSL 内编译（源码在 /mnt/d 也行，
  但 target 放 WSL 文件系统更快）。
- **`rtk rewrite` 退出码 3 = Ask**（改写已生效），自动化脚本别当失败处理。
- **rtk 数据目录 `~/.local/share/rtk`**（recall.db/history.db）两 rtk 臂共享：理论上
  `rtk recall --list` 可翻到历史 run 的折叠内容，实测 168+ 命令 0 次被访问、且内容多为
  同仓库状态冗余——已接受的风险；严格场景可在 sweep 里一并清理。
- **pip editable 累积**：每 run prewarm `pip install -e .`，site-packages 会积累各实例的
  editable 安装；臂序轮转下对称，已接受；严格场景需快照/恢复 site-packages。

---

## 6. 已验证实验结论摘要（供结果合理性校验）

### 6.1 rtk 源码优化（分支 feat/swe-bench-optimization，7 文件未提交）

| # | 文件 | 改动 | 解决的问题 |
|---|------|------|-----------|
| P1 | cmds/python/pytest_cmd.rs | assert diff 相关行 3→5，E 行截断 100→200 字符 | 失败细节丢失→模型重跑 |
| P2 | core/config.rs | grep_max_per_file 25→50 | grep 折叠过狠 |
| P3 | cmds/git/git.rs | 小 diff(≤1 文件<50 行)输出原始 unified diff+stat | 紧凑格式改变语义 |
| P4 | cmds/system/ls.rs | <20 条目目录不加尺寸注解 | 格式扰动 |
| P7 | discover/rules.rs | pytest 管道生产者改写禁用 | **`pytest\|tail` 摘要被切（最大轮次浪费源）** |
| P8 | main.rs | ENOENT 报错含命令名 | 模型模仿 `rtk python` 排错浪费轮次 |

### 6.2 关键数字（复现参考量级）

| 实验 | 配置 | 结果 |
|------|------|------|
| sympy-11870 深测 v2（干净 /tmp，n=10/臂） | 优化版 vs nortk | 轮数 29 vs 34，tokens 1.45M vs 1.82M（-20.6%），双臂 10/10 |
| 44 实例三臂（隔离修复后，n=44/臂） | 优化版 / v0 / nortk | 解题 36/44 三臂持平；均值 tokens 1.54M / 1.86M / 1.78M（**自优化 vs v0 = -17%**，配对胜率 28:14） |
| 一致性校验 | v0 vs nortk | 本机 +4.6% tokens，与早期实验 +4.9% 吻合 |

**预期量级**：rtk 强度高的实例（pytest/grep 密集）收益大；全池平均后收益被稀释至
均值 -13%~-17%；中位数与 nortk 基本持平是正常现象（n=44 方差大，单对不显著也正常）。

---

## 7. 本机文件地图（迁移参考）

```
/root/swebench-run/
├── swebench_driver_v6.py          # 驱动（含全部隔离修复，用这个）
├── swebench_driver_v5.py          # 旧版（无 server_sweep/refs 检测/三臂）
├── eval_3arm_v2.sh                # 三臂并行评测
├── analysis_3arm.py               # 三方对比分析
├── experiment/instances_go50.json # 44 实例清单
├── runs_s11870/                   # 深测数据 + RTK_VS_NORTK_COMPARE.md（逐命令对比方法学）
├── runs_s11870_v2/                # 干净环境深测（P7+P8 验证）
├── runs_3arm/                     # 44 实例三臂实验（preds + 132 录音 + REPORT.md）
├── logs/evaluation/               # swebench eval 结果
└── RTK_TESTING_GUIDE.md           # 本文档

/home/<user>/jiuwenswarm/
├── scripts/rtk-rewrite-hook.py    # PreToolUse hook（fail-open 设计）
└── .venv/                         # jiuwenswarm + 依赖

<rtk 源码>/ (D:\Workspace\rtk_adapter_dsh\rtk)
├── src/cmds/system/search.rs      # rtk grep/rg 实现（输出过滤器）
├── src/cmds/python/pytest_cmd.rs  # rtk pytest
├── src/discover/rules.rs          # 改写规则表（pipeline_safety）
├── src/main.rs                    # CLI 分发 + ENOENT 报错
└── 分支 feat/swe-bench-optimization  # P1-P8 改动

/opt/rtk-v0/bin/rtk                # 原版 0.49.0 二进制（v0 对照臂）
/usr/local/bin/rtk                 # 优化版二进制
~/.config/rtk/                     # rtk 全局配置（filters.toml）
```

---

## 8. 快速上手清单（按序执行）

1. 通读第 5 章（坑），特别是 5.1/5.2/5.3/5.5
2. 按 3.2 编译两版 rtk，md5 确认不同
3. 按 3.3 起三个 server，跑"隔离验证三件套"
4. 4.2 启动前检查单逐项过（pgrep 防双开！WSL 保活！）
5. systemd-run 启动 driver v6（--record 必开，后分析依赖录音）
6. 跑完 → eval_3arm_v2.sh → analysis_3arm.py
7. 结果与 6.2 量级对照，偏差过大先查隔离（grep 录音里有没有 `.jiuwenswarm`、
   `/tmp` 翻宝、`recall --list` 等访问痕迹）
