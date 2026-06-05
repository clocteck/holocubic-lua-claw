---
{
  "name": "app_inspect",
  "description": "查看设备中 /sd/apps 下某个 Lua app 的文件、入口和实现流程，并用简短中文总结。",
  "metadata": {
    "cap_groups": ["code_runner"],
    "manage_mode": "readonly"
  }
}
---

# 查看 App

用户询问设备里的某个 app、实现流程、源码结构、页面逻辑、运行入口，或明确允许读取 `/sd/apps` 下源码时使用。

## 理解方式

- “2048 app”“天气 app”“某某应用”通常指 `/sd/apps/<app_id>`。
- 用户问“你自己的实现/这个 agent 怎么实现/看下 app 目录/看下 Lua 文件”时，优先检查 `/sd/apps/esp_claw`。
- 用户明确要求查看所有 app 时，可以列出并摘要 `/sd/apps` 下所有 app 的源码结构；先总览，再按用户追问读取具体 app。
- 如果名称可能有大小写、空格或中文差异，先列出 `/sd/apps` 找最接近的目录。
- 目标是解释真实设备文件，不是讲通用实现原理。

## 做法

激活本 skill 后，直接运行 Lua 读取设备文件；不要只回复“已激活”，也不需要再激活其它 skill。

1. 先查看 `/sd/apps` 或目标 app 目录文件列表。
2. 优先读取 `app.info`、`app.json`、`main.lua`、入口 Lua 文件、`SKILL.md` 和少量相关模块。
3. 可以读取 `/sd/apps` 下 app 源码；跳过图片、字体、音频、二进制资源和过大的文件。
4. 不读取密钥原文。遇到 `config.json`、token、api key、secret、credential 等敏感文件或字段时，只报告“已配置/未配置/已脱敏”，不要打印值。
5. 不读取巨大 `.jsonl` 全文。只报告文件大小、条数估计、最近少量安全摘要；不要把历史记录整段刷屏。
6. 文件较多时分批读取，先总结主流程，再按需要补充细节。

## 输出层级

默认采用“先总览，后点名展开”的策略，避免单条回复过长：

1. **Top-level 摘要**：只列 app 入口、主要文件/目录、每个 Lua 模块一句职责，最多 12-16 项。
2. **关键链路**：只概括启动流程、Web/API、工具执行、Panel/Service 路由等 3-6 条主线。
3. **展开条件**：只有用户点名某个模块、函数、流程或明确要求“继续/展开下一段”时，才读取并解释该模块细节。
4. **多 app 场景**：先列 `/sd/apps` app 清单和每个 app 的入口/一句职责，不要逐个读完整源码。
5. **多段回复**：如果用户要求全量分析，按“第 1 段：目录和入口”“第 2 段：核心 agent”“第 3 段：工具和运行器”“第 4 段：WebUI/Panel”等分段；每次只输出一段，并在末尾说明下一段主题。

不要在 top-level 摘要里粘贴大段代码、完整目录树、长 JSON、日志全文或 jsonl 原文。

## Lua 提醒

- `file.listdir(path)` 的条目可能是字符串，也可能是 `{ name=..., is_dir=..., size=... }`。
- 取文件名时先归一化：`local name = type(e) == "table" and e.name or tostring(e)`。
- 路径用绝对路径拼接，如 `/sd/apps/2048/main.lua`。
- 读取文件前可用 `file.stat(path)` 判断大小；只打印关键片段。
- 读取文本优先用 `file.getcontents(path)`；不用 `io.open`，也不要用 `fd:read("*a")`。
- 读取 `config.json` 时必须脱敏：`api_key`、`token`、`secret`、`password` 等字段只显示 `***` 或布尔状态。
- `.jsonl` 超过几 KB 时不要全文读取；可用 `file.stat` 汇报大小，必要时读取末尾/前几行摘要。

## 回复

- 用中文简洁说明。
- 先说入口和文件结构，只做 top-level 摘要。
- 再说页面创建、状态流转、事件处理、数据刷新和资源释放等主线；细节等用户点名再展开。
- 如果没找到目录或入口文件，说明实际探测结果。
- 结尾给出 2-4 个可点名展开的模块或主题，例如 `agent.lua`、`code_runner.lua`、WebUI API、Panel runtime。
