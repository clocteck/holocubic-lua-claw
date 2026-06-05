local M = {}

local function add(checks, id, label, status, detail)
  checks[#checks + 1] = {
    id = id,
    label = label,
    status = status,
    detail = M.APP.core.text_or(detail, ""),
  }
end

-- 读取 Claw Panel status.json，用于判断前台面板心跳。
local function read_panel_status()
  local APP = M.APP
  local core = APP.core
  local id = core.trim(APP.config.panel_app_id)
  if id == "" then id = "claw_panel" end
  local raw = core.read_text_file("/sd/apps/" .. id .. "/status.json")
  if not raw or raw == "" then
    return nil, "panel status missing"
  end
  local doc, err = core.safe_json_decode(raw)
  if type(doc) ~= "table" then
    return nil, err or "panel status json failed"
  end
  return doc, nil
end

-- 检查 SD 读写能力，使用 app 目录下的临时文件。
local function check_sd()
  local APP = M.APP
  local core = APP.core
  local ok, err = core.ensure_app_dir()
  if not ok then
    return "fail", err
  end
  local path = APP.APP_DIR .. "/diag.tmp"
  local token = "diag-" .. tostring(core.now_ms())
  ok, err = core.write_text_file(path, token)
  if not ok then
    return "fail", err
  end
  local raw = core.read_text_file(path)
  if file and file.remove then
    pcall(file.remove, path)
  end
  if raw ~= token then
    return "fail", "readback mismatch"
  end
  return "ok", "read/write ok"
end

-- 运行一次低成本健康检查，不主动请求外部 LLM，避免消耗网络和 token。
local function run(source)
  local APP = M.APP
  local core = APP.core
  source = type(source) == "table" and source or { channel = "web", chat_id = "web" }
  local checks = {}

  if http and http.get and http.post then
    add(checks, "http", "HTTP", "ok", "http.get/http.post available")
  else
    add(checks, "http", "HTTP", "fail", "http client missing")
  end

  if APP.config.llm_base_url ~= "" and APP.config.llm_api_key ~= "" and APP.config.llm_model ~= "" then
    add(checks, "llm", "LLM", "ok", APP.config.llm_model)
  else
    add(checks, "llm", "LLM", "warn", "base URL, API key, or model missing")
  end

  local sd_status, sd_detail = check_sd()
  add(checks, "sd", "SD", sd_status, sd_detail)

  if APP.config.wechat_enabled then
    if APP.config.wechat_token ~= "" then
      add(checks, "wechat", "WeChat", "ok", "enabled and token set")
    else
      add(checks, "wechat", "WeChat", "warn", "enabled but token missing")
    end
  else
    add(checks, "wechat", "WeChat", "warn", "disabled")
  end

  local panel, panel_err = read_panel_status()
  if panel then
    local updated = tonumber(panel.updated_ms) or 0
    local now = core.now_ms()
    local age = now - updated
    local fresh = updated > 0 and now > 0 and age >= 0 and age <= 5200
    add(checks, "panel", "Panel", fresh and "ok" or "warn",
      fresh and "heartbeat fresh" or ("stale heartbeat " .. tostring(updated)))
  else
    add(checks, "panel", "Panel", "warn", panel_err)
  end

  if APP.memory and APP.memory.snapshot then
    local ok, snap = pcall(APP.memory.snapshot, source)
    if ok and type(snap) == "table" then
      add(checks, "memory", "Memory", "ok", tostring(snap.facts or 0) .. " facts")
    else
      add(checks, "memory", "Memory", "fail", snap or "memory snapshot failed")
    end
  else
    add(checks, "memory", "Memory", "fail", "memory module missing")
  end

  local summary = { ok = 0, warn = 0, fail = 0 }
  for i = 1, #checks do
    local status = checks[i].status
    summary[status] = (summary[status] or 0) + 1
  end
  core.append_log("diag", "ok " .. tostring(summary.ok) .. " warn " .. tostring(summary.warn) .. " fail " .. tostring(summary.fail))
  return {
    ok = summary.fail == 0,
    checks = checks,
    summary = summary,
    at = core.now_ms(),
  }
end

function M.init(APP)
  M.APP = APP
  APP.diagnostics = {
    run = run,
  }
end

return M
