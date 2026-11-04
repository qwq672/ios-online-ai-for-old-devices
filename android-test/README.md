# AIAnyWhere Android — 测试版

## 目标

Android 2.3+ (API 9) 老设备 AI 聊天客户端。纯 Android SDK，无外部依赖。

## 构建

1. 用 Android Studio 打开此目录
2. Gradle 会自动同步（需要网络下载 AGP 4.0.2）
3. Build → Build APK

## 当前状态（v0.1 测试版）

### 已实现
- [x] 聊天界面（ListView + 输入框 + 发送按钮）
- [x] SSE 流式输出（HttpURLConnection + 手动解析）
- [x] 基础 Markdown 渲染（粗体/斜体/代码块/链接/标题/列表/引用块）
- [x] 设置页（API Key / Base URL / Model / System Prompt）
- [x] 深色模式支持（values-night）

### 未实现（后续）
- [ ] 思考模式（thinking / reasoning_content）
- [ ] 工具调用（tool_calls / function calling）
- [ ] 自主搜索 / URL 读取
- [ ] 分段推理 toggle
- [ ] 图片生成
- [ ] 图片识别（vision）
- [ ] 角色管理
- [ ] 多 AI 群聊
- [ ] 建议按钮 / 欢迎词
- [ ] 后台通知

## 架构

```
app/src/main/java/com/awa/aichat/
├── ui/
│   ├── ChatActivity.java     — 主聊天界面
│   └── SettingsActivity.java — 设置页
├── network/
│   └── NetworkService.java   — SSE 流式 HTTP 客户端
├── model/
│   └── Message.java          — 消息模型
├── adapter/
│   └── ChatAdapter.java      — ListView 消息适配器
└── markdown/
    └── MarkdownParser.java   — 基础 Markdown → Spannable 渲染
```

## 兼容性

- minSdkVersion 9 (Android 2.3 Gingerbread)
- targetSdkVersion 22 (Android 5.1 — 避免运行时权限模型)
- Java 7 语法（无 lambda）
- 无 AndroidX，无外部依赖
