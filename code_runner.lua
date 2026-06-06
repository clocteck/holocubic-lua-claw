local M = {}

local MAX_CODE_BYTES = 18 * 1024
local MAX_OUTPUT_CHARS = 6000
local DEFAULT_TIMEOUT_MS = 1200
local MAX_TIMEOUT_MS = 8000
local PANEL_RESULT_WAIT_MS = 3200
local PANEL_HEARTBEAT_TTL_MS = 5200
local PANEL_HISTORY_LIMIT = 12

local code_looks_visual

local function now_ms()
  return M.APP.core.now_ms()
end

local function limit_text(text, limit)
  text = M.APP.core.text_or(text, "")
  limit = limit or MAX_OUTPUT_CHARS
  if #text <= limit then
    return text
  end
  return text:sub(1, limit) .. "\n...(truncated)"
end

local function traceback(err)
  if debug and debug.traceback then
    return debug.traceback(tostring(err), 2)
  end
  return tostring(err)
end

local function make_env(output)
  local env = {}
  env.APP = M.APP
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    output[#output + 1] = table.concat(parts, "\t")
  end
  env.write = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    output[#output + 1] = table.concat(parts, "")
  end
  return setmetatable(env, {
    __index = _G,
    __newindex = function(t, k, v)
      rawset(t, k, v)
    end,
  })
end

local function set_timeout_hook(deadline_ms)
  if not debug or not debug.sethook then
    return false
  end
  debug.sethook(function()
    local now = now_ms()
    if now > 0 and deadline_ms > 0 and now > deadline_ms then
      error("lua_run timeout", 2)
    end
  end, "", 20000)
  return true
end

local function clear_timeout_hook(active)
  if active and debug and debug.sethook then
    pcall(debug.sethook)
  end
end

local function panel_app_dir()
  local APP = M.APP
  local id = APP.core.trim(APP.config.panel_app_id)
  if id == "" then id = "claw_panel" end
  return "/sd/apps/" .. id
end

local function panel_inbox_dir()
  local dir = M.APP.core.trim(M.APP.config.panel_mailbox_dir)
  if dir == "" then
    dir = panel_app_dir() .. "/inbox"
  end
  return dir:gsub("/+$", "")
end

local function panel_outbox_dir()
  return panel_app_dir() .. "/outbox"
end

local function panel_status_path()
  return panel_app_dir() .. "/status.json"
end

local function panel_info_path()
  return panel_app_dir() .. "/app.info"
end

local function panel_main_path()
  return panel_app_dir() .. "/main.lua"
end

local function inbox_path(name)
  return panel_inbox_dir() .. "/" .. name
end

local function outbox_path(name)
  return panel_outbox_dir() .. "/" .. name
end

local function panel_history_path()
  return M.APP.APP_DIR .. "/panel_history.jsonl"
end

local function artifacts_path()
  return M.APP.APP_DIR .. "/panel_artifacts.jsonl"
end

local function capabilities_path()
  return M.APP.APP_DIR .. "/capabilities.json"
end

local function sanitize_seq(seq)
  seq = M.APP.core.text_or(seq, "")
  seq = seq:gsub("[^%w_%-]", "_")
  if seq == "" then
    seq = tostring(now_ms()) .. "-" .. tostring(math.random(1000, 9999))
  end
  return seq
end

local function code_checksum(code)
  code = M.APP.core.text_or(code, "")
  local h = 0
  for i = 1, #code do
    h = (h * 131 + code:byte(i)) % 1000000007
  end
  return tostring(h)
end

local function sanitize_id(text, fallback)
  text = M.APP.core.text_or(text, ""):lower()
  text = text:gsub("[^%w_%-]+", "_")
  text = text:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if text == "" then
    text = fallback or ("artifact_" .. tostring(now_ms()))
  end
  if #text > 64 then
    text = text:sub(1, 64)
  end
  return text
end

local LVGL_KNOWN = {
  lv_scr_act = true,
  lv_layer_top = true,
  lv_obj_create = true,
  lv_obj_clean = true,
  lv_obj_del = true,
  lv_obj_set_pos = true,
  lv_obj_set_size = true,
  lv_obj_set_x = true,
  lv_obj_set_y = true,
  lv_obj_set_width = true,
  lv_obj_set_height = true,
  lv_obj_align = true,
  lv_obj_center = true,
  lv_obj_align_to = true,
  lv_obj_set_style_bg_color = true,
  lv_obj_set_style_bg_opa = true,
  lv_obj_set_style_border_width = true,
  lv_obj_set_style_border_color = true,
  lv_obj_set_style_radius = true,
  lv_obj_set_style_pad_all = true,
  lv_obj_set_style_text_color = true,
  lv_obj_set_style_text_font = true,
  lv_obj_set_style_text_align = true,
  lv_obj_set_style_line_width = true,
  lv_obj_set_style_line_color = true,
  lv_obj_set_style_line_rounded = true,
  lv_obj_set_style_opa = true,
  lv_label_create = true,
  lv_label_set_text = true,
  lv_line_create = true,
  lv_line_set_points = true,
  lv_btn_create = true,
  lv_checkbox_create = true,
  lv_dropdown_create = true,
  lv_textarea_create = true,
  lv_keyboard_create = true,
  lv_canvas_create = true,
  lv_canvas_frame_begin = true,
  lv_canvas_fill_bg = true,
  lv_canvas_draw_rect = true,
  lv_canvas_draw_line = true,
  lv_canvas_draw_text = true,
  lv_canvas_draw_arc = true,
  lv_canvas_draw_img = true,
  lv_canvas_frame_end = true,
}

local function default_capabilities()
  return {
    version = 1,
    platform = "ESP32-S3 Lua/LVGL device",
    routing = {
      panel_markers = { "lv_", "LV_", "lvgl", "LVGL", "ui_scr_act", "ui_clear" },
      rule = "LVGL/UI code runs on Claw Panel; non-UI Lua runs in ESP Claw service.",
    },
    lua_modules = { "tmr", "file", "wifi", "net", "httpd", "http", "uart", "i2s", "websocket", "app", "sys" },
    serialization = {
      json = "Do not use require(\"json\") or require(\"sjson\") in lua_run code; those modules are not loadable by require in this environment. For small JSON output, build the string with string.format/table.concat.",
    },
    timer = {
      preferred = "local timer = add_timer(tmr.create()); timer:alarm(ms, tmr.ALARM_AUTO, cb)",
      constants = { "tmr.ALARM_SINGLE", "tmr.ALARM_AUTO", "tmr.ALARM_SEMI" },
      avoid = { "local variable named tmr", "timer:register unless probed" },
    },
    lvgl = {
      colors = "Use 0xRRGGBB numbers directly; lv_color_hex is not available.",
      integer_pixels = true,
      functions = LVGL_KNOWN,
    },
    canvas = {
      lifecycle = "lv_canvas_frame_begin(cvs); draw/fill; lv_canvas_frame_end(cvs)",
      draw_line = "lv_canvas_draw_line(cvs,x1,y1,x2,y2,color,opa)",
      thick_lines = "Draw several offset lines or use lv_line with style_line_width.",
    },
  }
end

local function capabilities()
  local core = M.APP.core
  local raw = core.read_text_file(capabilities_path())
  if raw and raw ~= "" then
    local doc = core.safe_json_decode(raw)
    if type(doc) == "table" then
      return doc
    end
  end
  return default_capabilities()
end

local function add_issue(out, severity, code, message)
  out[#out + 1] = {
    severity = severity,
    code = code,
    message = message,
  }
end

local function code_uses_unknown_lua_module(code, name)
  return code:find("require%s*%(%s*['\"]" .. name .. "['\"]", 1, false) ~= nil
    or code:find("require%s*['\"]" .. name .. "['\"]", 1, false) ~= nil
end

-- 运行前做轻量静态预检：把常见设备 API 误用挡在真正执行之前。
local function preflight(args)
  local APP = M.APP
  local core = APP.core
  args = type(args) == "table" and args or {}
  local code = core.text_or(args.code, "")
  local errors = {}
  local warnings = {}
  local checksum = code_checksum(code)
  local visual = code_looks_visual(code)

  if code == "" then
    add_issue(errors, "error", "code_required", "code is required")
  end
  if #code > MAX_CODE_BYTES then
    add_issue(errors, "error", "code_too_large", "code is too large")
  end

  APP.state.code_runner = type(APP.state.code_runner) == "table" and APP.state.code_runner or {}
  local failed = type(APP.state.code_runner.failed_checksums) == "table" and APP.state.code_runner.failed_checksums or {}
  if failed[checksum] then
    add_issue(errors, "error", "repeated_failed_code", "same code checksum already failed; change the code before retrying")
  end

  if code:find(":register", 1, true) or code:find("tmr%.REPEAT", 1, false) then
    add_issue(errors, "error", "timer_register_pattern", "use timer:alarm(ms, tmr.ALARM_AUTO, cb), not timer:register/tmr.REPEAT")
  end
  if code:find("file%.remove%s*%(", 1, false)
    or code:find("file%.rmdir%s*%(", 1, false)
    or code:find(":remove%s*%(", 1, false)
    or code:find(":rmdir%s*%(", 1, false) then
    add_issue(errors, "error", "delete_requires_confirmation", "deleting files or directories is not allowed through lua_run; ask for explicit confirmation and use a dedicated safe delete path")
  end

  if visual then
    for fn in code:gmatch("(lv_[%w_]+)%s*%(") do
      if not LVGL_KNOWN[fn] then
        add_issue(errors, "error", "unknown_lvgl_api", "unknown or undocumented LVGL API: " .. fn)
      end
    end
    if code:find("lv_color_hex", 1, true) then
      add_issue(errors, "error", "unknown_color_api", "lv_color_hex is unavailable; use 0xRRGGBB")
    end
    if code:find("lv_align_", 1, true) or code:find("LV_ALIGN_", 1, true) then
      add_issue(errors, "error", "unknown_lvgl_constant", "lv_align_* constants are unavailable; use lv_obj_center() or integer lv_obj_set_pos()/lv_obj_align() arguments only after probing")
    end
    if code:find("lv_obj_set_[%w_]+%([^%)]*%d+%.%d+", 1, false) then
      add_issue(errors, "error", "float_pixel_literal", "LVGL object position/size calls must use integer pixels")
    end
    if code:find("lv_canvas_draw_line", 1, true) then
      if code:find("lv_canvas_draw_line%s*%([^%)]*$", 1, false) then
        add_issue(warnings, "warning", "line_parse", "could not fully inspect lv_canvas_draw_line call")
      end
      if code:find("lv_canvas_draw_line%s*%([^%)]-,%s*[1-9]%s*,%s*0x[%x]+", 1, false) then
        add_issue(errors, "error", "draw_line_arg_order", "lv_canvas_draw_line order is cvs,x1,y1,x2,y2,color,opa; width is not the 6th argument")
      end
    end
    if code:find("lv_canvas_draw_", 1, true) and not code:find("lv_canvas_frame_begin", 1, true) then
      add_issue(warnings, "warning", "canvas_frame_begin_missing", "canvas drawing should call lv_canvas_frame_begin before draw calls")
    end
    if code:find("lv_canvas_draw_", 1, true) and not code:find("lv_canvas_frame_end", 1, true) then
      add_issue(warnings, "warning", "canvas_frame_end_missing", "canvas drawing should call lv_canvas_frame_end after draw calls")
    end
    if code:find("tmr%.create", 1, false) and not code:find("add_timer", 1, true) then
      add_issue(warnings, "warning", "timer_not_registered", "panel animation timers should be wrapped with add_timer(tmr.create())")
    end
  end
  if code_uses_unknown_lua_module(code, "os") then
    add_issue(errors, "error", "module_unavailable", "os module is not available in Panel")
  end
  if code_uses_unknown_lua_module(code, "json") or code_uses_unknown_lua_module(code, "sjson") then
    add_issue(errors, "error", "module_unavailable", "json/sjson modules are not loadable with require() in lua_run; build simple JSON strings manually or use already-probed globals only")
  end

  return {
    ok = #errors == 0,
    code_checksum = checksum,
    code_bytes = #code,
    target = visual and "panel" or "service",
    errors = errors,
    warnings = warnings,
    capabilities_version = tonumber(capabilities().version) or 1,
  }
end

local function add_code_trace(out, code, checksum)
  local core = M.APP.core
  if type(out) ~= "table" then
    return out
  end
  code = core.text_or(code, "")
  out.code_bytes = #code
  out.code_checksum = checksum or code_checksum(code)
  out.code_preview = core.utf8_prefix(code:gsub("\r\n", "\n"), 1200)
  return out
end

local function add_command_trace(out, command_file)
  if type(out) == "table" and command_file and command_file ~= "" then
    out.command_file = command_file
  end
  return out
end

-- 读取 panel 运行历史，返回按时间倒序排列的条目。
local function read_panel_history(include_code, limit)
  local APP = M.APP
  local core = APP.core
  local raw = core.read_text_file(panel_history_path())
  local out = {}
  limit = core.clamp(limit or PANEL_HISTORY_LIMIT, 1, PANEL_HISTORY_LIMIT)
  if raw and raw ~= "" then
    for line in raw:gmatch("[^\r\n]+") do
      local item = core.safe_json_decode(line)
      if type(item) == "table" and core.text_or(item.id, "") ~= "" then
        out[#out + 1] = item
      end
    end
  end
  while #out > limit do
    table.remove(out)
  end
  if not include_code then
    for i = 1, #out do
      local code = core.text_or(out[i].code, "")
      out[i].code_preview = core.utf8_prefix(code:gsub("\r\n", "\n"), 1200)
      out[i].code = nil
    end
  end
  return out
end

-- 重写历史文件，只保留最近少量记录，避免长期占用 SD 空间。
local function write_panel_history(entries)
  local APP = M.APP
  local core = APP.core
  core.ensure_app_dir()
  entries = type(entries) == "table" and entries or {}
  while #entries > PANEL_HISTORY_LIMIT do
    table.remove(entries)
  end
  local lines = {}
  for i = 1, #entries do
    local raw = core.safe_json_encode(entries[i])
    if raw then
      lines[#lines + 1] = raw
    end
  end
  return core.write_text_file(panel_history_path(), table.concat(lines, "\n"))
end

-- 保存一次 panel 运行记录，包含完整代码用于 WebUI 重跑。
local function save_panel_history(args, code, response)
  local APP = M.APP
  local core = APP.core
  if type(response) ~= "table" or core.text_or(response.target, "") ~= "panel" then
    return
  end
  local entries = read_panel_history(true, PANEL_HISTORY_LIMIT)
  local seq = core.text_or(response.seq, tostring(core.now_ms()))
  local entry = {
    id = seq,
    seq = seq,
    title = core.short_text(args.title or "Claw Panel", 80),
    ok = response.ok ~= false,
    queued = response.queued == true,
    error = core.short_text(response.error or response.warning or "", 280),
    stdout = core.utf8_prefix(core.text_or(response.stdout, ""), 2200),
    result = core.short_text(response.result or "", 800),
    code = code,
    code_bytes = #core.text_or(code, ""),
    code_checksum = core.text_or(response.code_checksum, code_checksum(code)),
    elapsed_ms = tonumber(response.elapsed_ms) or 0,
    command_file = core.text_or(response.command_file, ""),
    created_ms = core.now_ms(),
  }
  table.insert(entries, 1, entry)
  local ok, err = write_panel_history(entries)
  if not ok then
    APP.state.panel.last_error = err or "panel history save failed"
  end
end

-- 返回单条 panel 历史；include_code 为 true 时带完整代码。
local function panel_history_detail(id, include_code)
  local core = M.APP.core
  id = core.trim(id)
  local entries = read_panel_history(include_code, PANEL_HISTORY_LIMIT)
  for i = 1, #entries do
    if core.text_or(entries[i].id, "") == id or core.text_or(entries[i].seq, "") == id then
      return entries[i]
    end
  end
  return nil
end

local function read_artifacts(limit)
  local APP = M.APP
  local core = APP.core
  local raw = core.read_text_file(artifacts_path())
  local out = {}
  limit = core.clamp(limit or PANEL_HISTORY_LIMIT, 1, PANEL_HISTORY_LIMIT)
  if raw and raw ~= "" then
    for line in raw:gmatch("[^\r\n]+") do
      local item = core.safe_json_decode(line)
      if type(item) == "table" and core.text_or(item.id, "") ~= "" then
        out[#out + 1] = item
      end
    end
  end
  while #out > limit do
    table.remove(out)
  end
  return out
end

local function write_artifacts(entries)
  local APP = M.APP
  local core = APP.core
  core.ensure_app_dir()
  entries = type(entries) == "table" and entries or {}
  while #entries > PANEL_HISTORY_LIMIT do
    table.remove(entries)
  end
  local lines = {}
  for i = 1, #entries do
    local raw = core.safe_json_encode(entries[i])
    if raw then
      lines[#lines + 1] = raw
    end
  end
  return core.write_text_file(artifacts_path(), table.concat(lines, "\n"))
end

local function collect_api_names(code)
  local out = {}
  local seen = {}
  code = M.APP.core.text_or(code, "")
  for fn in code:gmatch("(lv_[%w_]+)%s*%(") do
    if not seen[fn] then
      seen[fn] = true
      out[#out + 1] = fn
    end
  end
  for fn in code:gmatch("(tmr%.%w+)") do
    if not seen[fn] then
      seen[fn] = true
      out[#out + 1] = fn
    end
  end
  table.sort(out)
  return out
end

local function infer_artifact_id(args, code, response)
  local core = M.APP.core
  local explicit = core.trim(type(args) == "table" and args.artifact_id or "")
  if explicit ~= "" then
    return sanitize_id(explicit)
  end
  local title = core.trim(type(args) == "table" and args.title or "")
  local id = sanitize_id(title, "")
  if id ~= "" then
    return id
  end
  local stdout = type(response) == "table" and core.text_or(response.stdout, "") or ""
  local first = stdout:match("([^\r\n]+)") or ""
  id = sanitize_id(first, "")
  if id ~= "" then
    return id
  end
  return "panel_" .. code_checksum(code)
end

local function save_panel_artifact(args, code, response)
  local APP = M.APP
  local core = APP.core
  if type(response) ~= "table" or core.text_or(response.target, "") ~= "panel" then
    return
  end
  local entries = read_artifacts(PANEL_HISTORY_LIMIT)
  local id = infer_artifact_id(args, code, response)
  local now = core.now_ms()
  local prev_index = nil
  for i = 1, #entries do
    if core.text_or(entries[i].id, "") == id then
      prev_index = i
      break
    end
  end
  local prev = prev_index and entries[prev_index] or {}
  local response_ok = response.ok ~= false
  local code_text = core.text_or(code, "")
  local checksum = core.text_or(response.code_checksum, code_checksum(code))
  local good_code = response_ok and code_text or core.text_or(prev.current_good_code or prev.code, "")
  local good_checksum = response_ok and checksum or core.text_or(prev.current_good_checksum or prev.code_checksum, "")
  local good_history_id = response_ok and core.text_or(response.seq, "") or core.text_or(prev.current_good_history_id or prev.history_id, "")
  local good_updated_ms = response_ok and now or tonumber(prev.current_good_updated_ms or prev.updated_ms) or now
  local good_stdout = response_ok and core.utf8_prefix(core.text_or(response.stdout, ""), 1200)
    or core.utf8_prefix(core.text_or(prev.current_good_stdout or prev.stdout, ""), 1200)
  local entry = {
    id = id,
    title = core.short_text(args.title or prev.title or "Claw Panel", 80),
    goal = core.utf8_prefix(core.text_or(args.goal or prev.goal or args.user_goal, ""), 500),
    mode = core.short_text(args.mode or prev.mode or "", 40),
    target = "panel",
    ok = good_code ~= "",
    latest_ok = response_ok,
    queued = response.queued == true,
    error = core.short_text(response_ok and "" or (response.error or response.warning or ""), 280),
    latest_error = core.short_text(response.error or response.warning or "", 280),
    stdout = good_stdout,
    latest_stdout = core.utf8_prefix(core.text_or(response.stdout, ""), 1200),
    result = response_ok and core.short_text(response.result or "", 600) or core.short_text(prev.result or "", 600),
    latest_result = core.short_text(response.result or "", 600),
    code = good_code,
    latest_code = code_text,
    code_bytes = #good_code,
    latest_code_bytes = #code_text,
    code_checksum = good_checksum,
    latest_code_checksum = checksum,
    current_good_code = good_code,
    current_good_checksum = good_checksum,
    current_good_history_id = good_history_id,
    current_good_updated_ms = good_updated_ms,
    current_good_stdout = good_stdout,
    APIs = collect_api_names(good_code),
    latest_APIs = collect_api_names(code),
    history_id = good_history_id,
    latest_history_id = core.text_or(response.seq, ""),
    command_file = core.text_or(response.command_file, ""),
    latest_command_file = core.text_or(response.command_file, ""),
    created_ms = tonumber(prev.created_ms) or now,
    updated_ms = now,
  }
  if prev_index then
    table.remove(entries, prev_index)
  end
  table.insert(entries, 1, entry)
  local ok, err = write_artifacts(entries)
  if not ok then
    APP.state.panel.last_error = err or "panel artifact save failed"
  end
end

local function artifact_matches(item, query)
  local core = M.APP.core
  query = core.trim(query):lower()
  if query == "" then
    return true
  end
  local hay = table.concat({
    core.text_or(item.id, ""),
    core.text_or(item.title, ""),
    core.text_or(item.goal, ""),
    core.text_or(item.stdout, ""),
    core.text_or(item.error, ""),
  }, "\n"):lower()
  if hay:find(query, 1, true) ~= nil then
    return true
  end
  local matched = 0
  local total = 0
  for raw_term in query:gmatch("[^%s,，;；|/]+") do
    local term = core.trim(raw_term)
    if #term >= 2 then
      total = total + 1
      if hay:find(term, 1, true) ~= nil then
        matched = matched + 1
      end
    end
  end
  return total > 0 and matched > 0
end

local function panel_artifacts(args)
  local APP = M.APP
  local core = APP.core
  args = type(args) == "table" and args or {}
  local include_code = args.include_code ~= false
  local limit = core.clamp(args.limit or PANEL_HISTORY_LIMIT, 1, PANEL_HISTORY_LIMIT)
  local query = core.text_or(args.query, "")
  local entries = read_artifacts(PANEL_HISTORY_LIMIT)
  local out = {}
  for i = 1, #entries do
    local item = entries[i]
    if artifact_matches(item, query) then
      local copy = {}
      for k, v in pairs(item) do
        copy[k] = v
      end
      local code = core.text_or(copy.code, "")
      if include_code then
        copy.code = core.utf8_prefix(code:gsub("\r\n", "\n"), i == 1 and 9000 or 5000)
        copy.code_truncated = #copy.code < #code
      else
        copy.code_preview = core.utf8_prefix(code:gsub("\r\n", "\n"), 1200)
        copy.code = nil
      end
      out[#out + 1] = copy
      if #out >= limit then
        break
      end
    end
  end
  return { ok = true, entries = out, artifacts = out }
end

local function result_path(seq)
  return outbox_path("result_" .. sanitize_seq(seq) .. ".json")
end

local function command_path(seq)
  return inbox_path("cmd_" .. sanitize_seq(seq) .. ".json")
end

local function write_atomic(path, raw)
  local APP = M.APP
  local core = APP.core
  local tmp = path .. ".tmp"
  -- 先写临时文件再 rename，避免 Panel 读到半截 JSON 命令。
  local ok_write, write_err = core.write_text_file(tmp, raw)
  if not ok_write then
    return false, write_err
  end
  if file and file.rename then
    local ok_call, ok_rename = pcall(file.rename, tmp, path)
    if ok_call and ok_rename then
      return true, nil
    end
  end
  return core.write_text_file(path, raw)
end

local function install_panel_app()
  local APP = M.APP
  local core = APP.core
  local runtime, read_err = core.read_text_file(APP.APP_DIR .. "/claw_panel.lua")
  if not runtime or runtime == "" then
    return false, "panel runtime missing: " .. core.text_or(read_err, "claw_panel.lua")
  end

  local info = table.concat({
    "name = Claw Panel",
    "entry = main.lua",
    "description = ESP Claw dynamic LVGL runtime",
    "",
  }, "\n")

  local ok_info, info_err = core.write_text_file(panel_info_path(), info)
  if not ok_info then
    return false, info_err
  end
  local ok_main, main_err = core.write_text_file(panel_main_path(), runtime)
  if not ok_main then
    return false, main_err
  end
  core.append_log("panel", "runtime installed")
  return true
end

local function ensure_panel_mailbox()
  local APP = M.APP
  local core = APP.core
  -- Panel runtime 缺失时由 service 自动安装，用户只需要运行 esp_claw 服务。
  local ok_apps, apps_err = core.ensure_dir("/sd/apps")
  if not ok_apps then
    return false, apps_err
  end
  local ok_panel, panel_err = core.ensure_dir(panel_app_dir())
  if not ok_panel then
    return false, panel_err
  end
  local stat_main = file and file.stat and file.stat(panel_main_path()) or nil
  local stat_info = file and file.stat and file.stat(panel_info_path()) or nil
  if not stat_main or not stat_info then
    local ok_install, install_err = install_panel_app()
    if not ok_install then
      return false, install_err
    end
  end
  local ok_inbox, inbox_err = core.ensure_dir(panel_inbox_dir())
  if not ok_inbox then
    return false, inbox_err
  end
  return core.ensure_dir(panel_outbox_dir())
end

function code_looks_visual(code)
  code = M.APP.core.text_or(code, "")
  -- 只用少量稳定标记判断可视化任务，避免把普通文件/HTTP Lua 误投到 Panel。
  return code:find("lv_", 1, true)
    or code:find("LV_", 1, true)
    or code:find("lvgl", 1, true)
    or code:find("LVGL", 1, true)
    or code:find("ui_scr_act", 1, true)
    or code:find("ui_clear", 1, true)
end

local function should_route_to_panel(args, code)
  local visual = code_looks_visual(code)
  return visual
end

local function read_panel_status()
  local APP = M.APP
  local core = APP.core
  local raw = core.read_text_file(panel_status_path())
  if not raw or raw == "" then
    return nil
  end
  local doc = core.safe_json_decode(raw)
  if type(doc) == "table" then
    return doc
  end
  return nil
end

local function panel_heartbeat_fresh()
  local APP = M.APP
  local status = read_panel_status()
  if type(status) ~= "table" then
    return false, nil
  end
  local updated_ms = tonumber(status.updated_ms or 0) or 0
  local now = now_ms()
  if updated_ms <= 0 or now <= 0 then
    return false, status
  end
  APP.state.panel.heartbeat_ms = updated_ms
  if status.running == false then
    return false, status
  end
  local age = now - updated_ms
  return age >= 0 and age <= PANEL_HEARTBEAT_TTL_MS, status
end

local function launch_panel_now()
  local APP = M.APP
  local core = APP.core
  if not APP.config.panel_auto_open then
    APP.state.panel.last_error = "panel auto open disabled"
    return false, APP.state.panel.last_error
  end
  if APP.state.panel.launch_pending then
    return true, nil
  end
  APP.state.panel.launch_pending = true
  APP.state.panel.last_launch_ms = now_ms()

  if app and app.rescan then
    pcall(app.rescan)
    core.sleep_ms(120)
  end
  if not app or not app.launch then
    APP.state.panel.launch_pending = false
    APP.state.panel.last_error = "app.launch missing"
    return false, APP.state.panel.last_error
  end

  local ok_call, ok_launch, launch_err = pcall(app.launch, APP.config.panel_app_id)
  APP.state.panel.launch_pending = false
  if not ok_call or not ok_launch then
    APP.state.panel.last_error = core.text_or(launch_err, "launch panel failed")
    return false, APP.state.panel.last_error
  end
  APP.state.panel.opened = (APP.state.panel.opened or 0) + 1
  APP.state.panel.last_error = ""
  return true, nil
end

local function wait_panel_result(seq, wait_ms)
  local APP = M.APP
  local core = APP.core
  local deadline = now_ms() + (tonumber(wait_ms) or PANEL_RESULT_WAIT_MS)
  local last_status = nil
  while now_ms() <= deadline do
    local raw = core.read_text_file(result_path(seq))
    if raw and raw ~= "" then
      local doc = core.safe_json_decode(raw)
      if type(doc) == "table" and doc.seq == seq then
        doc.confirmation = "result"
        return doc
      end
    end
    local status_raw = core.read_text_file(panel_status_path())
    local status = core.safe_json_decode(status_raw)
    if type(status) == "table" and core.text_or(status.current_seq, "") == seq then
      last_status = status
    end
    core.sleep_ms(120)
  end
  return nil, last_status
end

local function panel_timeout_response(seq, code, checksum, cmd_file, fresh, status)
  local APP = M.APP
  local core = APP.core
  status = type(status) == "table" and status or {}
  local phase = core.text_or(status.phase, "")
  local picked_up = core.text_or(status.current_seq, "") == seq
  local err = "panel result timeout"
  local message = fresh and "panel online but result timeout" or "panel launched but result timeout"
  if picked_up then
    message = "panel picked up command but result file was not confirmed"
  end
  APP.state.panel.last_error = err
  return add_command_trace(add_code_trace({
    ok = false,
    target = "panel",
    seq = seq,
    queued = true,
    picked_up = picked_up,
    panel_phase = phase,
    launch_pending = APP.state.panel.launch_pending or false,
    panel_app_id = APP.config.panel_app_id,
    error = err,
    message = message,
    warning = err,
  }, code, checksum), cmd_file)
end

-- 把 LVGL 可视化代码投递到前台 Claw Panel，service 自己只负责排队和打开面板。
local function run_on_panel(args, code, timeout_ms)
  local APP = M.APP
  local core = APP.core
  local ok_dir, dir_err = ensure_panel_mailbox()
  if not ok_dir then
    return false, { ok = false, target = "panel", error = dir_err }
  end

  local seq = tostring(now_ms()) .. "-" .. tostring(math.random(1000, 9999))
  local checksum = code_checksum(code)
  local payload = {
    seq = seq,
    code = code,
    code_bytes = #code,
    code_checksum = checksum,
    title = core.short_text(args.title or "Claw Panel", 80),
    timeout_ms = timeout_ms,
    created_ms = now_ms(),
  }
  local raw, enc_err = core.safe_json_encode(payload)
  if not raw then
    return false, { ok = false, target = "panel", error = enc_err or "panel request encode failed" }
  end

  local cmd_file = command_path(seq)
  local ok_write, write_err = write_atomic(cmd_file, raw)
  if not ok_write then
    return false, { ok = false, target = "panel", error = write_err }
  end

  APP.state.panel.queued = (APP.state.panel.queued or 0) + 1
  APP.state.panel.last_seq = seq
  APP.state.panel.last_error = ""

  local fresh = panel_heartbeat_fresh()
  local launched, launch_err = launch_panel_now()
  if not launched then
    APP.state.panel.last_error = launch_err
    return false, add_command_trace(add_code_trace({
      ok = false,
      target = "panel",
      seq = seq,
      queued = true,
      panel_app_id = APP.config.panel_app_id,
      heartbeat_fresh = fresh == true,
      error = launch_err,
    }, code, checksum), cmd_file)
  end

  local wait_budget = fresh and math.min(PANEL_RESULT_WAIT_MS, timeout_ms + 1800)
    or math.min(PANEL_RESULT_WAIT_MS + 1600, timeout_ms + 3600)
  local result, status = wait_panel_result(seq, wait_budget)
  if type(result) == "table" then
    result.target = "panel"
    result.panel_app_id = APP.config.panel_app_id
    result.heartbeat_fresh = fresh == true
    add_code_trace(result, code, checksum)
    add_command_trace(result, cmd_file)
    return result.ok ~= false, result
  end
  return false, panel_timeout_response(seq, code, checksum, cmd_file, fresh, status)
end

-- Service 侧执行非可视化 Lua。这里给代码一个独立 env，同时保留必要的全局设备 API。
local function run_local(args, code, timeout_ms)
  local APP = M.APP
  local core = APP.core
  local output = {}
  local env = make_env(output)
  local chunk, load_err = load(code, "=(esp_claw lua_run)", "t", env)
  if not chunk then
    return false, {
      ok = false,
      target = "service",
      error = tostring(load_err),
      phase = "load",
    }
  end

  local started = now_ms()
  local deadline = started > 0 and (started + timeout_ms) or 0
  local hook_active = set_timeout_hook(deadline)
  local ok, result = xpcall(chunk, traceback)
  clear_timeout_hook(hook_active)
  local elapsed = started > 0 and (now_ms() - started) or 0

  local stdout = limit_text(table.concat(output, "\n"), MAX_OUTPUT_CHARS)
  local response = {
    ok = ok,
    target = "service",
    stdout = stdout,
    elapsed_ms = elapsed,
    timeout_hook = hook_active,
  }
  if ok then
    response.result = result == nil and "" or core.short_text(tostring(result), 1000)
  else
    response.error = limit_text(result, 1800)
    response.phase = "runtime"
  end
  return ok, response
end

-- 执行模型生成的 Lua 片段。service 里执行逻辑代码；LVGL 代码自动转交 Claw Panel。
-- lua_run 总入口：先预检，再按代码内容自动选择 service 或 panel。
local function run(args)
  local APP = M.APP
  local core = APP.core
  args = type(args) == "table" and args or {}
  local code = core.text_or(args.code, "")
  if code == "" then
    return false, { ok = false, error = "code is required" }
  end
  if #code > MAX_CODE_BYTES then
    return false, { ok = false, error = "code too large" }
  end

  local check = preflight({ code = code })
  if not check.ok then
    -- 预检失败直接返回给模型修正，不进入真实执行阶段。
    return false, add_code_trace({
      ok = false,
      target = check.target,
      error = "preflight failed",
      phase = "preflight",
      preflight = check,
    }, code, check.code_checksum)
  end

  local timeout_ms = core.clamp(args.timeout_ms or DEFAULT_TIMEOUT_MS, 100, MAX_TIMEOUT_MS)
  local ok, response
  if should_route_to_panel(args, code) then
    ok, response = run_on_panel(args, code, timeout_ms)
  else
    ok, response = run_local(args, code, timeout_ms)
  end
  -- Panel 历史只记录可视化运行，方便 WebUI 重跑和后续“继续修改”。
  if type(response) == "table" and type(check.warnings) == "table" and #check.warnings > 0 then
    response.preflight = {
      ok = check.ok,
      warnings = check.warnings,
      code_checksum = check.code_checksum,
    }
  end
  save_panel_history(args, code, response)
  save_panel_artifact(args, code, response)

  local S = APP.state.code_runner
  S.runs = (S.runs or 0) + 1
  S.last_ok = ok
  S.last_error = ok and "" or core.short_text(response and response.error or "lua_run failed", 180)
  S.last_elapsed_ms = response and response.elapsed_ms or 0
  S.failed_checksums = type(S.failed_checksums) == "table" and S.failed_checksums or {}
  local checksum = check.code_checksum or code_checksum(code)
  local failure_text = core.text_or(response and (response.error or response.warning or response.stdout), "")
  local code_failure = not ok
    and failure_text:find("panel result timeout", 1, true) == nil
    and failure_text:find("launch panel failed", 1, true) == nil
    and failure_text:find("app.launch missing", 1, true) == nil
  -- 记录真正代码错误的 checksum，防止模型原样重复运行同一段失败代码。
  if ok then
    S.failed_checksums[checksum] = nil
  elseif code_failure then
    S.failed_checksums[checksum] = core.short_text(failure_text ~= "" and failure_text or "failed", 120)
  end
  core.append_log("code", ok and ("lua_run " .. core.text_or(response and response.target, "ok"))
    or ("lua_run " .. S.last_error))
  return ok, response
end

-- WebUI 读取 panel 历史列表。
local function panel_history(limit)
  return {
    ok = true,
    entries = read_panel_history(false, limit or PANEL_HISTORY_LIMIT),
  }
end

-- WebUI 读取 panel 历史详情。
local function panel_history_get(id)
  local item = panel_history_detail(id, true)
  if not item then
    return nil, "history item not found"
  end
  return item, nil
end

-- WebUI 按历史记录重跑 panel 代码。
local function panel_history_rerun(id)
  local APP = M.APP
  local core = APP.core
  local item, err = panel_history_get(id)
  if not item then
    return false, { ok = false, error = err or "history item not found" }
  end
  local code = core.text_or(item.code, "")
  if code == "" then
    return false, { ok = false, error = "history code missing" }
  end
  return run({
    code = code,
    title = "Rerun " .. core.short_text(item.title or item.id, 48),
    timeout_ms = DEFAULT_TIMEOUT_MS,
  })
end

-- WebUI 清空 panel 历史文件。
local function panel_history_clear()
  local ok, err = M.APP.core.write_text_file(panel_history_path(), "")
  if ok then
    M.APP.core.append_log("panel", "history cleared")
  end
  return ok, err
end

function M.init(APP)
  M.APP = APP
  APP.state.code_runner = type(APP.state.code_runner) == "table" and APP.state.code_runner or {
    runs = 0,
    last_ok = false,
    last_error = "",
    last_elapsed_ms = 0,
    failed_checksums = {},
  }
  APP.state.code_runner.failed_checksums = type(APP.state.code_runner.failed_checksums) == "table"
    and APP.state.code_runner.failed_checksums or {}
  APP.state.panel = type(APP.state.panel) == "table" and APP.state.panel or {
    opened = 0,
    queued = 0,
    last_seq = "",
    last_error = "",
    heartbeat_ms = 0,
    launch_pending = false,
    last_launch_ms = 0,
  }
  APP.code_runner = {
    run = run,
    capabilities = capabilities,
    preflight = preflight,
    panel_history = panel_history,
    panel_history_get = panel_history_get,
    panel_history_rerun = panel_history_rerun,
    panel_history_clear = panel_history_clear,
    panel_artifacts = panel_artifacts,
  }
end

return M
