---
{
  "name": "code_runner",
  "description": "编写并运行设备 Lua 代码，检查模块、文件、网络、UI、运行状态，并打开或关闭 Lua app/service。",
  "metadata": {
    "cap_groups": ["code_runner"],
    "manage_mode": "execute"
  }
}
---

# 代码执行

用户要求写代码、运行代码、调试脚本、检查设备模块或读写文件时使用。

## 核心规则

1. 必须用 `lua_run` 执行实际代码；用户要求“实现、运行、修复、测试、继续”时，不要只给方案。
2. 只使用本文明确列出的接口，或刚用探针确认存在的接口。没确认的接口不要猜、不要编。
3. 不带 UI/LVGL 的代码必须跑 service。读取文件、列目录、查模块、HTTP 探测、解释源码、状态检查都跑 service。
4. 只有用户要在屏幕上创建/修改可见界面、动画、控件、Canvas、LVGL 画面时才走 Claw Panel。
5. 带 `lv_`、`LV_`、`ui_scr_act`、`ui_clear`、`lvgl/LVGL` 的代码跑 Claw Panel；没有这些 UI 标记时不要为了“探测”而走 Panel。
6. Claw Panel 缺入口时由 ESP Claw 自动安装运行时；Panel 不在前台时可以排队并启动。Panel 被用户退出到 launcher 是正常状态，不要把它当作代码错误。
7. UI 代码必须在 panel 运行；不要在 service 里调用或探测 LVGL。
6. 出错后先按错误修代码并再跑一次；不要把失败、timeout、queued 当成功。
7. 回答用户时只说实际执行结果，不提内部 capability。
8. 先看 Agent task plan：`new_code` 优先按最新需求新实现，不要因为有历史就沿用旧作品；`modify_previous/debug_previous` 才查相关历史。
9. 续改时优先用 `get_panel_artifacts(query=用户主题)` 找匹配作品；找不到再用 `get_panel_history`。只沿用匹配代码，不要随机拿最近一条。
10. Claw Panel 屏幕是 **320x240 像素**。所有 UI、Canvas、游戏棋盘、动画路径都必须适配这个可视范围；写代码前先计算宽高，确保 `x >= 0`、`y >= 0`、`x + w <= 320`、`y + h <= 240`。
11. LVGL 对象要可见时，设置背景颜色后必须显式设置不透明度：`lv_obj_set_style_bg_opa(obj, 255, 0)`。圆点、小球、背景矩形、面板都不要只设 `bg_color`。
12. Panel Lua 性能有限。游戏/棋盘/动画要预创建少量 LVGL 对象并在 tick 中原地更新颜色、位置或文本；不要每帧大量 `lv_obj_create/lv_obj_del`，不要在每个 tick 做全局大搜索，棋盘 AI 搜索应只在新方块/落点变化时计算。

## 禁止猜接口,文档里没有的接口不要用



## Timer 固定写法

动画 timer 优先只用这一种：

```lua
local timer = add_timer(tmr.create())
timer:alarm(50, tmr.ALARM_AUTO, draw)
```

不要把局部变量命名为 `tmr`，会遮蔽全局模块。普通动画不超过 30fps，复杂动画用 50ms 或更慢。

## Panel 屏幕尺寸

Claw Panel 的可视区域固定为 `320x240`。不要创建超过屏幕的主画布、棋盘或背景；如果需要全屏 Canvas，用 `lv_canvas_create(root, 320, 240, ...)`，然后把所有绘制坐标限制在 `0..319`、`0..239`。

游戏/网格类 UI 必须先按屏幕反推 cell size 和偏移。例如 10x20 俄罗斯方块棋盘不能用 `BS=18`，因为高度 `20*18=360` 会超出 240；应改成 `BS<=11`，或减少行数/留出侧边信息区。绘制边框不要用一个填充大矩形盖住棋盘，使用四条线或四个细矩形。

## lua_run 参数

- `code`：要执行的 Lua 代码，尽量短。
- `timeout_ms`：100 到 8000。
- `title`：panel 顶部短标题。
- `target`：兼容字段；实际按代码内容自动路由。
- `artifact_id/goal/mode`：Panel 可视化建议填写，方便后续续改和回放。

## 历史上下文

`get_panel_artifacts` 读取按作品保存的 Panel 代码，适合续改。`get_panel_history` 读取原始运行记录，适合排查最近工具链。全新任务忽略历史。

`get_code_capabilities` 读取机器可读接口表；不确定接口签名时先读它。`preflight_lua` 可在运行前检查代码；`lua_run` 也会自动做 preflight，失败时按错误修正后再跑。

## Panel 最小示例

```lua
local root = lv_scr_act()
lv_obj_clean(root)

local line = lv_line_create(root)
lv_obj_set_style_line_width(line, 4, 0)
lv_obj_set_style_line_rounded(line, true, 0)
lv_obj_set_style_line_color(line, 0x4DA3FF, 0)
local line_pts = {40, 120, 280, 120}
lv_line_set_points(line, line_pts, 2)

local frame = 0
local function draw()
  frame = frame + 1
  local y = math.floor(120 + math.sin(frame * 0.08) * 40 + 0.5)
  line_pts[2] = y
  line_pts[4] = 240 - y
  lv_line_set_points(line, line_pts, 2)
end

draw()
local timer = add_timer(tmr.create())
timer:alarm(50, tmr.ALARM_AUTO, draw)
print("panel ok")
```

## 可用接口速记

Lua 全局模块：`tmr`、`file`、`wifi`、`net`、`httpd`、`http`、`uart`、`i2s`、`websocket`、`json`、`sjson`、`app`、`sys`。

文件：`file.open/getcontents/putcontents/listdir/list/stat/exists/mkdir/rmdir/remove/rename/fsinfo`。

HTTP：`http.get(url[, options][, callback])`、`http.post(url, options, body[, callback])`。`options` 可含 `headers/timeout/bufsz/max_redirects/cert`。

App：`app.list()`、`app.current()`、`app.launch(id)`、`app.exit()`、`app.rescan()`、`app.start_service(id)`、`app.stop_service(id_or_instance)`、`app.exiting()`。

Timer：`tmr.create()`、`timer:alarm(ms, tmr.ALARM_SINGLE|tmr.ALARM_AUTO|tmr.ALARM_SEMI, cb)`、`timer:start/stop/unregister`、`tmr.now()`、`tmr.time()`。

LVGL 基础：`lv_scr_act()`、`lv_layer_top()`、`lv_obj_create(parent)`、`lv_obj_clean`、`lv_obj_del`、`lv_obj_set_pos/size/x/y/width/height`、`lv_obj_align/center/align_to`。

LVGL 样式：`lv_obj_set_style_bg_color/bg_opa/border_width/border_color/radius/pad_all/text_color/text_font/text_align/line_width/line_color/line_rounded/opa`。颜色直接用 `0xRRGGBB`。

可见对象固定写法：

```lua
lv_obj_set_style_bg_color(obj, 0x4DA3FF, 0)
lv_obj_set_style_bg_opa(obj, 255, 0)
```

`lv_obj_create` 的背景可能默认透明；小球、圆点、背景块、卡片必须设置 `bg_opa`。线条用 `lv_obj_set_style_opa` 或线条样式，Canvas 绘制函数的最后一个参数通常就是 `opa`，例如 `lv_canvas_draw_rect(cvs,x,y,w,h,color,255)`。

LVGL 控件：`lv_label_create`、`lv_label_set_text`、`lv_line_create`、`lv_line_set_points`、`lv_btn_create`、`lv_checkbox_create`、`lv_dropdown_create`、`lv_textarea_create`、`lv_keyboard_create`。

`lv_line_set_points` 会保留点数组引用；点数组必须是和 line 同生命周期的持久 table。不要写 `lv_line_set_points(line, {x1,y1,x2,y2}, 2)`，动画里要复用并修改 `line_pts`。

Canvas：`lv_canvas_create(root, w, h[, fmt])` 后必须先画一帧：`lv_canvas_frame_begin(cvs)`、`lv_canvas_fill_bg(cvs,color,255)`、`lv_canvas_draw_rect/line/text/arc/img`、`lv_canvas_frame_end(cvs)`。主 canvas 推荐不超过 `320x240`；所有坐标、对象尺寸、棋盘宽高都要在屏幕内。画线用已确认顺序：`lv_canvas_draw_line(cvs,x1,y1,x2,y2,color,opa)`，坐标是整数；需要粗线时画多条偏移线或用 `lv_line` 控件。

坐标和尺寸传整数；动画里先算浮点，再 `math.floor(v + 0.5)`。
