# TokenUsage

macOS 15+（Apple Silicon）菜单栏应用 + 桌面小组件，实时展示 **DeepSeek**、**Kimi（Moonshot）**、**Kimi Code**、**GLM（智谱）**、**MiniMax**、**Claude**、**Codex**、**小米 MiMo** 及**自定义接口模型**的账户余额 / 额度与用量趋势。

## 功能

- **菜单栏常驻面板**：图标显示在菜单栏（与控制中心同排的系统状态区），点击展开详情弹层；图标旁文本可在设置中选择：全部余额合计 / 仅图标 / 指定服务商（金额制显示剩余余额，配额制显示本周剩余百分比）。**面板高度可从下边框拖拽调节**（上边框固定锚在菜单栏；最大高度随内容自适应——内容显示完就拖不长，不会再出现空白区域；简洁/详细切换时窗口随内容自动收放，上限为屏幕高度）
- **服务商自定义排序**：设置 →「展示排序」用上移/下移调整菜单栏面板中服务商卡片的顺序
- **多账户 + 多 Key 管理**：同一服务商可添加多个平台账户，账户下再挂多个 API Key；看板「账户」下拉可查看单个账户，也可全部账户合并展示；设置中可添加/重命名/删除账户（删除账户会连带删除其 Key、余额历史与已导入数据）
- **Kimi Code 额度**：会员配额制专属卡片——本周额度与 5 小时滚动窗口双进度条（用量超 80% 变橙、90% 变红）、重置/恢复时间、并行上限、加量包状态；额度数据来自 `api.kimi.com/coding/v1/usages`（API Key 在 Kimi Code Console 申请）
- **余额卡**：今日消耗（大数字，导入真实消费 + 覆盖截止后实时推算）+ 今日 Tokens（导入真实值 + 实时估算，含估算时带 ≈ 前缀）+ 累计消费（默认 `***` 遮蔽，鼠标悬停显示；合并视图下各账户小标题也有各自的累计消费）+ 剩余余额。今日口径与所选时间段无关
- **累计消费校准**：看板的累计消费 = 校准值 + 已导入 + 实时消耗。在设置 → 各账户「累计消费校准」填入平台注册至今的总消费，即可补齐导入数据覆盖不到的历史
- **时间段切换**：今天 / 昨天 / 近 7 天 / 近 30 天 / 本月 / 上月，「时间维度」下拉一键切换统计口径（对齐 DeepSeek 用量页）。今天/昨天为**小时粒度**（横轴 00:00、01:00…）：逐小时柱来自官网登录态同步的精确数据；仅按天聚合的导入数据以半透明跨幅柱呈现当日合计，覆盖边界之后的新消耗由 App 按小时实时追加
- **图表交互**：所有图表支持鼠标悬停（hover）显示当天/当小时各系列明细数值；悬停图例项高亮对应系列（其余淡出），悬停某天时其余日期淡出；非零数据有最小可见柱高，再小的用量也能看到柱子，无数据时显示明确的空态占位
- **迷你趋势图**：每个模型小节标题右侧有该模型 tokens 日趋势 sparkline
- **导入 DeepSeek 用量**：卡片标题栏下载图标导入平台导出的 `usage_data_*.zip`（多账户时可选择导入到哪个账户；同账户重导视为校准，自动覆盖旧数据），展示逻辑对齐平台用量页：
  - 统计卡：消费金额（CSV 中 price × amount 的**真实消费**，非估算）、API 请求次数、Tokens
  - 消费金额堆叠图支持「模型 / API Key」双维度切换
  - 每个模型独立小节：Tokens 日用量图（按 Key 堆叠着色）+ API 请求次数平滑面积图
  - 「API Key」下拉可筛选单个 Key，也可查看全部 Key 合计
  - **导入覆盖截止时刻之后的消耗实时合并**：以导入 CSV 的最大行时间戳为边界，之后的消耗用每 5 分钟余额快照的下降量推算（导入覆盖今天时，今天后续的消耗也会持续计入，不再丢失），并入统计卡与消费金额图（Key 维度与导入系列合并；模型维度按各 Key 最近一天的模型消费占比分摊，毫无可参照口径时才单列灰色「实时消耗」系列），「Tokens（实时估算）」图按各 Key 最近一天的 tokens/元 口径折算，随用随更新
- **清除所有数据**：设置 → 数据 →「清除所有数据」，删除所有 API Key、账户、余额历史与已导入用量，连同面板偏好一并重置回首次安装状态，用于手动校准后重新配置与导入
- **动画**：卡片入场渐显、柱状图升起 / 面积图擦除展开的加载动画、卡片悬停提亮微浮、图标按钮按压缩放回弹、刷新时圆点与图标脉动、刷新图标旋转、数字滚动过渡、tooltip 淡入缩放、加载微光占位
- **桌面/通知中心小组件**：小号、中号两种尺寸，含余额与趋势迷你图（发布包已内置，安装后主 App 运行一次即自动注册）
- **自动刷新**：1/5/15/30 分钟可选；API Key 以 0600 权限存于 `~/Library/Application Support/TokenUsage/api_keys.json`（见下注）
- 原生 macOS 风格：SwiftUI + Swift Charts，遵循系统外观（深浅色自适应）

## 安装（开箱即用）

成品包发布在仓库的 **Releases** 页面：`TokenUsage.zip`（含菜单栏 App + 桌面小组件，ad-hoc 签名），解压即得 `TokenUsage.app`。

1. 解压后把 `TokenUsage.app` 拖到 `/Applications`（或直接双击运行亦可）
2. 首次启动会弹出**初始化向导**，引导添加服务商账户并填入 API Key：
   - DeepSeek：<https://platform.deepseek.com/api_keys>
   - Kimi：<https://platform.moonshot.cn/console/api-keys>
   - 其余服务商（Kimi Code / GLM / MiniMax / Claude / Codex / 小米 MiMo / 自定义）在设置中按选项卡配置
3. 保存后自动开始轮询；余额历史随时间积累，趋势图和消耗统计会越来越完整

若 macOS 提示无法打开（经过网络拷贝带隔离属性时），执行：
`xattr -dr com.apple.quarantine /Applications/TokenUsage.app`

## 关于"控制中心"与小组件的说明

- **控制中心**：macOS 不向第三方应用开放控制中心（Control Center）模块接口，业界标准做法是本应用采用的 `MenuBarExtra`——图标在菜单栏系统状态区，与控制中心同排，点击即弹出面板。
- **小组件**：发布包已内置 `TokenUsageWidget` 扩展（ad-hoc 签名在本机可正常注册运行）。主 App 运行一次后，桌面右键 → 编辑小组件 → 搜索"Token 用量"即可添加；若列表里找不到，注销或重启一次 Mac 让 LaunchServices 刷新。

## 自行构建

```bash
./build.sh        # 仅需 Command Line Tools：本机直装的菜单栏 App（不含小组件），输出 dist/TokenUsage.app
```

完整版（含小组件）需要 Xcode，打开 `TokenUsage.xcodeproj` 直接 ⌘R，或命令行：

```bash
xcodebuild -scheme TokenUsage -configuration Release -derivedDataPath build/DerivedData build
# 产物：build/DerivedData/Build/Products/Release/TokenUsage.app
```

工程两个 target 均为 Automatic 签名、`DEVELOPMENT_TEAM` 留空，此时按「Sign to Run Locally」本机签名，小组件可正常使用；填入自己的 Team ID（免费个人账号即可）亦可。

## 关于 API Key 存储的说明

免签名（ad-hoc）构建的 Keychain 条目按签名身份绑定，重编译后旧条目无法删除/覆盖，会导致"删旧 Key 存新 Key"静默失败。因此 Key 存储采用本地文件（0600 权限，仅当前用户可读，与 `~/.ssh` 私钥同级），添加、覆盖、删除均即时生效。

## 数据来源与口径

- 余额来自官方接口：`api.deepseek.com/user/balance`、`api.moonshot.cn/v1/users/me/balance`；Kimi Code 为会员配额制，额度来自 `api.kimi.com/coding/v1/usages`（周额度 + 5 小时滚动窗口，无金额余额）
- 两家官方均**未开放**逐模型 token 用量查询接口（已实测：平台用量页自用的 `/api/v0/usage/by_api_key/*` 接口拒绝 API Key，仅接受网页登录态），因此：
  - 导入 `usage_data_*.zip` 后：Tokens、请求次数、消费金额均来自导出 CSV 的真实统计（消费金额 = price × amount 逐行累加，与平台用量页一致）
  - 导入覆盖截止时刻之后 / 未导入时：「消耗金额」用相邻两次轮询的余额下降量（充值不计入）实时推算，为真实测量值；「Tokens（实时估算）」按各 Key 最近一天导入数据的 tokens/元 口径折算（不用全历史比率——账户切换模型后旧模型的单价会扭曲估算），为估算值；本地 Key 与导入数据按平台 Key 名自动对应（同名优先，账户内唯一时直接配对）。旧缓存没有记录覆盖时间时退化为「导入截止日次日 0 点」，重新导入一次即恢复精确
- 已在设置中登录官网（保存登录态）的 DeepSeek 账户：App 每 10 分钟自动轻量同步「今天 + 昨天」的单日逐小时用量，今天/昨天维度的模型归属以官网精确数据为准，余额差额的占比估算只补足两次同步之间的几分钟；登录态失效时本次运行期内自动停止，重新登录后恢复

## 目录结构

```
Shared/            # 主 App 与 Widget 共用：数据模型、App Group 存储、定价表、格式化、迷你图
TokenUsage/        # 主 App：菜单栏入口、余额服务（网络）、Key 存储、状态 store、SwiftUI 视图
TokenUsageWidget/  # WidgetKit 小组件（小号/中号），需 Xcode + Team 签名构建
Tools/             # 开发工具：发布打包、图标生成、离屏渲染校验、导入修复等脚本
build.sh           # 无 Xcode 手工构建脚本（Command Line Tools），输出 dist/TokenUsage.app
dist/              # 本地构建产物（不入库；成品包见 Releases）
```
