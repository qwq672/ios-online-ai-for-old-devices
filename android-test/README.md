# AIAnyWhere Android — v0.2 测试版

## 目标

Android 2.3+ (API 9) 老设备 AI 聊天客户端。纯 Android SDK，无外部依赖。

## 构建

1. 用 Android Studio 打开此目录
2. Gradle 会自动同步（需要网络下载 AGP 4.0.2）
3. Build → Build APK

也可以命令行：
```
./gradlew assembleDebug
```

## 版本历史

### v0.2.0 (current)
- **修复了 4 个无法正常聊天的致命 bug**：
  - 点"停止"会显示 IOException 错误（现在静默取消）
  - 非 SSE JSON 响应没处理（国产中转 API 常见，现在兼容）
  - ChatAdapter 没有 ViewHolder，长对话 OOM 闪退（现在用 ViewHolder 回收）
  - 深色模式下 inputField 不可见（现在用 ThemeManager 手动切换）
- **`values-night` 在 Android 2.3-5.x 不生效** —— 现在用 ThemeManager 手动切换主题（跟随系统/浅色/深色）
- 设置新增：
  - 主题模式（跟随系统 / 浅色 / 深色）
  - 温度调节（0.0 - 2.0）
  - max_tokens（0 = 不限制）
  - 流式开关（关闭时走非 SSE JSON）
  - 重置所有设置
- 顶栏新增「清空」按钮（带确认对话框）
- thinking 文字现在显示在 AI 气泡顶部（之前被忽略）
- 错误消息用红色气泡区分
- Markdown 渲染缓存（流式时不重复解析）
- 自适应配色：浅色 / 深色 / 错误 / 思考 四套气泡颜色
- 切换主题不丢对话（onSaveInstanceState）
- 应用名 AIChat → AIAnyWhere

### v0.1.0
- 聊天界面（ListView + 输入框 + 发送按钮）
- SSE 流式输出（HttpURLConnection + 手动解析）
- 基础 Markdown 渲染（粗体/斜体/代码块/链接/标题/列表/引用块）
- 设置页（API Key / Base URL / Model / System Prompt）

## 未实现（后续）
- [ ] 思考模式开关（thinking.type / reasoning_effort 显式声明）
- [ ] 工具调用（tool_calls / function calling）
- [ ] 自主搜索 / URL 读取
- [ ] 分段推理 toggle
- [ ] 图片生成
- [ ] 图片识别（vision）
- [ ] 角色管理
- [ ] 多 AI 群聊
- [ ] 建议按钮 / 欢迎词
- [ ] 后台通知
- [ ] 对话历史持久化
- [ ] 多 provider 切换

## 架构

```
app/src/main/java/com/awa/aichat/
├── ui/
│   ├── ChatActivity.java     — 主聊天界面
│   └── SettingsActivity.java — 设置页（v0.2 大改）
├── network/
│   └── NetworkService.java   — SSE 流式 HTTP 客户端（v0.2 兼容非 SSE）
├── model/
│   └── Message.java          — 消息模型（v0.2 加 thinking/error 字段）
├── adapter/
│   └── ChatAdapter.java      — ListView 消息适配器（v0.2 ViewHolder + 主题感知）
├── markdown/
│   └── MarkdownParser.java   — Markdown → Spannable（v0.2 主题感知 + 缓存）
└── util/
    └── ThemeManager.java     — 手动深色模式切换（v0.2 新增）
```

## 兼容性

- minSdkVersion 9 (Android 2.3 Gingerbread)
- targetSdkVersion 22 (Android 5.1 — 避免运行时权限模型)
- compileSdkVersion 28 (Android 9)
- Java 7 语法（无 lambda、无 try-with-resources、无 diamond operator）
- AGP 4.0.2 + Gradle 6.1.1（兼容 JDK 8+）
- 无 AndroidX，无外部依赖

## 验收测试清单

发图（v0.2 暂不支持 vision，文本聊天先确保稳定）：

1. 首次启动 → 自动打开设置页 → 输入 API Key/Base URL/Model → 保存 → 回到聊天
2. 发送"你好" → 应该流式收到 AI 回复（带 Markdown 渲染）
3. 流式中点"停止" → 不应显示错误消息，AI 气泡停留在已生成内容
4. 设置页切换主题到"深色" → 保存 → 回到聊天 → 全部 UI 应该变深色，且对话内容保留
5. 设置页温度调到 0.0 → 发"写一首诗" → 应该非常确定/单调
6. 设置页关闭"流式输出" → 发消息 → 应该一次性返回完整回复（非 SSE）
7. 点顶栏"清空" → 确认 → 对话清空
8. 设置页"重置设置" → 确认 → 所有字段恢复默认，API Key 清空
