local prev = rawget(_G, "CLAW_PANEL_APP")
if prev and prev.stop then
  pcall(function()
    prev.stop("reload")
  end)
end

local PANEL = {
  APP_ID = "claw_panel",
  APP_DIR = "/sd/apps/claw_panel",
  INBOX_DIR = "/sd/apps/claw_panel/inbox",
  OUTBOX_DIR = "/sd/apps/claw_panel/outbox",
  STATUS_PATH = "/sd/apps/claw_panel/status.json",
  timers = {},
  dynamic_timers = {},
  active_stage = nil,
  current_seq = "",
  last_phase = "ready",
  last_error = "",
  last_stdout = "",
  exec_visual_ops = 0,
  running = true,
}

CLAW_PANEL_APP = PANEL

local show_error_screen
local show_text_screen
local write_status
local traceback

local function now_ms()
  if millis then
    local ok, value = pcall(millis)
    if ok and tonumber(value) then
      return tonumber(value)
    end
  end
  if tmr and tmr.now then
    local ok, value = pcall(tmr.now)
    if ok and tonumber(value) then
      return math.floor(tonumber(value) / 1000)
    end
  end
  if tmr and tmr.time then
    local ok, value = pcall(tmr.time)
    if ok and tonumber(value) then
      return tonumber(value) * 1000
    end
  end
  return 0
end

local function json_encode(value)
  if json and json.encode then
    local ok, out = pcall(json.encode, value)
    if ok and type(out) == "string" then
      return out
    end
  end
  if sjson and sjson.encode then
    local ok, out = pcall(sjson.encode, value)
    if ok and type(out) == "string" then
      return out
    end
  end
  return nil
end

local function json_decode(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  if json and json.decode then
    local ok, out = pcall(json.decode, text)
    if ok and type(out) == "table" then
      return out
    end
  end
  if sjson and sjson.decode then
    local ok, out = pcall(sjson.decode, text)
    if ok and type(out) == "table" then
      return out
    end
  end
  return nil
end

local function read_text(path)
  if file and file.getcontents then
    local ok, data = pcall(file.getcontents, path)
    if ok then
      return data
    end
  end
  if not file or not file.open then
    return nil
  end
  local fd = file.open(path, "r")
  if not fd then
    return nil
  end
  local chunks = {}
  while true do
    local chunk = fd:read(1024)
    if not chunk or chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
  end
  fd:close()
  return table.concat(chunks)
end

local function write_text(path, text)
  text = tostring(text or "")
  if file and file.putcontents then
    local ok, result = pcall(file.putcontents, path, text)
    if ok and result ~= nil then
      return true
    end
  end
  if not file or not file.open then
    return nil, "file api missing"
  end
  local fd = file.open(path, "w+")
  if not fd then
    return nil, "open failed"
  end
  local ok, err = pcall(function()
    fd:write(text)
    fd:close()
  end)
  if not ok then
    pcall(function() fd:close() end)
    return nil, tostring(err)
  end
  return true
end

local function write_atomic(path, text)
  local tmp = path .. ".tmp"
  local ok, err = write_text(tmp, text)
  if not ok then
    return nil, err
  end
  if file and file.rename then
    if file.remove then
      pcall(file.remove, path)
    end
    local ok_call, ok_rename = pcall(file.rename, tmp, path)
    if ok_call and ok_rename then
      return true
    end
  end
  local ok_final, final_err = write_text(path, text)
  if file and file.remove then
    pcall(file.remove, tmp)
  end
  return ok_final, final_err
end

local function remove_file(path)
  if file and file.remove then
    pcall(file.remove, path)
  end
end

local function ensure_dir(path)
  if file and file.mkdir then
    pcall(file.mkdir, path)
  end
end

local function to_int(value)
  local n = tonumber(value) or 0
  if n >= 0 then
    return math.floor(n + 0.5)
  end
  return math.ceil(n - 0.5)
end

local function sanitize_numeric_table(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return value
  end
  seen[value] = true
  for k, v in pairs(value) do
    if type(v) == "number" then
      value[k] = to_int(v)
    elseif type(v) == "table" then
      sanitize_numeric_table(v, seen)
    end
  end
  return value
end

local function add_timer(timer, dynamic)
  if timer then
    local list = dynamic and PANEL.dynamic_timers or PANEL.timers
    list[#list + 1] = timer
  end
  return timer
end

local function add_dynamic_timer(timer)
  add_timer(timer, true)
  if not timer then
    return timer
  end
  local proxy = {}
  local unpack_args = table.unpack or unpack
  local function report_timer_error(err)
    local msg = traceback(err)
    PANEL.last_error = tostring(msg)
    PANEL.last_phase = "timer_error"
    pcall(function() timer:stop() end)
    if show_error_screen then
      show_error_screen(PANEL.last_error, PANEL.active_stage or PANEL.exec_stage)
    end
    if write_status then
      write_status({ phase = "timer_error", async_error = true })
    end
  end
  function proxy:alarm(ms, mode, cb)
    local wrapped = cb
    if type(cb) == "function" then
      wrapped = function(...)
        local args = { ... }
        local ok, err = xpcall(function()
          return cb(unpack_args(args))
        end, traceback)
        if not ok then
          report_timer_error(err)
        end
      end
    end
    return timer:alarm(ms, mode, wrapped)
  end
  function proxy:start()
    return timer:start()
  end
  function proxy:stop()
    return timer:stop()
  end
  function proxy:unregister()
    return timer:unregister()
  end
  function proxy:raw()
    return timer
  end
  return proxy
end

local function stop_timer(timer)
  pcall(function() timer:stop() end)
  pcall(function() timer:unregister() end)
end

local function cleanup_dynamic()
  for _, timer in ipairs(PANEL.dynamic_timers) do
    stop_timer(timer)
  end
  PANEL.dynamic_timers = {}
end

local function stop_dynamic_range(first_index, last_index)
  first_index = tonumber(first_index) or 1
  last_index = tonumber(last_index) or #PANEL.dynamic_timers
  for i = first_index, last_index do
    if PANEL.dynamic_timers[i] then
      stop_timer(PANEL.dynamic_timers[i])
    end
  end
end

local function trim_dynamic_timers(count)
  count = tonumber(count) or 0
  while #PANEL.dynamic_timers > count do
    table.remove(PANEL.dynamic_timers)
  end
end

local function create_stage()
  local root = lv_scr_act and lv_scr_act() or 0
  if not lv_obj_create then
    return root
  end
  local stage = lv_obj_create(root)
  if lv_obj_set_pos then pcall(lv_obj_set_pos, stage, 0, 0) end
  if lv_obj_set_size then pcall(lv_obj_set_size, stage, 320, 240) end
  if lv_obj_set_style_bg_color then pcall(lv_obj_set_style_bg_color, stage, 0x000000, 0) end
  if lv_obj_set_style_bg_opa then pcall(lv_obj_set_style_bg_opa, stage, 255, 0) end
  if lv_obj_set_style_border_width then pcall(lv_obj_set_style_border_width, stage, 0, 0) end
  if lv_obj_set_style_pad_all then pcall(lv_obj_set_style_pad_all, stage, 0, 0) end
  return stage
end

local function delete_obj(obj)
  if obj and lv_obj_del then
    pcall(lv_obj_del, obj)
  end
end

local function ui_clear()
  local root = PANEL.exec_stage or (lv_scr_act and lv_scr_act() or 0)
  if lv_obj_clean then
    lv_obj_clean(root)
  end
  return root
end

local function mark_visual()
  PANEL.exec_visual_ops = (tonumber(PANEL.exec_visual_ops) or 0) + 1
end

show_text_screen = function(title, detail, target)
  local root = target or (PANEL.exec_stage or PANEL.active_stage) or (lv_scr_act and lv_scr_act() or 0)
  if not lv_label_create then
    return
  end
  if lv_obj_clean then
    pcall(lv_obj_clean, root)
  end
  if lv_obj_set_style_bg_color then
    pcall(lv_obj_set_style_bg_color, root, 0x101418, 0)
  end
  if lv_obj_set_style_bg_opa then
    pcall(lv_obj_set_style_bg_opa, root, 255, 0)
  end
  local label = lv_label_create(root)
  if lv_label_set_text then
    local text = tostring(title or "Claw Panel")
    local body = tostring(detail or "")
    if body ~= "" then
      text = text .. "\n" .. body
    end
    if #text > 260 then
      text = text:sub(1, 260) .. "..."
    end
    pcall(lv_label_set_text, label, text)
  end
  if lv_obj_set_style_text_color then
    pcall(lv_obj_set_style_text_color, label, 0xFFFFFF, 0)
  end
  if lv_obj_set_style_text_font and LV_FONT_MONTSERRAT_12 then
    pcall(lv_obj_set_style_text_font, label, LV_FONT_MONTSERRAT_12, 0)
  end
  if lv_obj_set_width then
    pcall(lv_obj_set_width, label, 300)
  end
  if lv_obj_set_pos then
    pcall(lv_obj_set_pos, label, 10, 18)
  end
end

show_error_screen = function(err, target)
  show_text_screen("Panel code error", tostring(err or ""), target)
end

write_status = function(extra)
  extra = type(extra) == "table" and extra or {}
  if type(extra.phase) == "string" and extra.phase ~= "" then
    PANEL.last_phase = extra.phase
  end
  local doc = {
    ok = true,
    running = PANEL.running,
    app_id = PANEL.APP_ID,
    updated_ms = now_ms(),
    current_seq = PANEL.current_seq,
    phase = PANEL.last_phase ~= "" and PANEL.last_phase or "ready",
    last_phase = PANEL.last_phase,
    last_error = PANEL.last_error,
    last_stdout = PANEL.last_stdout,
  }
  for k, v in pairs(extra) do
    if k ~= "phase" then
      doc[k] = v
    end
  end
  local raw = json_encode(doc)
  if raw then
    write_atomic(PANEL.STATUS_PATH, raw)
  end
end

local function command_files()
  local out = {}
  if file and file.listdir then
    local ok, items = pcall(file.listdir, PANEL.INBOX_DIR)
    if ok and type(items) == "table" then
      for _, item in ipairs(items) do
        local name = type(item) == "table" and item.name or tostring(item or "")
        if name:match("^cmd_.+%.json$") then
          out[#out + 1] = name
        end
      end
    end
  end
  table.sort(out)
  return out
end

local function result_path(seq)
  seq = tostring(seq or ""):gsub("[^%w_%-]", "_")
  return PANEL.OUTBOX_DIR .. "/result_" .. seq .. ".json"
end

local function make_env(output, stage)
  local lv_wrappers = {}
  local function wrap_lv(name, fn)
    if lv_wrappers[name] then
      return lv_wrappers[name]
    end
    lv_wrappers[name] = function(...)
      mark_visual()
      return fn(...)
    end
    return lv_wrappers[name]
  end
  local env = {
    APP = {
      APP_ID = PANEL.APP_ID,
      APP_DIR = PANEL.APP_DIR,
      SCREEN_W = 320,
      SCREEN_H = 240,
    },
    add_timer = add_dynamic_timer,
    ui_scr_act = function()
      return stage or (lv_scr_act and lv_scr_act() or 0)
    end,
    ui_clear = ui_clear,
    lv_clear = ui_clear,
    lv_scr_act = function()
      return stage or (lv_scr_act and lv_scr_act() or 0)
    end,
    lv_layer_top = function()
      return stage or (lv_layer_top and lv_layer_top() or (lv_scr_act and lv_scr_act() or 0))
    end,
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
      end
      output[#output + 1] = table.concat(parts, "\t")
    end,
    write = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
      end
      output[#output + 1] = table.concat(parts, "")
    end,
  }
  if lv_obj_clean then
    env.lv_obj_clean = function(obj) return lv_obj_clean(obj) end
  end
  if lv_canvas_frame_begin then
    env.lv_canvas_frame_begin = function(cvs) return lv_canvas_frame_begin(cvs) end
  end
  if lv_canvas_frame_end then
    env.lv_canvas_frame_end = function(cvs) return lv_canvas_frame_end(cvs) end
  end
  if lv_obj_set_pos then
    env.lv_obj_set_pos = function(obj, x, y) return lv_obj_set_pos(obj, to_int(x), to_int(y)) end
  end
  if lv_obj_set_size then
    env.lv_obj_set_size = function(obj, w, h) return lv_obj_set_size(obj, to_int(w), to_int(h)) end
  end
  if lv_obj_set_x then
    env.lv_obj_set_x = function(obj, x) return lv_obj_set_x(obj, to_int(x)) end
  end
  if lv_obj_set_y then
    env.lv_obj_set_y = function(obj, y) return lv_obj_set_y(obj, to_int(y)) end
  end
  if lv_obj_set_width then
    env.lv_obj_set_width = function(obj, w) return lv_obj_set_width(obj, to_int(w)) end
  end
  if lv_obj_set_height then
    env.lv_obj_set_height = function(obj, h) return lv_obj_set_height(obj, to_int(h)) end
  end
  if lv_obj_align then
    env.lv_obj_align = function(obj, align, x, y) return lv_obj_align(obj, align, to_int(x), to_int(y)) end
  end
  if lv_obj_align_to then
    env.lv_obj_align_to = function(obj, base, align, x, y) return lv_obj_align_to(obj, base, align, to_int(x), to_int(y)) end
  end
  if lv_line_set_points then
    env.lv_line_set_points = function(line, points, count)
      mark_visual()
      sanitize_numeric_table(points)
      return lv_line_set_points(line, points, count)
    end
  end
  if lv_canvas_draw_line then
    env.lv_canvas_draw_line = function(cvs, x1, y1, x2, y2, color, opa)
      mark_visual()
      return lv_canvas_draw_line(cvs, to_int(x1), to_int(y1), to_int(x2), to_int(y2), color, opa)
    end
  end
  if lv_canvas_draw_rect then
    env.lv_canvas_draw_rect = function(cvs, x, y, w, h, color, opa)
      mark_visual()
      return lv_canvas_draw_rect(cvs, to_int(x), to_int(y), to_int(w), to_int(h), color, opa)
    end
  end
  if lv_canvas_draw_arc then
    env.lv_canvas_draw_arc = function(cvs, x, y, r, start_angle, end_angle, color, opa)
      mark_visual()
      return lv_canvas_draw_arc(cvs, to_int(x), to_int(y), to_int(r), to_int(start_angle), to_int(end_angle), color, opa)
    end
  end
  if lv_canvas_draw_img then
    env.lv_canvas_draw_img = function(cvs, x, y, img)
      mark_visual()
      return lv_canvas_draw_img(cvs, to_int(x), to_int(y), img)
    end
  end
  return setmetatable(env, {
    __index = function(_, key)
      local value = _G[key]
      if type(key) == "string" and type(value) == "function" and key:find("^lv_") then
        return wrap_lv(key, value)
      end
      return value
    end,
    __newindex = function(t, k, v)
      rawset(t, k, v)
    end,
  })
end

traceback = function(err)
  if debug and debug.traceback then
    return debug.traceback(tostring(err), 2)
  end
  return tostring(err)
end

local function execute_command(cmd)
  local seq = tostring(cmd.seq or now_ms())
  local code = tostring(cmd.code or "")
  local timeout_ms = tonumber(cmd.timeout_ms or 1200) or 1200
  PANEL.current_seq = seq
  PANEL.last_error = ""
  PANEL.last_stdout = ""
  PANEL.exec_visual_ops = 0
  write_status({ phase = "picked_up", picked_up = true })

  local output = {}
  local started = now_ms()
  local old_stage = PANEL.active_stage
  local old_timer_count = #PANEL.dynamic_timers
  local stage = create_stage()
  PANEL.exec_stage = stage
  local env = make_env(output, stage)
  local chunk, load_err = load(code, "=(claw_panel visual)", "t", env)
  local ok = false
  local result = nil
  local phase = "load"
  local hook_active = false
  if chunk then
    phase = "runtime"
    write_status({ phase = "running", picked_up = true })
    if debug and debug.sethook then
      local deadline = started + timeout_ms
      debug.sethook(function()
        if now_ms() > deadline then
          error("panel lua_run timeout", 2)
        end
      end, "", 20000)
      hook_active = true
    end
    ok, result = xpcall(chunk, traceback)
    if hook_active then
      pcall(debug.sethook)
    end
  else
    result = tostring(load_err)
  end
  PANEL.exec_stage = nil

  local stdout = table.concat(output, "\n")
  PANEL.last_stdout = stdout
  if not ok then
    PANEL.last_error = tostring(result)
    stop_dynamic_range(old_timer_count + 1, #PANEL.dynamic_timers)
    trim_dynamic_timers(old_timer_count)
    show_error_screen(PANEL.last_error, stage)
    if old_stage and old_stage ~= stage then
      delete_obj(old_stage)
    end
    PANEL.active_stage = stage
  else
    stop_dynamic_range(1, old_timer_count)
    local new_timers = {}
    for i = old_timer_count + 1, #PANEL.dynamic_timers do
      new_timers[#new_timers + 1] = PANEL.dynamic_timers[i]
    end
    PANEL.dynamic_timers = new_timers
    if old_stage and old_stage ~= stage then
      delete_obj(old_stage)
    end
    PANEL.active_stage = stage
    if (tonumber(PANEL.exec_visual_ops) or 0) <= 0 then
      local detail = stdout ~= "" and stdout or "Completed, but no visible UI was created."
      if #new_timers > 0 and stdout == "" then
        detail = "Code is running; waiting for timer output."
      end
      show_text_screen("Claw Panel", detail, stage)
    end
  end

  local response = {
    ok = ok,
    seq = seq,
    picked_up = true,
    stdout = stdout,
    result = ok and (result == nil and "" or tostring(result)) or "",
    error = ok and "" or tostring(result),
    phase = ok and "done" or phase,
    elapsed_ms = now_ms() - started,
  }
  PANEL.last_phase = response.phase
  local raw = json_encode(response) or "{\"ok\":false,\"error\":\"result encode failed\"}"
  write_atomic(result_path(seq), raw)
  write_status({ phase = response.phase })
end

local function poll_once()
  for _, name in ipairs(command_files()) do
    local path = PANEL.INBOX_DIR .. "/" .. name
    local raw = read_text(path)
    remove_file(path)
    local cmd = json_decode(raw)
    if type(cmd) == "table" then
      execute_command(cmd)
    else
      PANEL.last_error = "bad command json: " .. name
      write_status({ phase = "bad_command" })
    end
  end
end

function PANEL.stop(reason)
  PANEL.running = false
  PANEL.last_error = tostring(reason or "")
  write_status({ running = false, phase = "stopped" })
  cleanup_dynamic()
  for _, timer in ipairs(PANEL.timers) do
    stop_timer(timer)
  end
  PANEL.timers = {}
end

ensure_dir(PANEL.APP_DIR)
ensure_dir(PANEL.INBOX_DIR)
ensure_dir(PANEL.OUTBOX_DIR)
PANEL.active_stage = create_stage()
show_text_screen("Claw Panel", "Ready\nWaiting for code.", PANEL.active_stage)
write_status({ phase = "ready" })

if app and app.set_home_exit then
  pcall(function() app.set_home_exit(true) end)
end

local status_timer = add_timer(tmr.create(), false)
status_timer:alarm(1000, tmr.ALARM_AUTO, function()
  write_status({ heartbeat = true })
end)

local poll_timer = add_timer(tmr.create(), false)
poll_timer:alarm(220, tmr.ALARM_AUTO, function()
  poll_once()
end)

poll_once()
print("[claw_panel] ready")
