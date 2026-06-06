local M = {}

local route_reset
local dispatch_chat_jobs

local function safe_session_part(APP, text, fallback)
  text = APP.core.text_or(text, fallback or "")
  text = text:gsub("[^%w%._%-]", "_")
  text = text:gsub("_+", "_")
  if text == "" or text == "_" then
    text = fallback or "default"
  end
  if #text > 80 then
    text = text:sub(1, 80)
  end
  return text
end

local function job_session_key(APP, source)
  source = type(source) == "table" and source or {}
  local channel = APP.core.text_or(source.channel, "web")
  local chat_id = APP.core.text_or(source.chat_id, channel)
  return safe_session_part(APP, channel, "web") .. ":" .. safe_session_part(APP, chat_id, channel)
end

local function normalize_source(APP, source)
  source = type(source) == "table" and source or {}
  local channel = APP.core.text_or(source.channel, "web")
  local chat_id = APP.core.text_or(source.chat_id, channel)
  return {
    channel = channel,
    chat_id = chat_id,
    sender_id = APP.core.text_or(source.sender_id, ""),
    message_id = APP.core.text_or(source.message_id, ""),
    image_path = APP.core.text_or(source.image_path, ""),
    title = APP.core.text_or(source.title, ""),
  }
end

local function ensure_runtime(APP)
  APP.chat_runtime = type(APP.chat_runtime) == "table" and APP.chat_runtime or {}
  local rt = APP.chat_runtime
  rt.max_running = tonumber(rt.max_running) or 2
  rt.running = tonumber(rt.running) or 0
  rt.queue = type(rt.queue) == "table" and rt.queue or {}
  rt.jobs = type(rt.jobs) == "table" and rt.jobs or {}
  rt.order = type(rt.order) == "table" and rt.order or {}
  rt.running_by_session = type(rt.running_by_session) == "table" and rt.running_by_session or {}
  return rt
end

local function sync_runtime_state(APP)
  local rt = ensure_runtime(APP)
  APP.state.chat_runtime = type(APP.state.chat_runtime) == "table" and APP.state.chat_runtime or {}
  APP.state.chat_runtime.max_running = rt.max_running
  APP.state.chat_runtime.running = rt.running
  APP.state.chat_runtime.queued = #rt.queue
  APP.state.chat_runtime.active_sessions = rt.running_by_session
  APP.state.busy = (tonumber(APP.state.agent_running) or 0) > 0 or rt.running > 0
end

local function remember_chat_job(APP, job)
  if type(job) ~= "table" or APP.core.text_or(job.id, "") == "" then
    return
  end
  APP.chat_jobs = type(APP.chat_jobs) == "table" and APP.chat_jobs or {}
  APP.chat_job_order = type(APP.chat_job_order) == "table" and APP.chat_job_order or {}
  local id = APP.core.text_or(job.id, "")
  ensure_runtime(APP).jobs[id] = job
  if not APP.chat_jobs[id] then
    APP.chat_job_order[#APP.chat_job_order + 1] = id
  end
  APP.chat_jobs[id] = job
  while #APP.chat_job_order > 40 do
    local old = table.remove(APP.chat_job_order, 1)
    if old ~= APP.core.text_or(APP.state.chat_job and APP.state.chat_job.id, "") then
      APP.chat_jobs[old] = nil
      ensure_runtime(APP).jobs[old] = nil
    end
  end
end

local function find_chat_job(APP, id)
  id = APP.core.text_or(id, "")
  local rt = ensure_runtime(APP)
  if id ~= "" and rt.jobs[id] then
    return rt.jobs[id]
  end
  if id ~= "" and type(APP.chat_jobs) == "table" and APP.chat_jobs[id] then
    return APP.chat_jobs[id]
  end
  local current = type(APP.state.chat_job) == "table" and APP.state.chat_job or {}
  if id == "" or id == APP.core.text_or(current.id, "") then
    return current
  end
  return nil
end

local function chat_job_public(APP, include_reply, job)
  local core = APP.core
  job = type(job) == "table" and job or (APP.state.chat_job or {})
  local out = {
    id = core.text_or(job.id, ""),
    status = core.text_or(job.status, "idle"),
    message = core.short_text(job.message or "", 160),
    error = core.short_text(job.error or "", 260),
    channel = core.text_or(job.channel, ""),
    chat_id = core.text_or(job.chat_id, ""),
    session_key = core.text_or(job.session_key, ""),
    queue_pos = tonumber(job.queue_pos) or 0,
    created_ms = tonumber(job.created_ms or 0) or 0,
    started_ms = tonumber(job.started_ms or 0) or 0,
    finished_ms = tonumber(job.finished_ms or 0) or 0,
  }
  if include_reply then
    out.reply = core.text_or(job.reply, "")
  end
  return out
end

local function queue_positions(rt)
  for i = 1, #rt.queue do
    rt.queue[i].queue_pos = i
  end
end

local function finish_chat_job(APP, job, reply, err)
  local core = APP.core
  local rt = ensure_runtime(APP)
  job.finished_ms = core.now_ms()
  if reply then
    job.status = "done"
    job.reply = reply
    job.error = ""
    core.append_log("job", "chat " .. core.text_or(job.id, "") .. " done")
  else
    job.status = "error"
    job.reply = ""
    job.error = core.text_or(err, "agent failed")
    core.append_log("error", "chat job " .. core.short_text(job.error, 140))
  end
  rt.running = math.max(0, (tonumber(rt.running) or 1) - 1)
  rt.running_by_session[job.session_key] = nil
  remember_chat_job(APP, job)
  sync_runtime_state(APP)
  if type(job.on_done) == "function" then
    pcall(job.on_done, job, reply, err)
  end
  APP.ui_api.redraw()
  dispatch_chat_jobs(APP)
end

local function start_chat_job(APP, job)
  local core = APP.core
  local rt = ensure_runtime(APP)
  local timer = tmr.create()
  APP.add_timer(timer)
  job.status = "running"
  job.started_ms = core.now_ms()
  job.error = ""
  job.queue_pos = 0
  rt.running = rt.running + 1
  rt.running_by_session[job.session_key] = job.id
  APP.state.chat_job = job
  remember_chat_job(APP, job)
  sync_runtime_state(APP)
  core.append_log("job", "chat " .. core.text_or(job.id, "") .. " running")
  APP.ui_api.redraw()
  timer:alarm(80, tmr.ALARM_SINGLE or 0, function()
    pcall(function() timer:stop() end)
    pcall(function() timer:unregister() end)
    local ok, reply, err = pcall(APP.agent.handle_user_message, core.text_or(job.message, ""), job.source)
    if not ok then
      finish_chat_job(APP, job, nil, reply)
    else
      finish_chat_job(APP, job, reply, err)
    end
  end)
  return true
end

dispatch_chat_jobs = function(APP)
  local rt = ensure_runtime(APP)
  if not tmr or not tmr.create then
    return false, "timer unavailable"
  end
  local started_any = false
  while rt.running < rt.max_running and #rt.queue > 0 do
    local pick_index = nil
    for i = 1, #rt.queue do
      local job = rt.queue[i]
      if job.status == "queued" and not rt.running_by_session[job.session_key] then
        pick_index = i
        break
      end
    end
    if not pick_index then
      break
    end
    local job = table.remove(rt.queue, pick_index)
    queue_positions(rt)
    start_chat_job(APP, job)
    started_any = true
  end
  sync_runtime_state(APP)
  return true, started_any
end

local function submit_chat_job(APP, message, source, opts)
  local core = APP.core
  if not tmr or not tmr.create then
    return nil, "timer unavailable"
  end
  opts = type(opts) == "table" and opts or {}
  source = normalize_source(APP, source)
  local job_id = tostring(core.now_ms()) .. "-" .. tostring(math.random(1000, 9999))
  local job = {
    id = job_id,
    status = "queued",
    message = core.text_or(message, ""),
    reply = "",
    error = "",
    channel = source.channel,
    chat_id = source.chat_id,
    session_key = job_session_key(APP, source),
    source = source,
    on_done = opts.on_done,
    created_ms = core.now_ms(),
    started_ms = 0,
    finished_ms = 0,
    queue_pos = 0,
  }
  local rt = ensure_runtime(APP)
  rt.queue[#rt.queue + 1] = job
  queue_positions(rt)
  APP.state.chat_job = job
  remember_chat_job(APP, job)
  core.append_log("job", "chat " .. job_id .. " queued " .. job.session_key)
  dispatch_chat_jobs(APP)
  APP.ui_api.redraw()
  return job, nil
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
  local source = normalize_source(APP, {
    channel = core.text_or(doc.channel, "web"),
    chat_id = core.text_or(doc.chat_id, "web"),
    title = core.text_or(doc.title, ""),
  })
  if doc.reset then
    -- reset 只清当前 Web 会话上下文，不清长期记忆。
    if APP.agent and APP.agent.clear_session_history then
      APP.agent.clear_session_history(source)
    end
    if APP.skills and APP.skills.clear_session then
      APP.skills.clear_session(source)
    end
  end
  local job, submit_err = submit_chat_job(APP, message, source)
  if not job then
    return core.error_response("500 Internal Server Error", submit_err or "chat job submit failed")
  end
  return core.json_response("202 Accepted", {
    ok = true,
    queued = true,
    job_id = job.id,
    job = chat_job_public(APP, false, job),
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
  if action == "sessions_list" then
    if not APP.agent or not APP.agent.sessions_list then
      return core.error_response("500 Internal Server Error", "session list missing")
    end
    local result = APP.agent.sessions_list()
    result.jobs = {
      running = APP.state.chat_runtime and APP.state.chat_runtime.running or 0,
      queued = APP.state.chat_runtime and APP.state.chat_runtime.queued or 0,
      max_running = APP.state.chat_runtime and APP.state.chat_runtime.max_running or 2,
    }
    return core.json_response("200 OK", result)
  end
  if action == "session_history" then
    if not APP.agent or not APP.agent.session_history then
      return core.error_response("500 Internal Server Error", "session history missing")
    end
    return core.json_response("200 OK", APP.agent.session_history(core.text_or(doc.key, ""), doc.limit or 60))
  end
  if action == "session_clear" then
    if not APP.agent or not APP.agent.clear_session_history then
      return core.error_response("500 Internal Server Error", "session clear missing")
    end
    local key = core.text_or(doc.key, "")
    if key ~= "" then
      APP.agent.clear_session_history(key)
    else
      APP.agent.clear_session_history(source)
    end
    return core.json_response("200 OK", { ok = true, sessions = APP.agent.sessions_list().sessions })
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
    local fallback = APP.agent.classify_task(message, source)
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
    return core.json_response("200 OK", {
      ok = true,
      queued = type(result) == "table" and result.queued == true,
      pending = type(result) == "table" and result.pending == true,
      result = result,
    })
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
    local text, vision_err = APP.vision.inspect_image(core.text_or(doc.path, ""), core.text_or(doc.prompt, "请简要描述这张图片。"), source)
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
    return route_reset(source)
  end
  return core.error_response("404 Not Found", "unknown action")
end

-- 清空会话历史和错误状态。
route_reset = function(source)
  local APP = M.APP
  local S = APP.state
  source = normalize_source(APP, source)
  if APP.agent and APP.agent.clear_session_history then
    APP.agent.clear_session_history(source)
  end
  if APP.skills and APP.skills.clear_session then
    APP.skills.clear_session(source)
  end
  S.last_error = ""
  S.last_user = ""
  S.last_reply = "Session cleared"
  APP.core.append_log("session", "cleared " .. job_session_key(APP, source))
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
    submit_chat_job = function(message, source, opts)
      return submit_chat_job(APP, message, source, opts)
    end,
    dispatch_chat_jobs = function()
      return dispatch_chat_jobs(APP)
    end,
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
