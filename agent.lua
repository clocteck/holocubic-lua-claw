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

local function wants_code_explanation(text)
  if text_has_code_explanation(text) then
    return true
  end
  local history = M.APP.history or {}
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

local function simple_checksum(text)
  text = M.APP.core.text_or(text, "")
  local h = 0
  for i = 1, #text do
    h = (h * 131 + text:byte(i)) % 1000000007
  end
  return tostring(h)
end

local function append_jsonl_limited(path, entry, limit)
  local APP = M.APP
  local core = APP.core
  limit = tonumber(limit) or 120
  entry = type(entry) == "table" and entry or {}
  entry.at = tonumber(entry.at) or core.now_ms()
  local line = core.safe_json_encode(entry)
  if not line then
    return false, "ledger encode failed"
  end
  local lines = {}
  local raw = core.read_text_file(path)
  if raw and raw ~= "" then
    for old in raw:gmatch("[^\r\n]+") do
      lines[#lines + 1] = old
    end
  end
  lines[#lines + 1] = line
  while #lines > limit do
    table.remove(lines, 1)
  end
  return core.write_text_file(path, table.concat(lines, "\n"))
end

local function append_ledger(entry)
  local ok, err = append_jsonl_limited(execution_ledger_path(), entry, 160)
  if not ok and M.APP and M.APP.core then
    M.APP.core.append_log("warn", M.APP.core.short_text(err or "ledger failed", 120))
  end
end

local function execution_ledger(limit)
  local APP = M.APP
  local core = APP.core
  local raw = core.read_text_file(execution_ledger_path())
  local out = {}
  limit = core.clamp(limit or 40, 1, 160)
  if raw and raw ~= "" then
    for line in raw:gmatch("[^\r\n]+") do
      local item = core.safe_json_decode(line)
      if type(item) == "table" then
        out[#out + 1] = item
      end
    end
  end
  while #out > limit do
    table.remove(out, 1)
  end
  return { ok = true, entries = out }
end

local function classify_task(user_text)
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
    "帮我画", "帮我实现", "帮我做", "帮我写", "帮我改", "帮我修",
    "画一个", "做一个", "写一个", "运行", "上传", "修复", "改成", "帮我测试", "测试一下",
    "补上", "加上", "加一", "加个", "添加", "增加", "加入", "优化", "增强",
    "直接实现", "直接做", "直接写", "直接运行", "跑起来", "开始写", "开写",
  }) or lower:find("implement", 1, true) or lower:find("draw ", 1, true)
    or lower:find("build ", 1, true) or lower:find("fix ", 1, true)
    or lower:find("run ", 1, true) or lower:find("write ", 1, true)
    or lower:find("add ", 1, true) or lower:find("improve", 1, true)

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
    "帮我画", "帮我实现", "帮我做", "帮我写", "画一个", "做一个", "写一个",
    "实现一个", "新建", "从头", "重新做一个",
  }) or lower:find("draw ", 1, true) or lower:find("build ", 1, true)

  local previous_cue = text_has_any(text, {
    "之前", "上一", "上次", "刚才", "刚才代码", "继续", "基于", "基础上", "保留",
    "没显示", "不显示", "看不到", "没有显示", "没画", "没出来", "没有出来", "画不出来", "错", "错误", "报错",
    "修", "改一下", "调整", "补上", "加上", "加一", "加个",
    "添加", "增加", "加入", "优化", "增强", "少了", "缺少", "不对",
  }) or lower:find("previous", 1, true) or lower:find("last", 1, true)
    or lower:find("continue", 1, true) or lower:find("fix", 1, true)
    or lower:find("add ", 1, true) or lower:find("improve", 1, true)

  local visual = text_has_any(text, {
    "画", "显示", "屏幕", "面板", "动画", "旋转", "摆", "立方体", "圆锥",
    "圆角", "Canvas", "LVGL", "UI", "轨迹", "颜色", "线条",
  }) or lower:find("lvgl", 1, true) or lower:find("canvas", 1, true)

  local mode = "answer"
  if asks_code then
    if previous_cue and not fresh_creation then
      mode = text_has_any(text, { "报错", "错误", "没显示", "不显示", "看不到", "没画", "没出来", "画不出来", "失败" }) and "debug_previous" or "modify_previous"
    else
      mode = "new_code"
    end
  elseif previous_cue then
    mode = text_has_any(text, { "没显示", "不显示", "看不到", "没画", "没出来", "画不出来", "报错", "错误", "失败" })
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
    "帮我实现", "帮我做", "帮我写", "帮我改", "帮我修", "帮我上传", "帮我测试",
    "直接实现", "直接做", "直接写", "直接运行", "直接给我做", "直接上", "上代码",
    "我要补上", "我要实现", "我要做", "我要接", "我要运行", "我要写",
    "补上真实", "接真实", "接入真实", "实现这个", "实现这个app", "实现这个 App",
    "写代码", "运行代码", "跑起来", "开始做", "开始写", "开写", "开干",
    "继续做", "继续写", "继续实现", "接着做", "接着写", "接着改",
    "没显示", "不显示", "看不到", "没画", "没出来", "画不出来",
    "在刚才代码基础上", "在之前代码基础上", "基于刚才", "基于之前",
    "加一", "加个", "加上", "添加", "增加", "加入", "优化", "增强",
    "全部从头实现", "从头实现", "完整实现",
  }) then
    return true
  end

  if text_has_any(text, { "好的", "可以", "行", "开始", "继续", "来", "上" })
    and text_has_any(text, { "补上", "实现", "接入", "真实数据", "运行", "做", "写", "代码" }) then
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
    "直接实现", "直接做", "直接写", "直接给我做", "直接上", "上代码",
    "我要补上", "我要实现", "我要做", "我要接", "我要写",
    "补上真实", "接真实", "接入真实", "实现这个", "实现这个app", "实现这个 App",
    "写代码", "跑起来", "开始写", "开写", "开干", "继续做", "继续写", "继续实现",
    "接着做", "接着写", "接着改",
    "没显示", "不显示", "看不到", "没画", "没出来", "画不出来",
    "在刚才代码基础上", "在之前代码基础上", "基于刚才", "基于之前",
    "加一", "加个", "加上", "添加", "增加", "加入", "优化", "增强",
    "全部从头实现", "从头实现", "完整实现",
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

local function recent_user_expects_implementation(limit)
  local history = M.APP.history or {}
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

local function turn_expects_implementation(text)
  if user_expects_implementation(text) then
    return true
  end
  return short_action_confirmation(text) and recent_user_expects_implementation(8)
end

local function turn_expects_action(text)
  if user_expects_action(text) then
    return true
  end
  return short_action_confirmation(text) and recent_user_expects_implementation(8)
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
    or text_has_any(text, {
      "请告诉我具体", "告诉我具体", "需要哪部分", "需要哪个部分", "你要看哪部分",
      "要我继续", "我可以继续", "如果需要我可以",
    }) then
    return true
  end
  return text_has_any(text, {
    "如果你愿意", "如果你要", "你要的话", "下一步", "我可以继续",
    "我就直接", "我再继续", "请把", "发我", "需要你确认",
    "再查一次", "我再查", "换用", "换个接口", "换一个接口", "再试一次",
    "改用备用", "等待返回",
  })
end

-- 不在这里判断用户意图，只判断“这条无工具回复值得让模型自审一次”。
local function should_review_no_tool_response(user_text, previous_text, task_plan)
  local execution_required = type(task_plan) == "table" and task_plan.execution_required == true
  if execution_required and response_looks_like_unexecuted_code(previous_text) then
    return true
  end
  if execution_required and response_looks_like_deferral(previous_text) then
    return true
  end
  if execution_required and short_action_confirmation(user_text) and recent_user_expects_implementation(8) then
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

local function lua_run_needs_followup(user_text, args_json, output, task_plan)
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
  elseif not turn_expects_implementation(user_text) then
    return false
  end
  return lua_run_looks_probe(args_json, output)
end

local function tool_reply_can_be_fallback(name, args_json, output, user_text, task_plan)
  if name == "activate_skill" then
    return false
  end
  if name == "get_panel_history" or name == "get_panel_artifacts"
    or name == "get_code_capabilities" or name == "preflight_lua" then
    return false
  end
  if name == "lua_run" and lua_run_needs_followup(user_text, args_json, output, task_plan) then
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

local function lua_code_looks_visual(code)
  code = M.APP.core.text_or(code, "")
  return code:find("lv_", 1, true)
    or code:find("LV_", 1, true)
    or code:find("ui_scr_act", 1, true)
    or code:find("ui_clear", 1, true)
    or code:find("lvgl", 1, true)
    or code:find("LVGL", 1, true)
end

local function tool_start_notice(name, args_json)
  local APP = M.APP
  local core = APP.core
  local args = decode_tool_args(args_json)
  if name == "activate_skill" then
    return ""
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
            .. " url=" .. core.text_or(s.url, ""))
        end
      end
    elseif core.text_or(doc.url, "") ~= "" then
      remember_observation("lookup_source",
        core.text_or(doc.source, "") .. " status=" .. tostring(doc.status or "")
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
    "query=" .. core.text_or(ctx.query, "") .. " kind=" .. core.text_or(ctx.kind, "") .. " at=" .. tostring(ctx.at or 0),
  }
  if #sources > 0 then
    lines[#lines + 1] = "Sources:"
    for i = 1, math.min(#sources, 5) do
      local s = sources[i]
      if type(s) == "table" then
        lines[#lines + 1] = "- " .. core.text_or(s.source, "")
          .. " status=" .. tostring(s.status or "")
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

local function append_recent_conversation(parts, limit)
  local APP = M.APP
  local core = APP.core
  local history = APP.history or {}
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

-- 无工具回复疑似空转时，让模型自己二次判断该聊天还是该执行。
local function force_action_input(user_text, previous_text, task_plan, source)
  local APP = M.APP
  local core = APP.core
  local parts = {
    "Review the original request, recent conversation, and your previous response.",
    "Decide yourself whether the user is asking for a normal text answer or asking you to execute an action now.",
    "Your previous response did not call any tool.",
    "If the user only wanted explanation or discussion, answer concisely.",
    "If the user wanted implementation, running code, fixing, uploading, testing, or continuing a selected task, do not return a code block or plan as the final answer. Activate the appropriate skill and call tools.",
    "For Lua app, UI, HTTP, file, or device-code work, prefer activating code_runner. Do not activate memory_ops unless the user explicitly asks about long-term memory.",
    "If execution is impossible, report the concrete blocker instead of asking for vague confirmation.",
    "Original user request: " .. core.text_or(user_text, ""),
  }
  if type(task_plan) == "table" then
    local raw_plan = core.safe_json_encode(task_plan)
    if raw_plan then
      parts[#parts + 1] = "Agent task plan: " .. raw_plan
      if task_plan.mode == "inspect" then
        parts[#parts + 1] = "This is a real file/source inspection request. You must activate app_inspect or use service lua_run to inspect files. Do not answer from memory or previous responses."
        parts[#parts + 1] = "Current agent app root: " .. core.text_or(APP.APP_DIR, "/sd/apps/esp_claw") .. ". For this agent's own files, records, or recent conversation traces, start from this root unless the user names another path."
        parts[#parts + 1] = "If you have only activated a skill or listed a directory, the task is still incomplete. Use observed paths and the latest user request to decide which relevant files to read next with service lua_run."
      end
      if task_plan.target == "service" then
        parts[#parts + 1] = "This is a service-side task. Do not use Panel history/artifacts unless the latest user request explicitly mentions screen, Panel, UI, LVGL, canvas, or a visual artifact."
      end
    end
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
  append_recent_conversation(parts, 8)
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
      and not lua_run_needs_followup(user_text, item.arguments, item.output, task_plan) then
      local doc = M.APP.core.safe_json_decode(item.output)
      if type(doc) == "table" and doc.ok == true then
        saw_lua_success = true
      end
    end
    if type(item) == "table" and item.name == "lua_run" and lua_run_needs_followup(user_text, item.arguments, item.output, task_plan) then
      saw_probe = true
    end
  end
  local parts = {
    "The previous model step called tools. Tool results are below.",
    "Continue the same user request using these results.",
    "Decide whether the original request still requires execution. If it does, continue with tools; if it is complete, summarize the actual result.",
    "If a tool result contains stdout/data that answers the user's request, write the final user-facing answer now. Do not stop after progress text, and do not call more tools unless the requested information is clearly missing.",
    "activate_skill only loads operating instructions. It does not inspect files, run code, or complete the user's requested action by itself.",
    "The latest user request has priority over any history or artifact returned by tools.",
    "For Lua app, UI, HTTP, file, or device-code work, code_runner is the execution skill. memory_ops is only for long-term memory requests.",
    "Context and inspection tools such as get_panel_history, get_panel_artifacts, get_code_capabilities, and preflight_lua do not complete an implementation request by themselves.",
    "If the current user request is a short style, variant, quantity, or refinement, infer the pending visual/code task from Recent conversation and execute the updated version.",
    "When the user has already selected a style for a pending visual/code request, do not ask for another confirmation such as start/begin; run it unless a safety rule requires confirmation.",
    "If lua_run returned ok=false or its output contains ERR/traceback/nil-value error text, fix the Lua code and call lua_run again. Do not ask the user unless the error cannot be resolved from the result.",
    "If lua_run Output.error is panel result timeout, launch panel failed, or app.launch missing, do not rewrite the visual code as a fix; report the panel launch/confirmation problem.",
    "After a lua_run error, do not repeat the same failing code. If the user asked to intentionally test an error, the first observed error completes that test; the next lua_run must be the corrected implementation.",
    "For lua_run, the actual code written to the device is exactly Tool Arguments.code. If Output contains code_checksum/code_bytes/code_preview, use them as the execution trace.",
    "Do not describe UI contents, time sources, files written, or network results unless they are visible in Tool Arguments.code, Output.stdout, Output.result, or Output.error.",
    "If there are multiple lua_run calls, distinguish panel UI execution from later service probes; never use a service probe result as if it described the panel UI.",
  }
  if force_run_now then
    parts[#parts + 1] = "You have already inspected enough context for this implementation request. Do not call get_panel_artifacts, get_panel_history, get_code_capabilities, or preflight_lua again. Patch or write the Lua code now and call lua_run in this next step."
  end
  if type(task_plan) == "table" then
    local raw_plan = core.safe_json_encode(task_plan)
    if raw_plan then
      parts[#parts + 1] = "Agent task plan: " .. raw_plan
      if task_plan.execution_required == false or task_plan.allow_text_only == true then
        parts[#parts + 1] = "This request may be answered in text. Do not call tools just because the input or previous response contains code-looking text."
      elseif task_plan.mode == "live_lookup" then
        parts[#parts + 1] = "This is a current external information lookup. Prefer web_probe/web_fetch/lookup_context. If one source failed, compare other sources before declaring realtime lookup unavailable."
        parts[#parts + 1] = "Answer from structured source title/excerpt/items/status and include concise source names. For professional/API/model/spec questions, prefer official pages and compare 2-3 pages when possible."
      elseif task_plan.mode == "new_code" then
        parts[#parts + 1] = "This is a fresh implementation. If a history/artifact tool returned unrelated prior code, ignore it and run the requested new implementation."
      elseif task_plan.mode == "inspect" then
        parts[#parts + 1] = "This is an inspection request. If the only successful tool was activate_skill or a directory listing, continue with service lua_run and read the relevant source files. Do not stop after skill activation or listdir."
        parts[#parts + 1] = "Current agent app root: " .. core.text_or(APP.APP_DIR, "/sd/apps/esp_claw") .. ". For this agent's own files, records, or recent conversation traces, start from this root unless the user names another path."
        parts[#parts + 1] = "Use the observed directory listing and the user's actual question to choose the next files. Prefer a small set of highly relevant source files over dumping an entire app."
      elseif task_plan.needs_history then
        parts[#parts + 1] = "This looks like a follow-up. Use only matching prior artifacts/history; if none match, continue from the current request rather than a random recent artifact."
      end
      if task_plan.target == "service" then
        parts[#parts + 1] = "The target is service. Do not use get_panel_history or get_panel_artifacts unless the latest user request explicitly mentions screen, Panel, UI, LVGL, canvas, or visual artifact."
      end
    end
  end
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
  if wants_code_explanation(user_text) then
    parts[#parts + 1] = "The original request asks for an explanation. If lua_run succeeded, do not call more tools just to explain; summarize how the provided Lua code works using the tool arguments and output."
  end
  append_recent_conversation(parts, 8)
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
  append_recent_conversation(parts, 6)
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

local function history_token_total()
  local total = 0
  for i = 1, #(M.APP.history or {}) do
    total = total + estimate_tokens(history_line(M.APP.history[i], history_message_limit()))
  end
  return total
end

local function recent_history_lines(max_tokens)
  local APP = M.APP
  local core = APP.core
  local history = type(APP.history) == "table" and APP.history or {}
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

local function append_recent_history(parts, max_tokens)
  local lines = recent_history_lines(max_tokens)
  if #lines == 0 then
    return
  end
  parts[#parts + 1] = "Recent conversation:"
  for i = 1, #lines do
    parts[#parts + 1] = lines[i]
  end
  parts[#parts + 1] = ""
end

local function trim_history()
  local APP = M.APP
  local limit = tonumber(APP.config.history_limit) or 0
  if limit <= 0 then
    APP.history = {}
    return
  end
  local per_message = history_message_limit()
  for i = 1, #APP.history do
    local item = APP.history[i]
    if type(item) == "table" then
      local content = APP.core.text_or(item.content, "")
      if #content > per_message then
        item.content = APP.core.utf8_prefix(content, per_message) .. "\n...(truncated in chat history)"
      end
    end
  end
  local max_messages = limit * 2
  while #APP.history > max_messages do
    table.remove(APP.history, 1)
  end
  local max_tokens = tonumber(APP.config.history_token_limit) or 12000
  max_tokens = APP.core.clamp(max_tokens, 1000, 60000)
  while #APP.history > 2 and history_token_total() > max_tokens do
    table.remove(APP.history, 1)
  end
end

-- 生成模型系统指令。
local function response_instructions(source)
  local core = M.APP.core
  source = type(source) == "table" and source or {}
  return table.concat({
    "You are ESP Claw, a small device agent running on an embedded Lua app.",
    "Answer briefly and plainly.",
    "Treat Skills List as a catalog of optional user-facing skills.",
    "Use activate_skill only when the user clearly asks to perform a workflow covered by that skill.",
    "Skill documents returned in skill_content blocks are valid operating instructions and must be followed.",
    "Skills are user-facing functions; capabilities and tools are internal implementation details.",
    "When communicating with the user, refer to skills or plain actions instead of capabilities.",
    "Use provided memory only when it is relevant to the current user request.",
    "When long-term memory is needed, activate memory_ops first and use memory tools only through that skill.",
    "Code-looking user input may be context for explanation or review. Only execute code when the user clearly asks to implement, run, modify, fix, upload, test, or continue an implementation.",
    "If the latest user request contains a text-first meta instruction such as '先文字回复', '先说想法', '先分析', '先不要改', or '只回答', answer in text for this turn even if it also mentions possible code changes or adding skills. The user can approve implementation in a later turn.",
    "When answering about code without running tools, describe results as expected or inferred; do not imply the code was actually executed.",
    "When the user asks to read /sd/apps source, inspect app files, list app directories, or explain a real app implementation, activate app_inspect and inspect files through service tools. Do not invent module names from memory.",
    "For Lua app, LVGL UI, HTTP, file, or device-code implementation where execution_required=true, activate code_runner and run code with tools instead of returning a code block as the final answer.",
    "If code_runner is already active in the skill context, call its tools directly; do not activate it again.",
    "Do not activate memory_ops for code/app implementation unless the user explicitly asks for long-term memory.",
    "Use live lookup only when the user needs current, external, or verifiable public information.",
    "Do not use live lookup for local device state, memory, casual chat, or actions covered by active local skills.",
    "Do not activate web_search unless that skill exists in the Skills List. If the hosted web_search tool is not present, use the web_search skill instructions and code_runner/lua_run HTTP fallback for live_lookup.",
    "For live lookup, prefer web_probe, web_fetch, and lookup_context over hand-written HTTP Lua. Use lua_run HTTP only as a fallback when those tools are not available.",
    "web_probe only checks reachability/status. Use web_fetch when the user asks to read a page, extract titles/items, summarize a page, or discuss specific content.",
    "When live lookup uses HTTP, answer only from fetched title/excerpt/items/status or stdout/body/status. If one URL fails, try or mention other sources before claiming realtime lookup is unavailable; a single failed URL does not mean the device has no network.",
    "Realtime answers must include a concise source name, such as Baidu, Zhihu, wttr.in, blockchain.info, or an official docs site.",
    "For realtime professional/API/model/spec questions, prefer official pages first and compare 2-3 relevant pages when possible before giving a confident answer.",
    "For follow-up questions about a previous lookup, use lookup_context first before fetching new pages.",
    "For service HTTP lookups in Lua, prefer synchronous calls such as local code, body = http.get(url, {timeout=5000, bufsz=...}) and print the status/body. Avoid callback-style HTTP when the user needs the result in this chat turn, because callback output may not be captured before lua_run returns.",
    "Do not use raw memory files such as memory_records.jsonl, memory_index.json, memory_digest.log, or MEMORY.md as direct decision input.",
    "When execution_required=true or the user clearly asks to implement, build, run, fix, upload, test, or continue an implementation, do the work with skills and tools. If allow_text_only=true, a concise normal answer is acceptable.",
    "If the recent conversation contains a pending visual/code request and the user now provides a style, variant, element count, or short refinement, treat it as confirmation to continue that request and execute it. Do not ask the user to say start again.",
    "Each turn may include an Agent task plan. Treat it as routing context, but the latest user request has priority.",
    "For new_code tasks, implement the requested new result first; do not stop after reading history and do not replace the request with an unrelated recent artifact.",
    "For modify_previous/debug_previous tasks, decide whether prior code is relevant. If needed, activate code_runner and read matching Panel artifacts/history before writing code; preserve the relevant previous program instead of replacing it with an unrelated small demo.",
    "For code tasks with thinking enabled, keep internal reasoning concise and proceed to the necessary tool call promptly.",
    "For multi-step work, make the visible process feel interactive: give short user-facing progress notes and final action summaries. Do not reveal hidden chain-of-thought; summarize observable steps, decisions, and results.",
    "Do not guess GPIO pins, board inventory, or hardware support.",
    "Do not claim file, image, GPIO, or complex hardware control support unless an active skill or tool declares it.",
    "Never delete directories or broad paths such as /sd. For deleting a single file, ask for explicit confirmation first and do not call tools in the same turn.",
    "When writing device code, do not invent APIs. Use only interfaces declared by active Skill docs or observed in tool results; otherwise probe first or choose a simpler verified API.",
    "Even when the user asks only for a design or explanation for this device, keep API names consistent with known device capabilities. Do not suggest unverified APIs as if they were available.",
    "Use Panel history/artifacts only for screen, UI, LVGL, canvas, visual, or Panel follow-ups. For service-side Lua/data/file tasks, use service tools and recent conversation instead.",
    "If the user asks for implementation details, explanation, or how previous code worked, answer from recent conversation and tool results. Do not activate code_runner just to report activation.",
    "When summarizing lua_run, only claim what the tool actually executed: Tool Arguments.code is the submitted code, and Output.stdout/result/error is the observed result.",
    "If a panel lua_run is queued or reports a result timeout, say execution was not confirmed instead of saying the UI is running.",
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
    local raw_plan = core.safe_json_encode(task_plan)
    if raw_plan then
      parts[#parts + 1] = "Agent task plan:"
      parts[#parts + 1] = raw_plan
      parts[#parts + 1] = "Use artifacts/history only when this plan says needs_history=true, unless the latest user request clearly requires otherwise."
      parts[#parts + 1] = "If text_first_request=true, the user is asking for discussion or analysis first. Let your semantic judgment decide the answer, but do not force tool use merely because code changes are mentioned."
      parts[#parts + 1] = "If execution_required=false or allow_text_only=true, answer normally unless the user clearly asks you to run or modify code. Code snippets may be context for explanation."
      if task_plan.target == "service" then
        parts[#parts + 1] = "For service-side tasks, do not use Panel history/artifacts unless the latest user request explicitly mentions screen, Panel, UI, LVGL, canvas, or a visual artifact."
      end
      if task_plan.mode == "inspect" then
        parts[#parts + 1] = "For inspect requests, activating a skill or listing a directory is not enough. Use service lua_run to read relevant source files and summarize observed contents."
        parts[#parts + 1] = "Current agent app root: " .. core.text_or(APP.APP_DIR, "/sd/apps/esp_claw") .. ". For this agent's own files, records, or recent conversation traces, start from this root unless the user names another path."
        parts[#parts + 1] = "Choose files from observed paths based on the user's wording. Read only enough source to answer accurately, then summarize what you actually observed."
      end
      if task_plan.mode == "live_lookup" then
        parts[#parts + 1] = "For live lookup, use web_probe/web_fetch for structured source checks. Do not decide the whole network is offline from one failed URL."
        parts[#parts + 1] = "web_probe is status-only. If the user asks to fetch/read/list items/headlines, call web_fetch or lookup_context before answering."
        parts[#parts + 1] = "For follow-up lookup questions, first use Recent lookup_context if it answers the user's reference, item number, or source question."
        parts[#parts + 1] = "Final realtime answers must cite concise source names and should prefer official sources for professional/API/model/spec questions."
      end
      parts[#parts + 1] = ""
    end
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
  append_recent_history(parts, math.min(tonumber(APP.config.history_token_limit) or 8000, 8000))
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
  local task_plan = classify_task(user_text)

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
  append_recent_history(history_parts, math.min(tonumber(APP.config.history_token_limit) or 8000, 8000))

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
      max_tokens = (type(source) == "table" and source.router_call) and 700 or (deepseek_thinking and 65535 or 4096),
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
      max_output_tokens = (type(source) == "table" and source.router_call) and 700 or 4096,
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
  local request_timeout = tonumber(APP.config.llm_timeout_ms) or 45000
  if type(source) == "table" and source.router_call then
    request_timeout = math.min(request_timeout, 12000)
  end
  if plan_is_code_task(task_plan) then
    request_timeout = math.min(request_timeout, 30000)
  end
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

  if code ~= 200 then
    local transient = core.text_or(resp_body, ""):find("ESP_ERR_HTTP_INCOMPLETE_DATA", 1, true)
      or core.text_or(resp_body, ""):find("timeout", 1, true)
    if api_kind == "chat" and is_deepseek_base() and transient and type(body.thinking) == "table"
      and body.thinking.type == "enabled" then
      -- 长推理在嵌入式 HTTP 上偶发不完整，降级为普通回答再试一次。
      body.thinking = { type = "disabled" }
      body.reasoning_effort = nil
      body.max_tokens = 4096
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
    "Do not require extra work just because more detail is possible. Require continuation only when the requested action/facts are missing, unsupported by tool facts, contradicted, or the answer asks the user to continue after the work should already be complete.",
    "If tool facts show only one failed external URL, do not infer the whole device network is offline unless multiple relevant probes or a clear network-wide error support that conclusion.",
    "web_probe proves only reachability/status. It does not prove page contents or extracted items. If the candidate lists headlines/items/page details, those exact facts must appear in web_fetch items/excerpt/title, lookup_context items, or another content-bearing tool result.",
    "For source/file inspection, skill activation or directory listing alone is not enough if the user asked to read specific implementation content.",
    "For code/run tasks, a final answer should mention the observed success/error from tool facts, especially if a failure was later repaired.",
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
  append_recent_conversation(parts, 6)
  return table.concat(parts, "\n")
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
  local output = APP.tools.execute_tool("lua_run", args_json)
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

local function apply_task_plan_policy(plan, fallback, user_text)
  local core = M.APP.core
  fallback = type(fallback) == "table" and fallback or classify_task(user_text)
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
  fallback = type(fallback) == "table" and fallback or classify_task(user_text)
  if not llm_configured() or not http or not http.post then
    fallback.router_source = "fallback"
    fallback.router_reason = "router unavailable"
    return apply_task_plan_policy(fallback, fallback, user_text)
  end
  if fallback.text_first_request == true then
    -- 用户明确要求先文字讨论时，本地策略优先于模型 router。
    fallback.router_source = "fallback_text_first"
    fallback.router_reason = "text-first policy override"
    return apply_task_plan_policy(fallback, fallback, user_text)
  end

  local history = {}
  -- Router 只看最近几条，避免旧任务把当前短句带偏。
  local start_index = #(APP.history or {}) - 5
  if start_index < 1 then start_index = 1 end
  for i = start_index, #(APP.history or {}) do
    local item = APP.history[i]
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
    "Use debug_previous with needs_history=true for follow-up failure reports such as a prior visual not rendering, not showing, drawing nothing, errors, or asking why the previous result failed.",
    "Use live_lookup when the user needs current external facts such as prices, news, weather, exchange rates, or latest public info.",
    "Words such as today, latest, weather, or price are hints only; choose live_lookup only when the user is really asking for current external facts.",
    "Use panel only for visible UI/LVGL/Canvas/screen visual work; use service for HTTP, files, source reading, and non-UI Lua.",
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
    return apply_task_plan_policy(fallback, fallback, user_text)
  end
  local text = response_text(resp)
  local raw_json = extract_json_object(text)
  local parsed = raw_json and core.safe_json_decode(raw_json) or nil
  if type(parsed) ~= "table" then
    fallback.router_source = "fallback"
    fallback.router_reason = "router returned non-json"
    return apply_task_plan_policy(fallback, fallback, user_text)
  end
  parsed.router_source = "model"
  return apply_task_plan_policy(parsed, fallback, user_text)
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
    APP.history[#APP.history + 1] = { role = "user", content = user_text .. "\n[image] " .. source.image_path }
    APP.history[#APP.history + 1] = { role = "assistant", content = final_text }
    trim_history()
    if APP.memory and APP.memory.observe_turn then
      pcall(APP.memory.observe_turn, user_text, final_text, source)
    end
    return final_text, nil
  end

  local rounds = core.clamp(tonumber(APP.config.max_tool_rounds) or 32, 1, 64)
  local fallback_plan = classify_task(user_text)
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
  local forced_action_retries = 0
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
      local needs_action_retry = should_review_no_tool_response(user_text, text, task_plan) or implementation_without_run or repair_without_run
      if force_final_answer and fallback_text ~= "" and response_looks_like_unexecuted_code(text) then
        final_text = fallback_text
        break
      elseif needs_action_retry and forced_action_retries < 2 then
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
        final_text = "操作未完成：这次请求需要实际读取或执行工具，但模型没有调用必要工具。"
        break
      else
        local continued_by_review = false
        local candidate_text = text
        if completion_reviews < 1 then
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
      local tool_outputs = {}
      local tool_results = {}
      local finish_after_tool = false
      local step_context_only = #tool_calls > 0
      local step_lua_success_with_stdout = false
      for i = 1, #tool_calls do
        local tc = tool_calls[i]
        local name = core.text_or(tc.name, "")
        local args = tc.arguments or "{}"
        if not is_context_tool(name) then
          step_context_only = false
        end
        if progress_notices < max_progress_notices then
          local notice = tool_start_notice(name, args)
          if notice ~= "" then
            send_progress_once(notice)
          end
        end
        -- 工具执行结果会进入下一轮模型输入，也会被记录到 execution ledger 便于排查。
        local output = APP.tools.execute_tool(name, args)
        if name == "activate_skill" then
          saw_activate_skill = true
        end
        if name == "lua_run" and not lua_run_needs_followup(user_text, args, output, task_plan) then
          saw_lua_run = true
        end
        if name == "web_probe" or name == "web_fetch" or name == "lookup_context" then
          saw_action_run = true
        end
        if name == "lua_run" and lua_run_repairable_error_text(output) == ""
          and not lua_run_needs_followup(user_text, args, output, task_plan) then
          local doc = core.safe_json_decode(output)
          if type(doc) == "table" and doc.ok == true then
            saw_lua_success = true
          end
        end
        if name == "lua_run" and lua_run_repairable_error_text(output) ~= "" then
          saw_lua_error = true
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
        if tool_reply_can_be_fallback(name, args, output, user_text, task_plan) then
          local stdout_reply = name == "lua_run" and lua_stdout_fallback(output, task_plan) or ""
          fallback_text = stdout_reply ~= "" and stdout_reply or reply_hint
        elseif name == "lua_run" and fallback_text == "" then
          fallback_text = lua_stdout_fallback(output, task_plan)
        end
        if name == "lua_run"
          and lua_stdout_fallback(output, task_plan) ~= ""
          and lua_run_repairable_error_text(output) == ""
          and not lua_run_needs_followup(user_text, args, output, task_plan) then
          step_lua_success_with_stdout = true
        end
        if name == "lua_run" and progress_notices < max_progress_notices then
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
        if name == "lua_run" and wants_code_explanation(user_text) then
          should_finish = false
        end
        if name == "lua_run" and lua_run_needs_followup(user_text, args, output, task_plan) then
          should_finish = false
        end
        if should_finish then
          finish_after_tool = true
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
      if finish_after_tool then
        final_text = fallback_text or "操作已执行。"
        break
      end
      if step_context_only and plan_expects_implementation and not saw_lua_run then
        context_lookup_count = context_lookup_count + 1
      end
      input = tool_followup_input(user_text, tool_results, source, task_plan, context_lookup_count >= context_lookup_limit)
      if fallback_text ~= "" and step_lua_success_with_stdout and not wants_code_explanation(user_text) then
        input = tool_summary_input(user_text, accumulated_tool_results, source, task_plan)
        force_final_answer = true
      elseif fallback_text ~= "" and not saw_lua_error
        and ((type(task_plan) == "table" and task_plan.mode == "live_lookup")
          or user_wants_tool_result_answer(user_text)) then
        input = tool_summary_input(user_text, accumulated_tool_results, source, task_plan)
        force_final_answer = true
      end
      previous_response_id = ""
    end
  end

  if not final_text or final_text == "" then
    if fallback_text then
      final_text = fallback_text
    elseif saw_reasoning_only then
      final_text = "操作未完成：模型只返回了 thinking，没有给出工具调用或最终内容。"
    else
      final_text = "操作未完成：模型没有给出最终回复。"
    end
  end
  final_text = fit_final_reply(final_text, source, instructions, task_plan)

  APP.history[#APP.history + 1] = { role = "user", content = user_text }
  APP.history[#APP.history + 1] = { role = "assistant", content = final_text }
  trim_history()
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

  local guarded_reply = destructive_delete_guard(user_text)
  if guarded_reply then
    -- 删除类危险请求在进入 LLM 前拦截，避免模型通过工具绕过去。
    S.busy = false
    S.request_count = S.request_count + 1
    S.last_error = ""
    S.last_user = user_text
    S.last_channel = core.text_or(source.channel, "web")
    S.last_chat_id = core.text_or(source.chat_id, "")
    S.last_reply = guarded_reply
    core.append_log("guard", core.short_text(guarded_reply, 140))
    APP.history[#APP.history + 1] = { role = "user", content = user_text }
    APP.history[#APP.history + 1] = { role = "assistant", content = guarded_reply }
    trim_history()
    APP.ui_api.redraw()
    return guarded_reply, nil
  end

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
  S.busy = false
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
  }
end

return M
