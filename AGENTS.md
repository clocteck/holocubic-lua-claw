# AGENTS.md

- 本目录对应设备：`/sd/apps/esp_claw`
- 设备：`http://192.168.31.200`
- WebUI：`http://192.168.31.200/esp_claw/`
- DevTools：`http://192.168.31.200/devtools/`

## DevTools 文件

- 列目录：`GET /devtools/api/list?path=/sd/apps/esp_claw`
- 读文件：`GET /devtools/api/read?path=<path>&offset=0&size=65536`
- 上传：`PUT /devtools/api/upload?path=<path>&offset=0&total=<bytes>`
- 建目录：`POST /devtools/api/mkdir?path=<path>`
- 删除文件：`DELETE /devtools/api/remove?path=<path>`
- 删除目录：`DELETE /devtools/api/rmdir?path=<path>&recursive=1`
- 重命名：`POST /devtools/api/rename?path=<old>&new_path=<new>`

## DevRun 执行

- 运行 Lua：`POST /devtools/api/code/run`，正文为 `text/plain; charset=utf-8`
- DevRun 会写入并启动：`/sd/apps/devrun/main.lua`
- 用 `print()` 看结果；短探测先跑 DevRun，不直接改 app 源码。

## App / Service

- 刷新应用：`app.rescan()`
- 打开前台 app：`app.launch(id)`
- 启服务：`app.start_service("esp_claw")`
- 停服务：`app.stop_service("esp_claw")`
- 关闭当前前台 app：`app.exit()`，只能在该前台 app/panel 环境执行。
- 不用 `app.start`；不要在 ESP Claw service 里用 `app.exit()` 关闭别的 app。

## PowerShell 速记

```powershell
$base = "http://192.168.31.200"
Invoke-RestMethod "$base/devtools/api/list?path=/sd/apps/esp_claw"
Invoke-RestMethod "$base/devtools/api/code/run" -Method Post -ContentType "text/plain; charset=utf-8" -Body 'app.rescan(); print(app.start_service("esp_claw"))'
```
## 目标
  - 是让模型变聪明、长对话自然，核心不应该是堆硬编码和硬规则
  - 可以把很多东西交给模型判断,把模型放在信息更完整、动作边界更清楚的位置上
