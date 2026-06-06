local M = {}

local route_reset

local function ensure_chat_job(APP)
  APP.state.chat_job = type(APP.state.chat_job) == "table" and APP.state.chat_job or {}
  local job = APP.state.chat_job
  job.id = APP.core.text_or(job.id, "")
  job.status = APP.core.text_or(job.status, "idle")
  if job.status == "" then
    job.status = "idle"
  end
  return job
end

local function chat_job_active(job)
  return type(job) == "table" and (job.status == "queued" or job.status == "running")
end

local function remember_chat_job(APP, job)
  if type(job) ~= "table" or APP.core.text_or(job.id, "") == "" then
    return
  end
  APP.chat_jobs = type(APP.chat_jobs) == "table" and APP.chat_jobs or {}
  APP.chat_job_order = type(APP.chat_job_order) == "table" and APP.chat_job_order or {}
  local id = APP.core.text_or(job.id, "")
  if not APP.chat_jobs[id] then
    APP.chat_job_order[#APP.chat_job_order + 1] = id
  end
  APP.chat_jobs[id] = job
  while #APP.chat_job_order > 6 do
    local old = table.remove(APP.chat_job_order, 1)
    if old ~= APP.core.text_or(APP.state.chat_job and APP.state.chat_job.id, "") then
      APP.chat_jobs[old] = nil
    end
  end
end

local function find_chat_job(APP, id)
  id = APP.core.text_or(id, "")
  if id ~= "" and type(APP.chat_jobs) == "table" and APP.chat_jobs[id] then
    return APP.chat_jobs[id]
  end
  local current = ensure_chat_job(APP)
  if id == "" or id == APP.core.text_or(current.id, "") then
    return current
  end
  return nil
end

local function chat_job_public(APP, include_reply, job)
  local core = APP.core
  job = type(job) == "table" and job or ensure_chat_job(APP)
  local out = {
    id = core.text_or(job.id, ""),
    status = core.text_or(job.status, "idle"),
    message = core.short_text(job.message or "", 160),
    error = core.short_text(job.error or "", 260),
    created_ms = tonumber(job.created_ms or 0) or 0,
    started_ms = tonumber(job.started_ms or 0) or 0,
    finished_ms = tonumber(job.finished_ms or 0) or 0,
  }
  if include_reply then
    out.reply = core.text_or(job.reply, "")
  end
  return out
end

local function schedule_chat_job(APP)
  local core = APP.core
  if not tmr or not tmr.create then
    return false, "timer unavailable"
  end
  if APP.chat_job_timer then
    pcall(function() APP.chat_job_timer:stop() end)
    pcall(function() APP.chat_job_timer:unregister() end)
    APP.chat_job_timer = nil
  end
  local timer = tmr.create()
  APP.chat_job_timer = timer
  APP.add_timer(timer)
  -- Web 请求先返回 202，真正的 LLM 对话放到单次 timer 里执行，避免 HTTP handler 长时间占住。
  timer:alarm(600, tmr.ALARM_SINGLE or 0, function()
    pcall(function() timer:stop() end)
    pcall(function() timer:unregister() end)
    if APP.chat_job_timer == timer then
      APP.chat_job_timer = nil
    end
    local job = ensure_chat_job(APP)
    if job.status ~= "queued" then
      return
    end
    job.status = "running"
    job.started_ms = core.now_ms()
    job.error = ""
    core.append_log("job", "chat " .. core.text_or(job.id, "") .. " running")
    APP.ui_api.redraw()

    local reply, err = APP.agent.handle_user_message(core.text_or(job.message, ""), {
      channel = core.text_or(job.channel, "web"),
      chat_id = core.text_or(job.chat_id, "web"),
    })
    job.finished_ms = core.now_ms()
    if reply then
      job.status = "done"
      job.reply = reply
      job.error = ""
      remember_chat_job(APP, job)
      core.append_log("job", "chat " .. core.text_or(job.id, "") .. " done")
    else
      job.status = "error"
      job.reply = ""
      job.error = core.text_or(err, "agent failed")
      remember_chat_job(APP, job)
      core.append_log("error", "chat job " .. core.short_text(job.error, 140))
    end
    APP.ui_api.redraw()
  end)
  return true
end

-- 处理聊天 API 请求。
local function route_chat(req)
  local APP = M.APP
  local core = APP.core
  local body, body_err = core.read_request_body(req, APP.MAX_BODY_BYTES)
  if not body then
    return core.error_response("413 Payload Too Large", body_err)
  end
  local doc, err = core.safe_json_decode(body)
  if type(doc) ~= "table" then
    return core.error_response("400 Bad Request", err or "invalid json")
  end
  local message = core.trim(doc.message)
  if message == "" then
    return core.error_response("400 Bad Request", "message is required")
  end
  local active = ensure_chat_job(APP)
  -- 设备端一次只跑一个聊天 job，避免多个 LLM/tool 循环同时写状态和文件。
  if APP.state.busy or chat_job_active(active) then
    return core.json_response("202 Accepted", {
      ok = true,
      busy = true,
      job_id = core.text_or(active.id, ""),
      job = chat_job_public(APP, false),
      state = core.status_snapshot(),
    })
  end
  if doc.reset then
    -- reset 只清当前 Web 会话上下文，不清长期记忆。
    APP.history = {}
    if APP.skills and APP.skills.clear_session then
      APP.skills.clear_session({ channel = "web", chat_id = "web" })
    end
  end
  local job_id = tostring(core.now_ms()) .. "-" .. tostring(math.random(1000, 9999))
  APP.state.chat_job = {
    id = job_id,
    status = "queued",
    message = message,
    reply = "",
    error = "",
    channel = "web",
    chat_id = "web",
    created_ms = core.now_ms(),
    started_ms = 0,
    finished_ms = 0,
  }
  remember_chat_job(APP, APP.state.chat_job)
  local ok_schedule, schedule_err = schedule_chat_job(APP)
  if not ok_schedule then
    APP.state.chat_job.status = "error"
    APP.state.chat_job.error = schedule_err or "chat job schedule failed"
    return core.error_response("500 Internal Server Error", APP.state.chat_job.error)
  end
  core.append_log("job", "chat " .. job_id .. " queued")
  APP.ui_api.redraw()
  return core.json_response("202 Accepted", {
    ok = true,
    queued = true,
    job_id = job_id,
    job = chat_job_public(APP, false),
    state = core.status_snapshot(),
  })
end

local function route_chat_result(doc)
  local APP = M.APP
  local core = APP.core
  local requested = core.text_or(doc.job_id or doc.id, "")
  local job = find_chat_job(APP, requested)
  if not job then
    return core.error_response("404 Not Found", "chat job not found")
  end
  return core.json_response("200 OK", {
    ok = true,
    job_id = core.text_or(job.id, ""),
    job = chat_job_public(APP, true, job),
    state = core.status_snapshot(),
  })
end

-- 返回公开配置。
local function route_config_get()
  local APP = M.APP
  return APP.core.json_response("200 OK", {
    ok = true,
    config = APP.core.public_config(),
  })
end

-- 保存配置。
local function route_config_post(doc)
  local APP = M.APP
  local core = APP.core
  local ok, save_err = core.save_config(doc)
  if not ok then
    return core.error_response("500 Internal Server Error", save_err)
  end
  core.append_log("config", "saved")
  APP.ui_api.redraw()
  return core.json_response("200 OK", {
    ok = true,
    config = core.public_config(),
  })
end

-- 统一处理 WebUI 的 action API。
local function route_api(req)
  local APP = M.APP
  local core = APP.core
  local body, body_err = core.read_request_body(req, APP.MAX_BODY_BYTES)
  if not body then
    return core.error_response("413 Payload Too Large", body_err)
  end
  local doc, err = core.safe_json_decode(body)
  if type(doc) ~= "table" then
    return core.error_response("400 Bad Request", err or "invalid json")
  end

  local action = core.trim(doc.action)
  -- WebUI 所有轻量动作都走同一个 action API，聊天本身走 /chat job 流程。
  local source = {
    channel = core.text_or(doc.channel, "web"),
    chat_id = core.text_or(doc.chat_id, "web"),
  }
  if action == "state" then
    return core.json_response("200 OK", core.status_snapshot())
  end
  if action == "config" then
    return route_config_get()
  end
  if action == "prompt_preview" then
    if not APP.agent or not APP.agent.prompt_preview then
      return core.error_response("500 Internal Server Error", "agent prompt preview missing")
    end
    return core.json_response("200 OK", APP.agent.prompt_preview(core.text_or(doc.message, ""), source))
  end
  if action == "memory" then
    return core.json_response("200 OK", APP.memory.snapshot(source))
  end
  if action == "memory_search" then
    local items = APP.memory.list_facts(core.text_or(doc.query, ""), doc.limit or 20)
    return core.json_response("200 OK", { ok = true, memories = items })
  end
  if action == "memory_forget" then
    local removed = 0
    if core.trim(doc.id) ~= "" and APP.memory.forget_id then
      removed = APP.memory.forget_id(core.text_or(doc.id, ""))
    else
      removed = APP.memory.forget_matching(core.text_or(doc.query, ""), source)
    end
    return core.json_response("200 OK", { ok = true, removed = removed, memory = APP.memory.snapshot(source) })
  end
  if action == "memory_profiles" then
    return core.json_response("200 OK", { ok = true, profiles = APP.memory.profiles() })
  end
  if action == "memory_profiles_save" then
    local ok, save_err = APP.memory.save_profiles(type(doc.profiles) == "table" and doc.profiles or {})
    if not ok then
      return core.error_response("500 Internal Server Error", save_err)
    end
    return core.json_response("200 OK", { ok = true, profiles = APP.memory.profiles() })
  end
  if action == "memory_export" then
    return core.json_response("200 OK", APP.memory.export_data(source))
  end
  if action == "memory_import" then
    local ok, result = APP.memory.import_data(doc, source)
    if not ok then
      return core.error_response("500 Internal Server Error", result)
    end
    return core.json_response("200 OK", { ok = true, imported = result, memory = APP.memory.snapshot(source) })
  end
  if action == "memory_clear" then
    local ok, clear_err = APP.memory.clear(core.text_or(doc.scope, "session"), source)
    if not ok then
      return core.error_response("500 Internal Server Error", clear_err)
    end
    return core.json_response("200 OK", APP.memory.snapshot(source))
  end
  if action == "skills" then
    return core.json_response("200 OK", APP.skills.snapshot(source))
  end
  if action == "skills_clear" then
    if APP.skills and APP.skills.clear_session then
      APP.skills.clear_session(source)
    end
    return core.json_response("200 OK", APP.skills.snapshot(source))
  end
  if action == "panel_history" then
    if not APP.code_runner or not APP.code_runner.panel_history then
      return core.error_response("500 Internal Server Error", "panel history missing")
    end
    return core.json_response("200 OK", APP.code_runner.panel_history(doc.limit or 12))
  end
  if action == "execution_ledger" then
    if not APP.agent or not APP.agent.execution_ledger then
      return core.error_response("500 Internal Server Error", "execution ledger missing")
    end
    return core.json_response("200 OK", APP.agent.execution_ledger(doc.limit or 40))
  end
  if action == "classify_task" then
    if not APP.agent or not APP.agent.classify_task then
      return core.error_response("500 Internal Server Error", "classifier missing")
    end
    local message = core.text_or(doc.message or doc.text, "")
    local fallback = APP.agent.classify_task(message)
    local plan = fallback
    if doc.semantic == true or doc.use_llm == true then
      if not APP.agent.route_task then
        return core.error_response("500 Internal Server Error", "semantic router missing")
      end
      plan = APP.agent.route_task(message, source, fallback)
    end
    return core.json_response("200 OK", {
      ok = true,
      plan = plan,
      fallback_plan = fallback,
    })
  end
  if action == "code_capabilities" then
    if not APP.code_runner or not APP.code_runner.capabilities then
      return core.error_response("500 Internal Server Error", "code capabilities missing")
    end
    return core.json_response("200 OK", { ok = true, capabilities = APP.code_runner.capabilities() })
  end
  if action == "preflight_lua" then
    if not APP.code_runner or not APP.code_runner.preflight then
      return core.error_response("500 Internal Server Error", "preflight missing")
    end
    return core.json_response("200 OK", APP.code_runner.preflight({ code = core.text_or(doc.code, "") }))
  end
  if action == "panel_artifacts" then
    if not APP.code_runner or not APP.code_runner.panel_artifacts then
      return core.error_response("500 Internal Server Error", "panel artifacts missing")
    end
    return core.json_response("200 OK", APP.code_runner.panel_artifacts({
      query = core.text_or(doc.query, ""),
      limit = doc.limit or 12,
      include_code = doc.include_code ~= false,
    }))
  end
  if action == "panel_history_get" then
    if not APP.code_runner or not APP.code_runner.panel_history_get then
      return core.error_response("500 Internal Server Error", "panel history missing")
    end
    local item, hist_err = APP.code_runner.panel_history_get(core.text_or(doc.id, ""))
    if not item then
      return core.error_response("404 Not Found", hist_err)
    end
    return core.json_response("200 OK", { ok = true, item = item })
  end
  if action == "panel_rerun" then
    if not APP.code_runner or not APP.code_runner.panel_history_rerun then
      return core.error_response("500 Internal Server Error", "panel rerun missing")
    end
    local ok, result = APP.code_runner.panel_history_rerun(core.text_or(doc.id, ""))
    if not ok then
      return core.error_response("500 Internal Server Error", type(result) == "table" and result.error or result)
    end
    return core.json_response("200 OK", { ok = true, result = result })
  end
  if action == "panel_clear" then
    if APP.code_runner and APP.code_runner.panel_history_clear then
      local ok, clear_err = APP.code_runner.panel_history_clear()
      if not ok then
        return core.error_response("500 Internal Server Error", clear_err)
      end
    end
    return core.json_response("200 OK", { ok = true })
  end
  if action == "self_check" then
    if not APP.diagnostics or not APP.diagnostics.run then
      return core.error_response("500 Internal Server Error", "diagnostics missing")
    end
    return core.json_response("200 OK", APP.diagnostics.run(source))
  end
  if action == "wechat_crypto_test" then
    local ok, result = APP.wechat_crypto.self_test()
    if not ok then
      return core.error_response("500 Internal Server Error", result)
    end
    return core.json_response("200 OK", { ok = true, result = result })
  end
  if action == "wechat_qr_start" then
    local ok, result = APP.wechat.qr_start(doc.force ~= false, doc.wechat_base_url)
    if not ok then
      return core.error_response("500 Internal Server Error", result)
    end
    return core.json_response("200 OK", result)
  end
  if action == "wechat_qr_status" then
    local ok, result = APP.wechat.qr_poll_once()
    if not ok then
      return core.error_response("500 Internal Server Error", result)
    end
    return core.json_response("200 OK", result)
  end
  if action == "wechat_qr_cancel" then
    local ok, result = APP.wechat.qr_cancel()
    if not ok then
      return core.error_response("500 Internal Server Error", result)
    end
    return core.json_response("200 OK", result)
  end
  if action == "wechat_send_image" then
    local ok, send_err = APP.wechat.send_image(core.text_or(doc.chat_id, ""), core.text_or(doc.path, ""), core.text_or(doc.caption, ""))
    if not ok then
      return core.error_response("500 Internal Server Error", send_err)
    end
    return core.json_response("200 OK", { ok = true })
  end
  if action == "inspect_image" then
    if not APP.vision or not APP.vision.inspect_image then
      return core.error_response("500 Internal Server Error", "vision module missing")
    end
    local text, vision_err = APP.vision.inspect_image(core.text_or(doc.path, ""), core.text_or(doc.prompt, "请简要描述这张图片。"), {
      channel = "web",
      chat_id = "web",
    })
    if not text then
      local err_text = core.text_or(vision_err, "")
      local base = core.text_or(APP.config and APP.config.llm_base_url, ""):lower()
      if base:find("api.deepseek.com", 1, true)
        and (err_text:find("DeepSeek", 1, true) or err_text:find("图片", 1, true)) then
        return core.json_response("200 OK", { ok = true, reply = err_text, state = core.status_snapshot() })
      end
      return core.error_response("500 Internal Server Error", vision_err)
    end
    return core.json_response("200 OK", { ok = true, reply = text, state = core.status_snapshot() })
  end
  if action == "save_config" then
    return route_config_post(doc)
  end
  if action == "chat_result" then
    return route_chat_result(doc)
  end
  if action == "chat" then
    return route_chat({
      getbody = function()
        if body then
          local tmp = body
          body = nil
          return tmp
        end
        return nil
      end,
    })
  end
  if action == "reset" then
    return route_reset()
  end
  return core.error_response("404 Not Found", "unknown action")
end

-- 清空会话历史和错误状态。
route_reset = function()
  local APP = M.APP
  local S = APP.state
  APP.history = {}
  if APP.skills and APP.skills.clear_session then
    APP.skills.clear_session({ channel = "web", chat_id = "web" })
  end
  S.last_error = ""
  S.last_user = ""
  S.last_reply = "Session cleared"
  S.chat_job = {
    id = "",
    status = "idle",
    message = "",
    reply = "",
    error = "",
    created_ms = 0,
    started_ms = 0,
    finished_ms = 0,
  }
  APP.chat_jobs = {}
  APP.chat_job_order = {}
  APP.core.append_log("session", "cleared")
  APP.ui_api.redraw()
  return APP.core.json_response("200 OK", { ok = true, state = APP.core.status_snapshot() })
end

-- 返回 WebUI HTML 页面。
local function route_index()
  local APP = M.APP
  local core = APP.core
  local html, err = core.read_text_file(APP.APP_DIR .. "/web.html")
  if not html then
    return core.text_response("500 Internal Server Error", "text/plain; charset=utf-8", "web.html missing: " .. core.text_or(err, "read failed"))
  end
  html = html:gsub("__BASE__", function()
    return APP.ROUTE_BASE
  end)
  return core.text_response("200 OK", "text/html; charset=utf-8", html)
end

-- 返回到 app 路由根路径。
-- 注册 httpd 动态路由并记录，便于 reload 释放。
local function register_route(method, route, handler)
  local APP = M.APP
  local err = httpd.dynamic(method, route, handler)
  if err then
    local msg = "httpd.dynamic failed: " .. route .. " (" .. tostring(err) .. ")"
    APP.state.last_error = msg
    APP.core.append_log("error", msg)
    print("[esp_claw] " .. msg)
    return false
  end
  APP.add_route(method, route)
  return true
end

local function register_route_set(base)
  local APP = M.APP
  base = APP.core.trim(base)
  if base == "" then
    return
  end
  register_route(httpd.POST, base .. "/api", route_api)
  register_route(httpd.GET, base, route_index)
  register_route(httpd.GET, base .. "/", route_index)
end

-- 反注册本 app 已注册的所有路由。
local function unregister_routes()
  local APP = M.APP
  if not httpd or not httpd.unregister then
    APP.routes = {}
    return
  end
  for i = #APP.routes, 1, -1 do
    local item = APP.routes[i]
    pcall(function()
      httpd.unregister(item.method, item.route)
    end)
  end
  APP.routes = {}
end

-- 启动 WebUI 和 API 路由。
local function start()
  local APP = M.APP
  if not httpd or not httpd.start then
    APP.state.last_error = "httpd missing"
    return
  end

  httpd.start({
    webroot = "/sd",
    auto_index = httpd.INDEX_NONE,
    max_handlers = 64,
  })
  register_route_set(APP.ROUTE_BASE)
  -- app.route_base 可能变化，保留 /esp_claw 作为固定兼容入口。
  if APP.ROUTE_BASE ~= "/esp_claw" then
    register_route_set("/esp_claw")
  end

  if app and app.set_webui then
    local ok, err = app.set_webui(true)
    if not ok then
      APP.state.last_error = "webui " .. tostring(err or "failed")
    end
  end
end

-- 初始化 Web 模块。
function M.init(APP)
  M.APP = APP
  APP.web = {
    start = start,
    unregister_routes = unregister_routes,
  }
end

-- 停止 Web 模块，释放动态路由。
function M.stop()
  if M.APP and M.APP.chat_job_timer then
    pcall(function() M.APP.chat_job_timer:stop() end)
    pcall(function() M.APP.chat_job_timer:unregister() end)
    M.APP.chat_job_timer = nil
  end
  unregister_routes()
end

return M
