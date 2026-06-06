local M = {
  facts = {},
  loaded = false,
}

local RECALL_THRESHOLD = 1.2

-- 返回记忆根目录。
local function memory_root()
  return M.APP.APP_DIR .. "/memory"
end

-- 返回会话摘要目录。
local function session_dir()
  return memory_root() .. "/session"
end

-- 返回长期事实 JSONL 文件路径。
local function facts_path()
  return memory_root() .. "/memory_records.jsonl"
end

-- 返回长期记忆索引文件路径。
local function index_path()
  return memory_root() .. "/memory_index.json"
end

-- 返回人工可读记忆视图路径。
local function markdown_path()
  return memory_root() .. "/MEMORY.md"
end

-- 返回 profile 记忆路径。
local function profile_path(name)
  return memory_root() .. "/" .. name .. ".md"
end

-- 确保记忆目录存在，失败时记录到状态但不阻塞主流程。
local function ensure_dirs()
  local APP = M.APP
  local core = APP.core
  local ok, err = core.ensure_app_dir()
  if not ok then
    APP.state.memory.last_error = err or "ensure app dir failed"
    return false, err
  end
  ok, err = core.ensure_dir(memory_root())
  if not ok then
    APP.state.memory.last_error = err or "ensure memory dir failed"
    return false, err
  end
  ok, err = core.ensure_dir(session_dir())
  if not ok then
    APP.state.memory.last_error = err or "ensure session dir failed"
    return false, err
  end

  local defaults = {
    identity = "# Identity Card\n\n- Name: ESP Claw\n- Role: Embedded Lua device agent\n- Platform: ESP32-S3 Lua/LVGL device\n- Mission: Help the user through concise conversation and safe device control\n",
    user = "# User\n\n(empty)\n",
    soul = "# Soul\n\n- Be concise, practical, and device-aware.\n- Prefer stable Lua-side solutions before suggesting C changes.\n",
  }
  for name, text in pairs(defaults) do
    local path = profile_path(name)
    if not file or not file.exists or not file.exists(path) then
      core.write_text_file(path, text)
    end
  end
  if not file or not file.exists or not file.exists(markdown_path()) then
    core.write_text_file(markdown_path(), "# Long-term Memory\n\n(empty - ESP Claw will write memories here as it learns)")
  end
  if not file or not file.exists or not file.exists(index_path()) then
    local raw = core.safe_json_encode({
      version = 1,
      next_summary_id = 1,
      summaries = {},
      keyword_index = {},
    })
    if raw then
      core.write_text_file(index_path(), raw)
    end
  end
  return true, nil
end

-- 把 chat id 收口成可用于文件名的安全 key。
local function safe_key(text)
  text = M.APP.core.text_or(text, "default")
  text = text:gsub("[^%w%._%-]", "_")
  text = text:gsub("_+", "_")
  if text == "" or text == "_" then
    text = "default"
  end
  if #text > 64 then
    text = text:sub(1, 64)
  end
  return text
end

-- 根据消息来源生成会话 key。
local function session_key(source)
  local core = M.APP.core
  source = type(source) == "table" and source or {}
  local channel = core.text_or(source.channel, "web")
  local chat_id = core.text_or(source.chat_id, channel)
  return safe_key(channel .. "_" .. chat_id)
end

-- 返回某个来源的会话摘要文件路径。
local function session_path(source)
  return session_dir() .. "/" .. session_key(source) .. ".json"
end

-- 生成事实比较 key，用于去重。
local function fact_key(text)
  text = M.APP.core.normalize_space(text)
  text = text:lower()
  text = text:gsub("%s+", "")
  text = text:gsub("[%p%c]", "")
  return text
end

-- 兼容早期 text 字段，新格式优先使用 ESP-Claw 风格的 content 字段。
local function fact_content(item)
  if type(item) ~= "table" then
    return ""
  end
  return M.APP.core.text_or(item.content or item.text, "")
end

-- 将一段文本切成粗略关键词，用于轻量索引和召回。
local function extract_keywords(text, limit)
  local out = {}
  local seen = {}
  text = M.APP.core.normalize_space(text)
  limit = limit or 8

  for word in text:gmatch("[%w_%-]+") do
    local key = word:lower()
    if #key >= 3 and not seen[key] then
      seen[key] = true
      out[#out + 1] = key
      if #out >= limit then
        return out
      end
    end
  end

  for word in text:gmatch("[\128-\255][\128-\255][\128-\255]+") do
    if not seen[word] then
      seen[word] = true
      out[#out + 1] = word
      if #out >= limit then
        break
      end
    end
  end
  return out
end

-- 根据内容给出稳定摘要标签，尽量贴近 ESP-Claw 的 summary label 机制。
local function infer_tags(text, kind)
  local lower = text:lower()
  local tags = {}
  local function add(tag)
    if #tags < 3 then
      tags[#tags + 1] = tag
    end
  end

  if kind == "explicit" then
    add("user_preferences")
  end
  if lower:find("亮度", 1, true) or lower:find("屏幕", 1, true) or lower:find("brightness", 1, true) then
    add("device_preferences")
  end
  if lower:find("中文", 1, true) or lower:find("回复", 1, true) or lower:find("answer", 1, true) or lower:find("style", 1, true) then
    add("communication_style")
  end
  if lower:find("喜欢", 1, true) or lower:find("偏好", 1, true) or lower:find("like", 1, true) or lower:find("prefer", 1, true) then
    add("user_preferences")
  end
  if lower:find("每天", 1, true) or lower:find("routine", 1, true) or lower:find("习惯", 1, true) then
    add("daily_routine")
  end
  if #tags == 0 then
    add("general")
  end
  return table.concat(tags, ",")
end

-- 把 csv 字段转换成数组。
local function csv_list(text, limit)
  local out = {}
  local seen = {}
  limit = limit or 16
  text = M.APP.core.text_or(text, "")
  for token in text:gmatch("[^,;/|]+") do
    local item = M.APP.core.trim(token)
    if item ~= "" and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
      if #out >= limit then
        break
      end
    end
  end
  return out
end

-- 读取 JSON 文件，读取失败时返回 fallback。
local function read_json_file(path, fallback)
  local core = M.APP.core
  local raw, err = core.read_text_file(path)
  if not raw or raw == "" then
    return fallback, err
  end
  local doc, dec_err = core.safe_json_decode(raw)
  if type(doc) ~= "table" then
    return fallback, dec_err
  end
  return doc, nil
end

-- 写入 JSON 文件，统一走 core 的安全编码和写文件接口。
local function write_json_file(path, value)
  local core = M.APP.core
  local raw, err = core.safe_json_encode(value)
  if not raw then
    return false, err
  end
  return core.write_text_file(path, raw)
end

-- 限制事实数量，优先保留最近更新的事实。
local function trim_facts()
  local APP = M.APP
  local limit = tonumber(APP.config.memory_fact_limit) or 80
  table.sort(M.facts, function(a, b)
    return (tonumber(a.updated_ms) or 0) > (tonumber(b.updated_ms) or 0)
  end)
  while #M.facts > limit do
    table.remove(M.facts)
  end
end

-- 从 JSONL 文件加载长期事实，首次使用时才执行。
local function load_facts()
  local APP = M.APP
  local core = APP.core
  if M.loaded then
    return true, nil
  end
  M.loaded = true
  M.facts = {}

  if file and file.exists and not file.exists(facts_path()) then
    APP.state.memory.facts_loaded = 0
    return true, nil
  end

  local raw, err = core.read_text_file(facts_path())
  if not raw or raw == "" then
    APP.state.memory.facts_loaded = 0
    if err then
      APP.state.memory.last_error = core.short_text(err, 120)
    end
    return true, nil
  end

  for line in raw:gmatch("[^\r\n]+") do
    local doc = core.safe_json_decode(line)
    if type(doc) == "table" and fact_content(doc) ~= "" then
      doc.content = fact_content(doc)
      doc.text = nil
      doc.tags = core.text_or(doc.tags, infer_tags(doc.content, doc.kind))
      doc.keywords = core.text_or(doc.keywords, table.concat(extract_keywords(doc.content), ","))
      doc.source = core.text_or(doc.source, "manual")
      M.facts[#M.facts + 1] = doc
    end
  end
  trim_facts()
  APP.state.memory.facts_loaded = #M.facts
  return true, nil
end

-- 重建长期记忆摘要标签和关键词索引。
local function build_index()
  local summaries = {}
  local summary_seen = {}
  local keyword_index = {}

  for i = 1, #M.facts do
    local item = M.facts[i]
    local id = M.APP.core.text_or(item.id, "")
    for _, tag in ipairs(csv_list(item.tags, 3)) do
      if not summary_seen[tag] then
        summary_seen[tag] = { summary_id = #summaries + 1, ref_count = 0 }
        summaries[#summaries + 1] = {
          summary_id = summary_seen[tag].summary_id,
          label = tag,
          ref_count = 0,
        }
      end
      local stat = summary_seen[tag]
      stat.ref_count = stat.ref_count + 1
      summaries[stat.summary_id].ref_count = stat.ref_count
    end

    for _, keyword in ipairs(csv_list(item.keywords, 8)) do
      if id ~= "" then
        keyword_index[keyword] = keyword_index[keyword] or {}
        keyword_index[keyword][#keyword_index[keyword] + 1] = id
      end
    end
  end

  return {
    version = 1,
    next_summary_id = #summaries + 1,
    summaries = summaries,
    keyword_index = keyword_index,
  }
end

-- 同步 MEMORY.md，定位为人工可读视图，不作为检索事实源。
local function sync_markdown()
  local lines = {
    "# Long-term Memory",
    "",
  }
  if #M.facts == 0 then
    lines[#lines + 1] = "(empty - ESP Claw will write memories here as it learns)"
  else
    for i = 1, #M.facts do
      local item = M.facts[i]
      lines[#lines + 1] = "- " .. M.APP.core.text_or(item.content, "")
      if M.APP.core.text_or(item.tags, "") ~= "" then
        lines[#lines + 1] = "  tags: " .. item.tags
      end
    end
  end
  return M.APP.core.write_text_file(markdown_path(), table.concat(lines, "\n"))
end

-- 保存长期事实到 JSONL，便于局部坏行不影响整体加载。
local function save_facts()
  local APP = M.APP
  local core = APP.core
  local ok, err = ensure_dirs()
  if not ok then
    return false, err
  end
  trim_facts()

  local lines = {}
  -- JSONL 的好处是单条坏记录不会拖垮整份长期记忆。
  for i = 1, #M.facts do
    local raw = core.safe_json_encode(M.facts[i])
    if raw then
      lines[#lines + 1] = raw
    end
  end
  ok, err = core.write_text_file(facts_path(), table.concat(lines, "\n"))
  if not ok then
    APP.state.memory.last_error = err or "save facts failed"
    return false, err
  end
  APP.state.memory.facts_saved = #M.facts
  APP.state.memory.facts_loaded = #M.facts
  APP.state.memory.last_error = ""
  write_json_file(index_path(), build_index())
  sync_markdown()
  return true, nil
end

-- 读取当前会话摘要。
local function load_session(source)
  local doc = read_json_file(session_path(source), {
    summary = "",
    turns = 0,
    updated_ms = 0,
  })
  if type(doc) ~= "table" then
    doc = { summary = "", turns = 0, updated_ms = 0 }
  end
  doc.summary = M.APP.core.text_or(doc.summary, "")
  doc.turns = tonumber(doc.turns or 0) or 0
  doc.updated_ms = tonumber(doc.updated_ms or 0) or 0
  return doc
end

-- 保存当前会话摘要。
local function save_session(source, doc)
  local APP = M.APP
  local core = APP.core
  local ok, err = ensure_dirs()
  if not ok then
    return false, err
  end
  ok, err = write_json_file(session_path(source), doc)
  if not ok then
    APP.state.memory.last_error = err or "save session failed"
    return false, err
  end
  APP.state.memory.session_saved = (APP.state.memory.session_saved or 0) + 1
  APP.state.memory.last_error = ""
  return true, nil
end

-- 从用户输入里提取显式记忆指令。
local function extract_memory_text(user_text)
  local core = M.APP.core
  local text = core.trim(user_text)
  local patterns = {
    "^记住[:：%s]*(.+)$",
    "^请记住[:：%s]*(.+)$",
    "^帮我记住[:：%s]*(.+)$",
    "^你要记住[:：%s]*(.+)$",
    "^remember%s+that%s+(.+)$",
    "^remember[:：%s]+(.+)$",
  }
  for i = 1, #patterns do
    local item = text:match(patterns[i])
    item = core.trim(item)
    if item ~= "" then
      return item
    end
  end
  return ""
end

-- 从用户输入里提取忘记指令。
local function extract_forget_text(user_text)
  local core = M.APP.core
  local text = core.trim(user_text)
  local patterns = {
    "^忘记[:：%s]*(.+)$",
    "^删除记忆[:：%s]*(.+)$",
    "^不要记住[:：%s]*(.+)$",
    "^forget[:：%s]+(.+)$",
  }
  for i = 1, #patterns do
    local item = text:match(patterns[i])
    item = core.trim(item)
    if item ~= "" then
      return item
    end
  end
  return ""
end

-- 添加或更新一条长期事实。
local function add_fact(text, opts)
  local APP = M.APP
  local core = APP.core
  if not APP.config.memory_enabled then
    return false, "memory disabled"
  end
  load_facts()

  opts = type(opts) == "table" and opts or {}
  text = core.short_text(core.normalize_space(text), 240)
  if text == "" then
    return false, "empty memory"
  end

  local key = fact_key(text)
  local now = core.now_ms()
  local scope = core.text_or(opts.scope, "chat")
  local chat_id = core.text_or(opts.chat_id, "")
  local kind = core.text_or(opts.kind, "fact")
  -- 同一 scope/chat 下的近似重复事实只增强权重，不重复写入。
  for i = 1, #M.facts do
    local item = M.facts[i]
    if fact_key(fact_content(item)) == key
      and core.text_or(item.scope, "chat") == scope
      and core.text_or(item.chat_id, "") == chat_id then
      item.updated_ms = now
      item.updated_at = now
      item.score = math.min(1, (tonumber(item.score) or 0.7) + 0.05)
      if core.text_or(item.tags, "") == "" then
        item.tags = infer_tags(text, kind)
      end
      if core.text_or(item.keywords, "") == "" then
        item.keywords = table.concat(extract_keywords(text), ",")
      end
      save_facts()
      return true, item
    end
  end

  local fact = {
    id = "m" .. tostring(now) .. "_" .. tostring(math.random(1000, 9999)),
    scope = scope,
    chat_id = chat_id,
    kind = kind,
    content = text,
    tags = core.text_or(opts.tags, infer_tags(text, kind)),
    keywords = core.text_or(opts.keywords, table.concat(extract_keywords(text), ",")),
    source = core.text_or(opts.source, "manual"),
    score = tonumber(opts.score) or 0.75,
    created_ms = now,
    updated_ms = now,
    created_at = now,
    updated_at = now,
  }
  table.insert(M.facts, 1, fact)
  local ok, err = save_facts()
  if ok then
    core.append_log("memory", "saved " .. core.short_text(text, 80))
  end
  return ok, err or fact
end

-- 删除匹配的长期事实，仅删除当前 chat 或全局范围内的内容。
local function forget_matching(query, source)
  local APP = M.APP
  local core = APP.core
  if not APP.config.memory_enabled then
    return 0
  end
  load_facts()

  source = type(source) == "table" and source or {}
  local chat_id = core.text_or(source.chat_id, "")
  local key = fact_key(query)
  if key == "" then
    return 0
  end

  local kept = {}
  local removed = 0
  for i = 1, #M.facts do
    local item = M.facts[i]
    local item_key = fact_key(fact_content(item))
    local same_chat = core.text_or(item.chat_id, "") == chat_id or core.text_or(item.scope, "chat") == "global"
    local matched = same_chat and (item_key:find(key, 1, true) or key:find(item_key, 1, true))
    if matched then
      removed = removed + 1
    else
      kept[#kept + 1] = item
    end
  end
  M.facts = kept
  if removed > 0 then
    save_facts()
    core.append_log("memory", "forgot " .. tostring(removed))
  end
  return removed
end

-- 给事实打分，偏向当前会话和最近更新的内容。
local function score_fact(item, user_text, source)
  local APP = M.APP
  local core = APP.core
  source = type(source) == "table" and source or {}
  local text_key = fact_key(fact_content(item) .. " " .. core.text_or(item.tags, "") .. " " .. core.text_or(item.keywords, ""))
  local query_key = fact_key(user_text)
  if query_key == "" or text_key == "" then
    return 0
  end

  local matched = false
  local score = 0
  if #query_key >= 6 and (text_key:find(query_key, 1, true) or query_key:find(text_key, 1, true)) then
    score = score + 3
    matched = true
  end
  for _, word in ipairs(extract_keywords(user_text, 10)) do
    local key = fact_key(word)
    if #key >= 3 and text_key:find(key, 1, true) then
      score = score + 0.8
      matched = true
    end
  end
  if not matched then
    return 0
  end

  local chat_id = core.text_or(source.chat_id, "")
  if core.text_or(item.chat_id, "") == chat_id and chat_id ~= "" then
    score = score + 0.7
  elseif core.text_or(item.scope, "chat") == "global" then
    score = score + 0.2
  end

  score = score + math.min(0.4, tonumber(item.score) or 0.5)
  score = score + math.min(0.2, (tonumber(item.updated_ms) or 0) / 1000000000)
  return score
end

-- 召回与当前请求相关的少量事实。
local function recall(user_text, source)
  local APP = M.APP
  if not APP.config.memory_enabled then
    return {}
  end
  load_facts()

  -- 不引入向量库，按关键词、scope 和分数做轻量召回，适合嵌入式端。
  local ranked = {}
  for i = 1, #M.facts do
    local item = M.facts[i]
    ranked[#ranked + 1] = {
      score = score_fact(item, user_text, source),
      fact = item,
    }
  end
  table.sort(ranked, function(a, b)
    return a.score > b.score
  end)

  local limit = tonumber(APP.config.memory_prompt_limit) or 6
  local out = {}
  for i = 1, #ranked do
    if #out >= limit then
      break
    end
    if ranked[i].score >= RECALL_THRESHOLD then
      out[#out + 1] = ranked[i].fact
    end
  end
  return out
end

-- 返回 profile markdown，供 WebUI 编辑 identity/user/soul。
local function profiles()
  local APP = M.APP
  local core = APP.core
  ensure_dirs()
  local out = {}
  for _, name in ipairs({ "identity", "user", "soul" }) do
    local raw = core.read_text_file(profile_path(name))
    out[name] = raw or ""
  end
  return out
end

-- 保存 profile markdown，限制单段长度避免 WebUI 误写过大文件。
local function save_profiles(values)
  local APP = M.APP
  local core = APP.core
  values = type(values) == "table" and values or {}
  local ok, err = ensure_dirs()
  if not ok then
    return false, err
  end
  for _, name in ipairs({ "identity", "user", "soul" }) do
    if type(values[name]) == "string" then
      local text = core.utf8_prefix(values[name], 6000)
      local wrote, write_err = core.write_text_file(profile_path(name), text)
      if not wrote then
        APP.state.memory.last_error = write_err or ("save profile failed: " .. name)
        return false, APP.state.memory.last_error
      end
    end
  end
  APP.state.memory.last_error = ""
  core.append_log("memory", "profiles saved")
  return true, nil
end

-- 搜索长期事实；query 为空时返回最近记录。
local function list_facts(query, limit)
  local APP = M.APP
  local core = APP.core
  load_facts()
  query = core.trim(query)
  limit = core.clamp(limit or 20, 1, 80)
  local key = fact_key(query)
  local out = {}
  for i = 1, #M.facts do
    local item = M.facts[i]
    local hay = fact_key(fact_content(item) .. " " .. core.text_or(item.tags, "") .. " " .. core.text_or(item.keywords, ""))
    if key == "" or hay:find(key, 1, true) then
      out[#out + 1] = item
      if #out >= limit then
        break
      end
    end
  end
  return out
end

-- 按 id 删除长期事实，WebUI 单条删除使用。
local function forget_id(id)
  local APP = M.APP
  local core = APP.core
  id = core.trim(id)
  if id == "" then
    return 0
  end
  load_facts()
  local kept = {}
  local removed = 0
  for i = 1, #M.facts do
    if core.text_or(M.facts[i].id, "") == id then
      removed = removed + 1
    else
      kept[#kept + 1] = M.facts[i]
    end
  end
  if removed > 0 then
    M.facts = kept
    save_facts()
    core.append_log("memory", "forgot id " .. id)
  end
  return removed
end

-- 导出长期事实、当前会话摘要和 profile markdown。
local function export_data(source)
  local APP = M.APP
  load_facts()
  ensure_dirs()
  return {
    ok = true,
    version = 1,
    exported_ms = APP.core.now_ms(),
    facts = M.facts,
    session = load_session(source),
    profiles = profiles(),
  }
end

-- 导入长期事实/profile/session；replace 会先清空事实。
local function import_data(doc, source)
  local APP = M.APP
  local core = APP.core
  doc = type(doc) == "table" and doc or {}
  local data = type(doc.data) == "table" and doc.data or doc
  local mode = core.text_or(doc.mode, "merge")
  local imported = 0
  ensure_dirs()
  load_facts()
  if mode == "replace" then
    M.facts = {}
  end

  local seen = {}
  for i = 1, #M.facts do
    local item = M.facts[i]
    seen[fact_key(fact_content(item)) .. "|" .. core.text_or(item.scope, "chat") .. "|" .. core.text_or(item.chat_id, "")] = true
  end

  local facts = type(data.facts) == "table" and data.facts or {}
  for i = 1, #facts do
    local item = facts[i]
    local content = fact_content(item)
    if content ~= "" then
      local scope = core.text_or(type(item) == "table" and item.scope or "", "chat")
      local chat_id = core.text_or(type(item) == "table" and item.chat_id or "", "")
      local key = fact_key(content) .. "|" .. scope .. "|" .. chat_id
      if not seen[key] then
        local now = core.now_ms()
        M.facts[#M.facts + 1] = {
          id = core.text_or(type(item) == "table" and item.id or "", "m" .. tostring(now) .. "_" .. tostring(math.random(1000, 9999))),
          scope = scope,
          chat_id = chat_id,
          kind = core.text_or(type(item) == "table" and item.kind or "", "import"),
          content = core.short_text(core.normalize_space(content), 240),
          tags = core.text_or(type(item) == "table" and item.tags or "", infer_tags(content, "import")),
          keywords = core.text_or(type(item) == "table" and item.keywords or "", table.concat(extract_keywords(content), ",")),
          source = core.text_or(type(item) == "table" and item.source or "", "import"),
          score = tonumber(type(item) == "table" and item.score or nil) or 0.7,
          created_ms = tonumber(type(item) == "table" and item.created_ms or nil) or now,
          updated_ms = tonumber(type(item) == "table" and item.updated_ms or nil) or now,
        }
        seen[key] = true
        imported = imported + 1
      end
    end
  end

  if type(data.profiles) == "table" then
    save_profiles(data.profiles)
  end
  if type(data.session) == "table" then
    save_session(source, {
      summary = core.text_or(data.session.summary, ""),
      turns = tonumber(data.session.turns) or 0,
      updated_ms = tonumber(data.session.updated_ms) or core.now_ms(),
    })
  end
  save_facts()
  core.append_log("memory", "imported " .. tostring(imported))
  return true, imported
end

-- 把会话摘要和长期事实格式化成 prompt 片段。
local function build_context(user_text, source)
  local APP = M.APP
  local core = APP.core
  if not APP.config.memory_enabled then
    return ""
  end

  -- 只把少量相关记忆注入 prompt，避免长期记录压过最新用户请求。
  local parts = {}
  ensure_dirs()

  local profile_parts = {}
  local profiles = {
    { title = "Identity", name = "identity" },
    { title = "User profile", name = "user" },
    { title = "Soul", name = "soul" },
  }
  for i = 1, #profiles do
    local raw = core.read_text_file(profile_path(profiles[i].name))
    raw = core.normalize_space(raw or "")
    if raw ~= "" and not raw:find("%(empty%)", 1, true) then
      profile_parts[#profile_parts + 1] = profiles[i].title .. ":\n" .. core.short_text(raw, 420)
    end
  end
  if #profile_parts > 0 then
    parts[#parts + 1] = "Profile memory:"
    parts[#parts + 1] = table.concat(profile_parts, "\n")
  end

  load_facts()
  local index = build_index()
  if type(index.summaries) == "table" and #index.summaries > 0 then
    local labels = {}
    for i = 1, #index.summaries do
      labels[#labels + 1] = index.summaries[i].label
      if #labels >= 10 then
        break
      end
    end
    if #labels > 0 then
      if #parts > 0 then
        parts[#parts + 1] = ""
      end
      parts[#parts + 1] = "Memory summary labels: " .. table.concat(labels, ", ")
    end
  end

  local sess = load_session(source)
  if sess.summary ~= "" then
    if #parts > 0 then
      parts[#parts + 1] = ""
    end
    parts[#parts + 1] = "Session summary:"
    parts[#parts + 1] = core.short_text(sess.summary, APP.config.memory_session_chars)
  end

  local facts = recall(user_text, source)
  if #facts > 0 then
    if #parts > 0 then
      parts[#parts + 1] = ""
    end
    parts[#parts + 1] = "Relevant memory facts:"
    for i = 1, #facts do
      parts[#parts + 1] = "- " .. core.short_text(fact_content(facts[i]), 160)
    end
  end

  if #parts == 0 then
    return ""
  end
  return table.concat(parts, "\n")
end

-- 更新滚动摘要，不额外请求模型，避免占用网络和 RAM。
local function update_session_summary(user_text, reply, source)
  local APP = M.APP
  local core = APP.core
  local sess = load_session(source)
  local line = "U: " .. core.short_text(user_text, 120) .. "\nA: " .. core.short_text(reply, 160)
  local summary = core.normalize_space(core.text_or(sess.summary, ""))
  if summary ~= "" then
    summary = summary .. "\n" .. line
  else
    summary = line
  end

  local limit = tonumber(APP.config.memory_session_chars) or 1200
  summary = core.utf8_clean(summary)
  while #summary > limit do
    local next_summary = summary:gsub("^[^\n]*\n?", "", 1)
    if next_summary == "" or next_summary == summary then
      summary = core.short_text(summary, limit)
      break
    end
    summary = next_summary
  end

  sess.summary = summary
  sess.turns = (tonumber(sess.turns) or 0) + 1
  sess.updated_ms = core.now_ms()
  return save_session(source, sess)
end

-- 观察一轮成功对话，更新摘要并处理显式记忆/忘记指令。
local function observe_turn(user_text, reply, source)
  local APP = M.APP
  local core = APP.core
  if not APP.config.memory_enabled then
    return
  end
  source = type(source) == "table" and source or {}

  -- 每轮结束后只做低成本观察：显式记忆指令、忘记指令和短会话摘要。
  local forget = extract_forget_text(user_text)
  if forget ~= "" then
    forget_matching(forget, source)
  end

  local fact = extract_memory_text(user_text)
  if fact ~= "" then
    add_fact(fact, {
      scope = "chat",
      chat_id = core.text_or(source.chat_id, ""),
      kind = "explicit",
      score = 0.9,
    })
  end

  local ok, err = update_session_summary(user_text, reply, source)
  if not ok then
    core.append_log("warn", "memory session " .. core.short_text(err, 100))
  end
end

-- 返回记忆状态快照，供 Web API 调试。
local function snapshot(source)
  local APP = M.APP
  load_facts()
  local sess = load_session(source)
  local recent = {}
  local limit = math.min(8, #M.facts)
  for i = 1, limit do
    recent[#recent + 1] = M.facts[i]
  end
  return {
    ok = true,
    enabled = APP.config.memory_enabled,
    facts = #M.facts,
    session = {
      key = session_key(source),
      turns = sess.turns,
      summary = sess.summary,
      updated_ms = sess.updated_ms,
    },
    recent = recent,
    profiles = profiles(),
    last_error = APP.state.memory.last_error,
  }
end

-- 清空当前会话摘要或全部长期事实。
local function clear(scope, source)
  local APP = M.APP
  local core = APP.core
  scope = core.text_or(scope, "session")
  ensure_dirs()
  if scope == "all" then
    M.facts = {}
    M.loaded = true
    save_facts()
  end
  if scope == "all" or scope == "session" then
    write_json_file(session_path(source), {
      summary = "",
      turns = 0,
      updated_ms = core.now_ms(),
    })
  end
  core.append_log("memory", "clear " .. scope)
  return true, nil
end

-- 初始化记忆模块，实际文件读取延迟到首次使用。
function M.init(APP)
  M.APP = APP
  APP.memory = {
    build_context = build_context,
    observe_turn = observe_turn,
    add_fact = add_fact,
    recall = recall,
    forget_matching = forget_matching,
    forget_id = forget_id,
    list_facts = list_facts,
    profiles = profiles,
    save_profiles = save_profiles,
    export_data = export_data,
    import_data = import_data,
    snapshot = snapshot,
    clear = clear,
  }
end

return M
