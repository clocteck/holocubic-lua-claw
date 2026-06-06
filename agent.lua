local M = {}

-- 把用户配置的 base URL 收口到可用的 LLM endpoint。
local function endpoint_url(base_url)
  local core = M.APP.core
  local base = core.trim(base_url)
  if base == "" then
    return nil, "llm_base_url is empty"
  end
  base = base:gsub("/+$", "")
  if base:match("/responses$") then
    return base, "responses"
  end
  if base:match("/chat/completions$") then
    return base, "chat"
  end
  if base:find("api.deepseek.com", 1, true) then
    return base .. "/chat/completions", "chat"
  end
  return base .. "/responses", "responses"
end

local function is_deepseek_base()
  local base = M.APP.core.text_or(M.APP.config and M.APP.config.llm_base_url, ""):lower()
  return base:find("api.deepseek.com", 1, true) ~= nil
end

local function plan_is_code_task(task_plan)
  return type(task_plan) == "table"
    and task_plan.execution_required ~= false
    and (task_plan.mode == "new_code" or task_plan.mode == "modify_previous" or task_plan.mode == "debug_previous")
end

local function deepseek_thinking_enabled(task_plan)
  local cfg = M.APP.config or {}
  if cfg.llm_thinking_enabled ~= true then
    return false
  end
  if cfg.llm_thinking_for_code_only ~= false and not plan_is_code_task(task_plan) then
    return false
  end
  return true
end

local function deepseek_reasoning_effort()
  local effort = M.APP.core.text_or(M.APP.config and M.APP.config.llm_reasoning_effort, "high"):lower()
  if effort == "max" then
    return "max"
  end
  return "high"
end

local function llm_transient_http_error(resp_body)
  local text = M.APP.core.text_or(resp_body, ""):lower()
  return text:find("esp_err_http_incomplete_data", 1, true) ~= nil
    or text:find("esp_err_http_eagain", 1, true) ~= nil
    or text:find("timeout", 1, true) ~= nil
    or text:find("timed out", 1, true) ~= nil
end

local function llm_output_token_limit(source, task_plan, deepseek_thinking)
  if type(source) == "table" and source.router_call then
    return 700
  end
  if plan_is_code_task(task_plan) then
    -- Embedded HTTP becomes unreliable with very large DeepSeek thinking payloads.
    -- Keep enough room for a full lua_run tool call without inviting huge reasoning JSON.
    return deepseek_thinking and 8192 or 6144
  end
  return deepseek_thinking and 6144 or 4096
end

local function llm_request_timeout(source, task_plan)
  local APP = M.APP
  local core = APP.core
  local request_timeout = tonumber(APP.config.llm_timeout_ms) or 45000
  request_timeout = core.clamp(request_timeout, 5000, 120000)
  if type(source) == "table" and source.router_call then
    return math.min(request_timeout, 12000)
  end
  if plan_is_code_task(task_plan) then
    return math.min(request_timeout, 30000)
  end
  return request_timeout
end

local function task_is_code_action(plan)
  return type(plan) == "table"
    and (plan.mode == "new_code" or plan.mode == "modify_previous" or plan.mode == "debug_previous")
end

-- 判断 LLM 配置是否完整。
local function chat_messages(input, instructions)
  local messages = {}
  if type(instructions) == "string" and instructions ~= "" then
    messages[#messages + 1] = {
      role = "system",
      content = instructions,
    }
  end
  messages[#messages + 1] = {
    role = "user",
    content = input,
  }
  return messages
end

local function normalize_chat_response(resp)
  if type(resp) ~= "table" or resp.error then
    return resp
  end
  local choice = type(resp.choices) == "table" and resp.choices[1] or nil
  local msg = type(choice) == "table" and choice.message or nil
  if type(msg) ~= "table" then
    return resp
  end

  local output = {}
  local content = type(msg.content) == "string" and msg.content or ""
  local reasoning_content = type(msg.reasoning_content) == "string" and msg.reasoning_content or ""
  if content ~= "" then
    output[#output + 1] = {
      type = "message",
      content = {
        { type = "output_text", text = content },
      },
    }
  end

  local tool_calls = type(msg.tool_calls) == "table" and msg.tool_calls or {}
  for i = 1, #tool_calls do
    local tc = tool_calls[i]
    local fn = type(tc) == "table" and tc["function"] or nil
    if type(fn) == "table" then
      output[#output + 1] = {
        type = "function_call",
        id = tc.id,
        call_id = tc.id,
        name = fn.name,
        arguments = fn.arguments or "{}",
      }
    end
  end

  return {
    id = resp.id,
    output = output,
    output_text = content,
    reasoning_content = reasoning_content,
    reasoning_chars = #reasoning_content,
    finish_reason = type(choice) == "table" and choice.finish_reason or nil,
  }
end

local function llm_configured()
  local APP = M.APP
  return APP.config.llm_base_url ~= "" and APP.config.llm_api_key ~= "" and APP.config.llm_model ~= ""
end

local function safe_session_part(text, fallback)
  text = M.APP.core.text_or(text, fallback or "")
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

local function session_key(source)
  local APP = M.APP
  local core = APP.core
  source = type(source) == "table" and source or {}
  local channel = core.text_or(source.channel, "web")
  local chat_id = core.text_or(source.chat_id, channel)
  return safe_session_part(channel, "web") .. ":" .. safe_session_part(chat_id, channel)
end

local function session_label(source, fallback_text)
  local APP = M.APP
  local core = APP.core
  source = type(source) == "table" and source or {}
  local title = core.trim(source.title)
  if title ~= "" then
    return core.short_text(title, 80)
  end
  local channel = core.text_or(source.channel, "web")
  local chat_id = core.text_or(source.chat_id, channel)
  local text = core.normalize_space(fallback_text or "")
  if text ~= "" then
    return core.short_text(text, 60)
  end
  return channel .. ":" .. core.short_text(chat_id, 32)
end

local function ensure_history_state()
  local APP = M.APP
  APP.histories = type(APP.histories) == "table" and APP.histories or {}
  APP.sessions = type(APP.sessions) == "table" and APP.sessions or {}
  return APP.histories, APP.sessions
end

local function touch_session(source, last_text)
  local APP = M.APP
  local core = APP.core
  local _, sessions = ensure_history_state()
  local key = session_key(source)
  source = type(source) == "table" and source or {}
  local sess = sessions[key]
  if type(sess) ~= "table" then
    sess = {
      key = key,
      channel = core.text_or(source.channel, "web"),
      chat_id = core.text_or(source.chat_id, "web"),
      title = "",
      created_ms = core.now_ms(),
      updated_ms = 0,
      turns = 0,
    }
    sessions[key] = sess
  end
  sess.channel = core.text_or(source.channel, sess.channel or "web")
  sess.chat_id = core.text_or(source.chat_id, sess.chat_id or "web")
  sess.title = sess.title ~= "" and sess.title or session_label(source, last_text)
  if last_text and last_text ~= "" then
    sess.last_text = core.short_text(core.normalize_space(last_text), 120)
  end
  sess.updated_ms = core.now_ms()
  return sess
end

local function history_for_source(source)
  local histories = ensure_history_state()
  local key = session_key(source)
  local history = histories[key]
  if type(history) ~= "table" then
    history = {}
    histories[key] = history
  end
  touch_session(source)
  return history, key
end

local function clear_history_for_source(source)
  local APP = M.APP
  local histories = ensure_history_state()
  histories[session_key(source)] = {}
  touch_session(source, "Session cleared")
  return true
end

local function append_history(source, role, content)
  local history = history_for_source(source)
  history[#history + 1] = {
    role = role,
    content = M.APP.core.text_or(content, ""),
    at = M.APP.core.now_ms(),
  }
  touch_session(source, content)
  return history
end

local function public_message(item)
  local core = M.APP.core
  item = type(item) == "table" and item or {}
  return {
    role = core.text_or(item.role, "message"),
    content = core.text_or(item.content, ""),
    at = tonumber(item.at) or 0,
  }
end

local function session_history_snapshot(key_or_source, limit)
  local APP = M.APP
  local core = APP.core
  ensure_history_state()
  local key = type(key_or_source) == "string" and key_or_source or session_key(key_or_source)
  local history = APP.histories[key] or {}
  limit = core.clamp(tonumber(limit) or 40, 1, 120)
  local start_index = #history - limit + 1
  if start_index < 1 then start_index = 1 end
  local messages = {}
  for i = start_index, #history do
    messages[#messages + 1] = public_message(history[i])
  end
  local sess = APP.sessions[key] or { key = key }
  return {
    ok = true,
    session = sess,
    messages = messages,
  }
end

local function sessions_list()
  local APP = M.APP
  local core = APP.core
  ensure_history_state()
  local out = {}
  for key, sess in pairs(APP.sessions) do
    if type(sess) == "table" then
      local history = APP.histories[key] or {}
      out[#out + 1] = {
        key = key,
        channel = core.text_or(sess.channel, ""),
        chat_id = core.text_or(sess.chat_id, ""),
        title = core.text_or(sess.title, key),
        last_text = core.text_or(sess.last_text, ""),
        created_ms = tonumber(sess.created_ms) or 0,
        updated_ms = tonumber(sess.updated_ms) or 0,
        turns = math.floor(#history / 2),
        messages = #history,
      }
    end
  end
  table.sort(out, function(a, b)
    return (tonumber(a.updated_ms) or 0) > (tonumber(b.updated_ms) or 0)
  end)
  return { ok = true, sessions = out }
end

local function clear_session_history(key_or_source)
  local APP = M.APP
  ensure_history_state()
  local key = type(key_or_source) == "string" and key_or_source or session_key(key_or_source)
  APP.histories[key] = {}
  if type(APP.sessions[key]) == "table" then
    APP.sessions[key].last_text = "Session cleared"
    APP.sessions[key].updated_ms = APP.core.now_ms()
  end
  return true
end

local function text_has_code_explanation(text)
  text = M.APP.core.text_or(text, "")
  local lower = text:lower()
  return text:find("说明", 1, true)
    or text:find("解释", 1, true)
    or text:find("讲解", 1, true)
    or text:find("实现过程", 1, true)
    or text:find("实现原理", 1, true)
    or text:find("代码实现", 1, true)
    or text:find("怎么实现", 1, true)
    or lower:find("explain", 1, true)
    or lower:find("how it works", 1, true)
    or lower:find("implementation", 1, true)
end

local function wants_code_explanation(text, source)
  if text_has_code_explanation(text) then
    return true
  end
  local history = history_for_source(source)
  local checked = 0
  for i = #history, 1, -1 do
    local item = history[i]
    if type(item) == "table" and item.role == "user" then
      checked = checked + 1
      if text_has_code_explanation(item.content) then
        return true
      end
      if checked >= 3 then
        break
      end
    end
  end
  return false
end

local function text_has_any(text, words)
  text = M.APP.core.text_or(text, "")
  for i = 1, #words do
    if text:find(words[i], 1, true) then
      return true
    end
  end
  return false
end

local function destructive_delete_guard(user_text)
  local core = M.APP.core
  local text = core.text_or(user_text, "")
  local lower = text:lower()
  local wants_delete = text_has_any(text, { "删除", "删掉", "清空", "移除", "抹掉" })
    or lower:find("delete", 1, true) ~= nil
    or lower:find("remove", 1, true) ~= nil
    or lower:find("rm ", 1, true) ~= nil
    or lower:find("rmdir", 1, true) ~= nil
  if not wants_delete then
    return nil
  end

  local path = text:match("(/sd[%w%p]*)") or ""
  path = path:gsub("[，。；;,%s]+$", "")
  local path_lower = path:lower()
  local mentions_dir = text_has_any(text, { "文件夹", "目录", "整个", "所有", "全部", "递归" })
    or lower:find("folder", 1, true) ~= nil
    or lower:find("directory", 1, true) ~= nil
    or lower:find("recursive", 1, true) ~= nil
    or lower:find("rmdir", 1, true) ~= nil
  local broad_path = path_lower == "/sd" or path_lower == "/sd/" or path_lower == "/sd/apps" or path_lower == "/sd/apps/"
  if broad_path or mentions_dir then
    return "抱歉，这是危险操作，我不能删除目录、递归删除，或删除 `/sd` 这类宽路径。请改为指定单个文件，并先确认你确实要删除。"
  end
  if path ~= "" then
    return "删除单个文件需要明确确认。我还没有执行删除。请回复：`确认删除 " .. path .. "`。"
  end
  return "删除操作需要先明确具体的单个文件路径，并再次确认；我还没有执行任何删除。"
end

local function execution_ledger_path()
  return M.APP.APP_DIR .. "/execution_ledger.jsonl"
end

local LEDGER_LIMIT = 160
local LEDGER_FLUSH_EVERY = 10
local ledger_path_cache = ""
local ledger_lines_cache = nil
local ledger_dirty = 0

local function simple_checksum(text)
  text = M.APP.core.text_or(text, "")
  local h = 0
  for i = 1, #text do
    h = (h * 131 + text:byte(i)) % 1000000007
  end
  return tostring(h)
end

local function load_ledger_lines(path, limit)
  local APP = M.APP
  local core = APP.core
  limit = tonumber(limit) or LEDGER_LIMIT
  if ledger_lines_cache and ledger_path_cache == path then
    return ledger_lines_cache
  end
  local lines = {}
  local raw = core.read_text_file(path)
  if raw and raw ~= "" then
    for old in raw:gmatch("[^\r\n]+") do
      lines[#lines + 1] = old
    end
  end
  while #lines > limit do
    table.remove(lines, 1)
  end
  ledger_path_cache = path
  ledger_lines_cache = lines
  ledger_dirty = 0
  return lines
end

local function flush_ledger(path)
  if not ledger_lines_cache or ledger_dirty <= 0 then
    return true, nil
  end
  local ok, err = M.APP.core.write_text_file(path, table.concat(ledger_lines_cache, "\n"))
  if ok then
    ledger_dirty = 0
  end
  return ok, err
end

local function append_jsonl_limited(path, entry, limit, force_flush)
  local APP = M.APP
  local core = APP.core
  limit = tonumber(limit) or LEDGER_LIMIT
  entry = type(entry) == "table" and entry or {}
  entry.at = tonumber(entry.at) or core.now_ms()
  local line = core.safe_json_encode(entry)
  if not line then
    return false, "ledger encode failed"
  end
  local lines = load_ledger_lines(path, limit)
  lines[#lines + 1] = line
  while #lines > limit do
    table.remove(lines, 1)
  end
  ledger_dirty = ledger_dirty + 1
  if force_flush or ledger_dirty >= LEDGER_FLUSH_EVERY then
    return flush_ledger(path)
  end
  return true, nil
end

local function append_ledger(entry)
  local force_flush = type(entry) == "table" and entry.event == "turn_final"
  local ok, err = append_jsonl_limited(execution_ledger_path(), entry, LEDGER_LIMIT, force_flush)
  if not ok and M.APP and M.APP.core then
    M.APP.core.append_log("warn", M.APP.core.short_text(err or "ledger failed", 120))
  end
end

local function execution_ledger(limit)
  local APP = M.APP
  local core = APP.core
  local out = {}
  limit = core.clamp(limit or 40, 1, LEDGER_LIMIT)
  local lines = load_ledger_lines(execution_ledger_path(), LEDGER_LIMIT)
  for i = 1, #lines do
    local item = core.safe_json_decode(lines[i])
    if type(item) == "table" then
      out[#out + 1] = item
    end
  end
  while #out > limit do
    table.remove(out, 1)
  end
  return { ok = true, entries = out }
end

local function classify_task(user_text, source)
  local core = M.APP.core
  local text = core.text_or(user_text, "")
  local lower = text:lower()
  -- 先用本地规则给一个保守 fallback，后续 model_route_task 可以再按语义修正。
  local explicit_text_only = text_has_any(text, {
    "说明", "解释", "讲解", "怎么看", "为什么", "原因", "分析一下", "帮我分析",
    "有没有问题", "会有问题吗", "是否合理", "先文字", "只文字", "不要运行",
    "不用运行", "别运行", "不要执行", "不用执行", "别执行",
    "先说想法", "先分析", "先不要改", "先别改", "先不改", "先不要写",
    "先别写", "先不要实现", "先别实现", "只回答", "只回复",
  }) or lower:find("explain", 1, true) or lower:find("why", 1, true)
    or lower:find("review", 1, true) or lower:find("do not run", 1, true)
    or lower:find("don't run", 1, true) or lower:find("no run", 1, true)
    or lower:find("text first", 1, true) or lower:find("answer first", 1, true)
    or lower:find("discuss first", 1, true) or lower:find("analysis first", 1, true)
    or lower:find("do not change yet", 1, true) or lower:find("don't change yet", 1, true)
    or lower:find("do not modify yet", 1, true) or lower:find("don't modify yet", 1, true)

  local has_code_context = text:find("```", 1, true) ~= nil
    or text:find("local ", 1, true) ~= nil
    or text:find("function ", 1, true) ~= nil
    or text:find("lv_", 1, true) ~= nil
    or text:find("代码", 1, true) ~= nil
    or text:find("http%.", 1, false) ~= nil
    or lower:find("lua", 1, true) ~= nil
    or lower:find("code", 1, true) ~= nil

  local execution_request = text_has_any(text, {
    "帮我实现", "帮我写", "帮我改", "帮我修",
    "写一个", "运行", "上传", "修复", "帮我测试", "测试一下",
    "直接实现", "直接写", "直接运行", "跑起来",
    "设置", "调整", "调一下", "调高", "调低", "改成", "改到",
    "打开", "关闭", "启动", "停止", "发送", "更新",
  }) or lower:find("implement", 1, true) or lower:find("draw ", 1, true)
    or lower:find("build ", 1, true) or lower:find("fix ", 1, true)
    or lower:find("run ", 1, true) or lower:find("write ", 1, true)

  local text_first_request = explicit_text_only and text_has_any(text, {
    "先文字", "只文字", "先说想法", "先分析", "先不要改", "先别改",
    "先不改", "先不要写", "先别写", "先不要实现", "先别实现",
    "只回答", "只回复", "不要运行", "不用运行", "别运行",
    "不要执行", "不用执行", "别执行",
  })
  if not text_first_request then
    text_first_request = explicit_text_only and (
      lower:find("text first", 1, true) ~= nil
        or lower:find("answer first", 1, true) ~= nil
        or lower:find("discuss first", 1, true) ~= nil
        or lower:find("analysis first", 1, true) ~= nil
        or lower:find("do not change yet", 1, true) ~= nil
        or lower:find("don't change yet", 1, true) ~= nil
        or lower:find("do not modify yet", 1, true) ~= nil
        or lower:find("don't modify yet", 1, true) ~= nil
    )
  end

  local file_inspect_request = text_has_any(text, {
    "读取", "读一下", "查看", "看下", "列目录", "源码", "实现流程",
    "app目录", "app 目录", "Lua文件", "lua文件", "/sd/apps",
  }) or lower:find("source", 1, true) ~= nil
    or lower:find("inspect", 1, true) ~= nil
    or lower:find("list files", 1, true) ~= nil
    or lower:find("/sd/apps", 1, true) ~= nil

  local live_lookup_request = (not text_first_request) and (
    text_has_any(text, {
      "查询", "查一下", "查下", "今天", "今日", "现在", "当前", "最新",
      "价格", "金价", "银价", "黄金", "白银", "新闻", "天气", "汇率",
      "股价", "行情", "报价",
    })
    or lower:find("latest", 1, true) ~= nil
    or lower:find("today", 1, true) ~= nil
    or lower:find("current", 1, true) ~= nil
    or lower:find("price", 1, true) ~= nil
    or lower:find("news", 1, true) ~= nil
    or lower:find("weather", 1, true) ~= nil
  )

  local asks_code = (execution_request and not text_first_request)
    or (file_inspect_request and not text_first_request)
    or (has_code_context and not explicit_text_only and text_has_any(text, { "测试", "调试", "改一下", "调整" }))

  local fresh_creation = text_has_any(text, {
    "帮我实现", "帮我写", "写一个", "实现一个", "新建", "从头", "重新做一个",
  }) or lower:find("draw ", 1, true) or lower:find("build ", 1, true)

  local previous_cue = text_has_any(text, {
    "之前", "上一", "上次", "刚才", "刚才代码", "继续", "基于", "基础上", "保留",
    "错误", "报错", "失败", "改一下", "调整",
  }) or lower:find("previous", 1, true) or lower:find("last", 1, true)
    or lower:find("continue", 1, true) or lower:find("fix", 1, true)

  local visual = text_has_any(text, {
    "屏幕", "面板", "动画", "Canvas", "LVGL", "UI",
  }) or lower:find("lvgl", 1, true) or lower:find("canvas", 1, true)

  local mode = "answer"
  if asks_code then
    if previous_cue and not fresh_creation then
      mode = text_has_any(text, { "报错", "错误", "失败" }) and "debug_previous" or "modify_previous"
    else
      mode = "new_code"
    end
  elseif previous_cue then
    mode = text_has_any(text, { "报错", "错误", "失败" })
      and "debug_previous" or "inspect"
  end

  if file_inspect_request and not execution_request and mode == "new_code" then
    mode = "inspect"
  end

  if text_first_request then
    mode = has_code_context and "code_review" or "answer"
  elseif explicit_text_only and not execution_request then
    mode = file_inspect_request and "inspect" or (has_code_context and "code_review" or "answer")
  end

  local execution_required = mode == "new_code" or mode == "modify_previous" or mode == "debug_previous" or file_inspect_request or mode == "live_lookup"
  if text_first_request then
    execution_required = false
  elseif explicit_text_only and not execution_request and not file_inspect_request then
    execution_required = false
  end
  local allow_text_only = not execution_required
  local target = text_first_request and "unknown" or (mode == "live_lookup" and "service" or (visual and "panel" or ((execution_required or has_code_context or file_inspect_request) and "service" or "unknown")))
  local confidence = text_first_request and 0.75 or ((execution_request or file_inspect_request or mode == "live_lookup") and 0.9 or (has_code_context and 0.65 or 0.5))

  return {
    mode = mode,
    needs_history = mode == "modify_previous" or mode == "debug_previous",
    target = target,
    has_code_context = has_code_context,
    execution_required = execution_required,
    allow_text_only = allow_text_only,
    text_first_request = text_first_request,
    live_lookup_hint = live_lookup_request == true,
    confidence = confidence,
    priority = "latest_user_request",
    note = text_first_request
      and "The user explicitly asked for a text-first answer. Let the model judge the semantics, but do not force tools in this turn."
      or (mode == "live_lookup"
      and "Current external information lookup: use web search if available, otherwise use service HTTP through code_runner; do not use Panel."
      or (mode == "inspect"
      and "Inspect real files through app_inspect or service tools; do not answer from memory."
      or (execution_required
      and (mode == "new_code"
        and "Fresh implementation: do not replace the request with an unrelated recent artifact."
        or "Use recent artifacts only if they match the current request.")
      or (live_lookup_request
        and "Possible current-info wording detected, but semantic routing should decide whether live lookup is actually needed."
        or "Text answer is allowed; code-looking input may be context rather than an execution request.")))),
  }
end

local function summarize_tool_args(args_json)
  local APP = M.APP
  local core = APP.core
  local args = {}
  if type(args_json) == "table" then
    args = args_json
  elseif type(args_json) == "string" and args_json ~= "" then
    local parsed = core.safe_json_decode(args_json)
    if type(parsed) == "table" then
      args = parsed
    end
  end
  local out = {}
  for k, v in pairs(args) do
    if k ~= "code" then
      out[k] = v
    end
  end
  local code = core.text_or(args.code, "")
  if code ~= "" then
    out.code_bytes = #code
    out.code_checksum = simple_checksum(code)
    out.code_preview = core.utf8_prefix(code:gsub("\r\n", "\n"), 500)
  end
  return out
end

local function summarize_tool_output(output)
  local APP = M.APP
  local core = APP.core
  local doc = core.safe_json_decode(output)
  if type(doc) ~= "table" then
    return { raw = core.short_text(output, 500) }
  end
  if type(doc.results) == "table" or type(doc.items) == "table" or core.text_or(doc.source, "") ~= "" then
    return {
      ok = doc.ok,
      status = doc.status,
      source = core.text_or(doc.source, ""),
      url = core.text_or(doc.url, ""),
      title = core.short_text(doc.title or "", 160),
      excerpt = core.short_text(doc.excerpt or "", 400),
      results = doc.results,
      sources = doc.sources,
      items = doc.items,
      error = core.short_text(doc.error or "", 300),
    }
  end
  return {
    ok = doc.ok,
    target = doc.target,
    phase = doc.phase,
    error = core.short_text(doc.error or "", 300),
    stdout = core.utf8_prefix(core.text_or(doc.stdout, ""), 500),
    result = core.short_text(doc.result or "", 300),
    code_checksum = core.text_or(doc.code_checksum, ""),
    code_bytes = tonumber(doc.code_bytes) or nil,
  }
end

-- 判断用户是否已经在要求执行，而不是继续听方案。
local function user_expects_action(text)
  text = M.APP.core.text_or(text, "")
  local lower = text:lower()
  if lower:find("implement", 1, true)
    or lower:find("run ", 1, true)
    or lower:find("fix ", 1, true)
    or lower:find("build ", 1, true)
    or lower:find("write ", 1, true)
    or lower:find("do it", 1, true) then
    return true
  end

  if text_has_any(text, {
    "帮我实现", "帮我写", "帮我改", "帮我修", "帮我上传", "帮我测试",
    "直接实现", "直接写", "直接运行", "上代码",
    "运行代码", "写代码", "跑起来",
    "设置", "调整", "调一下", "调高", "调低", "改成", "改到",
    "打开", "关闭", "启动", "停止", "发送", "更新",
    "继续做", "继续写", "继续实现", "接着做", "接着写", "接着改",
    "从头实现", "完整实现",
  }) then
    return true
  end

  if text_has_any(text, { "好的", "可以", "行", "开始", "继续", "来", "上" })
    and text_has_any(text, { "实现", "运行", "做", "写", "代码" }) then
    return true
  end
  return false
end

-- 用户要的是实现/接入时，单纯探测环境不能算完成。
local function user_expects_implementation(text)
  text = M.APP.core.text_or(text, "")
  local lower = text:lower()
  if lower:find("implement", 1, true)
    or lower:find("build ", 1, true)
    or lower:find("write ", 1, true) then
    return true
  end
  return text_has_any(text, {
    "帮我实现", "帮我做", "帮我写", "帮我改", "帮我修",
    "直接实现", "直接写", "上代码",
    "写代码", "跑起来", "继续做", "继续写", "继续实现",
    "接着做", "接着写", "接着改",
    "从头实现", "完整实现",
  })
end

local function short_action_confirmation(text)
  text = M.APP.core.trim(text)
  if text == "" or #text > 48 then
    return false
  end
  return text_has_any(text, {
    "开始", "开始写", "开写", "开干", "写", "写吧", "做", "做吧",
    "继续", "继续写", "继续做", "接着写", "接着做", "接着改",
    "可以", "好的", "行", "来", "上", "上代码",
  })
end

local function recent_user_expects_implementation(limit, source)
  local history = history_for_source(source)
  local checked = 0
  limit = tonumber(limit) or 6
  for i = #history, 1, -1 do
    local item = history[i]
    if type(item) == "table" and item.role == "user" then
      checked = checked + 1
      if user_expects_implementation(item.content) then
        return true
      end
      if checked >= limit then
        break
      end
    end
  end
  return false
end

local function turn_expects_implementation(text, source)
  if user_expects_implementation(text) then
    return true
  end
  return short_action_confirmation(text) and recent_user_expects_implementation(8, source)
end

local function turn_expects_action(text, source)
  if user_expects_action(text) then
    return true
  end
  return short_action_confirmation(text) and recent_user_expects_implementation(8, source)
end

local function response_looks_like_unexecuted_code(text)
  text = M.APP.core.text_or(text, "")
  local lower = text:lower()
  if text:find("```", 1, true) then
    return true
  end
  if lower:find("local ", 1, true) and lower:find("function", 1, true) then
    return true
  end
  return lower:find("http.get", 1, true)
    or lower:find("lv_", 1, true)
    or lower:find("return m", 1, true)
    or lower:find("require%(", 1, false) ~= nil
end

local function response_looks_like_deferral(text)
  text = M.APP.core.text_or(text, "")
  local lower = text:lower()
  if lower:find("if you want", 1, true)
    or lower:find("if needed", 1, true)
    or lower:find("tell me which", 1, true)
    or lower:find("which part", 1, true)
    or text_has_any(text, { "需要你确认", "请确认" }) then
    return true
  end
  return text_has_any(text, {
    "需要你确认", "请确认", "等待返回",
  })
end

-- 不在这里判断用户意图，只判断“这条无工具回复值得让模型自审一次”。
local function should_review_no_tool_response(user_text, previous_text, task_plan, source)
  local execution_required = type(task_plan) == "table" and task_plan.execution_required == true
  if execution_required and response_looks_like_unexecuted_code(previous_text) then
    return true
  end
  if execution_required and response_looks_like_deferral(previous_text) then
    return true
  end
  if execution_required and short_action_confirmation(user_text) and recent_user_expects_implementation(8, source) then
    return true
  end
  return false
end

local function lua_run_looks_probe(args_json, output)
  local core = M.APP.core
  local args = {}
  if type(args_json) == "string" and args_json ~= "" then
    local parsed = core.safe_json_decode(args_json)
    if type(parsed) == "table" then args = parsed end
  elseif type(args_json) == "table" then
    args = args_json
  end
  local doc = core.safe_json_decode(output)
  local code = core.text_or(args.code, "")
  local stdout = type(doc) == "table" and core.text_or(doc.stdout, "") or ""
  local stripped_code = code:gsub("%-%-[^\r\n]*", ""):gsub("%s+", "")
  if stripped_code == "" then
    return true
  end
  local text = (code .. "\n" .. stdout):lower()
  local changed_state = text_has_any(code, {
    "lv_", "LV_", "ui_", "file.putcontents", "file.rename", "file.remove",
    "file.mkdir", "httpd.dynamic", "tmr.create", ":alarm", "APP.", "set_screen", "save_config",
  })
  if text_has_any(text, {
    "probe", "探测", "检查环境", "检查模块", "module", "available",
    "exists", "fsinfo", "capability", "http module", "json module", "file module",
    "http true", "json true", "file true", " true yes", "module ok",
  }) then
    return true
  end
  if (not changed_state) and text_has_any(text, {
    "http.get", "http.post", "http.request", "https://", "http://",
    " status", " body", " body ", "response body", "api ",
  }) then
    return true
  end
  if not changed_state and stdout == "" then
    return true
  end
  return false
end

local function lua_run_reads_source_file(args_json, output)
  local core = M.APP.core
  local args = {}
  if type(args_json) == "string" and args_json ~= "" then
    local parsed = core.safe_json_decode(args_json)
    if type(parsed) == "table" then args = parsed end
  elseif type(args_json) == "table" then
    args = args_json
  end
  local doc = core.safe_json_decode(output)
  if type(doc) ~= "table" or doc.ok ~= true then
    return false
  end
  local stdout = core.trim(core.text_or(doc.stdout, ""))
  if stdout == "" then
    return false
  end
  local code = core.text_or(args.code, "")
  if code:find("file%.getcontents%s*%(", 1, false) then
    return true
  end
  if code:find("file%.open%s*%([^,%)]-,%s*['\"]r", 1, false) then
    return true
  end
  if code:find("file%.open%s*%([^,%)]-%)", 1, false)
    and (code:find(":read%s*%(", 1, false) or code:find("%.read%s*%(", 1, false)) then
    return true
  end
  return false
end

local function lua_run_needs_followup(user_text, args_json, output, task_plan, source)
  if type(task_plan) == "table" then
    if task_plan.mode == "live_lookup" then
      local doc = M.APP.core.safe_json_decode(output)
      local stdout = type(doc) == "table" and M.APP.core.trim(M.APP.core.text_or(doc.stdout, "")) or ""
      return stdout == ""
    end
    if task_plan.mode == "inspect" then
      return not lua_run_reads_source_file(args_json, output)
    end
    if task_plan.execution_required ~= true then
      return false
    end
  elseif not turn_expects_implementation(user_text, source) then
    return false
  end
  return lua_run_looks_probe(args_json, output)
end

local function tool_reply_can_be_fallback(name, args_json, output, user_text, task_plan, source)
  if name == "activate_skill" then
    return false
  end
  if name == "get_panel_history" or name == "get_panel_artifacts"
    or name == "get_code_capabilities" or name == "preflight_lua" then
    return false
  end
  if name == "lua_run" and lua_run_needs_followup(user_text, args_json, output, task_plan, source) then
    return false
  end
  return true
end

local function lua_stdout_fallback(output, task_plan)
  local core = M.APP.core
  local doc = core.safe_json_decode(output)
  if type(doc) ~= "table" or doc.ok ~= true then
    return ""
  end
  local stdout = core.trim(core.text_or(doc.stdout, ""))
  if stdout == "" then
    return ""
  end
  if type(task_plan) == "table" and task_plan.mode == "live_lookup" then
    return "查询结果：\n" .. core.short_text(stdout, 1200)
  end
  local target = core.text_or(doc.target, "")
  if target == "panel" then
    return "Panel 代码已运行，输出：\n" .. core.short_text(stdout, 1200)
  end
  return "代码已运行，输出：\n" .. core.short_text(stdout, 1200)
end

local function user_wants_tool_result_answer(text)
  text = M.APP.core.text_or(text, "")
  local lower = text:lower()
  return text_has_any(text, {
    "查询", "查一下", "查下", "总结", "汇总", "告诉我", "回复", "回答",
    "结果", "多少", "是什么", "有哪些", "列出", "看下", "查看",
  })
    or lower:find("query", 1, true) ~= nil
    or lower:find("search", 1, true) ~= nil
    or lower:find("summarize", 1, true) ~= nil
    or lower:find("summary", 1, true) ~= nil
    or lower:find("tell me", 1, true) ~= nil
    or lower:find("what is", 1, true) ~= nil
    or lower:find("list ", 1, true) ~= nil
end

local function is_context_tool(name)
  return name == "get_panel_history"
    or name == "get_panel_artifacts"
    or name == "get_code_capabilities"
    or name == "preflight_lua"
end

local function is_read_only_evidence_tool(name)
  return is_context_tool(name)
    or name == "get_device_status"
    or name == "memory_recall"
    or name == "memory_list"
    or name == "lookup_context"
end

local function lua_run_error_text(output)
  local core = M.APP.core
  local doc = core.safe_json_decode(output)
  if type(doc) ~= "table" then
    return ""
  end
  local text = core.text_or(doc.error, "")
  local stdout = core.text_or(doc.stdout, "")
  if stdout ~= "" then
    text = text ~= "" and (text .. "\n" .. stdout) or stdout
  end
  if text == "" then
    return ""
  end
  if doc.ok == false
    or text:find("ERR", 1, true)
    or text:find("traceback", 1, true)
    or text:find("attempt to ", 1, true)
    or text:find("bad argument", 1, true)
    or text:find("number has no integer representation", 1, true) then
    return text
  end
  return ""
end

local function lua_run_repairable_error_text(output)
  local text = lua_run_error_text(output)
  if text == "" then
    return ""
  end
  if text:find("panel result timeout", 1, true)
    or text:find("launch panel failed", 1, true)
    or text:find("app.launch missing", 1, true) then
    return ""
  end
  return text
end

local function tool_results_fallback_text(tool_results, task_plan)
  local core = M.APP.core
  local first_error = ""
  local last_stdout = ""
  local last_target = ""
  local saw_error = false
  local saw_success = false
  for i = 1, #(tool_results or {}) do
    local item = tool_results[i]
    if type(item) == "table" and item.name == "lua_run" then
      local doc = core.safe_json_decode(item.output)
      if type(doc) == "table" then
        local err = lua_run_repairable_error_text(item.output)
        if err ~= "" or doc.ok == false then
          saw_error = true
          if first_error == "" then
            first_error = err ~= "" and err or core.text_or(doc.error, "")
          end
        elseif doc.ok == true and not lua_run_needs_followup("", item.arguments, item.output, task_plan) then
          saw_success = true
          last_target = core.text_or(doc.target, "")
          last_stdout = core.trim(core.text_or(doc.stdout, ""))
        end
      end
    end
  end
  if not saw_success then
    return ""
  end
  local prefix = "代码已运行"
  if type(task_plan) == "table" and task_plan.mode == "live_lookup" then
    prefix = "查询已完成"
  elseif last_target == "panel" then
    prefix = "Panel 代码已运行"
  end
  local parts = {}
  if saw_error then
    parts[#parts + 1] = prefix .. "，中间遇到错误后已修复并重新运行成功。"
    if first_error ~= "" then
      parts[#parts + 1] = "之前的错误：" .. core.short_text(first_error:gsub("\r\n", "\n"), 180)
    end
  else
    parts[#parts + 1] = prefix .. "成功。"
  end
  if last_stdout ~= "" then
    parts[#parts + 1] = "输出：\n" .. core.short_text(last_stdout, 1200)
  end
  return table.concat(parts, "\n")
end

local function code_error_notice(output)
  local APP = M.APP
  local core = APP.core
  local text = lua_run_error_text(output)
  if text == "" then
    return ""
  end

  if text:find("panel result timeout", 1, true) then
    return "Panel 超时：没有回传执行结果。"
  end
  if text:find("launch panel failed", 1, true) or text:find("app.launch missing", 1, true) then
    return "Panel 启动失败：无法拉起 Claw Panel。"
  end

  local reason = ""
  if text:find("number has no integer representation", 1, true) then
    reason = "LVGL 坐标或尺寸传了小数。"
  elseif text:find("lv_scr_act", 1, true) and text:find("nil", 1, true) then
    reason = "代码跑在没有 LVGL 的环境。"
  elseif text:find("lv_color_hex", 1, true) and text:find("nil", 1, true) then
    reason = "`lv_color_hex` 不存在，颜色要用 `0xRRGGBB`。"
  elseif text:find("global 'os'", 1, true) or text:find('global "os"', 1, true) then
    reason = "Panel 环境没有 `os`。"
  elseif text:find("require", 1, true) and text:find("not found", 1, true) then
    reason = "引用了设备没有的 Lua 模块。"
  elseif text:find("lv_canvas_create", 1, true) then
    reason = "`lv_canvas_create` 参数不对。"
  elseif text:find("lv_canvas_draw_line", 1, true) and text:find("got no value", 1, true) then
    reason = "`lv_canvas_draw_line` 少传了参数。"
  elseif text:find("register", 1, true) and text:find("number expected, got nil", 1, true) then
    reason = "timer 模式常量是 nil，需改用 `tmr.ALARM_AUTO`。"
  elseif text:find("bad argument", 1, true) then
    reason = "函数参数类型不匹配。"
  elseif text:find("attempt to call a nil value", 1, true) or text:find("attempt to index a nil value", 1, true) then
    reason = "调用了不存在的函数或对象。"
  else
    reason = core.short_text(text:gsub("\n.*$", ""), 90)
  end

  return "代码报错：" .. reason .. "；我会修正后重试。"
end

local function progress_limit(source)
  local APP = M.APP
  local level = APP.config and APP.config.progress_level or "normal"
  if level == "off" then
    return 0
  end
  if level == "verbose" then
    return source and source.channel == "wechat" and 6 or 9
  end
  return source and source.channel == "wechat" and 4 or 6
end

local function reply_char_limit(source)
  local APP = M.APP
  return APP.MAX_REPLY_CHARS
end

local function send_progress_notice(source, text)
  local APP = M.APP
  local core = APP.core
  text = core.short_text(core.normalize_space(text), 220)
  if text == "" then
    return
  end
  core.append_log("progress", text)
  APP.state.last_reply = text
  if APP.ui_api and APP.ui_api.redraw then
    APP.ui_api.redraw()
  end
  if type(source) == "table"
    and source.channel == "wechat"
    and core.text_or(source.chat_id, "") ~= ""
    and APP.wechat and APP.wechat.send_text then
    local ok_call, ok_send, send_err = pcall(APP.wechat.send_text, source.chat_id, text)
    if not ok_call then
      core.append_log("warn", "progress send " .. core.short_text(ok_send, 120))
    elseif not ok_send then
      core.append_log("warn", "progress send " .. core.short_text(send_err, 120))
    end
  end
end

local function decode_tool_args(args_json)
  local core = M.APP.core
  if type(args_json) == "table" then
    return args_json
  end
  if type(args_json) ~= "string" or args_json == "" then
    return {}
  end
  local parsed = core.safe_json_decode(args_json)
  return type(parsed) == "table" and parsed or {}
end

local function display_source_from_args(args)
  local core = M.APP.core
  args = type(args) == "table" and args or {}
  local explicit = core.trim(args.source or args.name or "")
  if explicit ~= "" then
    return core.short_text(explicit, 60)
  end
  local url = core.trim(args.url or "")
  local host = url:match("^https?://([^/%?#]+)") or url:match("^([^/%?#]+)")
  host = core.trim(host or "")
  if host ~= "" then
    return core.short_text(host, 60)
  end
  return ""
end

local function lua_code_looks_visual(code)
  code = M.APP.core.text_or(code, "")
  return code:find("lv_", 1, true)
    or code:find("LV_", 1, true)
    or code:find("ui_scr_act", 1, true)
    or code:find("ui_clear", 1, true)
    or code:find("lvgl", 1, true)
    or code:find("LVGL", 1, true)
end

local function quiet_immediate_tool(name)
  return name == "set_brightness"
    or name == "set_screen_message"
    or name == "memory_store"
    or name == "memory_forget"
    or name == "wechat_send_image"
end

local function tool_start_notice(name, args_json)
  local APP = M.APP
  local core = APP.core
  local args = decode_tool_args(args_json)
  if quiet_immediate_tool(name) then
    return ""
  end
  if name == "activate_skill" then
    return ""
  end
  if name == "web_probe" then
    return "我不凭记忆直接回答，会先通过 HTTP 探测公开来源是否可用。"
  end
  if name == "web_fetch" then
    local source_name = display_source_from_args(args)
    if source_name ~= "" then
      return "我不凭记忆直接回答，正在通过 HTTP 查询 " .. core.short_text(source_name, 60) .. " 的最新信息。"
    end
    return "我不凭记忆直接回答，正在通过 HTTP 查询公开来源的最新信息。"
  end
  if name == "lookup_context" then
    return "我先读取刚才查询到的来源上下文，再整理回复。"
  end
  if name == "lua_run" then
    local code = core.text_or(args.code, "")
    if lua_code_looks_visual(code) then
      if lua_run_looks_probe(args_json, "") then
        return "我先探测 Panel 可用接口。"
      end
      return "这段是 UI/LVGL 代码，我会交给 Claw Panel 运行。"
    end
    if lua_run_looks_probe(args_json, "") then
      return "我先在 ESP Claw service 里查询或探测数据。"
    end
    return "这段不带 UI，我会在 ESP Claw service 里运行并读取结果。"
  end
  if name == "memory_store" then return "我把这条信息整理成长期记忆保存。" end
  if name == "memory_recall" then return "我先查一下长期记忆里有没有相关内容。" end
  if name == "memory_list" then return "我先列出最近保存的长期记忆。" end
  if name == "memory_forget" then return "我会按你的条件清理长期记忆。" end
  if name == "get_code_capabilities" then return "我先读取设备代码能力表。" end
  if name == "preflight_lua" then return "我先做代码预检查。" end
  if name == "get_panel_artifacts" then return "我先查找相关 Panel 作品。" end
  if name == "get_panel_history" then return "我先查看最近的 Panel 运行记录，再判断是否沿用上一版代码。" end
  if name == "inspect_image" then return "我先读取这张本地图片并进行分析。" end
  if name == "wechat_send_image" then return "我准备把这张本地图片发送到微信。" end
  if name == "self_check" then return "我先做一次本地健康检查。" end
  if name == "get_device_status" then return "我先读取设备当前状态。" end
  if name == "set_screen_message" then return "我准备更新设备屏幕上的短文字。" end
  if name == "set_brightness" then return "我准备调整屏幕亮度。" end
  return ""
end

local function tool_result_notice(name, args_json, output)
  local APP = M.APP
  local core = APP.core
  local doc = core.safe_json_decode(output)
  if name == "activate_skill" then
    local args = decode_tool_args(args_json)
    local requested = core.trim(args.skill_id)
    if type(doc) == "table" and doc.ok and doc.skill_id then
      return "成功加载 " .. core.text_or(doc.skill_id, "") .. "，接下来执行实际操作。"
    end
    local err = type(doc) == "table" and core.short_text(doc.error or "", 100) or ""
    local label = requested ~= "" and requested or "Skill"
    if err ~= "" then
      return label .. " 加载失败：" .. err
    end
    return label .. " 加载失败，我会看错误原因。"
  end
  if name == "get_panel_history" then
    if type(doc) ~= "table" or doc.ok == false then
      return "读取 Panel 历史失败，我会按当前上下文继续。"
    end
    local entries = type(doc.entries) == "table" and doc.entries or {}
    if #entries == 0 then
      return "没有找到最近的 Panel 运行记录。"
    end
    return "已读取最近 Panel 记录：" .. core.short_text(entries[1].title or entries[1].id or "", 80)
  end
  if name == "get_panel_artifacts" then
    if type(doc) ~= "table" or doc.ok == false then
      return "读取 Panel 作品失败，我会按当前请求继续。"
    end
    local entries = type(doc.entries) == "table" and doc.entries or {}
    if #entries == 0 then
      return "没有找到相关 Panel 作品。"
    end
    return "已读取相关 Panel 作品：" .. core.short_text(entries[1].title or entries[1].id or "", 80)
  end
  if name == "get_code_capabilities" then
    return "代码能力表已读取。"
  end
  if name == "preflight_lua" then
    if type(doc) == "table" and doc.ok then
      return "代码预检查通过。"
    end
    return "代码预检查发现问题，我会修正后再运行。"
  end
  if name == "lua_run" then
    if type(doc) ~= "table" then
      return "代码运行返回了非标准结果，我继续整理。"
    end
    if doc.ok == false then
      return ""
    end
    if lua_run_looks_probe(args_json, output) then
      return "Panel 接口探测完成，我会用确认过的接口继续。"
    end
    if doc.target == "panel" then
      if doc.queued then
        return "可视化代码已投递到 Claw Panel，但还没有确认执行结果。"
      end
      return "Claw Panel 已执行这段 UI 代码，我继续整理结果。"
    end
    local stdout = core.text_or(doc.stdout, "")
    if stdout ~= "" then
      return "service 代码已跑完，并拿到了输出；我继续根据结果处理。"
    end
    return "service 代码已跑完，我继续判断是否还需要下一步。"
  end
  if name == "inspect_image" and type(doc) == "table" and doc.ok then
    return "图片分析完成，我整理成简短回复。"
  end
  if name == "wechat_send_image" and type(doc) == "table" and doc.ok then
    return "图片已经发出。"
  end
  if name == "self_check" and type(doc) == "table" then
    return "自检完成，我整理检查结果。"
  end
  if name == "web_probe" and type(doc) == "table" then
    local sources = type(doc.sources) == "table" and doc.sources or {}
    if #sources > 0 then
      return "公开来源可用性已检查，我会选择能读到内容的来源继续。"
    end
    return "公开来源探测完成，我继续判断是否需要换来源。"
  end
  if name == "web_fetch" and type(doc) == "table" then
    local source_name = core.trim(doc.source or "")
    if doc.ok == false then
      if source_name ~= "" then
        return source_name .. " 暂时没读到有效内容，我会换来源或说明原因。"
      end
      return "这个公开来源暂时没读到有效内容，我会换来源或说明原因。"
    end
    if source_name ~= "" then
      return "已读到 " .. core.short_text(source_name, 60) .. " 的返回数据，我整理成简短结论。"
    end
    return "已读到公开来源的返回数据，我整理成简短结论。"
  end
  if name == "lookup_context" and type(doc) == "table" then
    return "查询上下文已读取，我整理成简短回复。"
  end
  return ""
end

-- 工具调用后的下一轮仍要带上短历史，避免“补充风格/数量”这类短句丢失上下文。
local function observations()
  local S = M.APP.state
  S.agent_observations = type(S.agent_observations) == "table" and S.agent_observations or {}
  return S.agent_observations
end

local function remember_observation(kind, text)
  local APP = M.APP
  local core = APP.core
  text = core.trim(text)
  if text == "" then
    return
  end
  local obs = observations()
  local key = kind .. "\n" .. text
  for i = 1, #obs do
    if obs[i].key == key then
      obs[i].at = core.now_ms()
      return
    end
  end
  obs[#obs + 1] = {
    key = key,
    kind = kind,
    text = core.utf8_prefix(text, 900),
    at = core.now_ms(),
  }
  while #obs > 36 do
    table.remove(obs, 1)
  end
end

local function collect_abs_paths(value, out, seen)
  out = out or {}
  seen = seen or {}
  if type(value) == "string" then
    for path in value:gmatch("(/sd/[%w_%.%-%+/]+)") do
      if not seen[path] then
        seen[path] = true
        out[#out + 1] = path
      end
    end
  elseif type(value) == "table" then
    for _, v in pairs(value) do
      collect_abs_paths(v, out, seen)
    end
  end
  return out
end

local function infer_listdir_paths(args, output_doc)
  local APP = M.APP
  local core = APP.core
  args = type(args) == "table" and args or {}
  local code = core.text_or(args.code, "")
  local base = code:match("file%.listdir%s*%(%s*['\"]([^'\"]+)['\"]")
    or code:match("file%.list%s*%(%s*['\"]([^'\"]+)['\"]")
  if not base or base == "" then
    return
  end
  base = base:gsub("/+$", "")
  local stdout = type(output_doc) == "table" and core.text_or(output_doc.stdout, "") or ""
  if stdout == "" then
    return
  end
  local count = 0
  for line in stdout:gmatch("[^\r\n]+") do
    local trimmed = core.trim(line)
    if trimmed ~= "" and not trimmed:find("/", 1, true) then
      for name in trimmed:gmatch("[%w_%.%-]+") do
        if name ~= "." and name ~= ".." and name ~= "" then
          remember_observation("path", base .. "/" .. name)
          count = count + 1
          if count >= 40 then
            return
          end
        end
      end
    end
  end
end

local function remember_tool_observations(name, args_json, output)
  local APP = M.APP
  local core = APP.core
  local args = decode_tool_args(args_json)
  local doc = core.safe_json_decode(output)
  local paths = collect_abs_paths({ args, doc, output })
  for i = 1, math.min(#paths, 16) do
    remember_observation("path", paths[i])
  end
  if name == "lua_run" and type(doc) == "table" then
    infer_listdir_paths(args, doc)
    local target = core.text_or(doc.target, "")
    local stdout = core.trim(core.text_or(doc.stdout, ""))
    local err = core.trim(core.text_or(doc.error, ""))
    local code = core.text_or(args.code, "")
    if stdout ~= "" then
      remember_observation("lua_result", "target=" .. target .. " stdout=" .. core.short_text(stdout, 500))
    end
    if err ~= "" then
      remember_observation("lua_error", "target=" .. target .. " error=" .. core.short_text(err, 500))
    end
    if target == "panel" then
      remember_observation("panel_run", "ok=" .. tostring(doc.ok == true)
        .. " phase=" .. core.text_or(doc.phase, "")
        .. " stdout=" .. core.short_text(stdout, 220)
        .. " error=" .. core.short_text(err, 220)
        .. " code=" .. core.short_text(code:gsub("\r\n", "\n"), 500))
    end
  elseif (name == "get_panel_history" or name == "get_panel_artifacts") and type(doc) == "table" then
    local entries = type(doc.entries) == "table" and doc.entries or {}
    for i = 1, math.min(#entries, 5) do
      local e = entries[i]
      if type(e) == "table" then
        remember_observation("panel_context",
          "id=" .. core.text_or(e.id or e.seq, "")
          .. " title=" .. core.short_text(core.text_or(e.title, ""), 80)
          .. " ok=" .. tostring(e.ok ~= false)
          .. " stdout=" .. core.short_text(core.text_or(e.stdout, ""), 180)
          .. " error=" .. core.short_text(core.text_or(e.error, ""), 220))
      end
    end
  elseif (name == "web_probe" or name == "web_fetch" or name == "lookup_context") and type(doc) == "table" then
    if type(doc.sources) == "table" then
      for i = 1, math.min(#doc.sources, 5) do
        local s = doc.sources[i]
        if type(s) == "table" then
          remember_observation("lookup_source",
            core.text_or(s.source, "") .. " status=" .. tostring(s.status or "")
            .. " evidence=" .. core.text_or(s.evidence, s.probe_only and "probe" or "")
            .. " probe_only=" .. tostring(s.probe_only == true)
            .. " url=" .. core.text_or(s.url, ""))
        end
      end
    elseif core.text_or(doc.url, "") ~= "" then
      remember_observation("lookup_source",
        core.text_or(doc.source, "") .. " status=" .. tostring(doc.status or "")
        .. " evidence=" .. core.text_or(doc.evidence, "content")
        .. " url=" .. core.text_or(doc.url, ""))
    end
    if type(doc.items) == "table" then
      for i = 1, math.min(#doc.items, 8) do
        local item = doc.items[i]
        if type(item) == "table" then
          remember_observation("lookup_item",
            "#" .. tostring(item.index or i) .. " " .. core.short_text(core.text_or(item.title, ""), 160)
            .. " source=" .. core.text_or(item.source, ""))
        end
      end
    end
  elseif name == "activate_skill" and type(doc) == "table" and doc.ok then
    remember_observation("skill", "activated=" .. core.text_or(doc.skill_id, "") .. " activation_only=true")
  end
end

local function observation_context(max_items)
  local APP = M.APP
  local core = APP.core
  local obs = observations()
  if #obs == 0 then
    return ""
  end
  max_items = tonumber(max_items) or 14
  local start_index = #obs - max_items + 1
  if start_index < 1 then start_index = 1 end
  local lines = {
    "Known observations from recent tool results:",
    "Use these observed absolute paths, stdout, errors, and ids instead of guessing or reconstructing them.",
  }
  for i = start_index, #obs do
    lines[#lines + 1] = "- [" .. core.text_or(obs[i].kind, "obs") .. "] " .. core.text_or(obs[i].text, "")
  end
  return table.concat(lines, "\n")
end

local function lookup_context_text(max_items)
  local APP = M.APP
  local core = APP.core
  local ctx = type(APP.state.lookup_context) == "table" and APP.state.lookup_context or nil
  if not ctx or (type(ctx.sources) ~= "table" and type(ctx.items) ~= "table") then
    return ""
  end
  local sources = type(ctx.sources) == "table" and ctx.sources or {}
  local items = type(ctx.items) == "table" and ctx.items or {}
  if #sources == 0 and #items == 0 then
    return ""
  end
  max_items = tonumber(max_items) or 12
  local lines = {
    "Recent lookup_context:",
    "Use this first for follow-up questions about previous live lookup sources, item numbers, or provenance.",
    "Sources marked probe_only=true are reachability/status evidence only. Use Items or web_fetch excerpts for page facts.",
    "query=" .. core.text_or(ctx.query, "") .. " kind=" .. core.text_or(ctx.kind, "") .. " at=" .. tostring(ctx.at or 0),
  }
  if #sources > 0 then
    lines[#lines + 1] = "Sources:"
    for i = 1, math.min(#sources, 5) do
      local s = sources[i]
      if type(s) == "table" then
        lines[#lines + 1] = "- " .. core.text_or(s.source, "")
          .. " status=" .. tostring(s.status or "")
          .. " evidence=" .. core.text_or(s.evidence, s.probe_only and "probe" or "")
          .. " probe_only=" .. tostring(s.probe_only == true)
          .. " title=" .. core.short_text(core.text_or(s.title, ""), 100)
          .. " url=" .. core.text_or(s.url, "")
      end
    end
  end
  if #items > 0 then
    lines[#lines + 1] = "Items:"
    for i = 1, math.min(#items, max_items) do
      local item = items[i]
      if type(item) == "table" then
        lines[#lines + 1] = "- #" .. tostring(item.index or i)
          .. " " .. core.short_text(core.text_or(item.title, ""), 160)
          .. " source=" .. core.text_or(item.source, "")
          .. " evidence=" .. core.text_or(item.evidence, "content")
      end
    end
  end
  return table.concat(lines, "\n")
end

local function panel_debug_context(task_plan)
  local APP = M.APP
  local core = APP.core
  if type(task_plan) ~= "table" or task_plan.target ~= "panel" then
    return ""
  end
  if task_plan.mode ~= "debug_previous" and task_plan.mode ~= "modify_previous" then
    return ""
  end
  if not APP.code_runner or not APP.code_runner.panel_history then
    return ""
  end
  local ok, doc = pcall(APP.code_runner.panel_history, 6)
  if not ok or type(doc) ~= "table" or type(doc.entries) ~= "table" or #doc.entries == 0 then
    return ""
  end
  local lines = {
    "Recent Panel context packet:",
    "For debug_previous, prefer the most recent failed panel run. For modify_previous, use the matching prior visual artifact/history.",
  }
  for i = 1, math.min(#doc.entries, 5) do
    local e = doc.entries[i]
    if type(e) == "table" then
      if APP.code_runner.panel_history_get then
        local id = core.text_or(e.id or e.seq, "")
        if id ~= "" then
          local ok_detail, detail = pcall(APP.code_runner.panel_history_get, id)
          if ok_detail and type(detail) == "table" then
            e = detail
          end
        end
      end
      local code = core.text_or(e.code, ""):gsub("\r\n", "\n")
      lines[#lines + 1] =
        "- id=" .. core.text_or(e.id or e.seq, "")
        .. " title=" .. core.short_text(core.text_or(e.title, ""), 70)
        .. " ok=" .. tostring(e.ok ~= false)
        .. " stdout=" .. core.short_text(core.text_or(e.stdout, ""), 120)
        .. " error=" .. core.short_text(core.text_or(e.error, ""), 220)
        .. " code_preview=" .. core.short_text(code, 650)
    end
  end
  return table.concat(lines, "\n")
end

local function append_recent_conversation(parts, limit, source)
  local APP = M.APP
  local core = APP.core
  local history = history_for_source(source)
  if #history == 0 then
    return
  end
  limit = tonumber(limit) or 8
  local start_index = #history - limit + 1
  if start_index < 1 then
    start_index = 1
  end
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Recent conversation before this tool step:"
  for i = start_index, #history do
    local item = history[i]
    if type(item) == "table" then
      local role = core.text_or(item.role, "message")
      local content = core.utf8_prefix(core.text_or(item.content, ""), 900)
      if content ~= "" then
        parts[#parts + 1] = role .. ": " .. content
      end
    end
  end
end

local function append_task_policy(parts, task_plan, source, opts)
  local APP = M.APP
  local core = APP.core
  opts = type(opts) == "table" and opts or {}
  if type(task_plan) ~= "table" then
    return
  end
  local raw_plan = opts.include_plan ~= false and core.safe_json_encode(task_plan) or nil
  if raw_plan then
    parts[#parts + 1] = (opts.plan_label or "Agent task plan:") .. " " .. raw_plan
  end
  parts[#parts + 1] = "Use the task plan as routing context; the latest user request remains authoritative."
  if task_plan.execution_required == true then
    parts[#parts + 1] = "When the latest request asks to change, set, update, start, stop, run, send, or otherwise act, context/status tools are only preparation; complete the action with the appropriate non-read tool."
  end
  if task_plan.text_first_request == true
    or task_plan.execution_required == false
    or task_plan.allow_text_only == true then
    parts[#parts + 1] = "This request may be answered in text; do not call tools merely because code-like context is present."
  end
  if task_plan.mode == "inspect" then
    parts[#parts + 1] = "Inspect means reading real device files. Skill activation or directory listing alone is not enough when the user asked for contents."
    parts[#parts + 1] = "Use observed paths and the request wording to read a small relevant set of files under " .. core.text_or(APP.APP_DIR, "/sd/apps/esp_claw") .. " or the user-named path."
  elseif task_plan.mode == "live_lookup" then
    parts[#parts + 1] = "Live lookup should use structured source tools when available; web_probe is status-only, web_fetch/lookup_context carry content."
    parts[#parts + 1] = "Do not declare the network unavailable from one failed source; final answers should name concise sources."
  elseif task_plan.mode == "new_code" then
    parts[#parts + 1] = "For fresh implementation, build the latest request first and ignore unrelated history."
  elseif task_plan.mode == "modify_previous" or task_plan.mode == "debug_previous" then
    parts[#parts + 1] = "For follow-up code/visual work, use only matching recent artifacts or history; preserve the relevant previous program."
    parts[#parts + 1] = "Interpret the user's complaint semantically: distinguish a request to restore missing behavior from a request to remove behavior. Do not invert the latest request."
  elseif task_plan.needs_history == true then
    parts[#parts + 1] = "Use recent history only when it matches the latest request."
  end
  if task_plan.target == "service" then
    parts[#parts + 1] = "Service-side tasks should not use Panel history/artifacts unless the user mentions screen, Panel, UI, LVGL, canvas, or a visual artifact."
  elseif task_plan.target == "panel" then
    parts[#parts + 1] = "Panel tasks must distinguish code execution success from visible UI confirmation; report queued/timeouts honestly."
    parts[#parts + 1] = "Claw Panel screen is 320x240 pixels; keep every canvas, object, game board, and animation path inside that visible area."
    parts[#parts + 1] = "For visible LVGL objects, set both bg_color and bg_opa=255; objects may be transparent if bg_opa is omitted."
    parts[#parts + 1] = "Panel Lua runs on a small device: keep games cheap. Pre-create grid/cell objects, update style colors in place, avoid creating/deleting many LVGL objects per tick, avoid large per-frame searches, and use only verified input/timer APIs."
  end
  if opts.force_run_now then
    parts[#parts + 1] = "Enough context has been inspected; perform the concrete tool action now instead of gathering more generic context."
  end
end

-- 无工具回复疑似空转时，让模型自己二次判断该聊天还是该执行。
local function force_action_input(user_text, previous_text, task_plan, source)
  local APP = M.APP
  local core = APP.core
  local parts = {
    "Review the original request, recent conversation, and your previous response.",
    "Decide yourself whether the user is asking for a normal text answer or asking you to execute an action now.",
    "Your previous response did not call any tool.",
    "If that previous response has already been shown to the user as an intermediate note, do not repeat it. Continue from it and complete the missing tool work when tool work is still required.",
    "If the user only wanted explanation or discussion, answer concisely.",
    "If the user wanted implementation, running code, fixing, uploading, testing, or continuing a selected task, do not return a code block or plan as the final answer. Activate the appropriate skill and call tools.",
    "For Lua app, UI, HTTP, file, or device-code work, prefer activating code_runner. Do not activate memory_ops unless the user explicitly asks about long-term memory.",
    "If execution is impossible, report the concrete blocker instead of asking for vague confirmation.",
    "Original user request: " .. core.text_or(user_text, ""),
  }
  if type(task_plan) == "table" then
    append_task_policy(parts, task_plan, source)
  end
  local obs = observation_context(12)
  if obs ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = obs
  end
  local panel_ctx = panel_debug_context(task_plan)
  if panel_ctx ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = panel_ctx
  end
  if APP.skills and APP.skills.build_context then
    local ok, skills_text = pcall(APP.skills.build_context, source)
    if ok and type(skills_text) == "string" and skills_text ~= "" then
      parts[#parts + 1] = ""
      parts[#parts + 1] = skills_text
    end
  end
  append_recent_conversation(parts, 8, source)
  if core.text_or(previous_text, "") ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "Previous non-action response:"
    parts[#parts + 1] = core.utf8_prefix(previous_text, 1200)
  end
  return table.concat(parts, "\n")
end

-- 把非终结工具结果写回下一轮输入，避免依赖 previous_response_id 的工具回填协议。
local function tool_followup_input(user_text, tool_results, source, task_plan, force_run_now)
  local APP = M.APP
  local core = APP.core
  local saw_lua_error = false
  local saw_probe = false
  local saw_lua_success = false
  for i = 1, #(tool_results or {}) do
    local item = tool_results[i]
    if type(item) == "table" and item.name == "lua_run" and lua_run_repairable_error_text(item.output) ~= "" then
      saw_lua_error = true
    end
    if type(item) == "table" and item.name == "lua_run"
      and lua_run_repairable_error_text(item.output) == ""
      and not lua_run_needs_followup(user_text, item.arguments, item.output, task_plan, source) then
      local doc = M.APP.core.safe_json_decode(item.output)
      if type(doc) == "table" and doc.ok == true then
        saw_lua_success = true
      end
    end
    if type(item) == "table" and item.name == "lua_run" and lua_run_needs_followup(user_text, item.arguments, item.output, task_plan, source) then
      saw_probe = true
    end
  end
  local parts = {
    "The previous model step called tools. Tool results are below.",
    "Continue the same user request using these results.",
    "Decide whether the original request still requires execution. If it does, continue with tools; if it is complete, summarize the actual result.",
    "If a tool result contains stdout/data that answers the user's request, write the final user-facing answer now. Do not stop after progress text, and do not call more tools unless the requested information is clearly missing.",
    "For action requests, read/status/inspection results are intermediate evidence, not completion. Use them to choose the next concrete action tool unless the user only asked to read or inspect.",
    "Result-present example: if a read tool returns the old value and the later action tool returns ok with the new value, answer with both values in one concise sentence and end the turn.",
    "Result-missing example: if the required action tool fails, times out, or returns no confirmed value after it was attempted, say the result is not confirmed and either continue with the next necessary tool or report the failure. Never write a success summary from a missing action result.",
    "After a final answer with an actual result, do not continue with apologies, summaries, or repeated confirmations unless the user asks another question.",
    "activate_skill only loads operating instructions; context/preflight/history tools do not complete the requested action by themselves.",
    "For Lua app, UI, HTTP, file, or device-code work, use code_runner tools; memory_ops is only for explicit long-term memory operations.",
    "If the current user request is a short style, variant, quantity, or refinement, infer the pending visual/code task from Recent conversation and execute the updated version.",
    "If lua_run returned ok=false or its output contains ERR/traceback/nil-value error text, fix the Lua code and call lua_run again. Do not ask the user unless the error cannot be resolved from the result.",
    "If lua_run Output.error is panel result timeout, launch panel failed, or app.launch missing, do not rewrite the visual code as a fix; report the panel launch/confirmation problem.",
    "After a lua_run error, do not repeat the same failing code. If the user asked to intentionally test an error, the first observed error completes that test; the next lua_run must be the corrected implementation.",
    "For lua_run, the actual code written to the device is exactly Tool Arguments.code. If Output contains code_checksum/code_bytes/code_preview, use them as the execution trace.",
    "Do not describe UI contents, time sources, files written, or network results unless they are visible in Tool Arguments.code, Output.stdout, Output.result, or Output.error.",
    "If there are multiple lua_run calls, distinguish panel UI execution from later service probes; never use a service probe result as if it described the panel UI.",
  }
  append_task_policy(parts, task_plan, source, { force_run_now = force_run_now })
  if saw_lua_error and saw_lua_success then
    parts[#parts + 1] = "A lua_run error occurred earlier, but a later lua_run succeeded. Summarize the successful stdout/result now; do not call more tools or rerun code."
  elseif saw_lua_error then
    parts[#parts + 1] = "A lua_run error has already occurred. Treat the original user request as background only; the immediate task is to run corrected code that avoids the failing API or argument pattern."
  end
  if saw_probe then
    parts[#parts + 1] = "The successful lua_run only probed the environment. Continue with the requested implementation now; do not stop with a probe summary."
  end
  if APP.skills and APP.skills.build_context then
    local ok, skills_text = pcall(APP.skills.build_context, source)
    if ok and type(skills_text) == "string" and skills_text ~= "" then
      parts[#parts + 1] = ""
      parts[#parts + 1] = skills_text
    end
  end
  local obs = observation_context(16)
  if obs ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = obs
  end
  local lookup_ctx = lookup_context_text(12)
  if lookup_ctx ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = lookup_ctx
  end
  local panel_ctx = panel_debug_context(task_plan)
  if panel_ctx ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = panel_ctx
  end
  parts[#parts + 1] = "Original user request: " .. core.text_or(user_text, "")
  if wants_code_explanation(user_text, source) then
    parts[#parts + 1] = "The original request asks for an explanation. If lua_run succeeded, do not call more tools just to explain; summarize how the provided Lua code works using the tool arguments and output."
  end
  append_recent_conversation(parts, 8, source)
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Tool results:"
  for i = 1, #tool_results do
    local item = tool_results[i]
    parts[#parts + 1] = "Tool: " .. core.text_or(item.name, "")
    local arguments = core.text_or(item.arguments, "")
    if arguments ~= "" then
      parts[#parts + 1] = "Arguments:"
      parts[#parts + 1] = core.utf8_prefix(arguments, 7000)
    end
    parts[#parts + 1] = "Output:"
    if item.name == "activate_skill" then
      local doc = core.safe_json_decode(item.output)
      if type(doc) == "table" and doc.ok then
        parts[#parts + 1] = "Skill active: " .. core.text_or(doc.skill_id, "") .. ". Full instructions are in the active skill context above."
        parts[#parts + 1] = "Important: activate_skill is activation_only=true; it did not inspect files, run code, or complete the task. Continue with the concrete tools enabled by this skill."
      else
        parts[#parts + 1] = core.utf8_prefix(core.text_or(item.output, ""), 1200)
      end
    else
      parts[#parts + 1] = core.utf8_prefix(core.text_or(item.output, ""), 9000)
    end
  end
  return table.concat(parts, "\n")
end

local function tool_summary_input(user_text, tool_results, source, task_plan)
  local APP = M.APP
  local core = APP.core
  local saw_lua_error = false
  local saw_lua_success = false
  local parts = {
    "The requested tool work is complete.",
    "Do not call tools. Write the final user-facing answer now.",
    "Use only the tool arguments and outputs below plus known observations. Mention what actually ran or was read.",
    "If stdout contains the requested marker or data, include it concisely in the answer.",
    "If an earlier tool call failed but a later tool call succeeded, say it was repaired instead of claiming there were no failures.",
    "Do not offer to rerun, continue, or wait for confirmation after the requested work is already complete.",
    "End after the final result. One concise sentence is enough for simple device actions; do not add apologies, repeated confirmations, or promises about future behavior.",
    "Result-present example: '当前值是 X，已改到 Y。'",
    "Result-missing example: '没有拿到确认结果，这次修改是否完成还不能确认。'",
    "If the outputs show only queued, timeout, ok=false, or no requested data, use the result-missing pattern rather than a success pattern.",
  }
  if type(source) == "table" and source.channel == "wechat" then
    parts[#parts + 1] = "This answer will be sent to WeChat. Be concise and natural. Use short paragraphs if details are needed; do not paste raw stdout or long code."
  else
    parts[#parts + 1] = "Summarize the result instead of pasting long raw stdout unless the user explicitly asked for raw output."
  end
  local raw_plan = type(task_plan) == "table" and core.safe_json_encode(task_plan) or nil
  if raw_plan then
    parts[#parts + 1] = "Agent task plan: " .. raw_plan
  end
  if type(task_plan) == "table" and task_plan.mode == "live_lookup" then
    parts[#parts + 1] = "For realtime lookup summaries, include concise source names and do not claim the whole network is offline based on one failed URL."
  end
  local obs = observation_context(12)
  if obs ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = obs
  end
  local lookup_ctx = lookup_context_text(12)
  if lookup_ctx ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = lookup_ctx
  end
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Original user request: " .. core.text_or(user_text, "")
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Completed tool results:"
  local result_count = #(tool_results or {})
  local start_index = 1
  if type(task_plan) == "table" and task_plan.mode == "inspect" and result_count > 4 then
    start_index = result_count - 3
  end
  local output_limit = (type(task_plan) == "table" and task_plan.mode == "inspect") and 2800 or 7000
  local trace = {}
  for i = 1, result_count do
    local item = tool_results[i]
    if type(item) == "table" and item.name == "lua_run" then
      local doc = core.safe_json_decode(item.output)
      if type(doc) == "table" then
        local err = lua_run_repairable_error_text(item.output)
        local stdout = core.trim(core.text_or(doc.stdout, ""))
        if err ~= "" or doc.ok == false then
          saw_lua_error = true
          trace[#trace + 1] = tostring(i) .. ". lua_run target=" .. core.text_or(doc.target, "")
            .. " failed: " .. core.short_text(err ~= "" and err or core.text_or(doc.error, ""), 220)
        elseif doc.ok == true then
          saw_lua_success = true
          trace[#trace + 1] = tostring(i) .. ". lua_run target=" .. core.text_or(doc.target, "")
            .. " succeeded" .. (stdout ~= "" and (": " .. core.short_text(stdout, 220)) or "")
        end
      end
    end
  end
  if #trace > 0 then
    parts[#parts + 1] = "Execution trace:"
    for i = 1, math.min(#trace, 8) do
      parts[#parts + 1] = "- " .. trace[i]
    end
    if saw_lua_error and saw_lua_success then
      parts[#parts + 1] = "Important: there was at least one failed lua_run before a later successful lua_run. Reflect that repair path if relevant."
    end
  end
  for i = start_index, result_count do
    local item = tool_results[i]
    if type(item) == "table" then
      parts[#parts + 1] = "Tool: " .. core.text_or(item.name, "")
      local arguments = core.text_or(item.arguments, "")
      if arguments ~= "" then
        parts[#parts + 1] = "Arguments:"
        parts[#parts + 1] = core.utf8_prefix(arguments, 5000)
      end
      parts[#parts + 1] = "Output:"
      parts[#parts + 1] = core.utf8_prefix(core.text_or(item.output, ""), output_limit)
    end
  end
  append_recent_conversation(parts, 6, source)
  return table.concat(parts, "\n")
end

-- 按配置限制历史条数。
local function estimate_tokens(text)
  text = M.APP.core.text_or(text, "")
  local ascii = 0
  for i = 1, #text do
    if text:byte(i) < 128 then
      ascii = ascii + 1
    end
  end
  local non_ascii_bytes = #text - ascii
  return math.ceil((ascii / 4) + (non_ascii_bytes / 2))
end

local function history_message_limit()
  local limit = tonumber(M.APP.config.history_message_char_limit) or 2400
  return M.APP.core.clamp(limit, 400, 12000)
end

local function history_line(item, limit)
  local core = M.APP.core
  item = type(item) == "table" and item or {}
  local role = core.text_or(item.role, "message")
  local content = core.text_or(item.content, "")
  limit = limit or history_message_limit()
  if #content > limit then
    content = core.utf8_prefix(content, limit) .. "\n...(truncated in chat history)"
  end
  return role .. ": " .. content
end

local function history_token_total(source)
  local total = 0
  local history = history_for_source(source)
  for i = 1, #history do
    total = total + estimate_tokens(history_line(history[i], history_message_limit()))
  end
  return total
end

local function recent_history_lines(max_tokens, source)
  local APP = M.APP
  local core = APP.core
  local history = history_for_source(source)
  max_tokens = tonumber(max_tokens) or tonumber(APP.config.history_token_limit) or 8000
  max_tokens = core.clamp(max_tokens, 200, 60000)
  local per_message = math.min(history_message_limit(), 2200)
  local selected = {}
  local used = 0
  for i = #history, 1, -1 do
    local line = history_line(history[i], per_message)
    local tokens = estimate_tokens(line)
    if used + tokens > max_tokens then
      if #selected == 0 then
        local bytes = core.clamp(max_tokens * 4, 300, per_message)
        line = core.utf8_prefix(line, bytes) .. "\n...(truncated to fit history budget)"
        table.insert(selected, 1, line)
      end
      break
    end
    table.insert(selected, 1, line)
    used = used + tokens
  end
  return selected, used
end

local function append_recent_history(parts, max_tokens, source)
  local lines = recent_history_lines(max_tokens, source)
  if #lines == 0 then
    return
  end
  parts[#parts + 1] = "Recent conversation:"
  for i = 1, #lines do
    parts[#parts + 1] = lines[i]
  end
  parts[#parts + 1] = ""
end

local function trim_history(source)
  local APP = M.APP
  local limit = tonumber(APP.config.history_limit) or 0
  local history = history_for_source(source)
  if limit <= 0 then
    clear_history_for_source(source)
    return
  end
  local per_message = history_message_limit()
  for i = 1, #history do
    local item = history[i]
    if type(item) == "table" then
      local content = APP.core.text_or(item.content, "")
      if #content > per_message then
        item.content = APP.core.utf8_prefix(content, per_message) .. "\n...(truncated in chat history)"
      end
    end
  end
  local max_messages = limit * 2
  while #history > max_messages do
    table.remove(history, 1)
  end
  local max_tokens = tonumber(APP.config.history_token_limit) or 12000
  max_tokens = APP.core.clamp(max_tokens, 1000, 60000)
  while #history > 2 and history_token_total(source) > max_tokens do
    table.remove(history, 1)
  end
  touch_session(source)
end

-- 生成模型系统指令。
local function response_instructions(source)
  local core = M.APP.core
  source = type(source) == "table" and source or {}
  return table.concat({
    "You are ESP Claw, a small device agent running on an embedded Lua app.",
    "Answer briefly and plainly.",
    "Treat the latest user request as authoritative; recent history, memory, and task plans are context.",
    "Use skills and tools for real device work; when a skill document is active, follow it as operating instructions.",
    "Use provided memory only when it is relevant to the current user request.",
    "For long-term memory operations, use memory_ops; for code, files, HTTP, device state, or UI work, use the relevant execution/inspection skills instead.",
    "Code-looking text may be context. Execute only when the user asks to implement, run, modify, fix, upload, test, inspect, or continue actual work.",
    "If the user says '先文字回复', '先说想法', '先分析', '先不要改', or '只回答', answer in text for this turn.",
    "When answering without tools, describe results as expected or inferred; never imply execution or file inspection happened.",
    "Use live lookup only for current external/public facts; local device state and files should use local skills/tools.",
    "Raw memory files are not default decision input. If the user explicitly asks to inspect memory files, read them through inspection tools and summarize safely.",
    "When writing device code, do not invent APIs. Use active skill docs, capabilities, or observed tool results; otherwise probe first or choose a verified simpler API.",
    "For code tasks, keep reasoning concise and proceed to the necessary tool call promptly.",
    "For multi-step work, make the visible process feel interactive: give short user-facing progress notes and final action summaries. Do not reveal hidden chain-of-thought; summarize observable steps, decisions, and results.",
    "When you call tools for a user-visible task, include one short user-facing progress sentence before the tool call when the API supports assistant text plus tool calls. Say what you understood and what you are about to verify or run; do not present it as the final result.",
    "Completion boundary: after tools return enough evidence and you have written the final user-facing result, stop this turn. Do not add extra apologies, recaps, repeated confirmations, or 'next time' promises unless the latest user explicitly asks for them.",
    "No-result boundary: if a required tool returns no usable result, an error, a timeout, or only an unconfirmed queued state, do not imply success. Continue with a needed tool if one is available; otherwise state concisely that no confirmed result was obtained.",
    "For action requests, reading status or context is only a precondition. Do not use a no-result final answer just because only the read step has run; continue to the concrete action tool when available.",
    "Never delete directories or broad paths such as /sd. For a single file delete, ask for explicit confirmation first and do not delete in the same turn.",
    "Summaries of tool work must be grounded in tool arguments and outputs; queued/timeouts are not confirmed success.",
    "Current configured underlying LLM model: " .. core.text_or(M.APP.config.llm_model, "unknown"),
    "Current configured LLM base URL: " .. core.text_or(M.APP.config.llm_base_url, "unknown"),
    "When asked what model you are, say you are ESP Claw, an embedded device agent, and name the configured underlying LLM model above.",
    "Current channel: " .. core.text_or(source.channel, "web"),
    "Current chat id: " .. core.text_or(source.chat_id, ""),
  }, "\n")
end

-- 构造包含记忆、Skill catalog、任务 plan 和短历史的用户输入。
local function response_user_input(user_text, source, task_plan)
  local APP = M.APP
  local core = APP.core
  local parts = {}
  -- Prompt 顺序很重要：长期记忆和 Skill catalog 是背景，最新 user 放在最后。
  if APP.memory and APP.memory.build_context then
    local ok, memory_text = pcall(APP.memory.build_context, user_text, source)
    if ok and type(memory_text) == "string" and memory_text ~= "" then
      parts[#parts + 1] = memory_text
      parts[#parts + 1] = ""
    end
  end
  if APP.skills and APP.skills.build_context then
    local ok, skills_text = pcall(APP.skills.build_context, source)
    if ok and type(skills_text) == "string" and skills_text ~= "" then
      parts[#parts + 1] = skills_text
      parts[#parts + 1] = ""
    end
  end
  if type(task_plan) == "table" then
    append_task_policy(parts, task_plan, source, { plan_label = "Agent task plan:" })
    parts[#parts + 1] = ""
  end
  local lookup_ctx = lookup_context_text(12)
  if lookup_ctx ~= "" and (type(task_plan) ~= "table" or task_plan.mode == "live_lookup" or task_plan.needs_history) then
    parts[#parts + 1] = lookup_ctx
    parts[#parts + 1] = ""
  end
  local obs = observation_context(14)
  if obs ~= "" then
    parts[#parts + 1] = obs
    parts[#parts + 1] = ""
  end
  local panel_ctx = panel_debug_context(task_plan)
  if panel_ctx ~= "" then
    parts[#parts + 1] = panel_ctx
    parts[#parts + 1] = ""
  end
  append_recent_history(parts, math.min(tonumber(APP.config.history_token_limit) or 8000, 8000), source)
  parts[#parts + 1] = "User: " .. user_text
  return table.concat(parts, "\n")
end

-- 生成下一轮 prompt 预览，供 WebUI 调试 memory/skills/history 注入内容。
local function prompt_preview(user_text, source)
  local APP = M.APP
  local core = APP.core
  source = type(source) == "table" and source or {}
  user_text = core.trim(user_text)
  if user_text == "" then
    user_text = APP.state.last_user ~= "" and APP.state.last_user or "Preview next user request"
  end
  local task_plan = classify_task(user_text, source)

  local memory_text = ""
  if APP.memory and APP.memory.build_context then
    local ok, text = pcall(APP.memory.build_context, user_text, source)
    if ok and type(text) == "string" then
      memory_text = text
    end
  end

  local skills_text = ""
  if APP.skills and APP.skills.build_context then
    local ok, text = pcall(APP.skills.build_context, source)
    if ok and type(text) == "string" then
      skills_text = text
    end
  end

  local history_parts = {}
  append_recent_history(history_parts, math.min(tonumber(APP.config.history_token_limit) or 8000, 8000), source)

  local history_text = table.concat(history_parts, "\n")
  local input = response_user_input(user_text, source, task_plan)
  local instructions = response_instructions(source)
  return {
    ok = true,
    user_text = user_text,
    plan = task_plan,
    source = {
      channel = core.text_or(source.channel, "web"),
      chat_id = core.text_or(source.chat_id, "web"),
    },
    instructions = core.utf8_prefix(instructions, 6000),
    memory = core.utf8_prefix(memory_text, 7000),
    skills = core.utf8_prefix(skills_text, 7000),
    history = core.utf8_prefix(history_text, 5000),
    input = core.utf8_prefix(input, 14000),
    sizes = {
      instructions = #instructions,
      memory = #memory_text,
      skills = #skills_text,
      history = #history_text,
      input = #input,
    },
  }
end

local function add_url_citation(citations, seen, annotation)
  local APP = M.APP
  local core = APP.core
  if type(annotation) ~= "table" or annotation.type ~= "url_citation" then
    return
  end
  local url = core.trim(annotation.url)
  if url == "" or seen[url] then
    return
  end
  seen[url] = true
  local title = core.short_text(core.normalize_space(annotation.title or ""), 90)
  if title ~= "" then
    citations[#citations + 1] = title .. " - " .. url
  else
    citations[#citations + 1] = url
  end
end

local function append_output_content(parts, citations, seen, content)
  local text = ""
  if type(content) == "table" then
    text = content.text or content.output_text or ""
    if type(content.annotations) == "table" then
      for i = 1, #content.annotations do
        add_url_citation(citations, seen, content.annotations[i])
      end
    end
  elseif type(content) == "string" then
    text = content
  end
  if type(text) == "string" and text ~= "" then
    parts[#parts + 1] = text
  end
end

-- 从 Responses API 响应里抽取可显示文本。
local function response_text(resp)
  if type(resp) ~= "table" then
    return ""
  end
  local parts = {}
  local citations = {}
  local seen = {}
  local output = type(resp.output) == "table" and resp.output or {}
  for i = 1, #output do
    local item = output[i]
    if type(item) == "table" then
      if item.type == "message" and type(item.content) == "table" then
        for j = 1, #item.content do
          append_output_content(parts, citations, seen, item.content[j])
        end
      elseif item.type == "output_text" and type(item.text) == "string" then
        parts[#parts + 1] = item.text
      end
    end
  end
  if #parts == 0 and type(resp.output_text) == "string" and resp.output_text ~= "" then
    parts[#parts + 1] = resp.output_text
  end
  local text = table.concat(parts, "\n")
  if #citations > 0 then
    text = text .. "\n\n来源："
    for i = 1, #citations do
      text = text .. "\n- " .. citations[i]
    end
  end
  return text
end

-- 从 Responses API 响应里抽取 function_call。
local function response_function_calls(resp)
  local calls = {}
  local output = type(resp) == "table" and type(resp.output) == "table" and resp.output or {}
  for i = 1, #output do
    local item = output[i]
    if type(item) == "table" and item.type == "function_call" then
      calls[#calls + 1] = {
        id = item.id,
        call_id = item.call_id,
        name = item.name,
        arguments = item.arguments or "{}",
      }
    end
  end
  return calls
end

-- 兼容普通 JSON 与 SSE 文本两类响应体。
local function decode_response_body(body)
  local core = M.APP.core
  local resp, dec_err = core.safe_json_decode(body)
  if type(resp) == "table" then
    return resp, nil
  end

  local completed = nil
  local latest = nil
  local text_parts = {}
  local calls = {}

  local function handle_event(doc)
    if type(doc) ~= "table" then
      return
    end
    if type(doc.response) == "table" then
      latest = doc.response
      if doc.type == "response.completed" or doc.response.status == "completed" then
        completed = doc.response
      end
    end
    if doc.type == "response.output_text.delta" and type(doc.delta) == "string" then
      text_parts[#text_parts + 1] = doc.delta
    end
    local item = type(doc.item) == "table" and doc.item or nil
    if item and item.type == "function_call" then
      calls[#calls + 1] = item
    end
  end

  for line in core.text_or(body, ""):gmatch("[^\r\n]+") do
    local data = line:match("^data:%s*(.+)$")
    if data and data ~= "[DONE]" then
      local doc = core.safe_json_decode(data)
      handle_event(doc)
    end
  end

  local out = completed or latest
  if type(out) == "table" then
    if (not out.output or #out.output == 0) and #calls > 0 then
      out.output = calls
    end
    if (not out.output_text or out.output_text == "") and #text_parts > 0 then
      out.output_text = table.concat(text_parts)
    end
    return out, nil
  end
  if #text_parts > 0 then
    return { output_text = table.concat(text_parts), output = {} }, nil
  end
  return nil, dec_err or "decode failed"
end

-- 调用一次 LLM Responses API。
local function call_llm(input, previous_response_id, instructions, source, task_plan)
  local APP = M.APP
  local core = APP.core
  local url, api_kind_or_err = endpoint_url(APP.config.llm_base_url)
  if not url then
    return nil, api_kind_or_err
  end
  local api_kind = api_kind_or_err

  local body = nil
  if api_kind == "chat" then
    -- Chat Completions 和 Responses 的工具 schema 不同，这里各自构造请求体。
    local deepseek_thinking = is_deepseek_base() and deepseek_thinking_enabled(task_plan)
    body = {
      model = APP.config.llm_model,
      messages = chat_messages(input, instructions),
      tools = APP.tools.chat_tool_defs(source),
      stream = false,
      max_tokens = llm_output_token_limit(source, task_plan, deepseek_thinking),
    }
    if is_deepseek_base() then
      if deepseek_thinking then
        body.thinking = { type = "enabled" }
        body.reasoning_effort = deepseek_reasoning_effort()
      else
        body.thinking = { type = "disabled" }
      end
    end
    if type(body.tools) ~= "table" or #body.tools == 0 then
      body.tools = nil
    elseif type(source) == "table" and source.force_lua_run_only then
      body.tool_choice = { type = "function", ["function"] = { name = "lua_run" } }
    end
  else
    body = {
      model = APP.config.llm_model,
      input = input,
      tools = APP.tools.response_tool_defs(source),
      stream = false,
      max_output_tokens = llm_output_token_limit(source, task_plan, false),
    }
    if instructions and instructions ~= "" then
      body.instructions = instructions
    end
    if type(body.tools) == "table" and #body.tools > 0
      and type(source) == "table" and source.force_lua_run_only then
      body.tool_choice = { type = "function", name = "lua_run" }
    end
    if previous_response_id and previous_response_id ~= "" then
      body.previous_response_id = previous_response_id
    end
  end
  local raw, enc_err = core.safe_json_encode(body)
  if not raw then
    return nil, enc_err
  end

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
    ["Authorization"] = "Bearer " .. APP.config.llm_api_key,
  }
  local request_timeout = llm_request_timeout(source, task_plan)
  local code, resp_body = http.post(url, {
    headers = headers,
    timeout = request_timeout,
    bufsz = 262144,
  }, raw)

  if code ~= 200 then
    -- 某些模型不接受强制 tool_choice，失败时放宽一次，让模型正常返回。
    if type(source) == "table" and source.force_lua_run_only and body.tool_choice ~= nil then
      body.tool_choice = nil
      local retry_raw, retry_enc_err = core.safe_json_encode(body)
      if retry_raw then
        code, resp_body = http.post(url, {
          headers = headers,
          timeout = math.min(request_timeout, 20000),
          bufsz = 131072,
        }, retry_raw)
      else
        return nil, retry_enc_err
      end
    end
  end

  local transient_retry_done = false
  if code ~= 200 then
    local transient = llm_transient_http_error(resp_body)
    if api_kind == "chat" and is_deepseek_base() and transient and type(body.thinking) == "table"
      and body.thinking.type == "enabled" then
      -- 长推理在嵌入式 HTTP 上偶发不完整，降级为普通回答再试一次。
      transient_retry_done = true
      body.thinking = { type = "disabled" }
      body.reasoning_effort = nil
      body.max_tokens = llm_output_token_limit(source, task_plan, false)
      local retry_raw, retry_enc_err = core.safe_json_encode(body)
      if retry_raw then
        code, resp_body = http.post(url, {
          headers = headers,
          timeout = math.min(math.max(request_timeout, 20000), 30000),
          bufsz = 131072,
        }, retry_raw)
      else
        return nil, retry_enc_err
      end
    end
  end

  if code ~= 200 and not transient_retry_done
    and api_kind == "chat" and is_deepseek_base() and llm_transient_http_error(resp_body) then
    -- 非 thinking 场景也可能遇到传输不完整；只做一次更小输出预算的重试。
    transient_retry_done = true
    body.thinking = { type = "disabled" }
    body.reasoning_effort = nil
    body.max_tokens = math.min(tonumber(body.max_tokens) or 4096, plan_is_code_task(task_plan) and 4096 or 2048)
    local retry_raw, retry_enc_err = core.safe_json_encode(body)
    if retry_raw then
      code, resp_body = http.post(url, {
        headers = headers,
        timeout = math.min(math.max(request_timeout, 15000), 22000),
        bufsz = 98304,
      }, retry_raw)
    else
      return nil, retry_enc_err
    end
  end

  if code ~= 200 then
    return nil, "llm http " .. tostring(code) .. ": " .. core.short_text(resp_body, 220)
  end

  local resp, dec_err = decode_response_body(resp_body)
  if api_kind == "chat" and type(resp) == "table" then
    resp = normalize_chat_response(resp)
  end
  if type(resp) ~= "table" then
    return nil, "llm json " .. core.text_or(dec_err, "decode failed") .. ": " .. core.short_text(resp_body, 220)
  end
  if resp.error then
    local msg = type(resp.error) == "table" and resp.error.message or resp.error
    return nil, "llm error " .. core.text_or(msg, "unknown")
  end
  if type(resp.output) ~= "table" and type(resp.output_text) ~= "string" then
    return nil, "llm response missing output"
  end
  return resp, nil
end

-- 完成一轮用户请求，包含可选工具调用。
-- Removed stale run_agent header from the old mojibake comment.
local function fit_final_reply(final_text, source, instructions, task_plan)
  local APP = M.APP
  local core = APP.core
  final_text = core.squash_repeated_reply(final_text)
  local limit = reply_char_limit(source)
  if #final_text <= limit then
    return final_text
  end
  if type(source) == "table" and source.channel == "wechat" then
    local input = table.concat({
      "Rewrite the following assistant answer for WeChat.",
      "Keep the same facts and outcome, but make it concise and natural.",
      "Target length: short enough to send in one to three WeChat messages.",
      "Use short paragraphs when details are necessary.",
      "Do not add new facts. Do not mention this rewrite instruction.",
      "",
      final_text,
    }, "\n")
    local compact_source = {}
    for k, v in pairs(source) do
      compact_source[k] = v
    end
    compact_source.disable_all_tools = true
    compact_source.router_call = true
    local ok, resp = pcall(call_llm, input, "", instructions or "", compact_source, task_plan)
    if ok and type(resp) == "table" then
      local compact = core.trim(response_text(resp))
      if compact ~= "" then
        final_text = core.squash_repeated_reply(compact)
      end
    end
  end
  if #final_text > limit then
    final_text = core.short_text(final_text, limit)
  end
  return final_text
end

local function extract_json_object(text)
  local core = M.APP.core
  text = core.trim(text)
  if text == "" then
    return nil
  end
  local fenced = text:match("```json%s*([\001-\255]-)%s*```")
    or text:match("```%s*([\001-\255]-)%s*```")
  if fenced and fenced ~= "" then
    text = core.trim(fenced)
  end
  local first = text:find("{", 1, true)
  local last = nil
  if first then
    for i = #text, first, -1 do
      if text:sub(i, i) == "}" then
        last = i
        break
      end
    end
  end
  if first and last and last >= first then
    return text:sub(first, last)
  end
  return text
end

local function completion_tool_facts(tool_results, max_items)
  local APP = M.APP
  local core = APP.core
  tool_results = type(tool_results) == "table" and tool_results or {}
  max_items = tonumber(max_items) or 8
  if #tool_results == 0 then
    return "No tool results were observed in this turn."
  end
  local start_index = #tool_results - max_items + 1
  if start_index < 1 then start_index = 1 end
  local lines = {}
  for i = start_index, #tool_results do
    local item = tool_results[i]
    if type(item) == "table" then
      local name = core.text_or(item.name, "")
      lines[#lines + 1] = "Tool #" .. tostring(i) .. ": " .. name
      local args = core.text_or(item.arguments, "")
      if args ~= "" then
        lines[#lines + 1] = "Arguments: " .. core.utf8_prefix(args:gsub("[\r\n]+", " "), 900)
      end
      local output = core.text_or(item.output, "")
      if name == "lua_run" then
        local doc = core.safe_json_decode(output)
        if type(doc) == "table" then
          local stdout = core.trim(core.text_or(doc.stdout, ""))
          local err = core.trim(core.text_or(doc.error, ""))
          lines[#lines + 1] = "Output summary: ok=" .. tostring(doc.ok == true)
            .. " target=" .. core.text_or(doc.target, "")
            .. " phase=" .. core.text_or(doc.phase, "")
            .. " stdout=" .. core.short_text(stdout:gsub("[\r\n]+", " "), 700)
            .. " error=" .. core.short_text(err:gsub("[\r\n]+", " "), 500)
        else
          lines[#lines + 1] = "Output: " .. core.utf8_prefix(output:gsub("[\r\n]+", " "), 1000)
        end
      else
        lines[#lines + 1] = "Output: " .. core.utf8_prefix(output:gsub("[\r\n]+", " "), 1000)
      end
    end
  end
  return table.concat(lines, "\n")
end

local function completion_self_review(user_text, candidate_text, tool_results, source, task_plan)
  local APP = M.APP
  local core = APP.core
  if not llm_configured() or not http or not http.post then
    return nil, "review unavailable"
  end
  candidate_text = core.trim(candidate_text)
  if candidate_text == "" then
    return nil, "empty candidate"
  end
  -- 自审只检查“是否完成”，不允许调用工具，避免额外制造副作用。
  local plan_raw = type(task_plan) == "table" and core.safe_json_encode(task_plan) or "{}"
  local instructions = table.concat({
    "You are a completion auditor for an embedded device agent.",
    "Return only one compact JSON object. No markdown.",
    "Judge whether the candidate final answer truly satisfies the latest user request, using tool facts as evidence.",
    "Require continuation only when requested facts/actions are missing, unsupported, contradicted, or the answer defers after the work should already be complete.",
    "Do not demand more detail just because more detail is possible.",
    "For tool-backed answers, claimed facts must appear in tool outputs or known observations.",
    "A concise final answer with the requested confirmed result is complete even if it does not apologize, recap history, or mention future behavior.",
    "If the required result is missing, failed, timed out, or unconfirmed, a success-style answer is incomplete; prefer rewrite to a concise no-confirmed-result answer when no further tool can help.",
    "If the user requested a change/action and the candidate answer only reports a read/status result, it is incomplete; choose continue when an action tool is still available.",
    "For live lookup, web_probe is only reachability/status evidence. Page contents, lists, prices, model specs, and article facts require web_fetch, lookup_context items, or another content-bearing tool result.",
    "Skill activation, status checks, directory listings, and preflight checks are not enough when the user asked for concrete file contents, code changes, or fetched page contents.",
    "For code/run tasks, the answer should mention the observed success/error and repair path when relevant.",
    "Allowed actions: final, rewrite, continue.",
    "Use action=continue only when another model/tool step is needed. Use action=rewrite when the facts are enough but the answer is incomplete, misleading, too deferring, or poorly phrased.",
    "Schema: {\"complete\":true,\"action\":\"final\",\"reason\":\"short\",\"revised_answer\":\"\",\"continue_instruction\":\"\"}",
  }, "\n")
  local input = table.concat({
    "Latest user request:",
    core.text_or(user_text, ""),
    "",
    "Agent task plan:",
    plan_raw or "{}",
    "",
    "Candidate final answer:",
    core.utf8_prefix(candidate_text, 2200),
    "",
    "Tool facts from this turn:",
    completion_tool_facts(tool_results, 10),
    "",
    "Known observations:",
    observation_context(10),
    "",
    "Recent lookup_context:",
    lookup_context_text(10),
  }, "\n")
  local review_source = {}
  for k, v in pairs(type(source) == "table" and source or {}) do
    review_source[k] = v
  end
  review_source.disable_all_tools = true
  review_source.router_call = true
  review_source.completion_review = true
  local resp, err = call_llm(input, "", instructions, review_source, {
    mode = "answer",
    execution_required = false,
    allow_text_only = true,
  })
  if not resp then
    return nil, err
  end
  local text = response_text(resp)
  local raw_json = extract_json_object(text)
  local parsed = raw_json and core.safe_json_decode(raw_json) or nil
  if type(parsed) ~= "table" then
    return nil, "review returned non-json"
  end
  parsed.action = core.trim(core.text_or(parsed.action, parsed.complete == false and "continue" or "final")):lower()
  parsed.reason = core.short_text(core.text_or(parsed.reason, ""), 240)
  parsed.revised_answer = core.trim(core.text_or(parsed.revised_answer, ""))
  parsed.continue_instruction = core.trim(core.text_or(parsed.continue_instruction, ""))
  parsed.complete = parsed.complete == true
  return parsed, nil
end

local function completion_continue_input(user_text, candidate_text, review, tool_results, source, task_plan)
  local APP = M.APP
  local core = APP.core
  local parts = {
    "A completion self-check found that the previous candidate answer did not fully satisfy the user's request.",
    "Continue the same user request now. Decide whether to call tools or produce a corrected final answer.",
    "Do not ask the user for confirmation unless the task is genuinely blocked.",
    "Do not repeat completed tool calls unless the facts are insufficient or contradicted.",
  }
  local raw_plan = type(task_plan) == "table" and core.safe_json_encode(task_plan) or nil
  if raw_plan then
    parts[#parts + 1] = "Agent task plan: " .. raw_plan
  end
  if type(review) == "table" then
    parts[#parts + 1] = "Self-check reason: " .. core.text_or(review.reason, "")
    if core.text_or(review.continue_instruction, "") ~= "" then
      parts[#parts + 1] = "Self-check requested next step: " .. core.text_or(review.continue_instruction, "")
    end
  end
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Original user request:"
  parts[#parts + 1] = core.text_or(user_text, "")
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Rejected candidate answer:"
  parts[#parts + 1] = core.utf8_prefix(core.text_or(candidate_text, ""), 1800)
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Tool facts already observed:"
  parts[#parts + 1] = completion_tool_facts(tool_results, 10)
  local obs = observation_context(12)
  if obs ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = obs
  end
  local lookup_ctx = lookup_context_text(12)
  if lookup_ctx ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = lookup_ctx
  end
  if APP.skills and APP.skills.build_context then
    local ok, skills_text = pcall(APP.skills.build_context, source)
    if ok and type(skills_text) == "string" and skills_text ~= "" then
      parts[#parts + 1] = ""
      parts[#parts + 1] = skills_text
    end
  end
  append_recent_conversation(parts, 6, source)
  return table.concat(parts, "\n")
end

local function incomplete_final_answer(user_text, source, task_plan, tool_results, reason, candidate_text)
  local APP = M.APP
  local core = APP.core
  if not llm_configured() or not http or not http.post then
    return ""
  end
  local explain_source = {}
  for k, v in pairs(type(source) == "table" and source or {}) do
    explain_source[k] = v
  end
  explain_source.disable_all_tools = true
  explain_source.router_call = true
  explain_source.incomplete_final = true

  local plan_raw = type(task_plan) == "table" and core.safe_json_encode(task_plan) or "{}"
  local instructions = table.concat({
    "Write the final user-facing answer for an embedded device agent.",
    "No tools are available in this step.",
    "Explain what was actually done, what is still missing, and why the request could not be fully completed.",
    "Use the observed tool facts instead of saying only that the model failed.",
    "If a candidate answer exists, you may preserve useful parts, but be honest when required tool work did not happen.",
    "Be concise, natural, and concrete. Do not invent file contents, code changes, network results, or device state.",
  }, "\n")
  local parts = {
    "Latest user request:",
    core.text_or(user_text, ""),
    "",
    "Agent task plan:",
    plan_raw or "{}",
    "",
    "Main-loop completion reason:",
    core.text_or(reason, "no final answer was produced"),
    "",
    "Candidate text already produced by the model, if any:",
    core.utf8_prefix(core.text_or(candidate_text, ""), 1800),
    "",
    "Tool facts observed in this turn:",
    completion_tool_facts(tool_results, 10),
  }
  local obs = observation_context(12)
  if obs ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = obs
  end
  local lookup_ctx = lookup_context_text(12)
  if lookup_ctx ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = lookup_ctx
  end
  append_recent_conversation(parts, 6, source)

  local resp = nil
  local ok, result = pcall(call_llm, table.concat(parts, "\n"), "", instructions, explain_source, {
    mode = "answer",
    execution_required = false,
    allow_text_only = true,
  })
  if ok then
    resp = result
  end
  local text = core.trim(response_text(resp))
  if text == "" then
    return ""
  end
  return text
end

local function recoverable_llm_failure_answer(user_text, err, tool_results, task_plan)
  local APP = M.APP
  local core = APP.core
  local lines = {
    "这轮没有完全完成：模型连接中断，错误是 " .. core.short_text(core.text_or(err, "llm error"), 180) .. "。",
  }
  if type(tool_results) == "table" and #tool_results > 0 then
    lines[#lines + 1] = "但本轮已经拿到了一些工具结果，我不会把这次中断当作正常完成："
    local start_index = #tool_results - 4 + 1
    if start_index < 1 then start_index = 1 end
    for i = start_index, #tool_results do
      local item = tool_results[i]
      if type(item) == "table" then
        local name = core.text_or(item.name, "")
        local doc = core.safe_json_decode(item.output)
        if name == "get_panel_artifacts" and type(doc) == "table" then
          local entries = type(doc.entries) == "table" and doc.entries or {}
          local title = entries[1] and core.text_or(entries[1].title or entries[1].id, "") or ""
          lines[#lines + 1] = "- 已读取 Panel 作品" .. (title ~= "" and ("：" .. core.short_text(title, 80)) or "。")
        elseif name == "get_panel_history" and type(doc) == "table" then
          local entries = type(doc.entries) == "table" and doc.entries or {}
          local title = entries[1] and core.text_or(entries[1].title or entries[1].id, "") or ""
          lines[#lines + 1] = "- 已读取 Panel 历史" .. (title ~= "" and ("：" .. core.short_text(title, 80)) or "。")
        elseif name == "lua_run" and type(doc) == "table" then
          if doc.ok == true then
            local stdout = core.trim(core.text_or(doc.stdout, ""))
            lines[#lines + 1] = "- lua_run 已成功" .. (stdout ~= "" and ("，输出：" .. core.short_text(stdout:gsub("[\r\n]+", " "), 140)) or "。")
          else
            local run_err = core.trim(core.text_or(doc.error, ""))
            lines[#lines + 1] = "- lua_run 报错：" .. core.short_text(run_err ~= "" and run_err or core.text_or(doc.stdout, ""), 160)
          end
        elseif name ~= "" then
          lines[#lines + 1] = "- 已执行工具：" .. name
        end
      end
    end
  end
  if task_is_code_action(task_plan) then
    lines[#lines + 1] = "下一次你说“继续”时，我会从这些已读作品、错误和工具结果接着修，不会重新把旧错误当成最终回复。"
  else
    lines[#lines + 1] = "可以继续追问，我会沿用已经拿到的上下文。"
  end
  return table.concat(lines, "\n")
end

local function observed_paths_snapshot(max_items)
  local APP = M.APP
  local core = APP.core
  local out = {}
  local seen = {}
  max_items = tonumber(max_items) or 40
  local root = core.trim(APP.APP_DIR)
  if root:match("^/sd/") then
    out[#out + 1] = root
    seen[root] = true
  end
  local obs = observations()
  for i = #obs, 1, -1 do
    local item = obs[i]
    if type(item) == "table" and item.kind == "path" then
      local path = core.trim(item.text)
      if path:match("^/sd/") and not seen[path] then
        seen[path] = true
        table.insert(out, 1, path)
        if #out >= max_items then
          break
        end
      end
    end
  end
  return out
end

local function model_choose_inspect_paths(user_text, source, task_plan, tool_results)
  local APP = M.APP
  local core = APP.core
  local paths = observed_paths_snapshot(48)
  if #paths == 0 then
    return nil, "no observed paths"
  end
  local parts = {
    "Choose the next files or directories to read for this inspect request.",
    "Return only JSON: {\"paths\":[\"/sd/...\"],\"reason\":\"short reason\"}.",
    "Use only paths from Observed paths. Choose 1 to 4 paths that are most relevant to the latest user request.",
    "Choose files likely to contain the requested facts or records, not merely source code that implements a related feature.",
    "If a directory was observed and the user needs records/history, you may choose that directory to list it before choosing files.",
    "Do not invent paths.",
    "",
    "Latest user request: " .. core.text_or(user_text, ""),
    "",
    "Observed paths:",
  }
  for i = 1, #paths do
    parts[#parts + 1] = "- " .. paths[i]
  end
  if type(tool_results) == "table" and #tool_results > 0 then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "Recent tool outputs:"
    for i = 1, math.min(#tool_results, 4) do
      local item = tool_results[i]
      if type(item) == "table" then
        parts[#parts + 1] = "Tool: " .. core.text_or(item.name, "")
        parts[#parts + 1] = core.utf8_prefix(core.text_or(item.output, ""), 1800)
      end
    end
  end
  local plan_raw = type(task_plan) == "table" and core.safe_json_encode(task_plan) or ""
  if plan_raw and plan_raw ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "Task plan: " .. plan_raw
  end
  local choice_source = {}
  for k, v in pairs(source or {}) do
    choice_source[k] = v
  end
  choice_source.disable_all_tools = true
  choice_source.router_call = true
  local resp, err = call_llm(table.concat(parts, "\n"), "", response_instructions(source), choice_source, task_plan)
  if not resp then
    return nil, err
  end
  local raw_json = extract_json_object(response_text(resp))
  local parsed = raw_json and core.safe_json_decode(raw_json) or nil
  if type(parsed) ~= "table" or type(parsed.paths) ~= "table" then
    return nil, "path choice missing"
  end
  local allowed = {}
  for i = 1, #paths do
    allowed[paths[i]] = true
  end
  local selected = {}
  local selected_seen = {}
  for i = 1, math.min(#parsed.paths, 4) do
    local path = core.trim(parsed.paths[i])
    if allowed[path] and not selected_seen[path] then
      selected_seen[path] = true
      selected[#selected + 1] = path
    end
  end
  if #selected == 0 then
    return nil, "no selected observed paths"
  end
  return selected, core.text_or(parsed.reason, "")
end

local function inspect_read_code_for_paths(paths)
  local lines = {
    "local paths = {",
  }
  for i = 1, #(paths or {}) do
    lines[#lines + 1] = "  " .. string.format("%q", paths[i]) .. ","
  end
  lines[#lines + 1] = "}"
  lines[#lines + 1] = [[
for _, path in ipairs(paths) do
  print("----- " .. path .. " -----")
  local st = file.stat and file.stat(path) or nil
  if st and st.is_dir then
    local items = file.listdir(path) or {}
    for _, e in ipairs(items) do
      local name = type(e) == "table" and e.name or tostring(e)
      print(path .. "/" .. name)
    end
  else
    local raw = file.getcontents and file.getcontents(path) or nil
    if raw and raw ~= "" then
      local n = #raw
      print("bytes=" .. tostring(n))
      if n > 12000 then
        print("----- tail " .. path .. " -----")
        print(string.sub(raw, n - 5000))
        print("----- head " .. path .. " -----")
        print(string.sub(raw, 1, 2500))
      else
        print(raw)
      end
    else
      print("not readable or empty")
    end
  end
end]]
  return table.concat(lines, "\n")
end

local function try_model_guided_inspect_read(user_text, source, task_plan, tool_results, turn_id)
  local APP = M.APP
  local core = APP.core
  if type(task_plan) ~= "table" or task_plan.mode ~= "inspect" then
    return false, nil, nil
  end
  local paths, reason = model_choose_inspect_paths(user_text, source, task_plan, tool_results)
  if not paths or #paths == 0 then
    return false, nil, reason
  end
  local args = {
    target = "service",
    code = inspect_read_code_for_paths(paths),
    timeout_ms = 5000,
    goal = "model-selected inspect read: " .. core.short_text(reason or "", 120),
  }
  local args_json = core.safe_json_encode(args) or "{}"
  append_ledger({
    event = "model_guided_tool_step",
    turn_id = turn_id,
    tool = "lua_run",
    selected_paths = paths,
    reason = reason,
  })
  local output = APP.tools.execute_tool("lua_run", args_json, source)
  append_ledger({
    event = "tool_result",
    turn_id = turn_id,
    tool = "lua_run",
    arguments = summarize_tool_args(args_json),
    output = summarize_tool_output(output),
  })
  remember_tool_observations("lua_run", args_json, output)
  local result = {
    name = "lua_run",
    arguments = args_json,
    output = output,
  }
  return true, result, nil
end

local function normalize_router_bool(value, fallback)
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "string" then
    local lower = value:lower()
    if lower == "true" or lower == "yes" or lower == "1" then
      return true
    end
    if lower == "false" or lower == "no" or lower == "0" then
      return false
    end
  end
  return fallback == true
end

local function normalize_router_mode(value)
  local mode = M.APP.core.text_or(value, ""):lower()
  local aliases = {
    text = "answer",
    discussion = "answer",
    explain = "answer",
    explanation = "answer",
    code = "new_code",
    execute = "new_code",
    execute_code = "new_code",
    run_code = "new_code",
    implement = "new_code",
    modify = "modify_previous",
    debug = "debug_previous",
    inspect_source = "inspect",
    file_inspect = "inspect",
    source_inspect = "inspect",
    current_info = "live_lookup",
    web_lookup = "live_lookup",
    search = "live_lookup",
    lookup = "live_lookup",
  }
  mode = aliases[mode] or mode
  local allowed = {
    answer = true,
    code_review = true,
    new_code = true,
    modify_previous = true,
    debug_previous = true,
    inspect = true,
    live_lookup = true,
  }
  return allowed[mode] and mode or ""
end

local function normalize_router_target(value, fallback)
  local target = M.APP.core.text_or(value, ""):lower()
  if target == "none" or target == "text" then
    target = "unknown"
  end
  if target ~= "service" and target ~= "panel" and target ~= "unknown" then
    target = fallback or "unknown"
  end
  return target
end

local function looks_like_non_visual_action(user_text, fallback)
  local text = M.APP.core.text_or(user_text, "")
  fallback = type(fallback) == "table" and fallback or {}
  if fallback.target ~= "service" or fallback.has_code_context == true then
    return false
  end
  if text_has_any(text, {
    "画", "绘制", "动画", "UI", "LVGL", "Canvas", "canvas",
    "面板", "界面", "可视化", "图形", "布局",
  }) then
    return false
  end
  return text_has_any(text, {
    "设置", "调整", "调一下", "调高", "调低", "改成", "改到",
    "打开", "关闭", "启动", "停止", "发送", "更新",
  })
end

local function apply_task_plan_policy(plan, fallback, user_text, source)
  local core = M.APP.core
  fallback = type(fallback) == "table" and fallback or classify_task(user_text, source)
  plan = type(plan) == "table" and plan or {}

  local mode = normalize_router_mode(plan.mode or plan.intent or plan.task_type)
  if mode == "" then
    mode = core.text_or(fallback.mode, "answer")
  end

  local target = normalize_router_target(plan.target, fallback.target)
  local needs_history = normalize_router_bool(plan.needs_history, fallback.needs_history)
  local execution_required = normalize_router_bool(plan.execution_required, fallback.execution_required)
  local allow_text_only = normalize_router_bool(plan.allow_text_only, fallback.allow_text_only)
  local has_code_context = normalize_router_bool(plan.has_code_context, fallback.has_code_context)
  local live_lookup_hint = normalize_router_bool(plan.live_lookup_hint, fallback.live_lookup_hint)
  local confidence = tonumber(plan.confidence) or tonumber(fallback.confidence) or 0.5
  if confidence < 0 then confidence = 0 end
  if confidence > 1 then confidence = 1 end

  if mode == "answer" or mode == "code_review" then
    execution_required = false
    allow_text_only = true
    if target == "panel" or target == "service" then
      target = "unknown"
    end
  elseif mode == "live_lookup" then
    execution_required = true
    allow_text_only = false
    target = "service"
  elseif mode == "inspect" then
    execution_required = true
    allow_text_only = false
    target = "service"
  elseif mode == "new_code" or mode == "modify_previous" or mode == "debug_previous" then
    execution_required = true
    allow_text_only = false
    if target == "unknown" then
      target = core.text_or(fallback.target, "service")
    end
  end

  if fallback.text_first_request ~= true
    and task_is_code_action(fallback)
    and fallback.execution_required == true
    and (mode == "answer" or mode == "code_review") then
    mode = core.text_or(fallback.mode, "modify_previous")
    target = core.text_or(fallback.target, target ~= "unknown" and target or "service")
    needs_history = fallback.needs_history == true
    execution_required = true
    allow_text_only = false
  end

  if fallback.text_first_request == true then
    mode = fallback.has_code_context and "code_review" or "answer"
    execution_required = false
    allow_text_only = true
    target = "unknown"
    needs_history = false
  end

  if fallback.text_first_request ~= true
    and fallback.mode == "inspect"
    and fallback.execution_required == true
    and (user_text:find("/sd/apps", 1, true) or user_text:find("源码", 1, true)) then
    mode = "inspect"
    execution_required = true
    allow_text_only = false
    target = "service"
  end

  if looks_like_non_visual_action(user_text, fallback) then
    if target == "panel" then
      target = "service"
    end
    needs_history = false
    if mode == "inspect" or mode == "modify_previous" or mode == "debug_previous" then
      mode = core.text_or(fallback.mode, "new_code")
    end
  end

  local out = {
    mode = mode,
    needs_history = needs_history,
    target = target,
    has_code_context = has_code_context,
    execution_required = execution_required,
    allow_text_only = allow_text_only,
    text_first_request = fallback.text_first_request == true,
    live_lookup_hint = live_lookup_hint,
    confidence = confidence,
    priority = "latest_user_request",
    router_source = core.text_or(plan.router_source, "model"),
    router_reason = core.short_text(core.text_or(plan.reason or plan.router_reason, ""), 220),
  }
  if out.router_reason ~= "" then
    out.note = out.router_reason
  else
    out.note = core.text_or(fallback.note, "")
  end
  return out
end

local function model_route_task(user_text, source, fallback)
  local APP = M.APP
  local core = APP.core
  fallback = type(fallback) == "table" and fallback or classify_task(user_text, source)
  if not llm_configured() or not http or not http.post then
    fallback.router_source = "fallback"
    fallback.router_reason = "router unavailable"
    return apply_task_plan_policy(fallback, fallback, user_text, source)
  end
  if fallback.text_first_request == true then
    -- 用户明确要求先文字讨论时，本地策略优先于模型 router。
    fallback.router_source = "fallback_text_first"
    fallback.router_reason = "text-first policy override"
    return apply_task_plan_policy(fallback, fallback, user_text, source)
  end

  local history = {}
  local source_history = history_for_source(source)
  -- Router 只看最近几条，避免旧任务把当前短句带偏。
  local start_index = #source_history - 5
  if start_index < 1 then start_index = 1 end
  for i = start_index, #source_history do
    local item = source_history[i]
    if type(item) == "table" then
      history[#history + 1] = {
        role = core.text_or(item.role, ""),
        content = core.utf8_prefix(core.text_or(item.content, ""), 500),
      }
    end
  end

  local fallback_raw = core.safe_json_encode(fallback) or "{}"
  local history_raw = core.safe_json_encode(history) or "[]"
  local instructions = table.concat({
    "You are a routing classifier for an embedded Lua device agent.",
    "Return only one compact JSON object. No markdown.",
    "Choose the semantic plan from the latest user request, using recent history only when needed.",
    "Allowed mode values: answer, code_review, new_code, modify_previous, debug_previous, inspect, live_lookup.",
    "Allowed target values: unknown, service, panel.",
    "Use answer/code_review when the user asks to discuss, explain, review, or says text first.",
    "Use inspect when the user wants real local app/source/files under /sd/apps to be read.",
    "Do not use inspect for a requested setting/state change; inspect is for reading or examining, not for completing an action.",
    "Use debug_previous with needs_history=true for follow-up failure reports such as a prior visual not rendering, not showing, drawing nothing, errors, or asking why the previous result failed.",
    "Interpret the latest request semantically. If the user is complaining that expected behavior is absent, route it as restoring or implementing that behavior; only route removal when the user actually asks to remove it.",
    "Use live_lookup when the user needs current external facts such as prices, news, weather, exchange rates, or latest public info.",
    "Words such as today, latest, weather, or price are hints only; choose live_lookup only when the user is really asking for current external facts.",
    "Use panel only for visible UI/LVGL/Canvas/screen visual work; use service for HTTP, files, source reading, and non-UI Lua.",
    "Do not route device settings, status reads, or app/service controls as panel visual work just because they mention the screen or display.",
    "Panel is for drawing or modifying UI artifacts, animations, canvas/LVGL scenes, or visible layouts. Setting a property, changing a device/app state, sending something, or starting/stopping something is a service/device action unless the user explicitly asks to draw or edit a UI artifact.",
    "Set execution_required=true only when the current turn needs a real tool/action, not just an explanation.",
    "Schema: {\"mode\":\"...\",\"target\":\"...\",\"execution_required\":true,\"allow_text_only\":false,\"needs_history\":false,\"has_code_context\":false,\"live_lookup_hint\":false,\"confidence\":0.0,\"reason\":\"short\"}",
  }, "\n")
  local input = table.concat({
    "Fallback plan from local heuristics:",
    fallback_raw,
    "",
    "Recent history:",
    history_raw,
    "",
    "Latest user request:",
    core.text_or(user_text, ""),
  }, "\n")

  local resp, err = call_llm(input, "", instructions, { disable_all_tools = true, router_call = true }, {
    mode = "answer",
    execution_required = false,
    allow_text_only = true,
  })
  if not resp then
    fallback.router_source = "fallback"
    fallback.router_reason = "router error: " .. core.short_text(err, 120)
    return apply_task_plan_policy(fallback, fallback, user_text, source)
  end
  local text = response_text(resp)
  local raw_json = extract_json_object(text)
  local parsed = raw_json and core.safe_json_decode(raw_json) or nil
  if type(parsed) ~= "table" then
    fallback.router_source = "fallback"
    fallback.router_reason = "router returned non-json"
    return apply_task_plan_policy(fallback, fallback, user_text, source)
  end
  parsed.router_source = "model"
  return apply_task_plan_policy(parsed, fallback, user_text, source)
end

-- 根据任务路由结果预激活必要 Skill，让模型下一步能直接看到操作说明。
local function ensure_task_skills(task_plan, source)
  local APP = M.APP
  if not APP.skills or not APP.skills.activate or type(task_plan) ~= "table" then
    return
  end
  local ids = {}
  if task_plan.mode == "inspect" then
    ids[#ids + 1] = "app_inspect"
  end
  if task_plan.mode == "live_lookup" then
    ids[#ids + 1] = "web_search"
  end
  if task_plan.mode == "new_code"
    or task_plan.mode == "modify_previous"
    or task_plan.mode == "debug_previous"
    or task_plan.mode == "live_lookup"
    or task_plan.execution_required == true then
    ids[#ids + 1] = "code_runner"
  end
  local seen = {}
  for i = 1, #ids do
    if not seen[ids[i]] then
      seen[ids[i]] = true
      pcall(APP.skills.activate, ids[i], source)
    end
  end
end

-- Agent 主入口：准备上下文、调用模型、执行工具循环，最后生成用户可读回复。
local function run_agent(user_text, source)
  local APP = M.APP
  local core = APP.core
  if not llm_configured() then
    return nil, "LLM is not configured. Set base URL, API key, and model in WebUI."
  end
  if not http or not http.post then
    return nil, "http client missing"
  end

  if source and type(source.image_path) == "string" and source.image_path ~= "" then
    if not APP.vision or not APP.vision.inspect_image then
      return nil, "vision module missing"
    end
    local final_text, vision_err = APP.vision.inspect_image(source.image_path, user_text, source)
    if not final_text then
      return nil, vision_err
    end
    final_text = fit_final_reply(final_text, source, response_instructions(source), nil)
    append_history(source, "user", user_text .. "\n[image] " .. source.image_path)
    append_history(source, "assistant", final_text)
    trim_history(source)
    if APP.memory and APP.memory.observe_turn then
      pcall(APP.memory.observe_turn, user_text, final_text, source)
    end
    return final_text, nil
  end

  local rounds = core.clamp(tonumber(APP.config.max_tool_rounds) or 32, 1, 64)
  local fallback_plan = classify_task(user_text, source)
  local task_plan = model_route_task(user_text, source, fallback_plan)
  local plan_expects_implementation = task_plan.execution_required == true
  if type(task_plan) == "table" and task_plan.mode == "live_lookup" and rounds < 7 then
    rounds = 7
  elseif user_wants_tool_result_answer(user_text) and rounds < 6 then
    rounds = 6
  elseif plan_expects_implementation and rounds < 5 then
    rounds = 5
  end
  local context_lookup_limit = 2
  if task_plan.mode == "modify_previous" or task_plan.mode == "debug_previous" then
    context_lookup_limit = 1
  end
  ensure_task_skills(task_plan, source)
  local turn_id = tostring(core.now_ms()) .. "-" .. tostring(math.random(1000, 9999))
  append_ledger({
    event = "turn_start",
    turn_id = turn_id,
    channel = core.text_or(source and source.channel, "web"),
    chat_id = core.text_or(source and source.chat_id, ""),
    user_goal = user_text,
    plan = task_plan,
  })
  local final_text = nil
  local fallback_text = nil
  local instructions = response_instructions(source)
  local input = response_user_input(user_text, source, task_plan)
  local previous_response_id = ""
  local progress_notices = 0
  local max_progress_notices = progress_limit(source)
  local sent_progress_notices = {}
  local saw_lua_run = false
  local saw_action_run = false
  local saw_lua_error = false
  local saw_lua_success = false
  local saw_reasoning_only = false
  local saw_activate_skill = false
  local force_final_answer = false
  local force_lua_run_only = false
  local guided_inspect_attempted = false
  local accumulated_tool_results = {}
  local context_lookup_count = 0
  local completion_reviews = 0
  local surfaced_no_tool_reply = {}
  local function send_progress_once(notice)
    notice = core.trim(notice)
    if notice == "" or sent_progress_notices[notice] then
      return false
    end
    sent_progress_notices[notice] = true
    progress_notices = progress_notices + 1
    send_progress_notice(source, notice)
    return true
  end
  local function surface_no_tool_reply(text)
    text = core.trim(text)
    if text == "" then
      return false
    end
    local notice = core.short_text(core.normalize_space(text), source and source.channel == "wechat" and 180 or 240)
    if notice == "" or surfaced_no_tool_reply[notice] then
      return false
    end
    surfaced_no_tool_reply[notice] = true
    append_ledger({
      event = "model_intermediate_text",
      turn_id = turn_id,
      reason = "no_tool_retry",
      text = notice,
    })
    send_progress_notice(source, notice)
    return true
  end
  if plan_expects_implementation and progress_notices < max_progress_notices then
    if type(task_plan) == "table" and task_plan.target == "panel" then
      send_progress_once("收到，我开始生成并运行这次的 Panel 代码。")
    else
      send_progress_once("收到，我开始执行这次的设备操作。")
    end
  end
  local forced_action_retries = 0
  local action_retry_limit = 3
  -- 多轮 function-calling 循环：模型可以先取上下文，再执行动作，再根据结果总结。
  for _ = 1, rounds do
    local llm_source = source
    if force_final_answer then
      llm_source = {}
      for k, v in pairs(source or {}) do
        llm_source[k] = v
      end
      llm_source.disable_all_tools = true
    elseif plan_expects_implementation and saw_activate_skill then
      llm_source = {}
      for k, v in pairs(source or {}) do
        llm_source[k] = v
      end
      llm_source.disable_activate_skill = true
    end
    if type(task_plan) == "table" and task_plan.mode == "live_lookup" then
      if llm_source == source then
        llm_source = {}
        for k, v in pairs(source or {}) do
          llm_source[k] = v
        end
      end
      llm_source.disable_context_tools = true
    end
    if type(task_plan) == "table" and task_plan.target == "service" then
      if llm_source == source then
        llm_source = {}
        for k, v in pairs(source or {}) do
          llm_source[k] = v
        end
      end
      llm_source.disable_panel_context_tools = true
    end
    if force_lua_run_only then
      if llm_source == source then
        llm_source = {}
        for k, v in pairs(source or {}) do
          llm_source[k] = v
        end
      end
      llm_source.force_lua_run_only = true
      llm_source.disable_activate_skill = true
    end
    if plan_expects_implementation and ((not saw_lua_run and not saw_action_run and context_lookup_count >= context_lookup_limit) or saw_lua_error) then
      llm_source = {}
      for k, v in pairs(source or {}) do
        llm_source[k] = v
      end
      llm_source.disable_context_tools = true
      if force_lua_run_only then
        llm_source.force_lua_run_only = true
        llm_source.disable_activate_skill = true
      end
      if force_final_answer then
        llm_source.disable_all_tools = true
      elseif saw_activate_skill then
        llm_source.disable_activate_skill = true
      end
    end
    local resp, err = call_llm(input, previous_response_id, instructions, llm_source, task_plan)
    if not resp then
      if fallback_text then
        core.append_log("warn", core.short_text(err, 120))
        final_text = fallback_text
        break
      end
      if #accumulated_tool_results > 0 then
        core.append_log("warn", core.short_text(err, 120))
        send_progress_once("模型连接中断：" .. core.short_text(core.text_or(err, ""), 140) .. "；我保留已完成的工具结果。")
        final_text = recoverable_llm_failure_answer(user_text, err, accumulated_tool_results, task_plan)
        break
      end
      return nil, err
    end
    local response_id = core.text_or(resp.id, "")
    if response_id ~= "" then
      previous_response_id = response_id
    end

    -- 兼容 Responses API 的 function_call 输出；Chat Completions 会在前面归一化。
    local tool_calls = response_function_calls(resp)
    if type(tool_calls) ~= "table" or #tool_calls == 0 then
      local text = response_text(resp)
      local reasoning_chars = tonumber(resp.reasoning_chars) or 0
      if text == "" and reasoning_chars > 0 then
        saw_reasoning_only = true
        append_ledger({
          event = "model_reasoning_only",
          turn_id = turn_id,
          reasoning_chars = reasoning_chars,
          finish_reason = resp.finish_reason,
        })
      end
      local implementation_without_run = plan_expects_implementation and not saw_lua_run and not saw_action_run
      local repair_without_run = plan_expects_implementation and saw_lua_error and not saw_lua_success
      local needs_action_retry = should_review_no_tool_response(user_text, text, task_plan, source) or implementation_without_run or repair_without_run
      if force_final_answer and fallback_text ~= "" and response_looks_like_unexecuted_code(text) then
        final_text = fallback_text
        break
      elseif needs_action_retry and forced_action_retries < action_retry_limit then
        surface_no_tool_reply(text)
        forced_action_retries = forced_action_retries + 1
        force_final_answer = false
        if type(task_plan) == "table" and task_plan.mode == "inspect" then
          force_lua_run_only = true
        end
        core.append_log("agent", "review no-tool response")
        input = force_action_input(user_text, text, task_plan, source)
        previous_response_id = ""
      elseif needs_action_retry and type(task_plan) == "table" and task_plan.mode == "inspect"
        and not guided_inspect_attempted then
        guided_inspect_attempted = true
        local ok_guided, guided_result = try_model_guided_inspect_read(user_text, source, task_plan, accumulated_tool_results, turn_id)
        if ok_guided and type(guided_result) == "table" then
          accumulated_tool_results[#accumulated_tool_results + 1] = guided_result
          saw_lua_run = true
          fallback_text = ""
          input = tool_summary_input(user_text, { guided_result }, source, task_plan)
          force_final_answer = true
          previous_response_id = ""
        else
          final_text = "操作未完成：我拿到了候选路径，但还没有读到足够的具体文件内容。"
          break
        end
      elseif needs_action_retry and plan_expects_implementation and not saw_lua_run then
        surface_no_tool_reply(text)
        final_text = incomplete_final_answer(
          user_text,
          source,
          task_plan,
          accumulated_tool_results,
          "The model produced text but still did not call the required tool after retry prompts.",
          text)
        if final_text == "" then
          final_text = text ~= "" and text
            or "操作未完成：这次请求需要实际读取或执行工具，但模型没有调用必要工具。"
        end
        break
      else
        local continued_by_review = false
        local candidate_text = text
        local pure_text_turn = #accumulated_tool_results == 0
          and (type(task_plan) ~= "table" or task_plan.execution_required ~= true)
        if completion_reviews < 1 and not pure_text_turn then
          completion_reviews = completion_reviews + 1
          local review, review_err = completion_self_review(user_text, candidate_text, accumulated_tool_results, source, task_plan)
          append_ledger({
            event = "completion_review",
            turn_id = turn_id,
            ok = type(review) == "table",
            complete = type(review) == "table" and review.complete or nil,
            action = type(review) == "table" and review.action or "",
            reason = type(review) == "table" and review.reason or core.short_text(review_err, 160),
          })
          if type(review) == "table" and review.complete == false then
            if review.action == "rewrite" and review.revised_answer ~= "" then
              final_text = review.revised_answer
              break
            elseif review.action == "continue" then
              input = completion_continue_input(user_text, candidate_text, review, accumulated_tool_results, source, task_plan)
              previous_response_id = ""
              force_final_answer = false
              if type(task_plan) == "table" and task_plan.mode == "inspect" then
                force_lua_run_only = true
              end
              core.append_log("agent", "completion review continue")
              continued_by_review = true
            elseif review.revised_answer ~= "" then
              final_text = review.revised_answer
              break
            end
          end
        end
        if not continued_by_review then
          final_text = candidate_text
          break
        end
      end
    else
      local tool_names = {}
      for i = 1, #tool_calls do
        tool_names[#tool_names + 1] = core.text_or(tool_calls[i].name, "")
      end
      append_ledger({
        event = "model_tool_step",
        turn_id = turn_id,
        tools = tool_names,
        reasoning_chars = tonumber(resp.reasoning_chars) or 0,
        finish_reason = resp.finish_reason,
      })
      local model_progress_sent = false
      local step_text = core.trim(response_text(resp))
      if step_text ~= "" then
        append_ledger({
          event = "model_progress_text",
          turn_id = turn_id,
          text = core.short_text(core.normalize_space(step_text), 240),
          surfaced = false,
        })
      end
      local tool_outputs = {}
      local tool_results = {}
      local finish_after_tool = false
      local finish_now_text = ""
      local step_context_only = #tool_calls > 0
      local step_lua_success_with_stdout = false
      for i = 1, #tool_calls do
        local tc = tool_calls[i]
        local name = core.text_or(tc.name, "")
        local args = tc.arguments or "{}"
        if not is_context_tool(name) then
          step_context_only = false
        end
        if progress_notices < max_progress_notices and not model_progress_sent then
          local notice = tool_start_notice(name, args)
          if notice ~= "" then
            send_progress_once(notice)
          end
        end
        -- 工具执行结果会进入下一轮模型输入，也会被记录到 execution ledger 便于排查。
        local output = APP.tools.execute_tool(name, args, source)
        local had_lua_error_before = saw_lua_error
        if name == "activate_skill" then
          saw_activate_skill = true
        end
        if name == "lua_run" and not lua_run_needs_followup(user_text, args, output, task_plan, source) then
          saw_lua_run = true
        end
        if name == "web_probe" or name == "web_fetch" or name == "lookup_context" then
          saw_action_run = true
        end
        if name == "lua_run" and lua_run_repairable_error_text(output) == ""
          and not lua_run_needs_followup(user_text, args, output, task_plan, source) then
          local doc = core.safe_json_decode(output)
          if type(doc) == "table" and doc.ok == true then
            saw_lua_success = true
          end
        end
        if name == "lua_run" and lua_run_repairable_error_text(output) ~= "" then
          saw_lua_error = true
        end
        if name == "lua_run" and had_lua_error_before and lua_run_repairable_error_text(output) == "" then
          local doc = core.safe_json_decode(output)
          if type(doc) == "table" and doc.ok == true then
            send_progress_once("上一个运行错误已修复，新的 lua_run 已成功。")
          end
        end
        append_ledger({
          event = "tool_result",
          turn_id = turn_id,
          tool = name,
          arguments = summarize_tool_args(args),
          output = summarize_tool_output(output),
        })
        remember_tool_observations(name, args, output)
        local reply_hint = APP.tools.tool_success_reply(name, args, output)
        if tool_reply_can_be_fallback(name, args, output, user_text, task_plan, source) then
          local stdout_reply = name == "lua_run" and lua_stdout_fallback(output, task_plan) or ""
          fallback_text = stdout_reply ~= "" and stdout_reply or reply_hint
        elseif name == "lua_run" and fallback_text == "" then
          fallback_text = lua_stdout_fallback(output, task_plan)
        end
        if name == "lua_run"
          and lua_stdout_fallback(output, task_plan) ~= ""
          and lua_run_repairable_error_text(output) == ""
          and not lua_run_needs_followup(user_text, args, output, task_plan, source) then
          step_lua_success_with_stdout = true
        end
        if name == "lua_run" then
          local notice = code_error_notice(output)
          if notice ~= "" then
            send_progress_once(notice)
          end
        end
        if progress_notices < max_progress_notices then
          local notice = tool_result_notice(name, args, output)
          if notice ~= "" then
            send_progress_once(notice)
          end
        end
        local should_finish = APP.tools.should_finish_after_tool and APP.tools.should_finish_after_tool(name, output)
        if name == "lua_run" and wants_code_explanation(user_text, source) then
          should_finish = false
        end
        if name == "lua_run" and lua_run_needs_followup(user_text, args, output, task_plan, source) then
          should_finish = false
        end
        if should_finish and is_read_only_evidence_tool(name)
          and plan_expects_implementation and turn_expects_action(user_text, source) then
          should_finish = false
        end
        if should_finish then
          finish_after_tool = true
          local doc = core.safe_json_decode(output)
          if quiet_immediate_tool(name) and type(doc) == "table" and doc.ok ~= false and reply_hint ~= "" then
            finish_now_text = reply_hint
          end
        end
        local call_id = core.text_or(tc.call_id, core.text_or(tc.id, ""))
        if call_id ~= "" then
          tool_outputs[#tool_outputs + 1] = {
            type = "function_call_output",
            call_id = call_id,
            output = output,
          }
        end
        tool_results[#tool_results + 1] = {
          name = name,
          arguments = args,
          output = output,
        }
        accumulated_tool_results[#accumulated_tool_results + 1] = tool_results[#tool_results]
        if name == "lua_run" then
          local trace_reply = tool_results_fallback_text(accumulated_tool_results, task_plan)
          if trace_reply ~= "" then
            fallback_text = trace_reply
          end
        end
      end
      if finish_now_text ~= "" then
        final_text = finish_now_text
        break
      end
      if finish_after_tool then
        input = tool_summary_input(user_text, accumulated_tool_results, source, task_plan)
        force_final_answer = true
      else
        if step_context_only and plan_expects_implementation and not saw_lua_run then
          context_lookup_count = context_lookup_count + 1
        end
        input = tool_followup_input(user_text, tool_results, source, task_plan, context_lookup_count >= context_lookup_limit)
        if fallback_text ~= "" and step_lua_success_with_stdout and not wants_code_explanation(user_text, source) then
          input = tool_summary_input(user_text, accumulated_tool_results, source, task_plan)
          force_final_answer = true
        elseif fallback_text ~= "" and not saw_lua_error
          and ((type(task_plan) == "table" and task_plan.mode == "live_lookup")
            or user_wants_tool_result_answer(user_text)) then
          input = tool_summary_input(user_text, accumulated_tool_results, source, task_plan)
          force_final_answer = true
        end
      end
      previous_response_id = ""
    end
  end

  if not final_text or final_text == "" then
    if fallback_text then
      final_text = fallback_text
    elseif saw_reasoning_only then
      final_text = incomplete_final_answer(
        user_text,
        source,
        task_plan,
        accumulated_tool_results,
        "The model returned only hidden reasoning and did not produce tool calls or user-facing text.",
        "")
      if final_text == "" then
        final_text = "操作未完成：模型只返回了 thinking，没有给出工具调用或最终内容。"
      end
    else
      final_text = incomplete_final_answer(
        user_text,
        source,
        task_plan,
        accumulated_tool_results,
        "The model did not produce a final user-facing reply before the tool loop ended.",
        "")
      if final_text == "" then
        final_text = "操作未完成：模型没有给出最终回复。"
      end
    end
  end
  final_text = fit_final_reply(final_text, source, instructions, task_plan)

  append_history(source, "user", user_text)
  append_history(source, "assistant", final_text)
  trim_history(source)
  if APP.memory and APP.memory.observe_turn then
    pcall(APP.memory.observe_turn, user_text, final_text, source)
  end
  append_ledger({
    event = "turn_final",
    turn_id = turn_id,
    final = final_text,
    plan = task_plan,
  })
  return final_text, nil
end

-- 统一处理 Web 和 WeChat 入口的用户消息。
local function handle_user_message(user_text, source)
  local APP = M.APP
  local core = APP.core
  local S = APP.state
  user_text = core.trim(user_text)
  if user_text == "" then
    return nil, "message is empty"
  end
  source = type(source) == "table" and source or {}
  source.channel = core.text_or(source.channel, "web")
  source.chat_id = core.text_or(source.chat_id, source.channel)
  touch_session(source, user_text)

  local guarded_reply = destructive_delete_guard(user_text)
  if guarded_reply then
    -- 删除类危险请求在进入 LLM 前拦截，避免模型通过工具绕过去。
    S.busy = (tonumber(S.agent_running) or 0) > 0
      or (S.chat_runtime and (tonumber(S.chat_runtime.running) or 0) > 0)
    S.request_count = S.request_count + 1
    S.last_error = ""
    S.last_user = user_text
    S.last_channel = core.text_or(source.channel, "web")
    S.last_chat_id = core.text_or(source.chat_id, "")
    S.last_reply = guarded_reply
    core.append_log("guard", core.short_text(guarded_reply, 140))
    append_history(source, "user", user_text)
    append_history(source, "assistant", guarded_reply)
    trim_history(source)
    APP.ui_api.redraw()
    return guarded_reply, nil
  end

  S.agent_running = (tonumber(S.agent_running) or 0) + 1
  S.busy = true
  -- 从这里开始更新共享状态，小屏、WebUI 和微信都会读这些字段。
  S.request_count = S.request_count + 1
  S.last_error = ""
  S.last_user = user_text
  S.last_channel = core.text_or(source.channel, "web")
  S.last_chat_id = core.text_or(source.chat_id, "")
  core.append_log("in", S.last_channel .. ": " .. core.short_text(user_text, 120))
  APP.ui_api.redraw()

  local reply, err = run_agent(user_text, source)
  S.agent_running = math.max(0, (tonumber(S.agent_running) or 1) - 1)
  S.busy = S.agent_running > 0
    or (S.chat_runtime and (tonumber(S.chat_runtime.running) or 0) > 0)
  if not reply then
    S.last_error = core.text_or(err, "agent failed")
    S.last_reply = S.last_error
    core.append_log("error", S.last_error)
    APP.ui_api.redraw()
    return nil, S.last_error
  end

  S.last_reply = reply
  core.append_log("out", core.short_text(reply, 140))
  APP.ui_api.redraw()
  return reply, nil
end

-- 初始化 agent 模块。
function M.init(APP)
  M.APP = APP
  APP.agent = {
    llm_configured = llm_configured,
    handle_user_message = handle_user_message,
    prompt_preview = prompt_preview,
    execution_ledger = execution_ledger,
    classify_task = classify_task,
    route_task = model_route_task,
    session_key = session_key,
    sessions_list = sessions_list,
    session_history = session_history_snapshot,
    clear_session_history = clear_session_history,
  }
end

return M
