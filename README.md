# iOS6AIChat — 在线 AI 聊天 App（iOS 6 拟物风格）

一个用 Objective-C + 纯代码 UI 写的 iOS 聊天 App，UI 复刻 iOS 6 的拟物化质感（高光、皮革纹理、圆角浮雕气泡）。

支持三种 AI provider：**智谱 GLM / OpenAI / Ollama**，并自带中转开关——开启后所有请求经默认中转服务器 `api-ai.awa.lat` 路由到对应后端，规避 iOS 6 的 TLS 兼容问题；想自建中转见 [`github.com/qwq672/online-ai-transit-server`](https://github.com/qwq672/online-ai-transit-server)。

| 功能                | 实现                                                                 |
| ------------------- | -------------------------------------------------------------------- |
| **流式回复**        | `NetworkService` 用 `NSURLConnection` + chunked SSE 增量解析         |
| **会话历史**        | `ConversationStore` 把每个 `Conversation` 序列化到 `.conv` 文件      |
| **Markdown**        | `MarkdownParser` 支持粗体 / 斜体 / 代码块 / 列表 / 标题 / 链接        |
| **多 Provider**     | 智谱 GLM / OpenAI / Ollama 三个内置 + 自定义直连                      |
| **中转开关**        | 开关 ON 时走中转服务器（带 `X-Provider` 头），OFF 时直连              |
| **iOS 6 拟物 UI**  | `iOS6Theme` + `ChatBubbleView` + `ComposerView` 全用 CoreGraphics 绘  |
| **键盘自适应**      | 监听 `UIKeyboardWillShowNotification`，手动画调整 bottom inset        |
| **自适应高度**      | `[ChatMessageCell heightForMessage:width:]` 离线测量                 |

---

## 1. 工程结构

```
iOS6AIChat/
├── Makefile                         # Theos 构建脚本（Linux + Docker 路径）
├── control                          # Theos .deb 包元数据
├── Dockerfile                       # ← 自包含 Docker 镜像（推荐路径）
├── build-ipa.sh                     # ← 一键构建脚本（Docker 包装器）
├── iOS6AIChat.xcodeproj/            # Xcode 工程（macOS CI 路径）
├── .github/workflows/
│   ├── build.yml                    # macOS runner CI（iOS 11+ IPA）
│   └── build-linux.yml              # Ubuntu + Theos CI（真 iOS 6 armv7）
├── README.md
└── iOS6AIChat/                      # 共享源码（已用 iOS 6 SDK 真编译验证）
    ├── main.m
    ├── AppDelegate.h/m
    ├── iOS6AIChat-Prefix.pch
    ├── iOS6Theme.h/m                # 拟物主题层（iOS 6 barStyle 守卫）
    ├── Resources/iOS6AIChat-Info.plist
    ├── Models/{Message,Conversation}.h/m
    ├── Services/{ConversationStore,NetworkService,MarkdownParser}.h/m
    ├── Views/{ChatBubbleView,ChatMessageCell,ComposerView}.h/m
    └── Controllers/{Chat,History,Settings}ViewController.h/m
```

---

## 2. 三条出 IPA 的路径对比

| 路径 | 工具链 | 部署目标 | 架构 | 真能装到 iOS 6 设备？ |
|------|--------|----------|------|----------------------|
| **A. Docker（推荐）** | Theos + cctools-port + iPhoneOS6.0.sdk | **iOS 6.0** | **armv7 / armv7s** | ✅ |
| B. GitHub Actions Linux | 同 A，在 ubuntu-22.04 runner 上 | iOS 6.0 | armv7/armv7s | ✅（需 SDK 在 secret） |
| C. GitHub Actions macOS | Xcode 14 + macos-13 | iOS 11+ | arm64 | ❌（系统最低 iOS 11） |

本机 Linux 上若不装 Docker，`clang-19` 能把所有 14 个 `.m` 文件编译成 armv7 .o 文件，但 Debian 自带的 `ld64.lld` 19 跟 iPhoneOS10.3 SDK 的 `.tbd` 格式不兼容（链接失败）。要拿到真 IPA，必须走 Docker 路径——Docker 里的 Theos + cctools-port 自带 Apple 原版 ld64 兼容实现。

---

## 3. 推荐路径：Docker 一键出 IPA

### 前置要求

- 装好 Docker（[Mac/Win/Linux](https://docs.docker.com/get-docker/)）或 Podman
- clone 本仓库到本地

### 一行命令出 IPA

```bash
cd iOS6AIChat
./build-ipa.sh
```

第一次构建约 5-10 分钟（下载 Theos + cctools-port + iPhoneOS6.0.sdk）。后续构建秒级。

输出：
- `packages/iOS6AIChat_1.0.0-1_iphoneos-arm.deb` → 越狱设备 `dpkg -i` 装
- `iOS6AIChat-unsigned.ipa` → 任何 iOS 设备经 Sideloadly/AltStore 自签装

### 参数

```bash
./build-ipa.sh              # 默认，构建镜像并运行
./build-ipa.sh --no-build   # 跳过构建，直接用现有镜像跑
./build-ipa.sh --clean      # 删旧镜像后重建
CONTAINER_ENGINE=podman ./build-ipa.sh   # 用 podman 替代 docker
```

---

## 4. 中转服务器协议

### 默认中转：`api-ai.awa.lat`

App 默认开启中转模式，所有请求经此服务器路由到对应 AI 后端。**好处**：

- iOS 6 上规避 TLS 1.2+ 兼容问题（中转服务器代你处理 TLS 握手）
- 多 provider 统一接口（一个端点支持所有 provider）
- API Key 不直连后端，隐私友好

### 协议

App 发送标准 OpenAI 格式请求：

```
POST https://api-ai.awa.lat/v1/chat/completions
Headers:
  Content-Type:  application/json
  Authorization: Bearer <你的 provider API key>
  X-Provider:    zhipu | openai | ollama
  X-Model:       <模型名，也通过 JSON body 发送>
Body:
{
  "model": "gpt-4o-mini",
  "messages": [...],
  "stream": true,
  "temperature": 0.7
}
```

中转服务器收到后，根据 `X-Provider` 头路由到对应后端，并把流式响应原样回传。响应格式同 OpenAI SSE。

### 关闭中转（直连）

如果用自己控制的 OpenAI 兼容端点（OpenAI 官方 / 自部署 vLLM / Ollama OpenAI 接口），关掉中转开关，Base URL 填直连地址。

### 自建中转

部署你的 [`online-ai-transit-server`](https://github.com/qwq672/online-ai-transit-server) 实例，把 Settings 里的 Transit URL 改成你的实例地址。该仓库支持路由到任意 OpenAI 兼容后端。

---

## 5. 安装 IPA 到设备

### 5.1 越狱设备（推荐用 `.deb`）

```bash
scp packages/iOS6AIChat_*.deb root@iphone:/var/mobile/
ssh root@iphone "dpkg -i /var/mobile/iOS6AIChat_*.deb && killall SpringBoard"
```

或：iPhone 上用 Filza/iFile 直接打开 .deb 装包，装完桌面出现 "AI Chat" 图标。

### 5.2 非越狱设备（用 `.ipa` + 自签）

1. 下载 [Sideloadly](https://sideloadly.io/)（Win/Mac/Linux 都有）
2. 数据线连 iPhone，开 Sideloadly
3. 输入 Apple ID（生成 7 天免费开发者证书）
4. 拖入 `iOS6AIChat-unsigned.ipa`，点 Start
5. iPhone → **设置 → 通用 → 描述文件与设备管理** → 信任你的 Apple ID
6. 桌面出现 "AI Chat" 图标，点开用

> AltStore 类似，但要求 iPhone 与装 AltServer 的电脑同 Wi-Fi，每 3 天自动重签。

### 5.3 用 设置 配置后端

App 装好后启动，点左上角 ☰ 汉堡按钮打开菜单，进「设置」：

| 字段 | 默认值 | 填什么 |
|------|--------|--------|
| 使用中转 | ON | 推荐开启；关掉则直连 |
| Transit URL | `https://api-ai.awa.lat` | 你的中转服务器地址，可改自建 |
| Provider | OpenAI | 选 智谱 GLM / OpenAI / Ollama |
| API Key | （空） | 对应 provider 的 key（如 `sk-...`） |
| Model | `gpt-4o-mini` | 不同 provider 默认模型已填好 |
| Temperature | `0.7` | 0~1，越高回复越随机 |

回聊天页（菜单 →「新对话」）输入文本，回车或点 Send 发送。

---

## 6. 已知限制

- **TLS**：iOS 6 不支持 TLS 1.2+。**中转模式刚好规避此问题**——中转服务器代做 TLS 握手。直连模式只对支持旧 TLS 的端点（如自部署 HTTP vLLM）可用。
- **iOS 6 ARM**：iOS 6 设备只有 32-bit ARM（armv7/armv7s），Makefile 已限定 `ARCHS = armv7 armv7s`，不要加 arm64。
- **iOS 7+ API 守卫**：源码里 `UITextView.textContainerInset`、`tabBar.barStyle`、`estimatedRowHeight` 等都用 `respondsToSelector` / `performSelector:withObject:` 守着，所以同一个二进制在 iOS 6/7/8+ 上都能跑。
- **本机无 Docker 时**：能用 `clang-19` + `iPhoneOS6.0.sdk` 把所有 `.m` 文件编译成 armv7 `.o`，但 Debian LLVM 19 的 `ld64.lld` 跟 iPhoneOS10.3.sdk 的 `.tbd` 格式不完全兼容，没法本地链接出二进制。**必须 Docker / GitHub Actions Linux CI** 才能出真 armv7 IPA。
- **SDK 兼容**：Docker / Linux CI 默认从 `theos/sdks` 拉 iPhoneOS6.0.sdk.tar.xz；该仓库不可用时设 `IOS_SDK_URL` secret 指向自托管的 SDK 压缩包。

---

## 7. 故障排查

| 现象 | 原因 / 解决 |
|------|-------------|
| `./build-ipa.sh` 报 docker 找不到 | 装 Docker，或 `CONTAINER_ENGINE=podman ./build-ipa.sh` |
| Docker 构建报 SDK 下载失败 | `theos/sdks` 不可用；自己从 Xcode 4.5 抽出 iPhoneOS6.0.sdk 压成 tar.xz 上传到你私有 URL，改 Dockerfile 里的下载 URL |
| CI `Could not obtain iPhoneOS6.0.sdk` | 三级回退都失败。设 `IOS_SDK_URL` secret 指向自托管的 SDK 压缩包。 |
| `make` 报 `THEOS env var not set` | Docker 内 Theos 已自动设；本地裸跑需 `export THEOS=~/theos` |
| 编译报 `framework not found UIKit` | SDK 没装对。检查 `$THEOS/sdks/iPhoneOS6.0.sdk/System/Library/Frameworks/UIKit.framework` 是否存在。 |
| iOS 6 设备上跑 TLS 错误 | 必须开启中转开关 + 用默认 `api-ai.awa.lat` 中转或自建中转。直连模式在 iOS 6 上几乎不可用（CFNetwork 不支持 TLS 1.2）。 |
| iOS 7 设备上气泡 OK 但顶部 Navbar 扁平 | iOS 7 系统强制扁平，App 自绘的是气泡；如要全套拟物只能在 iOS 6 系统跑。 |

---

## 8. 中转服务器源码

[github.com/qwq672/online-ai-transit-server](https://github.com/qwq672/online-ai-transit-server) —— 默认中转服务器 `api-ai.awa.lat` 的开源实现，支持：
- 多 provider 路由（zhipu / openai / ollama / 任意 OpenAI 兼容）
- SSE 流式转发
- TLS 终止（让 iOS 6 / 旧 Android 等老设备也能接入现代 AI 服务）
- 可自托管

---

## 9. License

MIT — 随意 fork / 修改 / 商用。
