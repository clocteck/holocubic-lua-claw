local M = {}

local DEFAULT_PROMPT = "请简要描述这张图片。"
local IMAGE_MAX_BYTES = 1024 * 1024

local function gc()
  if collectgarbage then
    pcall(collectgarbage)
  end
end

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

local function normalize_chat_response(resp)
  if type(resp) ~= "table" or resp.error then
    return resp
  end
  local choice = type(resp.choices) == "table" and resp.choices[1] or nil
  local msg = type(choice) == "table" and choice.message or nil
  if type(msg) ~= "table" then
    return resp
  end

  local content = type(msg.content) == "string" and msg.content or ""
  return {
    id = resp.id,
    output_text = content,
    output = {
      {
        type = "message",
        content = {
          { type = "output_text", text = content },
        },
      },
    },
  }
end

local function response_text(resp)
  if type(resp) ~= "table" then
    return ""
  end
  if type(resp.output_text) == "string" and resp.output_text ~= "" then
    return resp.output_text
  end
  local parts = {}
  local output = type(resp.output) == "table" and resp.output or {}
  for i = 1, #output do
    local item = output[i]
    if type(item) == "table" and item.type == "message" and type(item.content) == "table" then
      for j = 1, #item.content do
        local content = item.content[j]
        if type(content) == "table" then
          local text = content.text or content.output_text
          if type(text) == "string" and text ~= "" then
            parts[#parts + 1] = text
          end
        elseif type(content) == "string" and content ~= "" then
          parts[#parts + 1] = content
        end
      end
    elseif type(item) == "table" and item.type == "output_text" and type(item.text) == "string" then
      parts[#parts + 1] = item.text
    end
  end
  return table.concat(parts, "\n")
end

local function decode_response_body(body)
  local core = M.APP.core
  local resp, dec_err = core.safe_json_decode(body)
  if type(resp) == "table" then
    return resp, nil
  end

  local completed = nil
  local latest = nil
  local text_parts = {}
  for line in core.text_or(body, ""):gmatch("[^\r\n]+") do
    local data = line:match("^data:%s*(.+)$")
    if data and data ~= "[DONE]" then
      local doc = core.safe_json_decode(data)
      if type(doc) == "table" then
        if type(doc.response) == "table" then
          latest = doc.response
          if doc.type == "response.completed" or doc.response.status == "completed" then
            completed = doc.response
          end
        end
        if doc.type == "response.output_text.delta" and type(doc.delta) == "string" then
          text_parts[#text_parts + 1] = doc.delta
        end
      end
    end
  end

  local out = completed or latest
  if type(out) == "table" then
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

local function mime_from_path(path)
  path = tostring(path or ""):lower()
  if path:match("%.png$") then
    return "image/png"
  end
  if path:match("%.gif$") then
    return "image/gif"
  end
  if path:match("%.webp$") then
    return "image/webp"
  end
  if path:match("%.jpg$") or path:match("%.jpeg$") then
    return "image/jpeg"
  end
  return nil
end

local function file_size(path)
  if file and file.stat then
    local st = file.stat(path)
    if not st or st.is_dir then
      return nil, "image file not found"
    end
    return tonumber(st.size) or 0, nil
  end
  return nil, nil
end

local function checked_image_info(path, max_bytes)
  local APP = M.APP
  local core = APP.core
  path = core.trim(path)
  if path == "" then
    return nil, "image path is required"
  end
  if not path:match("^/sd/") then
    return nil, "image path must be under /sd"
  end

  local mime = mime_from_path(path)
  if not mime then
    return nil, "only jpg, png, gif, and webp images are supported"
  end

  max_bytes = core.clamp(max_bytes or IMAGE_MAX_BYTES, 16 * 1024, IMAGE_MAX_BYTES)
  local size, stat_err = file_size(path)
  if stat_err then
    return nil, stat_err
  end
  if size and size <= 0 then
    return nil, "image file is empty"
  end
  if size and size > max_bytes then
    return nil, "image file too large"
  end
  return {
    path = path,
    mime = mime,
    size = size,
    max_bytes = max_bytes,
  }, nil
end

local function read_image(info, max_bytes)
  local core = M.APP.core
  max_bytes = max_bytes or info.max_bytes
  local raw, read_err = core.read_text_file(info.path)
  if not raw then
    return nil, read_err or "read image failed"
  end
  if #raw == 0 then
    return nil, "image file is empty"
  end
  if #raw > max_bytes then
    raw = nil
    gc()
    return nil, "image file too large"
  end
  return raw, nil
end

local function image_data_url(info)
  local APP = M.APP
  local crypto = APP.wechat_crypto
  if not crypto or not crypto.base64_encode then
    return nil, "base64 encoder missing"
  end

  local raw, read_err = read_image(info, info.max_bytes)
  if not raw then
    return nil, read_err
  end
  local ok, data_url_or_err = pcall(function()
    return "data:" .. info.mime .. ";base64," .. crypto.base64_encode(raw)
  end)
  raw = nil
  gc()
  if not ok then
    return nil, "base64 encode failed: " .. tostring(data_url_or_err)
  end
  return data_url_or_err, nil
end

local function inspect_image(path, prompt, source)
  local APP = M.APP
  local core = APP.core
  local S = APP.state.vision
  if not APP.config.vision_enabled then
    return nil, "vision disabled"
  end
  if APP.config.llm_base_url == "" or APP.config.llm_api_key == "" or APP.config.llm_model == "" then
    return nil, "LLM is not configured"
  end
  if not http or not http.post then
    return nil, "http client missing"
  end

  path = core.trim(path)
  prompt = core.trim(prompt)
  if prompt == "" or prompt:match("^%[image:%d+%]$") then
    prompt = DEFAULT_PROMPT
  end

  local max_bytes = tonumber(APP.config.vision_max_image_bytes) or IMAGE_MAX_BYTES
  local info, info_err = checked_image_info(path, max_bytes)
  if not info then
    S.failed = (S.failed or 0) + 1
    S.last_error = core.text_or(info_err, "")
    S.last_path = path
    return nil, info_err
  end

  local detail = core.trim(APP.config.vision_detail)
  if detail ~= "low" and detail ~= "high" and detail ~= "auto" and detail ~= "original" then
    detail = "auto"
  end
  local model_name = tostring(APP.config.llm_model or ""):lower()
  if detail == "original" and (model_name:find("mini", 1, true) or model_name:find("nano", 1, true)) then
    detail = "auto"
  end

  local url, api_kind_or_err = endpoint_url(APP.config.llm_base_url)
  if not url then
    return nil, api_kind_or_err
  end
  local api_kind = api_kind_or_err
  if api_kind == "chat" and tostring(APP.config.llm_base_url or ""):lower():find("api.deepseek.com", 1, true) then
    local err = "当前配置的 DeepSeek 模型不支持图片识别；请切换到支持图片输入的视觉模型或接口。"
    S.failed = (S.failed or 0) + 1
    S.last_error = err
    S.last_path = path
    return nil, err
  end

  local data_url, data_err = image_data_url(info)
  if not data_url then
    S.failed = (S.failed or 0) + 1
    S.last_error = core.text_or(data_err, "")
    S.last_path = path
    return nil, data_err
  end

  local instructions = table.concat({
    "You analyze local images for ESP Claw.",
    "Answer in the user's language.",
    "Be concise. Say what is uncertain instead of guessing.",
  }, "\n")

  local image_part = nil
  local body = nil
  if api_kind == "chat" then
    image_part = {
      type = "image_url",
      image_url = {
        url = data_url,
        detail = detail,
      },
    }
    body = {
      model = APP.config.llm_model,
      messages = {
        { role = "system", content = instructions },
        {
          role = "user",
          content = {
            { type = "text", text = prompt },
            image_part,
          },
        },
      },
      stream = false,
    }
  else
    image_part = {
      type = "input_image",
      image_url = data_url,
      detail = detail,
    }
    body = {
      model = APP.config.llm_model,
      instructions = instructions,
      input = {
        {
          role = "user",
          content = {
            { type = "input_text", text = prompt },
            image_part,
          },
        },
      },
      stream = false,
    }
  end

  local raw, enc_err = core.safe_json_encode(body)
  data_url = nil
  body = nil
  if type(image_part.image_url) == "table" then
    image_part.image_url.url = nil
  elseif image_part.image_url then
    image_part.image_url = nil
  end
  gc()
  if not raw then
    S.failed = (S.failed or 0) + 1
    S.last_error = core.text_or(enc_err, "")
    S.last_path = path
    return nil, enc_err
  end

  local ok_call, code, resp_body = pcall(function()
    return http.post(url, {
      headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
        ["Authorization"] = "Bearer " .. APP.config.llm_api_key,
      },
      timeout = APP.config.llm_timeout_ms,
      bufsz = 8192,
    }, raw)
  end)
  raw = nil
  gc()

  if not ok_call then
    local err = "vision request failed: " .. core.short_text(code, 180)
    S.failed = (S.failed or 0) + 1
    S.last_error = err
    S.last_path = path
    return nil, err
  end

  if code ~= 200 then
    local err = "vision http " .. tostring(code) .. ": " .. core.short_text(resp_body, 220)
    S.failed = (S.failed or 0) + 1
    S.last_error = err
    S.last_path = path
    return nil, err
  end

  local resp, dec_err = decode_response_body(resp_body)
  if api_kind == "chat" and type(resp) == "table" then
    resp = normalize_chat_response(resp)
  end
  if type(resp) ~= "table" then
    local err = "vision json " .. core.text_or(dec_err, "decode failed")
    S.failed = (S.failed or 0) + 1
    S.last_error = err
    S.last_path = path
    return nil, err
  end
  if resp.error then
    local msg = type(resp.error) == "table" and resp.error.message or resp.error
    local err = "vision error " .. core.text_or(msg, "unknown")
    S.failed = (S.failed or 0) + 1
    S.last_error = err
    S.last_path = path
    return nil, err
  end

  local text = core.trim(response_text(resp))
  if text == "" then
    text = "我看到了图片，但没有生成可用描述。"
  end
  text = core.squash_repeated_reply(text)
  S.analyzed = (S.analyzed or 0) + 1
  S.last_path = path
  S.last_error = ""
  S.last_reply = core.short_text(text, 220)
  S.last_mode = "inline"
  core.append_log("vision", "inline " .. core.short_text(path, 110))
  return text, nil
end

function M.init(APP)
  M.APP = APP
  APP.state.vision = type(APP.state.vision) == "table" and APP.state.vision or {
    analyzed = 0,
    failed = 0,
    last_path = "",
    last_error = "",
    last_reply = "",
  }
  APP.vision = {
    inspect_image = inspect_image,
  }
end

return M
