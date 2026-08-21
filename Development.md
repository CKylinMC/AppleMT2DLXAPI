# AppleMTDeepLX 开发文档

面向开发者的构建、调试、打包与测试说明。

## 环境要求

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| macOS | 26.0+ | Translation 无头会话 API 的硬性要求 |
| Xcode | 26+ | 需包含 MacOSX 26.0+ SDK |
| xcodegen | 最新稳定版 | 生成 `.xcodeproj`：`brew install xcodegen` |

## 目录结构与模块职责

```
├── project.yml                      # XcodeGen 工程定义（单一事实来源，含版本号与 Sparkle 依赖）
├── Makefile                         # generate / build / release / run / clean / bump
├── bump                             # 版本管理命令入口（推荐，支持全部参数）
├── appcast.xml                      # Sparkle 更新源（由 CI 自动维护，勿手改）
├── scripts/
│   ├── bump.sh                      # 版本计算、写入、提交与打 tag
│   ├── release-notes.sh             # Conventional Commits 分类更新日志
│   └── update-appcast.sh            # appcast.xml 条目插入/去重
├── .github/workflows/release.yml    # tag 触发的自动发布流水线
├── Resources/
│   ├── Info.plist                   # LSUIElement、版本、zh-Hans
│   └── Assets.xcassets              # 应用图标
└── Sources/AppleMTDeepLX/
    ├── App/                         # 入口与编排
    │   ├── AppleMTDeepLXApp.swift   # @main：MenuBarExtra（label 叠加服务状态圆点）
    │   ├── AppDelegate.swift        # 激活策略切换（窗口开 .regular / 关 .accessory）
    │   ├── SettingsWindowController.swift  # 自管设置窗口：固定尺寸、不可缩放/全屏
    │   ├── UpdaterAccess.swift      # Sparkle 更新器包装（@Observable 环境注入载体）与通道代理
    │   └── AppState.swift           # 组合各模块；配置变更 → 服务热重启
    ├── Settings/                    # 配置与登录项
    │   ├── AppSettings.swift        # 配置模型与校验
    │   ├── SettingsStore.swift      # @Observable + UserDefaults(JSON) 持久化
    │   └── LoginItemManager.swift   # SMAppService.mainApp 封装
    ├── Translation/                 # 翻译引擎
    │   ├── LanguageCodes.swift      # DeepL 码 ↔ Locale.Language 映射与校验
    │   ├── LanguagePolicy.swift     # 语言策略：启用列表/默认语言/强制开关
    │   ├── LanguageSupportProbe.swift    # 系统语言包安装状态探测（仅设置界面）
    │   ├── SourceLanguageDetector.swift  # NLLanguageRecognizer 源语言检测
    │   ├── TranslationEngineError.swift  # 带 HTTP 语义的错误类型
    │   ├── TranslationSessionPool.swift  # 会话池（LRU 8 对 / 空闲 10 分钟）
    │   ├── TranslationSession+Sendable.swift
    │   └── TranslationScheduler.swift    # 并发上限 + FIFO 队列 + 超时 + 合批
    ├── Server/                      # HTTP 服务（Network.framework）
    │   ├── HTTPMessage.swift        # 请求/响应模型与序列化
    │   ├── HTTPParser.swift         # 增量状态机解析器
    │   ├── HTTPConnection.swift     # 连接循环：keep-alive、双超时
    │   ├── HTTPServer.swift         # NWListener 生命周期、端口探测
    │   └── Router.swift             # O(1) 路由表
    ├── Protocol/                    # DeepLX 协议适配
    │   ├── DeepLXModels.swift       # 请求/响应 DTO（snake_case）
    │   └── DeepLXHandler.swift      # 校验、调度、错误码映射
    ├── Auth/AuthGuard.swift         # Bearer / DeepL-Auth-Key / ?token=
    ├── Observability/ServerStats.swift
    └── UI/                          # 菜单栏、设置窗口（侧栏分页）、状态面板、关于
```

依赖方向单向：`UI → AppState → {HTTPServer, Scheduler, SettingsStore}`；
`Router/Handler → Scheduler 接口`；HTTP 层不感知翻译，引擎层不感知 HTTP。

## 构建

```bash
brew install xcodegen          # 首次
make build                     # = xcodegen generate + xcodebuild (Debug)
make release                   # Release 构建
make run                       # 构建并启动应用
make clean                     # 清理派生数据与工程文件
./bump --dump                  # 查看当前版本（版本管理见下文）
```

产物位置：`.build-derived/Build/Products/<Configuration>/AppleMTDeepLX.app`。

## 调试要点

- **必须在本机运行**：Translation 框架不支持模拟器。
- `xcodebuild` 日志可用 `os_log` 过滤：subsystem 统一为 `in.ckyl.applemtdeeplx`，
  分类：`Scheduler` / `SessionPool` / `HTTPServer` / `HTTPConn` / `DeepLX` / `LanguageDetect`。
  ```bash
  log stream --predicate 'subsystem == "in.ckyl.applemtdeeplx"' --info --debug
  ```
- 首次翻译新语言对时系统可能弹出语言包下载授权，属预期行为。
- 修改 `project.yml` 后需重新 `make generate`。

## 关键实现约定

- **Swift 6 严格并发**：引擎与调度器为 actor；HTTP 层状态仅在专用串行队列访问；
  `TranslationSession` 通过调度器的"同语言对串行 + 并发上限"保证单会话单在途批次，
  故标注 `@unchecked Sendable`（见 `TranslationSession+Sendable.swift`）。
- **超时**：覆盖排队与执行全周期；执行中超时由看门狗调用 `session.cancel()` 打断。
- **合批**：出队时合并队头连续同语言对作业（≤16 条文本）为一次 `translations(from:)`。
- **端口回写防环**：自动选端口成功后先更新 `appliedServerSnapshot` 再回写设置，
  避免 `onChange` 触发重复重启（见 `AppState.applyServerState`）。
- **语言策略**：启用列表/默认语言/强制开关由 `LanguagePolicy` 集中承载，在
  `DeepLXHandler.translateAndRespond` 单点解析；请求级生效，变更无需重启服务、
  不重建会话池（不在 `serverEquals` 字段内）。`enabledLanguages` 空集 = 全部启用；
  “相同语言”比较统一用 `Locale.Language.minimalIdentifier`（与会话池 PairKey 一致）；
  启用匹配按基础语言码两级规则（启用 EN 覆盖 EN-US）。显式请求被禁用语言 → 400；
  检测出的输入语言不可用 → 回退默认输入语言（未设置时保持存量 EN 回退）。
  设置界面的“未安装”标注为按参考语言对探测的启发式提示，运行时权威校验仍在
  `TranslationSessionPool.createSession`。
- **设置向后兼容**：`AppSettings` 手写 `init(from:)`（extension），新字段
  `decodeIfPresent` + 默认值，旧版 `settings.v1` JSON 缺键不抛错；新增设置字段时
  必须同步扩展手写解码，否则 `SettingsStore` 会静默重置全部配置。

## 打包与分发

正式发布走上述 tag 触发的自动流水线；以下仅供本地手工分发参考。

```bash
make release
```

分发方式（按正式程度递增）：

1. **本地自用**：直接使用 `.build-derived/Build/Products/Release/AppleMTDeepLX.app`
   （ad-hoc 签名，仅本机可用）。
2. **压缩分发**：
   ```bash
   cd .build-derived/Build/Products/Release
   ditto -c -k --keepParent AppleMTDeepLX.app AppleMTDeepLX-1.0.0.zip
   ```
3. **DMG**：
   ```bash
   hdiutil create -volname AppleMTDeepLX -srcfolder AppleMTDeepLX.app \
     -ov -format UDZO AppleMTDeepLX-1.0.0.dmg
   ```

## 版本管理与发布

### 版本单一事实来源

`project.yml` 的 `MARKETING_VERSION`（展示版本）与 `CURRENT_PROJECT_VERSION`（构建号，
Sparkle 以此比较新旧）。`Info.plist` 版本键为构建期插值（`$(MARKETING_VERSION)`），
勿手工改版本。每次 bump 两个字段同步变更，构建号必 +1（否则客户端检测不到更新）。

### bump 命令

```bash
./bump                    # patch +1：1.0.0 -> v1.0.1；当前为 beta 时定稿（去后缀）
./bump minor              # 1.0.0 -> v1.1.0
./bump major              # 1.0.0 -> v2.0.0
./bump --beta             # 1.0.0 -> v1.0.1-beta.1；已是 beta 时递增 -beta.N
./bump v2.0.0-beta.2      # 指定版本（可带 v 前缀与 beta 后缀，自动识别）
./bump --dump             # 仅输出当前版本号
./bump --no-commit        # 写入但不自动 commit（需同时 --no-tag）
./bump --no-tag           # 不创建 tag
./bump --help             # 帮助
```

macOS 自带 GNU Make 3.81 会把 `--` 开头参数当作自身选项，因此带旗标的调用请用
`./bump`（或 `make bump -- --beta` 形式）；`make bump minor` 等无旗标形式可直接用。

默认行为：写入 project.yml → `chore(release): vX.Y.Z` 提交 → 打 tag `vX.Y.Z`。
防呆：脏工作区拒绝执行、拒绝降级/重复版本、tag 已存在报错。

### 发布流水线（GitHub Actions）

推送 tag `vX.Y.Z`（或 `vX.Y.Z-beta.N`）后 `.github/workflows/release.yml` 自动执行：

1. 校验 tag 格式与 project.yml 版本一致性
2. `make release` 构建，断言 ad-hoc 签名
3. `ditto` 打包 zip，用 Sparkle `sign_update` EdDSA 签名
4. 按 Conventional Commits 生成分类更新日志（feat→新增功能 / fix→问题修复 /
   perf→性能优化 / 其余→其他）
5. 创建 GitHub Release（tag 带后缀时标记 prerelease）
6. 更新 `appcast.xml`（beta 条目带 `sparkle:channel="beta"`）并回推 main

### Sparkle 密钥（一次性配置）

```bash
# 下载 Sparkle 官方二进制包（Sparkle-x.y.z.tar.xz）解压后：
bin/generate_keys                 # 私钥存入本机钥匙串，务必妥善备份
bin/generate_keys -p              # 输出公钥 → 填入 Info.plist 的 SUPublicEDKey
bin/generate_keys -x key.txt      # 导出私钥（base64）→ 存入仓库 Secret：SPARKLE_EDDSA_KEY_B64
```

Secrets 清单：`SPARKLE_EDDSA_KEY_B64`。私钥泄露需重新生成密钥对并发布桥接版本。

### 手工回滚已发布的版本

```bash
git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z   # 删 tag
gh release delete vX.Y.Z --yes --cleanup-tag             # 删 Release 与资产
# 从 appcast.xml 移除对应 <item> 后提交推送
```

### Sparkle 集成要点

- SPM 依赖钉死于 `project.yml`（`exactVersion`）：`*.xcodeproj` 被 gitignore，
  Package.resolved 无法提交，靠钉版保证 CI 可复现。
- `SPUStandardUpdaterController` 是 ObjC 类（不符合 Observable），经 `UpdaterAccess`
  （`@Observable` 包装）注入 SwiftUI 环境；通道代理按 `receiveBetaUpdates`
  偏好返回允许通道（刻意存于 Sparkle 自带 UserDefaults，不进 AppSettings）。
- beta 分发：单 appcast + item 级 `sparkle:channel="beta"`，稳定用户默认不收 beta。

## 签名说明

| 方式 | 配置 | 影响 |
| --- | --- | --- |
| ad-hoc（当前默认） | `CODE_SIGN_IDENTITY: "-"` | 仅本机；SMAppService 注册可用但个别系统策略下可能受限 |
| Sign to Run Locally | Xcode 中选择个人团队 | 本机更完整的系统信任，仍不可分发 |
| Developer ID | 需 Apple 开发者账号 + 公证 | 可分发；SMAppService 与 Translation 行为最稳定 |

注意：
- 未开启 App Sandbox（`ENABLE_APP_SANDBOX: NO`），本地监听无需额外 entitlement；
  若改为沙盒构建，需补充 `com.apple.security.network.server`。
- 开机自启动要求应用位于稳定路径（/Applications），构建目录下注册不可靠。

## 测试用例清单

服务启动后逐项执行（默认未开鉴权）：

```bash
BASE=http://127.0.0.1:10825

# 1. 健康信息
curl -s $BASE/

# 2. free 端点成功路径
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"Hello world","source_lang":"EN","target_lang":"ZH"}'

# 3. v1 端点
curl -s $BASE/v1/translate -H 'Content-Type: application/json' \
  -d '{"text":"Good morning","target_lang":"DE"}'

# 4. v2 JSON（数组）
curl -s $BASE/v2/translate -H 'Content-Type: application/json' \
  -d '{"text":["Hello","World"],"source_lang":"EN","target_lang":"JA"}'

# 5. v2 表单
curl -s $BASE/v2/translate -d 'text=Hello&target_lang=FR'

# 6. 自动检测（省略 source_lang）
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"今日は良い天気です","target_lang":"EN"}'

# 7. 400：非法目标语言码
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"hi","target_lang":"XX"}'

# 8. 404：空文本
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"","target_lang":"DE"}'

# 9. 404：未知路径
curl -s $BASE/unknown

# 10. 503：未安装的语言对（选择系统未下载的语言对测试）
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"hello","target_lang":"VI"}'

# 11. 429：并发压测（队列满或超时）
seq 1 30 | xargs -P 30 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"This is a load test sentence number {}.","target_lang":"ZH"}'

# 12. keep-alive：同一连接多请求
curl -sv $BASE/translate $BASE/translate \
  -H 'Content-Type: application/json' \
  -d '{"text":"one","target_lang":"ZH"}' \
  -d '{"text":"two","target_lang":"ZH"}' 2>&1 | grep 'Re-using'

# 13. 鉴权（在设置中开启鉴权并设定密钥 mykey 后）
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"hi","target_lang":"DE"}'                                    # 401
curl -s $BASE/translate -H 'Authorization: Bearer mykey' \
  -H 'Content-Type: application/json' -d '{"text":"hi","target_lang":"DE"}' # 200
curl -s $BASE/translate -H 'Authorization: DeepL-Auth-Key mykey' \
  -H 'Content-Type: application/json' -d '{"text":"hi","target_lang":"DE"}' # 200
curl -s "$BASE/translate?token=mykey" -H 'Content-Type: application/json' \
  -d '{"text":"hi","target_lang":"DE"}'                                    # 200

# ===== 语言策略（需先在设置中配置）=====

# 14. 默认输出语言（设置默认输出为 ZH 后，省略 target_lang）
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"Hello world","source_lang":"EN"}'                            # 200，目标为 ZH
curl -s $BASE/v2/translate -d 'text=Hello&source_lang=EN'                   # form 同上

# 15. 输出与输入相同（已设默认输出 ZH）
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"Hello world","source_lang":"EN","target_lang":"EN"}'         # 200，目标改判为 ZH

# 16. 启用列表（仅启用 ZH，其余禁用后）
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"hi","source_lang":"EN","target_lang":"DE"}'                  # 400 disabled
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"hi","source_lang":"EN","target_lang":"ZH"}'                  # 200

# 17. 默认输入语言（禁用 DE、设默认输入为 EN 后，检测出德语）
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"Guten Tag","target_lang":"ZH"}'                              # 200，按 EN 处理

# 18. 强制开关（开启“强制使用默认输出语言”后，请求指定其他目标仍用默认）
curl -s $BASE/translate -H 'Content-Type: application/json' \
  -d '{"text":"Hello","target_lang":"DE"}'                                  # 响应 target_lang 为默认输出

# 19. 存量兼容（恢复默认设置：全不勾选、默认语言未设置、开关关闭）
# 用例 1–13 结果应与未启用本功能时逐字节一致（省略 target_lang 仍 400）
```
