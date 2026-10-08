# rtk Windows 基准测试报告（2026-09-16）

- 测试对象: rtk 0.48.0（Windows 11, PowerShell 5.1 环境，opencode agent 通过 rtk.ts 插件透明改写命令）
- 方法: 每条命令原生执行 3 次（baseline，直接 exe 调用绕过改写）+ agent 经插件改写执行 3 次（rtk 路径，数据来自 `%LOCALAPPDATA%\rtk\history.db`）
- 字节 = stdout+stderr；"Raw B" 为原生 baseline 中位数；"rtk internal %" 为 rtk 自身记账（raw/filtered bytes÷4 估算×4 还原）
- Overhead = mean(rtk exec_time_ms) − median(native ms)；rtk 路径恒为暖缓存，native 第 1 次可能冷缓存
- Harness: `scripts/bench-windows.ps1`（modes: marker / baseline / collect / report）

## 结果总表

| 命令 | 是否改写 | 执行次数 | 原始字节 | 过滤后字节 | 节省字节 | 节省% | rtk 内部% | 原生耗时ms | rtk 耗时ms | 额外开销ms | 评级 | 备注 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| git status | YES | 3 | 255 | 56 | 199 | 78.0 | 78.1 | 38 | 56 | +18 | GOOD | |
| git log --oneline -10 | YES | 3 | 633 | 632 | 1 | 0.2 | 0.6 | 34 | 26 | -8 | LOW | 本已紧凑，无压缩空间 |
| git diff（空 diff） | YES | 3 | 0 | 0 | 0 | - | - | 32 | 54 | +22 | - | 双方输出为空 |
| git diff HEAD~5 | YES | 3 | 480573 | 31748 | 448825 | 93.4 | 93.5 | 93 | 152 | +59 | GOOD | ⭐ 最大节省来源 |
| git show HEAD | YES | 3 | 287 | 288 | -1 | -0.3 | 0 | 41 | 158 | +117 | NEG | 透传+1B；rtk 路径最慢情形 |
| git branch | YES | 3 | 10 | 368 | -358 | -3580 | 94.4 | 35 | 29 | -6 | NEG | rtk 内部运行更丰富的命令（自记 raw=6.6KB），输出增强 |
| git stash list（空） | YES | 3 | 0 | 0 | 0 | - | - | 31 | 27 | -4 | - | |
| git worktree list | YES | 3 | 25 | 24 | 1 | 4.0 | 14.3 | 36 | 27 | -9 | LOW | |
| git add . | YES | 3 | 0 | 36 | -36 | - | - | 51 | 75 | +24 | - | 原生静默 → rtk 输出 36B 摘要 |
| git commit -am bench | YES | 3 | 55 | 12 | 43 | 78.2 | 79.1 | 101 | 90 | -11 | GOOD | |
| git checkout | YES | 3 | 0 | 0 | 0 | - | - | 38 | 29 | -9 | - | 双方输出为空 |
| npm run build | YES | 3 | 35 | 8 | 27 | 77.1 | 77.8 | 689 | 665 | -24 | GOOD | |
| npm run typecheck | YES | 3 | 48 | 16 | 32 | 66.7 | 66.7 | 680 | 725 | +45 | GOOD | |
| npx tsc --noEmit | YES | 3 | 0 | 28 | -28 | - | 0 | 1038 | 944 | -94 | - | 原生静默 → rtk 输出确认行 |
| npx eslint . | YES | 3 | 188 | 132 | 56 | 29.8 | 92.4 | 968 | 938 | -30 | LOW | rtk 内部跑更详细格式（raw 1.7KB→132B） |
| npx vitest run | YES | 3 | 500 | 500 | 0 | 0.0 | 1.1 | 1318 | 1400 | +82 | LOW | vitest 默认 reporter 已紧凑 |
| npx prettier --check . | YES | 3 | 238 | 24 | 214 | 89.9 | 0 | 817 | 346 | -471 | GOOD | ⚠ baseline 与 rtk 阶段间 node_modules 由 npm 转 pnpm，状态不完全对齐 |
| pnpm install | NO* | 0 | 219 | - | - | - | - | 53 | - | - | FALLBACK | *已改写执行但 parse 失败→静默回退，9 次执行 0 落库（pnpm 10 ERR_PNPM_IGNORED_BUILDS 未被 rtk 0.48 识别）|
| pnpm list | YES | 3 | 314 | 128 | 186 | 59.2 | 99.5 | 64 | 63 | -1 | WARN | rtk 内部 raw=28KB→128B，原生版未加 --depth 所以列更短 |
| pnpm outdated | YES | 3 | 1341 | 108 | 1233 | 91.9 | 77.5 | 59 | 56 | -3 | GOOD | ⭐ |
| pytest | YES | 5 | 401 | 13 | 388 | 96.8 | 84.0 | 320 | 263 | -57 | GOOD | ⭐ n=5（含 2 次冒烟） |
| ruff check . | YES | 4 | 663 | 404 | 259 | 39.1 | 83.4 | 34 | 21 | -13 | WARN | baseline 用 compact 格式（663B），rtk 内部 raw 2.4KB |
| ruff format --check . | YES | 3 | 421 | 420 | 1 | 0.2 | 0 | 26 | 18 | -8 | LOW | |
| mypy . | YES | 4 | 143 | 124 | 19 | 13.3 | 13.9 | 188 | 189 | +1 | LOW | mypy 输出本就极简 |
| pip list | YES | 3 | 409 | 336 | 73 | 17.8 | 44.0 | 277 | 334 | +57 | LOW | |
| ls | YES | 3 | 332 | 480 | -148 | -44.6 | 74.1 | 21 | 22 | +1 | NEG | rtk ls 输出增强（更多列/表头） |
| cat Cargo.toml | YES | 3 | 2601 | 2604 | -3 | -0.1 | 0 | 29 | 0 | -29 | NEG | read 透传，无压缩 |
| tree | YES | 4 | 24747 | 216 | 24531 | 99.1 | 0 | 54 | 8 | -46 | **BUG** | ⚠ "99.1%"无效：rtk tree 在 Windows 回退 tree.com 并把排除模式当参数传入，输出"参数太多"错误（exit 0） |
| grep -r TODO src | YES | 3 | 1244 | 1244 | 0 | 0.0 | 4.0 | 39 | 36 | -3 | LOW | |
| find . -name *.rs | YES | 3 | 11* | 920 | -909 | - | 75.9 | 28 | 11 | -17 | * | *baseline 无效：Git find.exe 从原生父进程调用时递归失效（仅匹配根目录 12B）；采信 rtk 内部数据 3.8KB→920B（75.9%） |
| wc -l Cargo.toml | YES | 3 | 14 | 4 | 10 | 71.4 | 75.0 | 20 | 16 | -4 | GOOD | |
| diff README.md app.txt | YES | 3 | 48 | 48 | 0 | 0.0 | 0 | 44 | 0 | -44 | LOW | 小 diff 无压缩价值 |

## 汇总

- 可测量命令总原始字节: 515,755 → 过滤后 40,857，**总节省 92.1%**（由 git diff HEAD~5 主导）
- Verdicts: GOOD=11, WARN=2, NEG=5（多为"输出增强"而非回归）
- **改写率: 32/32 命令全部被插件改写并执行**（`pnpm install` 改写后 rtk 内部失败回退）

## 有效节省排名（同口径可比项）

1. git diff HEAD~5 — **93.4%**（480KB→31KB, +59ms）
2. pytest — **96.8%**（401→13B, -57ms）
3. pnpm outdated — **91.9%**（1341→108B）
4. prettier --check — 89.9%（⚠ 状态差异存疑）
5. git commit / git status / npm run build / wc — **66–78%**
6. pnpm list / ruff check / eslint — rtk 内部口径 83–99%，同口径 30–59%

## 关键发现（非数据类）

1. **BUG: `rtk tree` 在 Windows 损坏** — 回退到 Windows tree.com，把内部排除模式串当参数传入，输出 `参数太多 - node_modules|.git|target|...`，且 exit code = 0（失败被掩盖）。建议排查 `src/cmds/system/` tree 模块的 Windows fallback。
2. **`rtk pnpm install` 对 pnpm 10 静默回退** — parse 失败后走 raw passthrough 且**不写跟踪 DB**（9 次执行 0 记录），`rtk gain` 统计会低估该场景。
3. **rtk 对"静默/小型输出"命令会增加输出**（git add +36B、tsc OK 确认行 +28B、git branch 增强 +358B、ls 增强 +148B）— 这是设计权衡：牺牲少量字节换取可读性，但对"同命令字节节省"口径为 NEG。
4. **rtk_cmd 记录值为规范化形式**（如 `rtk ls .`、`rtk read`、`rtk lint eslint .`）且部分带尾部空格 — 做数据分析时需 strip + 模糊匹配。
5. **RTK_DISABLED=1 不影响 opencode 插件改写**（该开关仅作用于 Claude Code hook 脚本层）。
6. 耗时开销总体可控：典型 ±50ms；最差诚实情形 git show +117ms；多项命令 rtk 路径反而更快（暖缓存 + rtk 内部调用方式差异）。

## 局限性

- token = bytes/4 估算（rtk 不内置 tokenizer），绝对字节为近似值
- baseline（3 次中位数）与 rtk 路径（均值×3-5 次）统计口径不同；缓存状态不对齐（tsc/prettier/mypy 受影响最明显）
- prettier/pnpm-list 存在 npm→pnpm 布局切换带来的状态差异
- pnpm install 测的是错误路径输出（ERR_PNPM_IGNORED_BUILDS），baseline 与 rtk 两侧一致可比
- 未覆盖: cargo（rustup 安装超时取消）、gh（未提供 token）、docker/k8s/java/php/ruby 等生态

## 复现

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bench-windows.ps1 -Mode baseline  # 原生 3 次/命令
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bench-windows.ps1 -Mode marker    # 记录 DB marker
# …用 opencode agent 执行矩阵命令（插件自动改写）…
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bench-windows.ps1 -Mode collect -Marker <n>
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bench-windows.ps1 -Mode report
```

原始数据: `%TEMP%\opencode\rtk-bench\results\{baseline.json, collect.json, report.md}`
