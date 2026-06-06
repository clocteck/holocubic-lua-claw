# Lua ESP Claw for Clocteck Holocubic

这是一个可以运行在 Clocteck Holocubic 设备上的 `lua-esp-claw` 服务应用。它部署在设备目录 `/sd/apps/esp_claw`，通过嵌入式 Lua、HTTP WebUI、LLM function calling 和本地 Skill 文档，把 Holocubic 变成一个可以聊天、读写设备文件、运行 Lua、控制小屏、处理微信消息和做轻量记忆的设备 Agent。


- App 目录：`/sd/apps/esp_claw`

## 项目结构

```text
.
├── app.info              # Holocubic app/service 元信息，声明 main.lua 为服务入口
├── main.lua              # 启动入口：建立 APP 全局状态、加载模块、启动 Web 和微信轮询
├── config.lua            # 默认配置、颜色、运行状态和共享 state 初始化
├── core.lua              # 通用工具：JSON、文件、HTTP 响应、日志、历史裁剪、状态快照等
├── agent.lua             # Agent 主循环：任务路由、Prompt 组装、LLM 请求、工具调用和最终回复
├── tools.lua             # LLM 可调用工具定义与执行分发
├── skills.lua            # 读取 skills/*/SKILL.md，按会话激活并注入 Skill 文档
├── code_runner.lua       # lua_run：Service/Panel 自动路由、预检、运行历史和可视化 artifact
├── memory.lua            # 长期记忆和会话摘要，保存到 /sd/apps/esp_claw/memory
├── vision.lua            # 本地图片分析，把图片转成 data URL 调用视觉模型
├── wechat.lua            # 微信 iLink 机器人登录、轮询、收发消息
├── wechat_crypto.lua     # 微信媒体加密和基础 crypto/base64 能力
├── wechat_media.lua      # 微信媒体保存、下载、上传辅助
├── web.lua               # HTTP 路由、WebUI API、异步聊天 job
├── web.html              # 浏览器端 WebUI
├── ui.lua                # 设备小屏 LVGL 状态界面
├── diagnostics.lua       # 自检：LLM、HTTP、SD、微信、Panel、memory 等健康状态
├── claw_panel.lua        # Claw Panel 前台运行时代码，用于执行 LVGL/Canvas 可视化程序
├── capabilities.json     # 设备 Lua/LVGL 能力表，供 code_runner 预检和模型参考
└── skills/               # Skill 文档目录，Agent 按需激活
```

`tests/` 是本地回归脚本目录，理解和部署主应用时可以忽略。

## 支持的 Skill

Skill 是用户可见能力，实际由 `skills.lua` 读取 `skills/<id>/SKILL.md`，再由 Agent 按会话激活。当前项目内置：

- `app_inspect`：查看 `/sd/apps` 下 Lua app 的入口、目录和实现流程。
- `code_runner`：编写、预检并运行设备 Lua；非 UI 代码跑 ESP Claw service，LVGL/Canvas 代码投递到 Claw Panel。
- `device_control`：读取设备状态、设置小屏文字、设置亮度。
- `image_inspect`：分析 `/sd/` 下 jpg/png/gif/webp 本地图片。
- `memory_ops`：保存、召回、列出和遗忘长期记忆。
- `self_check`：检查 LLM、HTTP、SD、微信、Claw Panel、memory 等健康状态。
- `web_search`：设备侧实时信息查询 fallback，优先使用 `web_probe`、`web_fetch`、`lookup_context`。
- `wechat_image`：向微信发送设备本地图片。

## Agent 实现技术

- **嵌入式 Lua 服务架构**：`main.lua` 建立 `ESP_CLAW_APP`，按顺序加载模块，并统一管理 timer、动态路由和 stop 生命周期。
- **OpenAI 兼容 LLM 调用**：`agent.lua`/`vision.lua` 支持 `/responses` 和 `/chat/completions` 两种 endpoint，也兼容 DeepSeek chat endpoint。
- **Function Calling 工具循环**：`tools.lua` 生成 Responses API 和 Chat Completions 两套工具 schema，`agent.lua` 在多轮里执行工具、回填结果、做最终摘要。
- **Skill 文档注入**：`skills.lua` 从 `SKILL.md` 读取 frontmatter 和正文，把 Skill catalog、已激活 Skill 文档、Skill-Tool 映射放进模型上下文，让模型在更完整的边界内判断。
- **任务路由与安全策略**：Agent 会先把请求分类为普通对话、源码检查、实时查询、新代码、续改、调试等模式，再决定是否需要执行工具；删除目录、宽路径删除、未确认接口等危险动作会被拦截。
- **Service/Panel 双运行时**：`code_runner.lua` 用代码特征识别 LVGL/Canvas 任务。普通 Lua 在 ESP Claw service 内隔离环境执行；可视化代码通过 mailbox 投递给 Claw Panel 前台运行。
- **能力表和预检**：`capabilities.json` 描述可用 Lua 模块、LVGL 函数、timer 写法和 Canvas 约束；`preflight_lua` 会拦截未知 LVGL API、错误 timer 写法、删除操作和不可用 `require()`。
- **轻量长期记忆**：`memory.lua` 使用 JSONL、索引 JSON 和 Markdown 视图保存稳定事实，并按关键词召回相关内容。
- **WebUI 与设备 API**：`web.lua` 注册 `/esp_claw/api` 路由，支持配置、聊天 job、状态、记忆、微信 QR、Prompt 预览等浏览器操作。
- **微信与图片能力**：`wechat.lua` 通过 iLink bot token/QR 登录轮询消息；图片保存到本地后可由 `vision.lua` 分析，或由 `wechat_image` 发送。

## 运行方式

设备端 `app.info` 已声明
保存到设备 `/sd/apps/esp_claw` 后，开机会自启动


## 设计目标

这个项目的核心不是把所有行为写成硬编码规则，而是把模型放在信息更完整、动作边界更清楚的位置上：Skill 负责给流程说明，工具负责执行有限动作，预检和安全策略负责兜底。这样长对话、续改、设备检查和真实执行会更自然，也更容易维护。
