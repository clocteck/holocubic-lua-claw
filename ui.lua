local M = {}

-- 设置屏幕 note 文本，并同步到状态。
local function set_screen_text(text)
  local APP = M.APP
  local core = APP.core
  local S = APP.state
  local UI = APP.ui

  S.screen_note = core.short_text(text, 120)
  if UI.note then
    core.call(lv_label_set_text, UI.note, S.screen_note)
  end
end

-- 根据状态刷新所有 LVGL 标签。
local function redraw()
  local APP = M.APP
  local core = APP.core
  local C = APP.colors
  local LV = APP.lv
  local S = APP.state
  local UI = APP.ui

  if UI.status then
    local state = S.busy and "BUSY" or (S.last_error ~= "" and "WARN" or "READY")
    core.call(lv_label_set_text, UI.status, state)
    local color = S.busy and C.amber or (S.last_error ~= "" and C.red or C.green)
    core.call(lv_obj_set_style_text_color, UI.status, color, LV.MAIN_STYLE)
  end
  if UI.route then
    core.call(lv_label_set_text, UI.route, APP.ROUTE_BASE)
  end
  if UI.last_user then
    core.call(lv_label_set_text, UI.last_user, core.short_text(S.last_user ~= "" and S.last_user or "No messages", 44))
  end
  if UI.last_reply then
    core.call(lv_label_set_text, UI.last_reply, core.short_text(S.last_reply, 92))
  end
  if UI.wechat then
    local text = "WeChat " .. (APP.config.wechat_enabled and "on" or "off")
    if APP.config.wechat_enabled and APP.config.wechat_token == "" then
      text = "WeChat no token"
    end
    core.call(lv_label_set_text, UI.wechat, text)
  end
  if UI.note then
    core.call(lv_label_set_text, UI.note, core.short_text(S.screen_note, 56))
  end
end

-- 创建一个固定尺寸 label，避免小屏文本重叠。
local function label(root, x, y, w, h, text, font, color, align, long_mode)
  local APP = M.APP
  local core = APP.core
  local LV = APP.lv

  local id = lv_label_create(root)
  core.call(lv_obj_set_pos, id, x, y)
  core.call(lv_obj_set_width, id, w)
  if h and lv_obj_set_height then
    core.call(lv_obj_set_height, id, h)
  end
  core.call(lv_label_set_text, id, text)
  core.call(lv_obj_set_style_text_font, id, font or LV.FONT_12, LV.MAIN_STYLE)
  core.call(lv_obj_set_style_text_color, id, color or APP.colors.text, LV.MAIN_STYLE)
  core.call(lv_obj_set_style_text_letter_space, id, 0, LV.MAIN_STYLE)
  core.call(lv_obj_set_style_text_line_space, id, 2, LV.MAIN_STYLE)
  if align and lv_obj_set_style_text_align then
    core.call(lv_obj_set_style_text_align, id, align, LV.MAIN_STYLE)
  end
  if lv_label_set_long_mode then
    core.call(lv_label_set_long_mode, id, long_mode or LV.LABEL_LONG_CLIP)
  end
  return id
end

-- 构建 320x240 状态页，只保留设备运行关键状态。
local function build()
  local APP = M.APP
  local core = APP.core
  local C = APP.colors
  local LV = APP.lv
  local UI = APP.ui

  if ui_clear then
    pcall(ui_clear)
  elseif lv_clear then
    pcall(lv_clear)
  end

  local root = (ui_scr_act and ui_scr_act()) or (lv_scr_act and lv_scr_act())
  if not root then
    return
  end

  core.call(lv_obj_set_style_bg_color, root, C.bg, LV.MAIN_STYLE)
  core.call(lv_obj_set_style_bg_opa, root, 255, LV.MAIN_STYLE)
  if lv_obj_clear_flag and rawget(_G, "LV_OBJ_FLAG_SCROLLABLE") then
    core.call(lv_obj_clear_flag, root, rawget(_G, "LV_OBJ_FLAG_SCROLLABLE"))
  end

  UI.title = label(root, 12, 10, 150, 24, "ESP Claw", LV.FONT_20, C.text, LV.ALIGN_LEFT)
  UI.status = label(root, 220, 13, 88, 22, "READY", LV.FONT_16, C.green, LV.ALIGN_CENTER)
  UI.route = label(root, 12, 38, 296, 18, APP.ROUTE_BASE, LV.FONT_12, C.sub, LV.ALIGN_LEFT)
  UI.wechat = label(root, 12, 62, 296, 18, "WeChat off", LV.FONT_12, C.dim, LV.ALIGN_LEFT)
  UI.last_user = label(root, 12, 96, 296, 34, "No messages", LV.FONT_12, C.blue, LV.ALIGN_LEFT, LV.LABEL_LONG_WRAP)
  UI.last_reply = label(root, 12, 136, 296, 58, "Open WebUI", LV.FONT_12, C.text, LV.ALIGN_LEFT, LV.LABEL_LONG_WRAP)
  UI.note = label(root, 12, 210, 296, 18, "", LV.FONT_10, C.amber, LV.ALIGN_LEFT)
  redraw()
end

-- 初始化 UI 模块并导出屏幕操作。
function M.init(APP)
  M.APP = APP
  APP.ui_api = {
    build = build,
    redraw = redraw,
    set_screen_text = set_screen_text,
  }
end

-- 释放 UI 引用，实际屏幕切换由 appmanager 或下一次 build 处理。
function M.stop(APP)
  APP.ui = {}
end

return M
