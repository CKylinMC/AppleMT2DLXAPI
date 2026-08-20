# AppleMTDeepLX

将 **macOS 系统翻译**（Apple Translation 框架，端侧离线运行）以 **DeepLX 兼容的本地 HTTP API** 形式提供，供浏览器翻译插件（如陪读蛙、沉浸式翻译等）与其他软件集成。

- 纯原生实现：SwiftUI + Network.framework + Translation，零第三方依赖
- 菜单栏常驻，不占用 Dock
- 同时兼容 DeepLX `free`、`v1` 与 DeepL 官方 `v2` 三套接口格式
- 并发排队、超时控制、可选鉴权、局域网访问开关

> 开发者：CKylinMC ｜ 版本：1.0.0 ｜ Bundle ID：`in.ckyl.applemtdeeplx`

---

## 系统要求

- **macOS 26.0 及以上**（依赖 Translation 框架的无头会话 API）
- 首次翻译某语言对时，系统可能提示下载对应语言包（下载后可完全离线使用）

## 安装与首次启动

1. 将 `AppleMTDeepLX.app` 拖入"应用程序"文件夹（开机自启动需要稳定路径）。
2. 启动应用后，菜单栏出现翻译图标（💬），无 Dock 图标。
3. 点击菜单栏图标 → **启动服务**（或在"设置"中打开）。
4. 建议先做一次测试翻译，触发并同意系统语言包下载：

```bash
curl -s http://127.0.0.1:10825/translate \
  -H 'Content-Type: application/json' \
  -d '{"text":"Hello, world!","target_lang":"ZH"}'
```

成功时返回：

```json
{
  "alternatives": null,
  "code": 200,
  "data": "你好，世界！",
  "id": 1779423094485,
  "method": "Free",
  "source_lang": "EN",
  "target_lang": "ZH"
}
```

## 菜单栏菜单

| 菜单项 | 说明 |
| --- | --- |
| 启动服务 / 关闭服务 | 按当前状态动态显示，切换 HTTP 服务 |
| 复制地址 | 复制 `http://127.0.0.1:<端口>/translate` 到剪贴板 |
| 设置… | 打开设置窗口 |
| 关于 | 版本与版权信息 |
| 退出 | 退出应用（服务随之停止） |

## 设置说明

| 设置项 | 默认值 | 说明 |
| --- | --- | --- |
| 启动服务 | 关 | 启动/关闭本地 API 服务 |
| 端口 | `10825` | 监听端口（与 DeepLX 官方默认一致） |
| 自动选择端口 | 开 | 端口被占用时自动向上探测空闲端口并回写 |
| 允许局域网访问 | 关 | 关：仅监听本机回环；开：监听 0.0.0.0（建议同时开鉴权） |
| 并发任务数 | `10` | 同时在途的翻译批次数，超出排队 |
| 翻译超时 | `10` 秒 | 排队 + 翻译的总时限，超时返回 429 |
| 启用鉴权 | 关 | 开启后所有请求需携带自定义 API 密钥 |
| 开机自启动 | 关 | 基于系统登录项，首次需在系统设置中批准 |

## API 文档

### 端点一览

| 端点 | 方法 | 协议 | 说明 |
| --- | --- | --- | --- |
| `/translate` | POST | DeepLX free | 单文本翻译 |
| `/v1/translate` | POST | DeepLX v1 | 与 free 相同格式 |
| `/v2/translate` | POST | DeepL 官方 v2 | 文本数组，JSON 或表单提交 |
| `/` | GET | — | 服务健康信息 |

### 请求参数（三端点通用）

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `text` | string（v2 为数组） | 是 | 待翻译文本 |
| `target_lang` | string | 是 | 目标语言码，如 `DE`、`EN-US`、`ZH`、`ZH-HANT` |
| `source_lang` | string | 否 | 源语言码；`auto` 或省略时自动检测 |

语言码大小写不敏感。`EN`/`PT` 作目标时分别解析为 `EN-US`/`PT-BR`；`ZH-HANS` 等价于 `ZH`。

### free / v1 响应

```json
{
  "alternatives": null,
  "code": 200,
  "data": "Hallo Welt",
  "id": 1779423094485,
  "method": "Free",
  "source_lang": "EN",
  "target_lang": "DE"
}
```

### v2 响应

```json
{
  "translations": [
    { "detected_source_language": "EN", "text": "Hallo Welt" }
  ]
}
```

### 鉴权（开启后）

三种携带方式任选其一：

```bash
# 1. Bearer 头（DeepLX 风格）
curl -H 'Authorization: Bearer your_key' ...

# 2. DeepL-Auth-Key 头（DeepL 官方 v2 客户端风格）
curl -H 'Authorization: DeepL-Auth-Key your_key' ...

# 3. URL 参数
curl 'http://127.0.0.1:10825/translate?token=your_key' ...
```

### 错误码

| 状态码 | 含义 |
| --- | --- |
| `200` | 翻译成功 |
| `400` | 语言码非法 / 请求体不合法（响应附合法语言码列表） |
| `401` | 鉴权失败（密钥缺失或错误） |
| `404` | 文本为空 |
| `429` | 队列已满或请求超时（附 `Retry-After: 1`） |
| `503` | 语言包未安装 / 翻译引擎内部错误 |

错误响应统一为：`{"code": <状态码>, "message": "<说明>"}`。

## 客户端配置示例

### curl

```bash
# DeepLX free 格式（自动检测源语言）
curl -s http://127.0.0.1:10825/translate \
  -H 'Content-Type: application/json' \
  -d '{"text":"Good morning","target_lang":"DE"}'

# DeepL 官方 v2 格式（表单）
curl -s http://127.0.0.1:10825/v2/translate \
  -d 'text=Hello&text=World&target_lang=ZH'
```

### 陪读蛙（Read Frog）

- BaseURL：`http://127.0.0.1:10825`（应用会自动补全 `/translate`）
- API Key：未开启鉴权时留空；开启后填入设置中的密钥

### 其他 DeepLX 客户端

填写 `http://127.0.0.1:10825` 作为 DeepLX 服务地址即可；支持 `?token=` 或 `Bearer` 鉴权的客户端可直接对接。

## FAQ

**端口被占用怎么办？**
开启"自动选择端口"后会自动探测空闲端口；也可在设置中手动改端口，从菜单栏"复制地址"获取最新地址。

**返回 503 提示语言包未安装？**
打开系统"翻译"App 或在设置中做一次翻译，按系统提示下载对应语言包后重试。

**局域网设备无法访问？**
默认仅监听本机回环。在设置中开启"允许局域网访问"，并建议同时开启鉴权。

**为什么要求 macOS 26？**
无头翻译会话 API（`TranslationSession.init(installedSource:target:)`）自 macOS 26 起可用。

---

开发与构建请参阅 [Development.md](Development.md)。
