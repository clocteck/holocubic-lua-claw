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
  last_phase = "",
  last_error = "",
  last_stdout = "",
  running = true,
}

CLAW_PANEL_APP = PANEL

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

local function add_timer(timer, dynamic)
  if timer then
    local list = dynamic and PANEL.dynamic_timers or PANEL.timers
    list[#list + 1] = timer
  end
  return timer
end

local function add_dynamic_timer(timer)
  return add_timer(timer, true)
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

local function show_error_screen(err)
  local root = lv_scr_act and lv_scr_act() or 0
  if not lv_label_create then
    return
  end
  local label = lv_label_create(root)
  if lv_label_set_text then
    local text = "Panel code error\n" .. tostring(err or "")
    if #text > 220 then
      text = text:sub(1, 220) .. "..."
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

local function write_status(extra)
  local doc = {
    ok = true,
    running = PANEL.running,
    app_id = PANEL.APP_ID,
    updated_ms = now_ms(),
    current_seq = PANEL.current_seq,
    last_phase = PANEL.last_phase,
    last_error = PANEL.last_error,
    last_stdout = PANEL.last_stdout,
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
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
  return setmetatable(env, {
    __index = _G,
    __newindex = function(t, k, v)
      rawset(t, k, v)
    end,
  })
end

local function traceback(err)
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
    if stage ~= old_stage then
      delete_obj(stage)
    end
    show_error_screen(PANEL.last_error)
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
write_status({ phase = "ready" })

if app and app.set_home_exit then
  pcall(function() app.set_home_exit(true) end)
end

local status_timer = add_timer(tmr.create(), false)
status_timer:alarm(1000, tmr.ALARM_AUTO, function()
  write_status({ phase = "ready" })
end)

local poll_timer = add_timer(tmr.create(), false)
poll_timer:alarm(220, tmr.ALARM_AUTO, function()
  poll_once()
end)

poll_once()
print("[claw_panel] ready")
