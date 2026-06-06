local M = {}

local FINISH_AFTER_TOOL = {
  get_device_status = true,
  set_screen_message = true,
  set_brightness = true,
  memory_store = true,
  memory_recall = true,
  memory_list = true,
  memory_forget = true,
  inspect_image = true,
  wechat_send_image = true,
  self_check = true,
}

local function lua_run_reported_error(doc)
  if type(doc) ~= "table" then
    return false
  end
  local text = M.APP.core.text_or(doc.error, "")
  local stdout = M.APP.core.text_or(doc.stdout, "")
  if stdout ~= "" then
    text = text ~= "" and (text .. "\n" .. stdout) or stdout
  end
  if text == "" then
    return false
  end
  if text:match("^%s*ERR[%s:%(]") or text:match("\n%s*ERR[%s:%(]") then
    return true
  end
  if text:find("(claw_panel visual):", 1, true) or text:find("(esp_claw lua_run):", 1, true) then
    return true
  end
  if text:find("attempt to call a nil value", 1, true) or text:find("attempt to index a nil value", 1, true) then
    return true
  end
  if text:find("stack traceback", 1, true) then
    return true
  end
  return false
end

-- 这些工具的输出已经足够回复用户，避免嵌入式端继续阻塞等待下一轮模型。
local function should_finish_after_tool(name, output)
  if name == "lua_run" then
    return false
  end
  return FINISH_AFTER_TOOL[name] == true
end

-- 读取设备状态，供 LLM tool 调用。
local function tool_get_device_status(args)
  local APP = M.APP
  local snap = APP.core.status_snapshot()
  snap.logs = nil
  snap.config = nil
  local raw = APP.core.safe_json_encode(snap)
  return raw or "{\"ok\":true}"
end

-- 设置小屏 note 文本。
local function tool_set_screen_message(args)
  local APP = M.APP
  local core = APP.core
  local message = core.short_text(type(args) == "table" and args.message or "", 120)
  if message == "" then
    return "{\"ok\":false,\"error\":\"message is required\"}"
  end
  APP.ui_api.set_screen_text(message)
  APP.ui_api.redraw()
  return "{\"ok\":true,\"message\":\"screen updated\"}"
end

-- 设置屏幕亮度，缺少底层接口时只更新 app 状态。
local function tool_set_brightness(args)
  local APP = M.APP
  local core = APP.core
  local level = core.clamp(type(args) == "table" and args.level or 80, 1, 100)
  APP.state.brightness = level
  if sys and sys.setbrightness then
    local ok, err = pcall(sys.setbrightness, level)
    if not ok then
      return string.format("{\"ok\":false,\"error\":%q}", tostring(err))
    end
  end
  APP.ui_api.redraw()
  return string.format("{\"ok\":true,\"level\":%d}", level)
end

-- 激活一个 Skill，并把 Skill 文档作为工具输出交还给模型继续执行。
local function source_or_last(source)
  local APP = M.APP
  local core = APP.core
  source = type(source) == "table" and source or {}
  return {
    channel = core.text_or(source.channel, APP.state.last_channel ~= "" and APP.state.last_channel or "web"),
    chat_id = core.text_or(source.chat_id, APP.state.last_chat_id ~= "" and APP.state.last_chat_id or "web"),
  }
end

local function tool_activate_skill(args, source)
  local APP = M.APP
  local core = APP.core
  if not APP.skills or not APP.skills.activate then
    return "{\"ok\":false,\"error\":\"skills module missing\"}"
  end
  local skill_id = core.trim(type(args) == "table" and args.skill_id or "")
  if skill_id == "" then
    return "{\"ok\":false,\"error\":\"skill_id is required\"}"
  end
  local ok, result = APP.skills.activate(skill_id, source_or_last(source))
  if not ok then
    return string.format("{\"ok\":false,\"error\":%q}", core.text_or(result, "activate skill failed"))
  end
  local raw = core.safe_json_encode({
    ok = true,
    skill_id = result.id,
    description = result.description,
    cap_groups = result.cap_groups,
    already_active = result.already_active == true,
    activation_only = true,
    next_action = "Skill activation only loads instructions. Continue the user request by calling the concrete tools enabled by this skill; do not treat activation as task completion.",
    skill_content = result.already_active == true and nil or result.body,
  })
  return raw or "{\"ok\":true}"
end

local function panel_history_entry_for_tool(item, include_code, code_limit)
  local core = M.APP.core
  item = type(item) == "table" and item or {}
  local out = {
    id = core.text_or(item.id, ""),
    seq = core.text_or(item.seq, ""),
    title = core.text_or(item.title, ""),
    ok = item.ok ~= false,
    queued = item.queued == true,
    error = core.text_or(item.error, ""),
    stdout = core.utf8_prefix(core.text_or(item.stdout, ""), 1200),
    result = core.utf8_prefix(core.text_or(item.result, ""), 600),
    code_bytes = tonumber(item.code_bytes) or 0,
    code_checksum = core.text_or(item.code_checksum, ""),
    elapsed_ms = tonumber(item.elapsed_ms) or 0,
  }
  local code = core.text_or(item.code, "")
  if include_code and code ~= "" then
    code = code:gsub("\r\n", "\n")
    out.code = core.utf8_prefix(code, code_limit or 5000)
    out.code_truncated = #out.code < #code
  else
    out.code_preview = core.utf8_prefix(core.text_or(item.code_preview, ""), 1200)
  end
  return out
end

-- 读取最近 Panel 运行历史，让模型自行判断当前请求是否应沿用上一版可视化代码。
local function tool_get_panel_history(args)
  local APP = M.APP
  local core = APP.core
  if not APP.code_runner or not APP.code_runner.panel_history then
    return "{\"ok\":false,\"error\":\"panel history unavailable\"}"
  end

  args = type(args) == "table" and args or {}
  local include_code = args.include_code ~= false
  local id = core.trim(args.id)
  local entries = {}

  if id ~= "" then
    if not APP.code_runner.panel_history_get then
      return "{\"ok\":false,\"error\":\"panel history detail unavailable\"}"
    end
    local item, err = APP.code_runner.panel_history_get(id)
    if not item then
      return string.format("{\"ok\":false,\"error\":%q}", core.text_or(err, "history item not found"))
    end
    entries[#entries + 1] = panel_history_entry_for_tool(item, include_code, 8000)
  else
    local limit = core.clamp(args.limit or 3, 1, 5)
    local ok, list = pcall(APP.code_runner.panel_history, limit)
    if not ok or type(list) ~= "table" or type(list.entries) ~= "table" then
      return "{\"ok\":false,\"error\":\"panel history read failed\"}"
    end
    for i = 1, #list.entries do
      local item = list.entries[i]
      if include_code and APP.code_runner.panel_history_get and i <= 2 then
        local full = nil
        local detail_id = core.text_or(item.id, item.seq)
        if detail_id ~= "" then
          local ok_detail, detail = pcall(APP.code_runner.panel_history_get, detail_id)
          if ok_detail and type(detail) == "table" then
            full = detail
          end
        end
        item = full or item
      end
      entries[#entries + 1] = panel_history_entry_for_tool(item, include_code and i <= 2, i == 1 and 8000 or 5000)
    end
  end

  local raw = core.safe_json_encode({
    ok = true,
    entries = entries,
    guidance = "Use this history only if it is relevant to the current user request; ignore it for a fresh task.",
  })
  return raw or "{\"ok\":true,\"entries\":[]}"
end

local function tool_get_code_capabilities(args)
  local APP = M.APP
  local core = APP.core
  if not APP.code_runner or not APP.code_runner.capabilities then
    return "{\"ok\":false,\"error\":\"code capabilities unavailable\"}"
  end
  local raw = core.safe_json_encode({
    ok = true,
    capabilities = APP.code_runner.capabilities(),
  })
  return raw or "{\"ok\":true}"
end

local function tool_preflight_lua(args)
  local APP = M.APP
  local core = APP.core
  if not APP.code_runner or not APP.code_runner.preflight then
    return "{\"ok\":false,\"error\":\"preflight unavailable\"}"
  end
  local result = APP.code_runner.preflight(args)
  local raw = core.safe_json_encode(result)
  return raw or "{\"ok\":false,\"error\":\"preflight encode failed\"}"
end

local function tool_get_panel_artifacts(args)
  local APP = M.APP
  local core = APP.core
  if not APP.code_runner or not APP.code_runner.panel_artifacts then
    return "{\"ok\":false,\"error\":\"panel artifacts unavailable\"}"
  end
  local result = APP.code_runner.panel_artifacts(args)
  local raw = core.safe_json_encode(result)
  return raw or "{\"ok\":true,\"entries\":[]}"
end

local function ensure_lookup_state()
  local S = M.APP.state
  S.lookup_context = type(S.lookup_context) == "table" and S.lookup_context or {}
  S.lookup_context.sources = type(S.lookup_context.sources) == "table" and S.lookup_context.sources or {}
  S.lookup_context.items = type(S.lookup_context.items) == "table" and S.lookup_context.items or {}
  return S.lookup_context
end

local function source_name_from_url(url)
  url = M.APP.core.text_or(url, "")
  local host = url:match("^https?://([^/%?#]+)") or url
  host = host:gsub("^www%.", "")
  return host
end

local function html_entity_decode(text)
  text = M.APP.core.text_or(text, "")
  local map = {
    amp = "&",
    lt = "<",
    gt = ">",
    quot = "\"",
    apos = "'",
    nbsp = " ",
  }
  text = text:gsub("&(#%d+);", function(num)
    local n = tonumber(num:sub(2))
    if n and n >= 32 and n <= 126 then
      return string.char(n)
    end
    return " "
  end)
  text = text:gsub("&([%a]+);", function(name)
    return map[name] or " "
  end)
  return text
end

local function strip_html(text)
  local core = M.APP.core
  text = core.text_or(text, "")
  text = text:gsub("<script[%s%S]->[%s%S]-</script>", " ")
  text = text:gsub("<style[%s%S]->[%s%S]-</style>", " ")
  text = text:gsub("<[^>]+>", " ")
  text = html_entity_decode(text)
  return core.normalize_space(text)
end

local function extract_title(body)
  local core = M.APP.core
  body = core.text_or(body, "")
  local title = body:match("<title[^>]*>([%s%S]-)</title>")
  if title and title ~= "" then
    return core.short_text(strip_html(title), 160)
  end
  title = body:match([["title"%s*:%s*"([^"]+)"]]) or body:match([["name"%s*:%s*"([^"]+)"]])
  return core.short_text(html_entity_decode(core.text_or(title, "")), 160)
end

local function add_lookup_item(out, seen, text, url, source)
  local core = M.APP.core
  text = strip_html(text)
  text = text:gsub("^%d+[%.)、%s]+", "")
  text = core.trim(text)
  if text == "" or #text < 6 or #text > 220 then
    return
  end
  local lower = text:lower()
  if lower:find("javascript", 1, true)
    or lower:find("function", 1, true)
    or lower:find("var ", 1, true)
    or lower:find("cookie", 1, true) then
    return
  end
  if seen[text] then
    return
  end
  seen[text] = true
  out[#out + 1] = {
    index = #out + 1,
    title = core.short_text(text, 180),
    url = core.text_or(url, ""),
    source = core.text_or(source, ""),
  }
end

local function extract_items(body, base_url, source, limit)
  local core = M.APP.core
  body = core.text_or(body, "")
  limit = tonumber(limit) or 20
  local out = {}
  local seen = {}
  for href, text in body:gmatch("<a[^>]-href=[\"']([^\"']+)[\"'][^>]*>([%s%S]-)</a>") do
    add_lookup_item(out, seen, text, href, source)
    if #out >= limit then return out end
  end
  for text in body:gmatch([["title"%s*:%s*"([^"]+)"]]) do
    add_lookup_item(out, seen, text, base_url, source)
    if #out >= limit then return out end
  end
  for text in body:gmatch([["name"%s*:%s*"([^"]+)"]]) do
    add_lookup_item(out, seen, text, base_url, source)
    if #out >= limit then return out end
  end
  for line in strip_html(body):gmatch("[^。！？\n]+[。！？]?") do
    add_lookup_item(out, seen, line, base_url, source)
    if #out >= limit then return out end
  end
  return out
end

local function update_lookup_context(ctx)
  local APP = M.APP
  local core = APP.core
  local S = ensure_lookup_state()
  S.at = APP.core.now_ms()
  S.query = core.text_or(ctx.query, S.query or "")
  S.kind = core.text_or(ctx.kind, S.kind or "")
  S.sources = type(S.sources) == "table" and S.sources or {}
  S.items = type(S.items) == "table" and S.items or {}
  local evidence = core.text_or(ctx.evidence, "content")
  local source_id = core.text_or(ctx.source_id, "src_" .. tostring(S.at))

  local function source_key(item)
    return table.concat({
      core.text_or(item.url, ""),
      core.text_or(item.source, ""),
      tostring(item.status or ""),
      core.text_or(item.title, ""),
    }, "|")
  end

  local source_seen = {}
  for i = 1, #S.sources do
    source_seen[source_key(S.sources[i])] = true
  end
  local sources = type(ctx.sources) == "table" and ctx.sources or {}
  for i = 1, #sources do
    local item = sources[i]
    if type(item) == "table" then
      local copy = {}
      for k, v in pairs(item) do copy[k] = v end
      copy.source_id = core.text_or(copy.source_id, source_id .. "_" .. tostring(i))
      copy.evidence = core.text_or(copy.evidence, evidence)
      copy.probe_only = copy.evidence == "probe"
      local key = source_key(copy)
      if not source_seen[key] then
        source_seen[key] = true
        S.sources[#S.sources + 1] = copy
      end
    end
  end
  while #S.sources > 12 do
    table.remove(S.sources, 1)
  end

  local item_seen = {}
  for i = 1, #S.items do
    item_seen[core.text_or(S.items[i].source, "") .. "|" .. core.text_or(S.items[i].url, "") .. "|" .. core.text_or(S.items[i].title, "")] = true
  end
  local items = type(ctx.items) == "table" and ctx.items or {}
  if evidence ~= "probe" then
    for i = 1, #items do
      local item = items[i]
      if type(item) == "table" then
        local copy = {}
        for k, v in pairs(item) do copy[k] = v end
        copy.source_id = core.text_or(copy.source_id, source_id .. "_1")
        copy.evidence = core.text_or(copy.evidence, "content")
        local key = core.text_or(copy.source, "") .. "|" .. core.text_or(copy.url, "") .. "|" .. core.text_or(copy.title, "")
        if not item_seen[key] then
          item_seen[key] = true
          S.items[#S.items + 1] = copy
        end
      end
    end
  end
  while #S.items > 60 do
    table.remove(S.items, 1)
  end
  for i = 1, #S.items do
    S.items[i].index = i
  end
  S.summary = core.text_or(ctx.summary, "")
end

local function fetch_url(url, options)
  local APP = M.APP
  local core = APP.core
  if not http or not http.get then
    return {
      ok = false,
      url = url,
      status = -1,
      source = source_name_from_url(url),
      error = "http.get missing",
    }
  end
  options = type(options) == "table" and options or {}
  local timeout = core.clamp(options.timeout_ms or 8000, 1000, 20000)
  local bufsz = core.clamp(options.bufsz or 32768, 4096, 131072)
  local code, body = http.get(url, {
    timeout = timeout,
    bufsz = bufsz,
    max_redirects = core.clamp(options.max_redirects or 2, 0, 5),
    headers = {
      ["User-Agent"] = "ESP-Claw/1.0",
      ["Accept"] = "text/html,application/json,text/plain,*/*",
    },
  })
  body = core.text_or(body, "")
  local status = tonumber(code) or -1
  local ok = status >= 200 and status < 400 and body ~= ""
  local title = ok and extract_title(body) or ""
  local excerpt = ok and core.short_text(strip_html(body), options.excerpt_chars or 1200) or ""
  local source = source_name_from_url(url)
  return {
    ok = ok,
    url = url,
    status = status,
    source = source,
    title = title,
    excerpt = excerpt,
    bytes = #body,
    error = ok and "" or core.short_text(body, 300),
    body = body,
  }
end

local function tool_web_probe(args)
  local APP = M.APP
  local core = APP.core
  args = type(args) == "table" and args or {}
  local urls = type(args.urls) == "table" and args.urls or {}
  local query = core.text_or(args.query, "")
  local kind = core.text_or(args.kind, "general")
  local limit = core.clamp(args.limit or #urls, 1, 5)
  local results = {}
  local sources = {}
  for i = 1, math.min(#urls, limit) do
    local url = core.trim(urls[i])
    if url ~= "" then
      local r = fetch_url(url, {
        timeout_ms = args.timeout_ms or 7000,
        bufsz = 16384,
        excerpt_chars = 360,
      })
      r.body = nil
      results[#results + 1] = r
      sources[#sources + 1] = {
        url = r.url,
        source = r.source,
        status = r.status,
        ok = r.ok,
        title = r.title,
        error = r.error,
      }
    end
  end
  update_lookup_context({
    query = query,
    kind = kind,
    sources = sources,
    items = {},
    evidence = "probe",
    summary = "web_probe checked " .. tostring(#results) .. " source(s)",
  })
  local raw = core.safe_json_encode({
    ok = true,
    query = query,
    kind = kind,
    results = results,
    sources = sources,
    evidence = "probe",
    probe_only = true,
    guidance = "A single failed URL does not prove the device is offline. Compare the statuses and continue with reachable sources.",
  })
  return raw or "{\"ok\":true}"
end

local function tool_web_fetch(args)
  local APP = M.APP
  local core = APP.core
  args = type(args) == "table" and args or {}
  local url = core.trim(args.url)
  if url == "" then
    return "{\"ok\":false,\"error\":\"url is required\"}"
  end
  local query = core.text_or(args.query, "")
  local kind = core.text_or(args.kind, "general")
  local r = fetch_url(url, {
    timeout_ms = args.timeout_ms or 9000,
    bufsz = args.bufsz or 65536,
    excerpt_chars = args.excerpt_chars or 1600,
  })
  local items = {}
  if r.ok then
    items = extract_items(r.body, url, r.source, core.clamp(args.item_limit or 16, 0, 30))
  end
  r.body = nil
  r.items = items
  update_lookup_context({
    query = query,
    kind = kind,
    source_id = "fetch_" .. tostring(core.now_ms()),
    sources = {
      {
        url = r.url,
        source = r.source,
        status = r.status,
        ok = r.ok,
        title = r.title,
        error = r.error,
        evidence = "content",
      },
    },
    items = items,
    evidence = "content",
    summary = r.ok and ("web_fetch " .. r.source .. " ok") or ("web_fetch " .. r.source .. " failed"),
  })
  local raw = core.safe_json_encode({
    ok = r.ok,
    url = r.url,
    status = r.status,
    source = r.source,
    title = r.title,
    excerpt = r.excerpt,
    bytes = r.bytes,
    error = r.error,
    items = items,
    evidence = "content",
    guidance = "Answer from title/excerpt/items and cite the concise source name. Do not claim more than this page supports.",
  })
  return raw or "{\"ok\":false,\"error\":\"web_fetch encode failed\"}"
end

local function tool_lookup_context(args)
  local APP = M.APP
  local core = APP.core
  local S = ensure_lookup_state()
  local raw = core.safe_json_encode({
    ok = true,
    at = S.at or 0,
    query = core.text_or(S.query, ""),
    kind = core.text_or(S.kind, ""),
    sources = S.sources,
    items = S.items,
    summary = core.text_or(S.summary, ""),
    guidance = "Use this for follow-up questions such as item numbers, source questions, or details from previous live lookups. Sources with probe_only=true are reachability evidence only; use content items for page facts.",
  })
  return raw or "{\"ok\":true}"
end

local TOOL_DEFS = {
  {
    type = "function",
    ["function"] = {
      name = "activate_skill",
      description = "Activate a user-facing skill by id and return its operating instructions.",
      parameters = {
        type = "object",
        properties = {
          skill_id = { type = "string", description = "Skill id from Skills List." },
        },
        required = { "skill_id" },
      },
    },
  },
  {
    groups = { "device_basic" },
    type = "function",
    ["function"] = {
      name = "get_device_status",
      description = "Read basic app, device, storage, and WeChat status.",
      parameters = {
        type = "object",
        properties = {
          include_details = {
            type = "boolean",
            description = "Optional. Return normal status details when true.",
          },
        },
      },
    },
  },
  {
    groups = { "device_basic" },
    type = "function",
    ["function"] = {
      name = "set_screen_message",
      description = "Set a short text note on the device screen.",
      parameters = {
        type = "object",
        properties = {
          message = { type = "string", description = "Short note to show on screen." },
        },
        required = { "message" },
      },
    },
  },
  {
    groups = { "device_basic" },
    type = "function",
    ["function"] = {
      name = "set_brightness",
      description = "Set device screen brightness from 1 to 100.",
      parameters = {
        type = "object",
        properties = {
          level = { type = "integer", minimum = 1, maximum = 100 },
        },
        required = { "level" },
      },
    },
  },
  {
    groups = { "claw_memory" },
    type = "function",
    ["function"] = {
      name = "memory_store",
      description = "Store a concise long-term memory fact on the device.",
      parameters = {
        type = "object",
        properties = {
          content = { type = "string", description = "Concise normalized memory fact, not a raw quote." },
          tags = { type = "string", description = "Optional comma-separated summary labels." },
          keywords = { type = "string", description = "Optional comma-separated retrieval keywords." },
        },
        required = { "content" },
      },
    },
  },
  {
    groups = { "claw_memory" },
    type = "function",
    ["function"] = {
      name = "memory_recall",
      description = "Recall relevant long-term memory facts for a query.",
      parameters = {
        type = "object",
        properties = {
          query = { type = "string", description = "Search query." },
        },
        required = { "query" },
      },
    },
  },
  {
    groups = { "claw_memory" },
    type = "function",
    ["function"] = {
      name = "memory_list",
      description = "List recent long-term memory facts.",
      parameters = {
        type = "object",
        properties = {
          limit = {
            type = "integer",
            minimum = 1,
            maximum = 20,
            description = "Optional maximum number of memories to list.",
          },
        },
      },
    },
  },
  {
    groups = { "claw_memory" },
    type = "function",
    ["function"] = {
      name = "memory_forget",
      description = "Forget long-term memory facts matching a query.",
      parameters = {
        type = "object",
        properties = {
          query = { type = "string", description = "Memory text or keyword to forget." },
        },
        required = { "query" },
      },
    },
  },
  {
    groups = { "code_runner" },
    type = "function",
    ["function"] = {
      name = "web_probe",
      description = "Probe 1-5 public URLs for live lookup and return structured reachability status. Use before declaring that network or realtime lookup is unavailable.",
      parameters = {
        type = "object",
        properties = {
          query = { type = "string", description = "The user's lookup question or search topic." },
          kind = { type = "string", description = "Optional lookup kind: news, docs, price, weather, official, or general." },
          urls = {
            type = "array",
            description = "Candidate public URLs to probe. Prefer official pages for professional/model/API questions.",
            items = { type = "string" },
          },
          limit = { type = "integer", minimum = 1, maximum = 5 },
          timeout_ms = { type = "integer", minimum = 1000, maximum = 20000 },
        },
        required = { "urls" },
      },
    },
  },
  {
    groups = { "code_runner" },
    type = "function",
    ["function"] = {
      name = "web_fetch",
      description = "Fetch one public page and return {url,status,source,title,excerpt,items} without dumping large HTML. Also saves lookup_context for follow-up questions.",
      parameters = {
        type = "object",
        properties = {
          url = { type = "string", description = "Public URL to fetch." },
          query = { type = "string", description = "The user's lookup question or search topic." },
          kind = { type = "string", description = "Optional lookup kind: news, docs, price, weather, official, or general." },
          item_limit = { type = "integer", minimum = 0, maximum = 30 },
          excerpt_chars = { type = "integer", minimum = 200, maximum = 3000 },
          timeout_ms = { type = "integer", minimum = 1000, maximum = 20000 },
          bufsz = { type = "integer", minimum = 4096, maximum = 131072 },
        },
        required = { "url" },
      },
    },
  },
  {
    groups = { "code_runner" },
    type = "function",
    ["function"] = {
      name = "lookup_context",
      description = "Return the most recent live lookup sources and extracted items for follow-up questions such as item numbers or source provenance.",
      parameters = {
        type = "object",
        properties = {},
      },
    },
  },
  {
    groups = { "code_runner" },
    type = "function",
    ["function"] = {
      name = "get_code_capabilities",
      description = "Read machine-readable Lua/LVGL capabilities, screen size constraints, known APIs, routing rules, and safe call signatures.",
      parameters = {
        type = "object",
        properties = {},
      },
    },
  },
  {
    groups = { "code_runner" },
    type = "function",
    ["function"] = {
      name = "preflight_lua",
      description = "Statically inspect Lua code before execution for unknown APIs, bad LVGL argument patterns, timer mistakes, and repeated failed code.",
      parameters = {
        type = "object",
        properties = {
          code = {
            type = "string",
            description = "Lua code to inspect.",
          },
        },
        required = { "code" },
      },
    },
  },
  {
    groups = { "code_runner" },
    type = "function",
    ["function"] = {
      name = "get_panel_artifacts",
      description = "Search recent Claw Panel visual artifacts by title/goal/stdout and optionally return their code for relevant follow-up modifications.",
      parameters = {
        type = "object",
        properties = {
          query = {
            type = "string",
            description = "Optional search text from the user's current request.",
          },
          limit = {
            type = "integer",
            minimum = 1,
            maximum = 12,
            description = "Optional maximum artifacts to return.",
          },
          include_code = {
            type = "boolean",
            description = "Optional. Include artifact code; defaults to true.",
          },
        },
      },
    },
  },
  {
    groups = { "code_runner" },
    type = "function",
    ["function"] = {
      name = "get_panel_history",
      description = "Read recent Claw Panel visual run history and optional code so you can decide whether a follow-up request should modify previous code.",
      parameters = {
        type = "object",
        properties = {
          id = {
            type = "string",
            description = "Optional history id/seq to fetch one specific run.",
          },
          limit = {
            type = "integer",
            minimum = 1,
            maximum = 5,
            description = "Optional number of recent runs to list when id is omitted.",
          },
          include_code = {
            type = "boolean",
            description = "Optional. Include code for recent runs; defaults to true.",
          },
        },
      },
    },
  },
  {
    groups = { "code_runner" },
    type = "function",
    ["function"] = {
      name = "lua_run",
      description = "Run a Lua code snippet on the device. Panel UI code must fit the 320x240 screen and visible LVGL objects need bg_opa=255.",
      parameters = {
        type = "object",
        properties = {
          code = {
            type = "string",
            description = "Lua code to execute. Print useful observations with print(). For Panel UI, keep all canvas/object/game coordinates within 320x240 and set lv_obj_set_style_bg_opa(obj,255,0) for visible objects.",
          },
          timeout_ms = {
            type = "integer",
            minimum = 100,
            maximum = 8000,
            description = "Optional soft timeout for pure Lua execution.",
          },
          target = {
            type = "string",
            description = "Optional execution target: auto, service, or panel. Use panel for LVGL visual demos.",
          },
          title = {
            type = "string",
            description = "Optional short title for panel visual demos.",
          },
          artifact_id = {
            type = "string",
            description = "Optional stable id for the visual artifact being created or modified.",
          },
          goal = {
            type = "string",
            description = "Optional concise user-visible goal for this run.",
          },
          mode = {
            type = "string",
            description = "Optional task mode such as new_code, modify_previous, or debug_previous.",
          },
        },
        required = { "code" },
      },
    },
  },
  {
    groups = { "image_inspect" },
    type = "function",
    ["function"] = {
      name = "inspect_image",
      description = "Analyze a local image file on the device.",
      parameters = {
        type = "object",
        properties = {
          path = { type = "string", description = "Absolute local image path under /sd/." },
          prompt = { type = "string", description = "What to inspect or describe in the image." },
        },
        required = { "path", "prompt" },
      },
    },
  },
  {
    groups = { "wechat_image" },
    type = "function",
    ["function"] = {
      name = "wechat_send_image",
      description = "Send a local image file to a WeChat chat.",
      parameters = {
        type = "object",
        properties = {
          chat_id = { type = "string", description = "Explicit WeChat chat id. Defaults to current chat when available." },
          path = { type = "string", description = "Local image path under /sd/." },
          caption = { type = "string", description = "Optional text sent before the image." },
        },
        required = { "path" },
      },
    },
  },
  {
    groups = { "self_check" },
    type = "function",
    ["function"] = {
      name = "self_check",
      description = "Run a local health check for LLM config, HTTP, SD, WeChat, Claw Panel, and memory.",
      parameters = {
        type = "object",
        properties = {},
      },
    },
  },
}

local HOSTED_TOOL_DEFS = {
  {
    type = "web_search",
    search_context_size = "low",
  },
}

local function tool_is_visible(item, source)
  local fn = type(item) == "table" and item["function"] or nil
  local name = type(fn) == "table" and fn.name or ""
  -- source 里的开关由 Agent 循环临时设置，用来限制某一轮可见工具。
  if type(source) == "table" and source.disable_all_tools then
    return false
  end
  if type(source) == "table" and source.disable_activate_skill and name == "activate_skill" then
    return false
  end
  if name == "preflight_lua" then
    return false
  end
  if type(source) == "table" and source.force_lua_run_only and name ~= "lua_run" then
    return false
  end
  if type(source) == "table" and source.disable_panel_context_tools
    and (name == "get_panel_history" or name == "get_panel_artifacts") then
    return false
  end
  if type(source) == "table" and source.disable_context_tools
    and (name == "get_panel_history" or name == "get_panel_artifacts"
      or name == "get_code_capabilities" or name == "preflight_lua") then
    return false
  end
  local groups = type(item) == "table" and item.groups or nil
  if type(groups) ~= "table" or #groups == 0 then
    return true
  end
  -- 带 groups 的工具必须先激活对应 Skill，避免模型越过用户可见能力边界。
  local APP = M.APP
  if not APP.skills or not APP.skills.is_group_active then
    return false
  end
  for i = 1, #groups do
    if APP.skills.is_group_active(groups[i], source) then
      return true
    end
  end
  return false
end

-- 下面这些辅助函数把工具能力组反查到 Skill，用于生成更清楚的模型提示。
local function tool_groups(item)
  local groups = type(item) == "table" and item.groups or nil
  return type(groups) == "table" and groups or {}
end

local function group_tool_names()
  local out = {}
  for i = 1, #TOOL_DEFS do
    local item = TOOL_DEFS[i]
    local fn = type(item) == "table" and item["function"] or nil
    local name = type(fn) == "table" and fn.name or ""
    if name ~= "" then
      local groups = tool_groups(item)
      for j = 1, #groups do
        local group = M.APP.core.trim(groups[j])
        if group ~= "" then
          out[group] = out[group] or {}
          out[group][#out[group] + 1] = name
        end
      end
    end
  end
  return out
end

local function skills_for_groups(groups)
  local APP = M.APP
  local out = {}
  local seen = {}
  if not APP.skills or not APP.skills.snapshot then
    return out
  end
  local ok, snap = pcall(APP.skills.snapshot, {
    channel = APP.state.last_channel,
    chat_id = APP.state.last_chat_id,
  })
  local catalog = ok and type(snap) == "table" and type(snap.catalog) == "table" and snap.catalog or {}
  for i = 1, #catalog do
    local skill = catalog[i]
    local skill_groups = type(skill) == "table" and type(skill.cap_groups) == "table" and skill.cap_groups or {}
    for j = 1, #skill_groups do
      for k = 1, #groups do
        if skill_groups[j] == groups[k] then
          local id = APP.core.text_or(skill.id, "")
          if id ~= "" and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

local function tool_requirement_text(item)
  local groups = tool_groups(item)
  if #groups == 0 then
    return ""
  end
  local skills = skills_for_groups(groups)
  if #skills == 1 then
    return "Requires active skill: " .. table.concat(skills, ", ") .. "."
  elseif #skills > 1 then
    return "Requires one active skill: " .. table.concat(skills, " or ") .. "."
  end
  return "Requires active capability group: " .. table.concat(groups, ", ") .. "."
end

local function function_def_for_model(item)
  local fn = type(item) == "table" and item["function"] or nil
  if type(fn) ~= "table" then
    return nil
  end
  local description = M.APP.core.text_or(fn.description, "")
  local req = tool_requirement_text(item)
  if req ~= "" and description:find(req, 1, true) == nil then
    description = description ~= "" and (description .. " " .. req) or req
  end
  return {
    name = fn.name,
    description = description,
    parameters = fn.parameters,
  }
end

-- 生成 Skill 到工具的可见映射，帮助模型先激活 Skill 再调用具体工具。
local function skill_tool_context(source)
  local APP = M.APP
  if not APP.skills or not APP.skills.snapshot then
    return ""
  end
  local ok, snap = pcall(APP.skills.snapshot, source)
  if not ok or type(snap) ~= "table" or type(snap.catalog) ~= "table" then
    return ""
  end
  local group_tools = group_tool_names()
  local active = {}
  if type(snap.active) == "table" then
    for i = 1, #snap.active do
      active[APP.core.text_or(snap.active[i], "")] = true
    end
  end
  local lines = {
    "Skill-Tool Map:",
    "Activate the listed skill before calling its tools. If a skill is already active, call its tools directly and do not activate it again.",
  }
  for i = 1, #snap.catalog do
    local skill = snap.catalog[i]
    local id = APP.core.text_or(type(skill) == "table" and skill.id or "", "")
    local groups = type(skill) == "table" and type(skill.cap_groups) == "table" and skill.cap_groups or {}
    local tools = {}
    local seen = {}
    for j = 1, #groups do
      local names = group_tools[groups[j]] or {}
      for k = 1, #names do
        if not seen[names[k]] then
          seen[names[k]] = true
          tools[#tools + 1] = names[k]
        end
      end
    end
    table.sort(tools)
    if id ~= "" and #tools > 0 then
      lines[#lines + 1] = "- " .. id .. (active[id] and " (active)" or "") .. " enables tools: " .. table.concat(tools, ", ")
    end
  end
  return #lines > 2 and table.concat(lines, "\n") or ""
end

-- Responses API 使用扁平 function schema。
local function response_tool_defs(source)
  if type(source) == "table" and source.disable_all_tools then
    return {}
  end
  local out = {}
  for i = 1, #HOSTED_TOOL_DEFS do
    out[#out + 1] = HOSTED_TOOL_DEFS[i]
  end
  for i = 1, #TOOL_DEFS do
    local item = TOOL_DEFS[i]
    if tool_is_visible(item, source) then
      local fn = function_def_for_model(item)
      if type(fn) == "table" then
        out[#out + 1] = {
          type = "function",
          name = fn.name,
          description = fn.description,
          parameters = fn.parameters,
        }
      end
    end
  end
  return out
end

-- Chat Completions 使用 function 包裹 schema。
local function chat_tool_defs(source)
  if type(source) == "table" and source.disable_all_tools then
    return {}
  end
  local out = {}
  for i = 1, #TOOL_DEFS do
    local item = TOOL_DEFS[i]
    if tool_is_visible(item, source) then
      local fn = function_def_for_model(item)
      if type(fn) == "table" then
        out[#out + 1] = {
          type = "function",
          ["function"] = fn,
        }
      end
    end
  end
  return out
end

local function acquire_tool_lock(owner)
  local APP = M.APP
  local core = APP.core
  APP.state.tool_lock = type(APP.state.tool_lock) == "table" and APP.state.tool_lock or {}
  local lock = APP.state.tool_lock
  owner = core.text_or(owner, "tool")
  local started = core.now_ms()
  while lock.active do
    if sys and sys.wait then
      sys.wait(50)
    else
      return false, "tool busy"
    end
    if core.now_ms() - started > 120000 then
      return false, "tool lock timeout"
    end
  end
  lock.active = true
  lock.owner = owner
  lock.since_ms = core.now_ms()
  return true
end

local function release_tool_lock(owner)
  local APP = M.APP
  APP.state.tool_lock = type(APP.state.tool_lock) == "table" and APP.state.tool_lock or {}
  APP.state.tool_lock.active = false
  APP.state.tool_lock.owner = ""
  APP.state.tool_lock.since_ms = 0
end

local function execute_tool_unlocked(name, args_json, source)
  local APP = M.APP
  local core = APP.core
  local call_source = source_or_last(source)
  local args = {}
  if type(args_json) == "string" and args_json ~= "" then
    local parsed = core.safe_json_decode(args_json)
    if type(parsed) == "table" then
      args = parsed
    end
  elseif type(args_json) == "table" then
    args = args_json
  end

  APP.state.tool_count = APP.state.tool_count + 1
  core.append_log("tool", name)

  if name == "activate_skill" then
    return tool_activate_skill(args, call_source)
  end
  if name == "get_device_status" then
    return tool_get_device_status(args)
  end
  if name == "set_screen_message" then
    return tool_set_screen_message(args)
  end
  if name == "set_brightness" then
    return tool_set_brightness(args)
  end
  if name == "memory_store" and APP.memory and APP.memory.add_fact then
    local ok, result = APP.memory.add_fact(core.text_or(args.content, ""), {
      scope = "chat",
      chat_id = call_source.chat_id,
      kind = "tool",
      source = "manual",
      tags = core.text_or(args.tags, ""),
      keywords = core.text_or(args.keywords, ""),
      score = 0.9,
    })
    if not ok then
      return string.format("{\"ok\":false,\"error\":%q}", core.text_or(result, "memory store failed"))
    end
    return string.format("{\"ok\":true,\"memory_id\":%q}", core.text_or(type(result) == "table" and result.id or "", ""))
  end
  if name == "memory_recall" and APP.memory and APP.memory.recall then
    local items = APP.memory.recall(core.text_or(args.query, ""), {
      channel = call_source.channel,
      chat_id = call_source.chat_id,
    })
    local out = {}
    for i = 1, #items do
      out[#out + 1] = {
        id = items[i].id,
        content = items[i].content or items[i].text,
        tags = items[i].tags,
      }
      if #out >= 6 then
        break
      end
    end
    local raw = core.safe_json_encode({ ok = true, memories = out })
    return raw or "{\"ok\":true,\"memories\":[]}"
  end
  if name == "memory_list" and APP.memory and APP.memory.snapshot then
    local snap = APP.memory.snapshot({
      channel = call_source.channel,
      chat_id = call_source.chat_id,
    })
    local raw = core.safe_json_encode(snap)
    return raw or "{\"ok\":true}"
  end
  if name == "memory_forget" and APP.memory and APP.memory.forget_matching then
    local removed = 0
    removed = APP.memory.forget_matching(core.text_or(args.query, ""), {
      channel = call_source.channel,
      chat_id = call_source.chat_id,
    })
    return string.format("{\"ok\":true,\"removed\":%d}", tonumber(removed) or 0)
  end
  if name == "get_panel_history" then
    return tool_get_panel_history(args)
  end
  if name == "get_code_capabilities" then
    return tool_get_code_capabilities(args)
  end
  if name == "preflight_lua" then
    return tool_preflight_lua(args)
  end
  if name == "get_panel_artifacts" then
    return tool_get_panel_artifacts(args)
  end
  if name == "web_probe" then
    return tool_web_probe(args)
  end
  if name == "web_fetch" then
    return tool_web_fetch(args)
  end
  if name == "lookup_context" then
    return tool_lookup_context(args)
  end
  if name == "lua_run" and APP.code_runner and APP.code_runner.run then
    local ok, result = APP.code_runner.run(args)
    if ok and type(result) == "table" and lua_run_reported_error(result) then
      result.ok = false
      result.phase = result.phase or "reported_error"
      result.error = result.error ~= "" and result.error or core.text_or(result.stdout, "lua_run reported error")
      ok = false
    end
    local raw = core.safe_json_encode(result)
    if raw then
      return raw
    end
    return ok and "{\"ok\":true}" or "{\"ok\":false,\"error\":\"lua_run result encode failed\"}"
  end
  if name == "inspect_image" and APP.vision and APP.vision.inspect_image then
    local text, err = APP.vision.inspect_image(core.text_or(args.path, ""), core.text_or(args.prompt, ""), {
      channel = call_source.channel,
      chat_id = call_source.chat_id,
    })
    if not text then
      return string.format("{\"ok\":false,\"error\":%q}", core.text_or(err, "image inspect failed"))
    end
    local raw = core.safe_json_encode({ ok = true, text = text })
    return raw or "{\"ok\":true}"
  end
  if name == "wechat_send_image" and APP.wechat and APP.wechat.send_image then
    local chat_id = core.trim(args.chat_id)
    if chat_id == "" and call_source.channel == "wechat" then
      chat_id = call_source.chat_id
    end
    if chat_id == "" then
      return "{\"ok\":false,\"error\":\"chat_id is required\"}"
    end
    local ok, err = APP.wechat.send_image(chat_id, core.text_or(args.path, ""), core.text_or(args.caption, ""))
    if not ok then
      return string.format("{\"ok\":false,\"error\":%q}", core.text_or(err, "wechat image send failed"))
    end
    return "{\"ok\":true,\"message\":\"image sent\"}"
  end
  if name == "self_check" and APP.diagnostics and APP.diagnostics.run then
    local result = APP.diagnostics.run({
      channel = call_source.channel,
      chat_id = call_source.chat_id,
    })
    local raw = core.safe_json_encode(result)
    return raw or "{\"ok\":true}"
  end
  return string.format("{\"ok\":false,\"error\":\"unknown tool %s\"}", core.text_or(name, ""))
end

-- 执行 LLM 请求的工具调用；所有工具入参都先从 JSON 收口成 Lua table。
local function execute_tool(name, args_json, source)
  local APP = M.APP
  local core = APP.core
  local owner_source = source_or_last(source)
  local owner = core.text_or(owner_source.channel, "web") .. ":" .. core.text_or(owner_source.chat_id, "")
    .. ":" .. core.text_or(name, "tool")
  local ok_lock, lock_err = acquire_tool_lock(owner)
  if not ok_lock then
    return string.format("{\"ok\":false,\"error\":%q}", core.text_or(lock_err, "tool lock failed"))
  end
  local ok, result = pcall(execute_tool_unlocked, name, args_json, owner_source)
  release_tool_lock(owner)
  if ok then
    return result
  end
  return string.format("{\"ok\":false,\"error\":%q}", core.text_or(result, "tool failed"))
end

-- 根据工具结果生成低成本确认文案。
local function tool_success_reply(name, args_json, output)
  local APP = M.APP
  local core = APP.core
  local args = {}
  if type(args_json) == "string" and args_json ~= "" then
    local parsed = core.safe_json_decode(args_json)
    if type(parsed) == "table" then
      args = parsed
    end
  end
  if name == "set_brightness" then
    local level = tonumber(args.level) or APP.state.brightness
    return "已将屏幕亮度调到 " .. tostring(level) .. "。"
  end
  if name == "set_screen_message" then
    return "已更新屏幕显示文字。"
  end
  if name == "get_device_status" then
    local snap = core.safe_json_decode(output)
    if type(snap) == "table" then
      local wx = type(snap.wechat) == "table" and snap.wechat or {}
      return "设备在线，亮度 " .. tostring(snap.brightness or APP.state.brightness) ..
        "，微信 " .. (wx.enabled and "已启用" or "未启用") .. "。"
    end
    return "已读取设备状态。"
  end
  if name == "activate_skill" then
    local doc = core.safe_json_decode(output)
    if type(doc) == "table" and doc.ok and doc.skill_id then
      return "已激活 Skill：" .. core.text_or(doc.skill_id, "") .. "。"
    end
    return "Skill 激活失败。"
  end
  if name == "memory_store" then
    return "已保存这条记忆。"
  end
  if name == "memory_recall" then
    local doc = core.safe_json_decode(output)
    local memories = type(doc) == "table" and type(doc.memories) == "table" and doc.memories or {}
    if #memories == 0 then
      return "没有找到相关长期记忆。"
    end
    local parts = { "找到这些记忆：" }
    for i = 1, math.min(3, #memories) do
      parts[#parts + 1] = "- " .. core.short_text(memories[i].content or "", 120)
    end
    return table.concat(parts, "\n")
  end
  if name == "memory_list" then
    local doc = core.safe_json_decode(output)
    local recent = type(doc) == "table" and type(doc.recent) == "table" and doc.recent or {}
    if #recent == 0 then
      return "当前没有长期记忆。"
    end
    local parts = { "最近的长期记忆：" }
    for i = 1, math.min(3, #recent) do
      parts[#parts + 1] = "- " .. core.short_text(recent[i].content or recent[i].text or "", 120)
    end
    return table.concat(parts, "\n")
  end
  if name == "memory_forget" then
    return "已按条件清理记忆。"
  end
  if name == "get_code_capabilities" then
    return "已读取代码能力表。"
  end
  if name == "preflight_lua" then
    local doc = core.safe_json_decode(output)
    if type(doc) == "table" and doc.ok then
      return "代码预检查通过。"
    end
    local errors = type(doc) == "table" and type(doc.errors) == "table" and doc.errors or {}
    local first = type(errors[1]) == "table" and core.text_or(errors[1].message, "") or ""
    return "代码预检查失败：" .. core.short_text(first ~= "" and first or output, 160)
  end
  if name == "get_panel_artifacts" then
    local doc = core.safe_json_decode(output)
    local entries = type(doc) == "table" and type(doc.entries) == "table" and doc.entries or {}
    if #entries == 0 then
      return "没有找到相关 Panel 作品。"
    end
    return "已读取相关 Panel 作品：" .. core.short_text(entries[1].title or entries[1].id or "", 80)
  end
  if name == "get_panel_history" then
    local doc = core.safe_json_decode(output)
    local entries = type(doc) == "table" and type(doc.entries) == "table" and doc.entries or {}
    if #entries == 0 then
      return "没有找到最近 Panel 记录。"
    end
    return "已读取最近 Panel 记录：" .. core.short_text(entries[1].title or entries[1].id or "", 80)
  end
  if name == "web_probe" then
    local doc = core.safe_json_decode(output)
    local results = type(doc) == "table" and type(doc.results) == "table" and doc.results or {}
    local ok_count = 0
    for i = 1, #results do
      if type(results[i]) == "table" and results[i].ok then
        ok_count = ok_count + 1
      end
    end
    return "已检查 " .. tostring(#results) .. " 个来源，其中 " .. tostring(ok_count) .. " 个可访问。"
  end
  if name == "web_fetch" then
    local doc = core.safe_json_decode(output)
    if type(doc) == "table" and doc.ok then
      return "已读取来源 " .. core.text_or(doc.source, "") .. "：" .. core.short_text(doc.title or doc.excerpt or "", 120)
    end
    local source = type(doc) == "table" and core.text_or(doc.source, "") or ""
    local err = type(doc) == "table" and core.text_or(doc.error, "") or output
    return "读取来源失败" .. (source ~= "" and ("（" .. source .. "）") or "") .. "：" .. core.short_text(err, 120)
  end
  if name == "lookup_context" then
    local doc = core.safe_json_decode(output)
    local items = type(doc) == "table" and type(doc.items) == "table" and doc.items or {}
    local sources = type(doc) == "table" and type(doc.sources) == "table" and doc.sources or {}
    return "已读取上次查询上下文：来源 " .. tostring(#sources) .. " 个，条目 " .. tostring(#items) .. " 条。"
  end
  if name == "lua_run" then
    local doc = core.safe_json_decode(output)
    if type(doc) == "table" and doc.ok then
      if doc.target == "panel" then
        local stdout = core.text_or(doc.stdout, "")
        if stdout ~= "" then
          return "已打开 Claw Panel 并运行可视化代码：\n" .. core.short_text(stdout, 900)
        end
        if doc.queued then
          return "可视化代码已投递到 Claw Panel，但还没有拿到执行结果。"
        end
        return "Claw Panel 已执行可视化代码，但代码没有打印运行摘要。"
      end
      local stdout = core.text_or(doc.stdout, "")
      if stdout ~= "" then
        return "代码已运行：\n" .. core.short_text(stdout, 900)
      end
      return "代码已运行。"
    end
    local err = type(doc) == "table" and doc.error or output
    return "代码运行失败：" .. core.short_text(err, 180)
  end
  if name == "inspect_image" then
    local doc = core.safe_json_decode(output)
    if type(doc) == "table" and doc.ok and type(doc.text) == "string" then
      return doc.text
    end
    local err = type(doc) == "table" and doc.error or ""
    return "图片分析失败：" .. core.short_text(err, 160)
  end
  if name == "wechat_send_image" then
    return "已发送微信图片。"
  end
  if name == "self_check" then
    local doc = core.safe_json_decode(output)
    local checks = type(doc) == "table" and type(doc.checks) == "table" and doc.checks or {}
    local parts = { "自检完成：" }
    for i = 1, math.min(6, #checks) do
      parts[#parts + 1] = "- " .. core.text_or(checks[i].label, checks[i].id) .. ": " ..
        core.text_or(checks[i].status, "") .. " " .. core.short_text(checks[i].detail or "", 80)
    end
    return table.concat(parts, "\n")
  end
  return "操作已执行。"
end

-- 初始化工具模块。
function M.init(APP)
  M.APP = APP
  APP.tools = {
    response_tool_defs = response_tool_defs,
    chat_tool_defs = chat_tool_defs,
    skill_tool_context = skill_tool_context,
    execute_tool = execute_tool,
    tool_success_reply = tool_success_reply,
    should_finish_after_tool = should_finish_after_tool,
  }
end

return M
