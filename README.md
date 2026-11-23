<div align="center">
  <img src="docs/images/app-logo.png" alt="AgentBar Logo" width="112" height="112" />
  <h1>AgentBar</h1>
  <p><strong>原生 macOS 液态玻璃（Liquid Glass）菜单栏 AI Agent 会话监控、指标统计与一键审批工具</strong></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-26%2B%20Tahoe-1d4ed8?style=flat-square&logo=apple&logoColor=white" alt="macOS 26+" />
    <img src="https://img.shields.io/badge/Swift-6.2-f05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.2" />
    <img src="https://img.shields.io/badge/UI-Liquid%20Glass-6366f1?style=flat-square" alt="Liquid Glass" />
    <img src="https://img.shields.io/badge/Dependencies-Zero-10b981?style=flat-square" alt="Zero Dependencies" />
  </p>
</div>

当你同时在本机多个项目工程和好几台远程 SSH 开发机上跑着 **Codex、Claude Code、DeepSeek Harness、Cursor、Trae、Antigravity** 时，很容易忘记哪个任务已经生成完、哪个卡在权限审批、哪个半路报错了。**AgentBar** 常驻在 macOS 菜单栏，用四色状态灯实时汇总本机与所有远程服务器上的会话状态，**看完新内容后绿点自动消失**，默认**精简收起只聚焦重点会话**，并支持**菜单栏一键审批**与**秒级跳回对应对话窗口**。

## 效果预览

| 精简收起模式 · 多会话同屏聚焦 | 展开详情模式 · 遥测指标 & Markdown | 总数据看板 · 会员窗口 & 余额同步 |
| :---: | :---: | :---: |
| ![AgentBar 精简收起模式](docs/images/sessions-panel.png) | ![AgentBar 展开详情模式](docs/images/sessions-expanded.png) | ![AgentBar 总数据与额度看板](docs/images/overview-dashboard.png) |

---

## 核心功能与特色

### 1. 原生 Liquid Glass 设计 · 四色状态灯 & 看完自动消绿点
- **纯正液态玻璃质感**：基于 macOS 原生 `NSGlassEffectView` 与 SwiftUI 构建，去除传统窗口直角灰框，窗口高度随会话数量平滑自适应，会话较多时自动限制最大高度并支持丝滑滚动。
- **菜单栏一眼掌握全局**：菜单栏胶囊图标实时显示各状态会话计数，支持面板内点击对应颜色胶囊快速筛选：
  - 🔵 **蓝色（运行中）**：正在流式生成回复或调用工具；
  - 🟢 **绿色（新生成）**：任务刚刚生成完成、尚未点开查看；
  - 🟡 **黄色（待审批）**：卡在工具调用 / 命令执行权限请求，等待你拍板；
  - 🔴 **红色（错误）**：遇到 API 限流（429）、请求超时或执行异常。
- **看完自动消绿点（无需手动点已读）**：自动同步 Codex 桌面端原生线程未读状态，并智能检测 VS Code / Cursor / Trae / Antigravity（含 `Remote-SSH` 远端工作区）、本机/远端交互终端及菜单栏面板视口浏览状态——只要你查看过新生成的内容，绿点便会自动消失；同一会话后续完成新一轮生成时又会自动重新亮起绿灯提醒。

### 2. 收起 & 展开双模式 · 自定义焦点排列顺序
- **默认只看重点，告别噪音**：面板默认按 **「新生成 → 待审批 / 运行中」** 分区精简展示当前真正需要关注的会话（每条自动附带所属 `服务器 / 项目` 标记），而大量暂时无需关注的静默历史对话默认收拢在底部的 **「所有对话（点击展开）」** 折叠栏中。
- **自由切换排列方式**：支持一键切换为 `新生成 → 待审批 / 运行中`、`待审批 / 运行中 → 新生成`、`待审批 → 新生成 → 运行中（独立三栏）` 或 `按服务器 / 项目目录分组`。

### 3. 全工具生态 & `~/.ssh/config` 远程服务器自动聚合
- **主流 Coding Agent 开箱即用**：支持 **Codex（桌面版 & CLI）**、**Claude Code（CLI & VS Code / Cursor 扩展）**、**DeepSeek Harness**、**Cursor**、**Trae**、**Antigravity 2.0**（自动读取本机摘要库与运行态进程），并自动为不同工具区分专属图标与 CLI 角标。
- **零配置发现远程 SSH 会话**：自动解析本机 `~/.ssh/config`（支持 `Include` 嵌套配置、跳板机与连接复用），并发流式探测远程服务器上的活跃会话与进程状态。
- **清爽的层级归纳**：一级按 **本机 / SSH 服务器** 分组（支持置顶、自定义排序与顶部主机快捷胶囊过滤），二级自动将真实工程合并到项目目录，临时对话或无特定目录的会话自动平铺为散会话，告别满屏单条空文件夹。

### 4. 详尽的会话运行指标与原生 Markdown 预览
点开任意一条会话，即可查看完整的运行遥测数据：
- **Token 明细与成本估算**：实时拆分输入（Input）、输出（Output）、缓存读取（Cache Read）、缓存写入（Cache Write）与推理（Reasoning）Token，并根据供应商与模型自动估算等效开销。
- **上下文窗口（Context Window）进度条**：直观展示当前上下文已用比例（如 `128k / 200k · 64%`），超过 85% 自动高亮预警，还统计自动 Compact 压缩次数。
- **Agent 工程指标**：Prompt **缓存命中率**（Cache Hit %）、工具调用时间线与**工具成功率**、输出吞吐速率（`tok/s`）、对话轮次，以及本地/远端 Agent 进程的**物理内存（Memory）与 CPU 占用率**。
- **面板内原生 Markdown 渲染**：已完成的回复可直接在菜单栏内展开预览格式化 Markdown（标题、代码块、表格），也可一键复制或弹出独立阅读窗口。

**统计口径**：今日会话日志按本机自然日计数。Claude 跨文件复用的消息 ID / 用户提示 UUID 只计一次；Codex 分支扣除继承基线。模型与项目排行是近期活跃会话的历史总量，不是窗口内增量。会话费用是按价格目录或用户规则计算的 API 等值，不是账单。

Codex 的 `gpt-6.2-astra` 按公开目录的长输入费率估价：仅当可核对的单次请求输入（含缓存）超过 272,000 Token 才使用高档价，输出不计入门槛。无法拆分的累计用量、没有分档的价格源和自定义固定费率仍按基础价计算；缓存节省指标仅按基础价作参考。没有转录的后台请求不计入会话统计。

今日 Token 净量为未缓存输入加输出，总量另含缓存读写。没有写入会话日志的后台或无痕请求不计入统计。

### 5. 一键审批 & 精准跳转到对应对话/窗口
- **菜单栏一键审批**：内置轻量 `agentbar-hook`，面板内可一键安装 Claude Code 权限审批 Hook；遇到待审批请求时直接点 **“一键审批”** 批量放行，若命中 `rm -rf`、`git push --force`、`sudo` 等高危命令则自动弹出二次确认保护。
- **点哪条就跳回哪条**：每条会话右侧常驻 `↗` 一键跳转按钮（也支持 `⌘ + 单击` 或右键菜单选择打开方式）：
  - **Codex 桌面版**：通过 `codex://threads/<sessionId>` Deep Link 直接切到 Codex 里对应的那条具体对话；
  - **VS Code / Cursor（含 Remote-SSH 远程项目）**：通过 `vscode://vscode-remote/ssh-remote+<host>/<dir>` 或 `cursor://...` 一秒聚焦你正在连着该远程服务器的 IDE 窗口；
  - **Antigravity / Trae 等桌面端**：点击直接唤醒或切回对应桌面应用；
  - **终端 CLI（本机 & 远程 SSH）**：自动定位活跃 iTerm2 / Terminal `tty` 标签页，或打开终端自动 `cd` 进入目标目录执行 `claude --resume` / `codex resume` 恢复对话。

### 6. 总数据看板 & 自动刷新的额度 Dashboard
- **会员与周期额度自动识别**：自动读取本机登录态，展示 **ChatGPT Plus / Pro（5h 窗口 & 7d 周额度进度条）**、Claude、**DeepSeek Harness 账号钱包（自动读取 `~/.dsh` 登录态同步充值余额、赠金与累计消耗，无需手填 Token）** 与 **Antigravity**（本机安装登录 `agy` 1.1.11+ CLI 后自动读取套餐名称、各模型组额度与重置时间）实时消耗与会话统计。
- **支持自定义 Dashboard 后台自动同步**：可添加团队内部 **SSO 网页看板**（内置智能登录窗口与 DOM 额度自动提取）、**JSON API**（如 DeepSeek API Key 余额，Token 安全存入 macOS Keychain）或**自定义 Shell 脚本**，支持每 **1 / 3 / 5 / 15 分钟**在后台静默自动刷新。

---

## 安装与本地编译（为什么没有直接发预编译 DMG？）

> **关于未提供预编译 `.dmg` 的说明：**
> 因为个人目前没有购买 Apple Developer 付费开发者签名与公证（Notarization）证书，直接上传未签名的预编译 `.dmg` 下载到其他 Mac 上会被 macOS Gatekeeper 拦截提示“应用已损坏/无法验证开发者”。
>
> 不过本项目是 **零第三方依赖的纯原生 Swift Package**，甚至**不需要安装几十 GB 的完整 Xcode**（只要有基础的 macOS Command Line Tools 即可），在本地让你的 AI 编程助手帮你编译一个 `.dmg` 或 `.app` 只需要十来秒！

### 方式一：直接让 AI 帮你一键编译安装（最省心 ✨）

把下面这句话复制发给你的 **Codex / Claude Code / Cursor**：

```text
帮我把 https://github.com/tangziyi1226-lab/AgentBar 克隆到本地，运行 ./scripts/build_dmg.sh 编译打包出 AgentBar.app 和 AgentBar.dmg，然后把 AgentBar.app 复制到 /Applications 并启动它。
```

### 方式二：终端三行命令手动编译

**环境要求**：macOS 26+（Tahoe 及以上，原生支持 Liquid Glass API），已安装 Command Line Tools（若未安装可执行 `xcode-select --install`）。

```bash
git clone https://github.com/tangziyi1226-lab/AgentBar.git
cd AgentBar
./scripts/build_dmg.sh
```

编译完成后产物位于 `dist/` 目录：
- **应用包**：`dist/AgentBar.app`
- **安装包镜像**：`dist/AgentBar.dmg`

直接安装并启动到菜单栏：

```bash
cp -R dist/AgentBar.app /Applications/
open /Applications/AgentBar.app
```

---

## 项目结构（欢迎自由魔改 🛠️）

代码结构非常轻量清晰，很适合按你自己的工作流继续扩展新 Agent、新指标或自定义 UI：

```text
AgentBar/
├── Package.swift
├── Sources/
│   ├── AgentBarCore/                 # 核心数据模型、解析器与后台服务
│   │   ├── Models.swift              # 会话、状态、主机与分组核心模型
│   │   ├── CodexAdapter.swift        # Codex 桌面版 / CLI 会话与速率解析
│   │   ├── ClaudeCodeAdapter.swift   # Claude Code CLI / IDE 扩展会话解析
│   │   ├── DeepSeekHarnessAdapter.swift
│   │   ├── DeepSeekAccountUsageService.swift # DeepSeek Harness 账号钱包与额度同步
│   │   ├── CursorTraeAdapter.swift   # Cursor / Trae 本地工作区会话解析
│   │   ├── AntigravityAdapter.swift  # Antigravity 2.0 本地摘要库与运行态解析
│   │   ├── AntigravityUsageService.swift # Antigravity CLI 套餐与模型组额度解析
│   │   ├── SSHProbeService.swift     # ~/.ssh/config 自动发现与无阻塞并发远程探测
│   │   ├── HookApprovalManager.swift # 一键审批 Hook 管理与高危命令拦截
│   │   ├── BalanceService.swift      # SSO 网页 / JSON API / 脚本额度提取
│   │   └── PricingAndMetrics.swift   # 模型定价估算与上下文窗口目录
│   ├── AgentBarApp/                  # macOS 菜单栏原生 Liquid Glass 界面
│   │   ├── StatusBarController.swift # 菜单栏多色胶囊与无边框透明悬浮面板
│   │   ├── PanelView.swift           # 焦点状态分区、流式筛选栏与可折叠全部对话树
│   │   ├── SessionRowView.swift      # 会话卡片、展开遥测详情与 Markdown 预览
│   │   ├── ActiveSessionViewDetector.swift # 前台 IDE / 终端活跃驻留自动已读检测
│   │   ├── OverviewDashboardView.swift # 总数据看板与订阅额度视图
│   │   └── JumpService.swift         # Codex Deep Link / Remote-SSH IDE / 终端精准跳转
│   └── agentbar-hook/                # 轻量审批事件桥接 CLI
└── scripts/
    └── build_dmg.sh                  # 一键 Release 编译、图标生成、本地签名与 DMG 打包脚本
```

## 隐私说明

- **纯本地运行**：AgentBar 所有会话读取、SSH 探测与统计均在你的 Mac 本机完成，不会向任何第三方服务器上传任何对话内容、路径或密钥。
- **凭证安全存储**：API Token 存储在系统钥匙串（macOS Keychain），SSO 登录态仅保存在本机 `WKWebsiteDataStore` 中。

---

如果觉得有用欢迎点个 Star ⭐，也欢迎 Fork 出去按自己的习惯改造新功能！
