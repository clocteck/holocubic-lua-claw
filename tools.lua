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
local function tool_activate_skill(args)
  local APP = M.APP
  local core = APP.core
  if not APP.skills or not APP.skills.activate then
    return "{\"ok\":false,\"error\":\"skills module missing\"}"
  end
  local skill_id = core.trim(type(args) == "table" and args.skill_id or "")
  if skill_id == "" then
    return "{\"ok\":false,\"error\":\"skill_id is required\"}"
  end
  local ok, result = APP.skills.activate(skill_id, {
    channel = APP.state.last_channel,
    chat_id = APP.state.last_chat_id,
  })
  if not ok then
    return string.format("{\"ok\":false,\"error\":%q}", core.text_or(result, "activate skill failed"))
  end
  local raw = core.safe_json_encode({
    ok = true,
    skill_id = result.id,
    description = result.description,
    cap_groups = result.cap_groups,
    skill_content = result.body,
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
      name = "get_code_capabilities",
      description = "Read machine-readable Lua/LVGL capabilities, known APIs, routing rules, and safe call signatures.",
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
      description = "Run a Lua code snippet on the device with broad access to available Lua modules and filesystem paths.",
      parameters = {
        type = "object",
        properties = {
          code = {
            type = "string",
            description = "Lua code to execute. Print useful observations with print().",
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
  if type(source) == "table" and source.disable_all_tools then
    return false
  end
  if type(source) == "table" and source.disable_activate_skill and name == "activate_skill" then
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

-- 返回 Responses API 使用的扁平 tool 定义，按当前会话已激活 Skill 过滤。
local function response_tool_defs(source)
  local out = {}
  if not (type(source) == "table" and source.disable_all_tools) then
    for i = 1, #HOSTED_TOOL_DEFS do
      out[#out + 1] = HOSTED_TOOL_DEFS[i]
    end
  end
  for i = 1, #TOOL_DEFS do
    local fn = TOOL_DEFS[i]["function"]
    if type(fn) == "table" and tool_is_visible(TOOL_DEFS[i], source) then
      out[#out + 1] = {
        type = "function",
        name = fn.name,
        description = fn.description,
        parameters = fn.parameters,
      }
    end
  end
  return out
end

local function chat_tool_defs(source)
  local out = {}
  for i = 1, #TOOL_DEFS do
    local fn = TOOL_DEFS[i]["function"]
    if type(fn) == "table" and tool_is_visible(TOOL_DEFS[i], source) then
      out[#out + 1] = {
        type = "function",
        ["function"] = fn,
      }
    end
  end
  return out
end

-- 执行 LLM 请求的工具调用。
local function execute_tool(name, args_json)
  local APP = M.APP
  local core = APP.core
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
    return tool_activate_skill(args)
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
      chat_id = APP.state.last_chat_id,
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
      channel = APP.state.last_channel,
      chat_id = APP.state.last_chat_id,
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
      channel = APP.state.last_channel,
      chat_id = APP.state.last_chat_id,
    })
    local raw = core.safe_json_encode(snap)
    return raw or "{\"ok\":true}"
  end
  if name == "memory_forget" and APP.memory and APP.memory.forget_matching then
    local removed = 0
    removed = APP.memory.forget_matching(core.text_or(args.query, ""), {
      channel = APP.state.last_channel,
      chat_id = APP.state.last_chat_id,
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
      channel = APP.state.last_channel,
      chat_id = APP.state.last_chat_id,
    })
    if not text then
      return string.format("{\"ok\":false,\"error\":%q}", core.text_or(err, "image inspect failed"))
    end
    local raw = core.safe_json_encode({ ok = true, text = text })
    return raw or "{\"ok\":true}"
  end
  if name == "wechat_send_image" and APP.wechat and APP.wechat.send_image then
    local chat_id = core.trim(args.chat_id)
    if chat_id == "" and APP.state.last_channel == "wechat" then
      chat_id = APP.state.last_chat_id
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
      channel = APP.state.last_channel,
      chat_id = APP.state.last_chat_id,
    })
    local raw = core.safe_json_encode(result)
    return raw or "{\"ok\":true}"
  end
  return string.format("{\"ok\":false,\"error\":\"unknown tool %s\"}", core.text_or(name, ""))
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
    execute_tool = execute_tool,
    tool_success_reply = tool_success_reply,
    should_finish_after_tool = should_finish_after_tool,
  }
end

return M
