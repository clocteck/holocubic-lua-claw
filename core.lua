local M = {}

-- 兼容 nil 函数调用，供 UI 更新这类弱依赖接口使用。
local function call(fn, ...)
  if fn then
    return pcall(fn, ...)
  end
  return false
end

-- 把 nil 或空串统一收口成字符串。
local function text_or(value, fallback)
  if value == nil then
    return fallback or ""
  end
  local text = tostring(value)
  if text == "" then
    return fallback or ""
  end
  return text
end

local function utf8_char_len_at(text, pos)
  local b = text:byte(pos)
  if not b then return 0 end
  if b < 0x80 then return 1 end
  if b >= 0xC2 and b <= 0xDF then return 2 end
  if b >= 0xE0 and b <= 0xEF then return 3 end
  if b >= 0xF0 and b <= 0xF4 then return 4 end
  return 0
end

local function utf8_cont(text, pos)
  local b = text:byte(pos)
  return b and b >= 0x80 and b <= 0xBF
end

-- 清除非法 UTF-8 字节，避免 JSON 请求被上游直接判 Bad Request。
local function utf8_clean(value)
  local text = text_or(value, "")
  if not text:find("[\128-\255]") then
    return text
  end
  local out = {}
  local i = 1
  local n = #text
  while i <= n do
    local b = text:byte(i)
    local len = utf8_char_len_at(text, i)
    local ok = false
    if len == 1 then
      ok = true
    elseif len == 2 then
      ok = utf8_cont(text, i + 1)
    elseif len == 3 then
      local b2 = text:byte(i + 1)
      ok = utf8_cont(text, i + 1) and utf8_cont(text, i + 2)
        and not (b == 0xE0 and b2 < 0xA0)
        and not (b == 0xED and b2 > 0x9F)
    elseif len == 4 then
      local b2 = text:byte(i + 1)
      ok = utf8_cont(text, i + 1) and utf8_cont(text, i + 2) and utf8_cont(text, i + 3)
        and not (b == 0xF0 and b2 < 0x90)
        and not (b == 0xF4 and b2 > 0x8F)
    end
    if ok and i + len - 1 <= n then
      out[#out + 1] = text:sub(i, i + len - 1)
      i = i + len
    else
      i = i + 1
    end
  end
  return table.concat(out)
end

local function utf8_prefix(value, limit)
  local text = utf8_clean(value)
  limit = tonumber(limit) or #text
  if limit <= 0 then return "" end
  if #text <= limit then return text end
  local out = {}
  local used = 0
  local i = 1
  while i <= #text do
    local len = utf8_char_len_at(text, i)
    if len <= 0 or used + len > limit then break end
    out[#out + 1] = text:sub(i, i + len - 1)
    used = used + len
    i = i + len
  end
  return table.concat(out)
end

-- 去除字符串两端空白。
local function trim(text)
  text = utf8_clean(text)
  return text:match("^%s*(.-)%s*$") or ""
end

-- 将数字限制到指定区间。
local function clamp(n, low, high)
  n = tonumber(n) or low
  if n < low then
    return low
  end
  if n > high then
    return high
  end
  return n
end

-- 读取当前毫秒时间，按可用运行时接口降级。
local function now_ms()
  if millis then
    local ok, value = pcall(millis)
    if ok and type(value) == "number" then
      return value
    end
  end
  if tmr and tmr.now then
    local ok, value = pcall(function()
      return tmr.now()
    end)
    if ok and type(value) == "number" then
      return math.floor(value / 1000)
    end
  end
  return 0
end

-- 查询 appmanager 是否正在要求当前 app 退出。
local function app_is_exiting()
  if app and app.exiting then
    local ok, exiting = pcall(app.exiting)
    return ok and exiting
  end
  return false
end

-- 简单阻塞等待，保留给后续低频流程使用。
local function sleep_ms(ms)
  if sleep then
    sleep(ms)
  elseif tmr and tmr.delay then
    tmr.delay(ms * 1000)
  end
end

-- URL 查询参数编码，避免直接拼接二维码 token。
local function url_encode(text)
  text = text_or(text, "")
  return (text:gsub("([^%w%-%._~])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

-- 缩短日志和屏幕文本，避免小屏和 JSON 响应过大。
local function short_text(value, limit)
  local text = utf8_clean(value)
  limit = limit or 48
  text = text:gsub("[\r\n]+", " ")
  if #text <= limit then
    return text
  end
  if limit <= 3 then
    return utf8_prefix(text, limit)
  end
  return utf8_prefix(text, limit - 3) .. "..."
end

-- 归一化空白，用于重复回复检测。
local function normalize_space(text)
  text = utf8_clean(text)
  text = text:gsub("[\r\n]+", "\n")
  text = text:gsub("[ \t]+", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

-- 生成忽略空白的比较文本。
local function compare_text(text)
  text = normalize_space(text)
  text = text:gsub("%s+", "")
  return text
end

-- 按中英文标点粗略拆分句子。
local function split_sentences(text)
  text = text_or(text, "")
  text = text:gsub("。", "。\n")
  text = text:gsub("！", "！\n")
  text = text:gsub("？", "？\n")
  text = text:gsub("%.", ".\n")
  text = text:gsub("!", "!\n")
  text = text:gsub("%?", "?\n")
  local sentences = {}
  for item in text:gmatch("[^\n]+") do
    local sentence = normalize_space(item)
    if sentence ~= "" then
      sentences[#sentences + 1] = sentence
    end
  end
  return sentences
end

-- 检测完全重复的句子或行序列并返回最短前缀。
local function repeated_sequence_prefix(items)
  local total = #items
  if total < 2 then
    return nil
  end
  for repeat_count = 4, 2, -1 do
    if total % repeat_count == 0 then
      local unit = total / repeat_count
      local same = true
      for i = unit + 1, total do
        if compare_text(items[i]) ~= compare_text(items[((i - 1) % unit) + 1]) then
          same = false
          break
        end
      end
      if same then
        local out = {}
        for i = 1, unit do
          out[#out + 1] = items[i]
        end
        return out
      end
    end
  end
  return nil
end

-- 压缩模型偶发的整段重复回复。
local function squash_repeated_reply(text)
  text = normalize_space(text)
  if text == "" then
    return ""
  end

  local flat = compare_text(text)
  for n = 2, 4 do
    if #flat % n == 0 then
      local part = flat:sub(1, #flat / n)
      local repeated = ""
      for _ = 1, n do
        repeated = repeated .. part
      end
      if repeated == flat then
        return part
      end
    end
  end

  local sentences = split_sentences(text)
  local sentence_prefix = repeated_sequence_prefix(sentences)
  if sentence_prefix then
    return table.concat(sentence_prefix, "\n")
  end

  local lines = {}
  for line in text:gmatch("[^\n]+") do
    local normalized_line = normalize_space(line)
    if normalized_line ~= "" then
      lines[#lines + 1] = normalized_line
    end
  end
  local line_prefix = repeated_sequence_prefix(lines)
  if line_prefix then
    return table.concat(line_prefix, "\n")
  end
  return text
end

-- 安全解码 JSON，屏蔽底层异常。
local function safe_json_decode(raw)
  if not raw or raw == "" or not json or not json.decode then
    return nil, "json missing"
  end
  local ok, doc, err = pcall(function()
    local value, decode_err = json.decode(raw)
    return value, decode_err
  end)
  if ok and doc then
    return doc, nil
  end

  -- Responses API 这类大 JSON 常带大量 null。部分固件 json.decode 默认把
  -- null 压成 nil 时会在嵌套表赋值阶段抛 "table index is nil"。
  -- 失败后保留 null 为 false 再解一次，避免整轮 LLM 响应报废。
  local first_err = ok and tostring(err or "decode failed") or tostring(doc)
  local ok_keep, doc_keep, err_keep = pcall(function()
    local value, decode_err = json.decode(raw, { null = false })
    return value, decode_err
  end)
  if ok_keep and doc_keep then
    return doc_keep, nil
  end
  if not ok_keep then
    return nil, tostring(doc_keep or first_err)
  end
  return nil, tostring(err_keep or first_err)
end

-- 安全编码 JSON，屏蔽底层异常。
local function sanitize_json_value(value, depth)
  depth = depth or 0
  if type(value) == "string" then
    return utf8_clean(value)
  end
  if type(value) ~= "table" or depth > 12 then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    local key = type(k) == "string" and utf8_clean(k) or k
    out[key] = sanitize_json_value(v, depth + 1)
  end
  return out
end

local function safe_json_encode(value)
  if not json or not json.encode then
    return nil, "json missing"
  end
  -- 设备侧字符串来源复杂，编码前先递归清理 UTF-8，减少上游 HTTP/JSON 报错。
  local ok, raw, err = pcall(function()
    local text, encode_err = json.encode(sanitize_json_value(value))
    return text, encode_err
  end)
  if not ok then
    return nil, tostring(raw)
  end
  if not raw then
    return nil, tostring(err or "encode failed")
  end
  return raw, nil
end

-- 插入运行日志并限制条数，避免长期运行占用内存。
local function append_log(kind, text)
  local APP = M.APP
  local S = APP.state
  local line = {
    at = now_ms(),
    kind = text_or(kind, "info"),
    text = short_text(text, 180),
  }
  table.insert(S.logs, 1, line)
  while #S.logs > 32 do
    table.remove(S.logs)
  end
end

-- 读取 HTTP request body，并限制最大字节数。
local function read_request_body(req, max_bytes)
  if not req or not req.getbody then
    return "", nil
  end
  local parts = {}
  local total = 0
  while true do
    local chunk = req.getbody()
    if not chunk then
      break
    end
    total = total + #chunk
    if max_bytes and total > max_bytes then
      return nil, "body too large"
    end
    parts[#parts + 1] = chunk
  end
  return table.concat(parts), nil
end

-- 生成 JSON HTTP 响应。
local function json_response(status, value)
  local raw, err = safe_json_encode(value)
  if not raw then
    raw = string.format("{\"ok\":false,\"error\":%q}", text_or(err, "json encode failed"))
    status = "500 Internal Server Error"
  end
  return {
    status = status or "200 OK",
    type = "application/json; charset=utf-8",
    headers = {
      ["cache-control"] = "no-store",
      ["connection"] = "close",
    },
    body = raw,
  }
end

-- 生成文本或 HTML HTTP 响应。
local function text_response(status, content_type, body, headers)
  headers = type(headers) == "table" and headers or {}
  headers["cache-control"] = headers["cache-control"] or "no-store"
  headers["connection"] = headers["connection"] or "close"
  return {
    status = status or "200 OK",
    type = content_type or "text/plain; charset=utf-8",
    headers = headers,
    body = text_or(body, ""),
  }
end

-- 生成统一 JSON 错误响应。
local function error_response(status, message)
  return json_response(status or "400 Bad Request", {
    ok = false,
    error = text_or(message, "request failed"),
  })
end

-- 应用配置表，只接受已知字段并做范围约束。
local function apply_config(cfg)
  local APP = M.APP
  if type(cfg) ~= "table" then
    return
  end
  if type(cfg.llm_base_url) == "string" then
    APP.config.llm_base_url = trim(cfg.llm_base_url)
  end
  if type(cfg.llm_api_key) == "string" then
    APP.config.llm_api_key = trim(cfg.llm_api_key)
  end
  if type(cfg.llm_model) == "string" then
    APP.config.llm_model = trim(cfg.llm_model)
  end
  APP.config.llm_timeout_ms = clamp(cfg.llm_timeout_ms or APP.config.llm_timeout_ms, 5000, 120000)
  if type(cfg.llm_thinking_enabled) == "boolean" then
    APP.config.llm_thinking_enabled = cfg.llm_thinking_enabled
  end
  if type(cfg.llm_thinking_for_code_only) == "boolean" then
    APP.config.llm_thinking_for_code_only = cfg.llm_thinking_for_code_only
  end
  if type(cfg.llm_reasoning_effort) == "string" then
    local effort = trim(cfg.llm_reasoning_effort):lower()
    if effort == "max" then
      APP.config.llm_reasoning_effort = "max"
    elseif effort == "low" or effort == "medium" or effort == "high" then
      APP.config.llm_reasoning_effort = "high"
    end
  end
  APP.config.max_tool_rounds = clamp(cfg.max_tool_rounds or APP.config.max_tool_rounds, 1, 64)
  APP.config.history_limit = clamp(cfg.history_limit or APP.config.history_limit, 0, 30)
  APP.config.history_token_limit = clamp(cfg.history_token_limit or APP.config.history_token_limit, 1000, 60000)
  APP.config.history_message_char_limit = clamp(cfg.history_message_char_limit or APP.config.history_message_char_limit, 400, 12000)
  if type(cfg.progress_level) == "string" then
    local level = trim(cfg.progress_level)
    if level == "off" or level == "normal" or level == "verbose" then
      APP.config.progress_level = level
    end
  end
  if type(cfg.memory_enabled) == "boolean" then
    APP.config.memory_enabled = cfg.memory_enabled
  end
  APP.config.memory_fact_limit = clamp(cfg.memory_fact_limit or APP.config.memory_fact_limit, 10, 300)
  APP.config.memory_prompt_limit = clamp(cfg.memory_prompt_limit or APP.config.memory_prompt_limit, 0, 16)
  APP.config.memory_session_chars = clamp(cfg.memory_session_chars or APP.config.memory_session_chars, 200, 4000)
  if type(cfg.vision_enabled) == "boolean" then
    APP.config.vision_enabled = cfg.vision_enabled
  end
  APP.config.vision_max_image_bytes = clamp(cfg.vision_max_image_bytes or APP.config.vision_max_image_bytes, 16 * 1024, 1024 * 1024)
  if type(cfg.vision_detail) == "string" then
    local detail = trim(cfg.vision_detail)
    if detail == "low" or detail == "high" or detail == "auto" or detail == "original" then
      APP.config.vision_detail = detail
    end
  end
  if type(cfg.panel_app_id) == "string" then
    APP.config.panel_app_id = trim(cfg.panel_app_id)
  end
  if type(cfg.panel_mailbox_dir) == "string" then
    APP.config.panel_mailbox_dir = trim(cfg.panel_mailbox_dir)
  end
  if type(cfg.panel_auto_open) == "boolean" then
    APP.config.panel_auto_open = cfg.panel_auto_open
  end

  if type(cfg.wechat_enabled) == "boolean" then
    APP.config.wechat_enabled = cfg.wechat_enabled
  end
  if type(cfg.wechat_token) == "string" then
    APP.config.wechat_token = trim(cfg.wechat_token)
  end
  if type(cfg.wechat_base_url) == "string" then
    APP.config.wechat_base_url = trim(cfg.wechat_base_url)
  end
  if type(cfg.wechat_cdn_base_url) == "string" then
    APP.config.wechat_cdn_base_url = trim(cfg.wechat_cdn_base_url)
  end
  APP.config.wechat_poll_ms = clamp(cfg.wechat_poll_ms or APP.config.wechat_poll_ms, 1500, 60000)
  APP.config.wechat_max_image_bytes = clamp(cfg.wechat_max_image_bytes or APP.config.wechat_max_image_bytes, 16 * 1024, 4 * 1024 * 1024)
  if type(cfg.wechat_media_dir) == "string" then
    APP.config.wechat_media_dir = trim(cfg.wechat_media_dir)
  end
end

-- 返回不会泄露密钥的公开配置。
local function public_config()
  local APP = M.APP
  return {
    llm_base_url = APP.config.llm_base_url,
    llm_api_key_set = APP.config.llm_api_key ~= "",
    llm_model = APP.config.llm_model,
    llm_timeout_ms = APP.config.llm_timeout_ms,
    llm_thinking_enabled = APP.config.llm_thinking_enabled,
    llm_thinking_for_code_only = APP.config.llm_thinking_for_code_only,
    llm_reasoning_effort = APP.config.llm_reasoning_effort,
    max_tool_rounds = APP.config.max_tool_rounds,
    history_limit = APP.config.history_limit,
    history_token_limit = APP.config.history_token_limit,
    history_message_char_limit = APP.config.history_message_char_limit,
    progress_level = APP.config.progress_level,
    memory_enabled = APP.config.memory_enabled,
    memory_fact_limit = APP.config.memory_fact_limit,
    memory_prompt_limit = APP.config.memory_prompt_limit,
    memory_session_chars = APP.config.memory_session_chars,
    vision_enabled = APP.config.vision_enabled,
    vision_max_image_bytes = APP.config.vision_max_image_bytes,
    vision_detail = APP.config.vision_detail,
    panel_app_id = APP.config.panel_app_id,
    panel_auto_open = APP.config.panel_auto_open,
    wechat_enabled = APP.config.wechat_enabled,
    wechat_token_set = APP.config.wechat_token ~= "",
    wechat_base_url = APP.config.wechat_base_url,
    wechat_cdn_base_url = APP.config.wechat_cdn_base_url,
    wechat_poll_ms = APP.config.wechat_poll_ms,
    wechat_max_image_bytes = APP.config.wechat_max_image_bytes,
    wechat_media_dir = APP.config.wechat_media_dir,
  }
end

-- 返回配置文件路径。
local function config_path()
  return M.APP.APP_DIR .. "/config.json"
end

-- 确保目录存在，不支持 mkdir 时按只读环境降级。
local function ensure_dir(path)
  if not file then
    return false, "file api missing"
  end
  if file.stat then
    local st = file.stat(path)
    if st and st.is_dir then
      return true, nil
    end
    if st then
      return false, path .. " is not a directory"
    end
  end
  if not file.mkdir then
    return true, nil
  end
  local ok = file.mkdir(path)
  if ok then
    return true, nil
  end
  if file.stat then
    local st = file.stat(path)
    if st and st.is_dir then
      return true, nil
    end
  end
  return false, "create dir failed: " .. path
end

-- 确保 app 自身目录存在。
local function ensure_app_dir()
  local APP = M.APP
  local ok_parent, parent_err = ensure_dir("/sd/apps")
  if not ok_parent then
    return false, parent_err
  end
  return ensure_dir(APP.APP_DIR)
end

-- 写入文本文件，优先使用 putcontents，回退到 file.open。
local function write_text_file(path, raw)
  if not file then
    return false, "file api missing"
  end
  if file.putcontents then
    local ok_call, ok_put = pcall(function()
      return file.putcontents(path, raw)
    end)
    if ok_call and ok_put then
      return true, nil
    end
  end
  if not file.open then
    return false, "file write api missing"
  end
  local fd = file.open(path, "w+")
  if not fd then
    return false, "open file failed: " .. path
  end
  local ok_write = fd:write(raw)
  if not ok_write then
    fd:close()
    return false, "write file failed: " .. path
  end
  if fd.flush then
    fd:flush()
  end
  fd:close()
  return true, nil
end

-- 读取文本文件，优先使用 getcontents。
local function read_text_file(path)
  if not file then
    return nil, "file api missing"
  end
  if file.getcontents then
    local ok, raw = pcall(function()
      return file.getcontents(path)
    end)
    if ok and raw then
      return raw, nil
    end
  end
  if not file.open then
    return nil, "file read api missing"
  end
  local fd = file.open(path, "r")
  if not fd then
    return nil, "open file failed: " .. path
  end
  local parts = {}
  while true do
    local chunk = fd:read(1024)
    if not chunk or chunk == "" then
      break
    end
    parts[#parts + 1] = chunk
  end
  fd:close()
  return table.concat(parts), nil
end

-- 从 SD 配置文件加载持久化设置。
local function load_config()
  local APP = M.APP
  if not file then
    return
  end
  local path = config_path()
  if file.exists and not file.exists(path) then
    return
  end
  local raw, read_err = read_text_file(path)
  if not raw then
    APP.state.last_error = "config read " .. text_or(read_err, "failed")
    append_log("warn", APP.state.last_error)
    return
  end
  if not raw or raw == "" then
    return
  end
  local cfg, dec_err = safe_json_decode(raw)
  if type(cfg) == "table" then
    apply_config(cfg)
    return
  end
  APP.state.last_error = "config json " .. text_or(dec_err, "decode failed")
  append_log("warn", APP.state.last_error)
end

-- 保存配置，支持 WebUI 用 __keep__ 保留已有密钥。
local function save_config(partial)
  local APP = M.APP
  local merged = {}
  -- WebUI 保存的是局部表；先复制现有配置，避免没提交的字段被清空。
  for k, v in pairs(APP.config) do
    merged[k] = v
  end
  for k, v in pairs(partial or {}) do
    if k == "llm_api_key" and v == "__keep__" then
      merged[k] = APP.config.llm_api_key
    elseif k == "wechat_token" and v == "__keep__" then
      merged[k] = APP.config.wechat_token
    else
      merged[k] = v
    end
  end
  apply_config(merged)
  local raw, err = safe_json_encode(APP.config)
  if not raw then
    return false, err
  end
  local ok_dir, dir_err = ensure_app_dir()
  if not ok_dir then
    return false, dir_err
  end
  local ok, write_err = write_text_file(config_path(), raw)
  if not ok then
    return false, write_err
  end
  return true, nil
end

-- 生成运行状态快照，供 WebUI 和工具调用使用。
local function refresh_panel_status_cache()
  local APP = M.APP
  local S = APP.state
  local id = trim(APP.config and APP.config.panel_app_id or "")
  if id == "" then id = "claw_panel" end
  -- Panel 是另一个前台 app，通过 status.json 心跳和 service 交换最小状态。
  local raw = read_text_file("/sd/apps/" .. id .. "/status.json")
  if type(raw) ~= "string" or raw == "" then
    return
  end
  local doc = safe_json_decode(raw)
  if type(doc) ~= "table" then
    return
  end
  local updated = tonumber(doc.updated_ms) or 0
  local now = now_ms()
  local age = now - updated
  local fresh = updated > 0 and now > 0 and age >= 0 and age <= 5200 and doc.running ~= false
  S.panel = type(S.panel) == "table" and S.panel or {}
  S.panel.heartbeat_ms = updated
  S.panel.fresh = fresh
  S.panel.phase = text_or(doc.phase, "")
  S.panel.last_phase = text_or(doc.last_phase, "")
  S.panel.current_seq = text_or(doc.current_seq, "")
  if text_or(doc.last_error, "") ~= "" then
    S.panel.last_error = text_or(doc.last_error, "")
  elseif fresh then
    S.panel.last_error = ""
  end
end

local function status_snapshot()
  local APP = M.APP
  local S = APP.state
  -- 快照会被 WebUI 高频轮询，内容保持轻量且自动脱敏。
  refresh_panel_status_cache()
  local remain, used, total = nil, nil, nil
  if file and file.fsinfo then
    local ok, a, b, c = pcall(file.fsinfo)
    if ok then
      remain, used, total = a, b, c
    end
  end

  local version = ""
  if sys and sys.version then
    local ok, v = pcall(sys.version)
    if ok then
      version = text_or(v, "")
    end
  end

  local llm_ready = false
  if APP.agent and APP.agent.llm_configured then
    local ok, ready = pcall(APP.agent.llm_configured)
    llm_ready = ok and ready
  end

  return {
    ok = true,
    version = APP.VERSION,
    route_base = APP.ROUTE_BASE,
    llm_ready = llm_ready,
    busy = S.busy,
    request_count = S.request_count,
    tool_count = S.tool_count,
    last_error = S.last_error,
    last_user = S.last_user,
    last_reply = S.last_reply,
    chat_job = {
      id = S.chat_job and S.chat_job.id or "",
      status = S.chat_job and S.chat_job.status or "idle",
      message = S.chat_job and short_text(S.chat_job.message or "", 160) or "",
      error = S.chat_job and short_text(S.chat_job.error or "", 220) or "",
      channel = S.chat_job and text_or(S.chat_job.channel, "") or "",
      chat_id = S.chat_job and text_or(S.chat_job.chat_id, "") or "",
      session_key = S.chat_job and text_or(S.chat_job.session_key, "") or "",
      queue_pos = S.chat_job and tonumber(S.chat_job.queue_pos) or 0,
      created_ms = S.chat_job and S.chat_job.created_ms or 0,
      started_ms = S.chat_job and S.chat_job.started_ms or 0,
      finished_ms = S.chat_job and S.chat_job.finished_ms or 0,
    },
    chat_runtime = {
      max_running = S.chat_runtime and S.chat_runtime.max_running or 2,
      running = S.chat_runtime and S.chat_runtime.running or 0,
      queued = S.chat_runtime and S.chat_runtime.queued or 0,
    },
    tool_lock = {
      active = S.tool_lock and S.tool_lock.active == true,
      owner = S.tool_lock and text_or(S.tool_lock.owner, "") or "",
      since_ms = S.tool_lock and S.tool_lock.since_ms or 0,
    },
    last_channel = S.last_channel,
    screen_note = S.screen_note,
    brightness = S.brightness,
    uptime_ms = now_ms() - (S.started_ms or now_ms()),
    fs = { remain = remain, used = used, total = total },
    sys_version = version,
    wechat = {
      enabled = APP.config.wechat_enabled,
      configured = APP.config.wechat_token ~= "",
      inflight = S.wechat_inflight,
      sync = S.wechat_sync_buf ~= "",
      media = {
        saved = S.wechat_media and S.wechat_media.saved or 0,
        failed = S.wechat_media and S.wechat_media.failed or 0,
        last_path = S.wechat_media and S.wechat_media.last_path or "",
        last_error = S.wechat_media and S.wechat_media.last_error or "",
      },
      qr = {
        active = S.wechat_qr.active,
        completed = S.wechat_qr.completed,
        status = S.wechat_qr.status,
        message = S.wechat_qr.message,
      },
    },
    memory = {
      enabled = APP.config.memory_enabled,
      facts_loaded = S.memory and S.memory.facts_loaded or 0,
      facts_saved = S.memory and S.memory.facts_saved or 0,
      session_saved = S.memory and S.memory.session_saved or 0,
      last_error = S.memory and S.memory.last_error or "",
    },
    vision = {
      enabled = APP.config.vision_enabled,
      analyzed = S.vision and S.vision.analyzed or 0,
      failed = S.vision and S.vision.failed or 0,
      last_path = S.vision and S.vision.last_path or "",
      last_error = S.vision and S.vision.last_error or "",
      last_reply = S.vision and S.vision.last_reply or "",
    },
    code_runner = {
      runs = S.code_runner and S.code_runner.runs or 0,
      last_ok = S.code_runner and S.code_runner.last_ok or false,
      last_error = S.code_runner and S.code_runner.last_error or "",
      last_elapsed_ms = S.code_runner and S.code_runner.last_elapsed_ms or 0,
    },
    panel = {
      app_id = APP.config.panel_app_id,
      mailbox_dir = APP.config.panel_mailbox_dir,
      opened = S.panel and S.panel.opened or 0,
      queued = S.panel and S.panel.queued or 0,
      last_seq = S.panel and S.panel.last_seq or "",
      last_error = S.panel and S.panel.last_error or "",
      heartbeat_ms = S.panel and S.panel.heartbeat_ms or 0,
      heartbeat_fresh = S.panel and S.panel.fresh or false,
      phase = S.panel and S.panel.phase or "",
      last_phase = S.panel and S.panel.last_phase or "",
      current_seq = S.panel and S.panel.current_seq or "",
      launch_pending = S.panel and S.panel.launch_pending or false,
      last_launch_ms = S.panel and S.panel.last_launch_ms or 0,
    },
    skills = {
      loaded = S.skills and S.skills.loaded or 0,
      active = S.skills and S.skills.active or 0,
      last_error = S.skills and S.skills.last_error or "",
    },
    logs = S.logs,
    config = public_config(),
  }
end

-- 初始化 core 模块并导出公共函数。
function M.init(APP)
  M.APP = APP
  APP.core = {
    call = call,
    text_or = text_or,
    trim = trim,
    clamp = clamp,
    now_ms = now_ms,
    app_is_exiting = app_is_exiting,
    sleep_ms = sleep_ms,
    url_encode = url_encode,
    short_text = short_text,
    normalize_space = normalize_space,
    squash_repeated_reply = squash_repeated_reply,
    safe_json_decode = safe_json_decode,
    safe_json_encode = safe_json_encode,
    utf8_clean = utf8_clean,
    utf8_prefix = utf8_prefix,
    append_log = append_log,
    read_request_body = read_request_body,
    json_response = json_response,
    text_response = text_response,
    error_response = error_response,
    apply_config = apply_config,
    public_config = public_config,
    load_config = load_config,
    save_config = save_config,
    ensure_dir = ensure_dir,
    ensure_app_dir = ensure_app_dir,
    read_text_file = read_text_file,
    write_text_file = write_text_file,
    status_snapshot = status_snapshot,
  }
  APP.state.started_ms = now_ms()
end

return M
