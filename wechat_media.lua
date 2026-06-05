local M = {}

local DEFAULT_KIND = "image"
local DEFAULT_MIME = "image/jpeg"
local DEFAULT_EXT = ".jpg"

local function media_root()
  local APP = M.APP
  local dir = APP.core.trim(APP.config.wechat_media_dir)
  if dir == "" then
    dir = APP.APP_DIR .. "/media/wechat"
  end
  return dir:gsub("/+$", "")
end

local function safe_name(value, fallback)
  value = M.APP.core.text_or(value, fallback or "item")
  value = value:gsub("[^%w_%-%.]", "_")
  value = value:gsub("^_+", ""):gsub("_+$", "")
  if value == "" then
    value = fallback or "item"
  end
  if #value > 48 then
    value = value:sub(1, 48)
  end
  return value
end

local function ensure_media_dir(chat_id)
  local APP = M.APP
  local core = APP.core
  local root = media_root()
  local ok, err = core.ensure_app_dir()
  if not ok then
    return nil, err
  end
  core.ensure_dir(APP.APP_DIR .. "/media")
  ok, err = core.ensure_dir(root)
  if not ok then
    return nil, err
  end
  local chat_dir = root .. "/" .. safe_name(chat_id, "chat")
  ok, err = core.ensure_dir(chat_dir)
  if not ok then
    return nil, err
  end
  return chat_dir, nil
end

local function append_file(path, raw)
  if not file or not file.open then
    return false, "file append api missing"
  end
  local fd = file.open(path, "a+")
  if not fd then
    local old = ""
    if file.getcontents then
      old = file.getcontents(path) or ""
    end
    return M.APP.core.write_text_file(path, old .. raw)
  end
  local ok = fd:write(raw)
  if not ok then
    fd:close()
    return false, "append failed: " .. path
  end
  if fd.flush then
    fd:flush()
  end
  fd:close()
  return true, nil
end

local function metadata_path()
  return media_root() .. "/metadata.jsonl"
end

local function write_metadata(meta)
  local APP = M.APP
  local core = APP.core
  local raw = core.safe_json_encode(meta)
  if not raw then
    return false, "metadata encode failed"
  end
  local dir, err = ensure_media_dir(meta.chat_id or "chat")
  if not dir then
    return false, err
  end
  return append_file(metadata_path(), raw .. "\n")
end

local function header_value(headers, name)
  if type(headers) ~= "table" then
    return ""
  end
  local want = tostring(name or ""):lower()
  for k, v in pairs(headers) do
    if tostring(k):lower() == want then
      return M.APP.core.text_or(v, "")
    end
  end
  return ""
end

local function ext_from_mime(mime, url)
  mime = tostring(mime or ""):lower()
  url = tostring(url or ""):lower()
  if mime:find("png", 1, true) or url:match("%.png[%?%#]?$") then
    return ".png"
  end
  if mime:find("gif", 1, true) or url:match("%.gif[%?%#]?$") then
    return ".gif"
  end
  if mime:find("webp", 1, true) or url:match("%.webp[%?%#]?$") then
    return ".webp"
  end
  return DEFAULT_EXT
end

local function get_media_table(item)
  if type(item) ~= "table" or type(item.image_item) ~= "table" then
    return nil
  end
  if type(item.image_item.media) == "table" then
    return item.image_item.media
  end
  return {}
end

local function extract_image_item(item, index)
  local APP = M.APP
  local core = APP.core
  local media = get_media_table(item)
  if not media then
    return nil
  end
  local image_item = item.image_item
  return {
    kind = DEFAULT_KIND,
    index = index,
    full_url = core.text_or(media.full_url or media.url or media.download_url, ""),
    download_param = core.text_or(media.encrypt_query_param or image_item.encrypt_query_param, ""),
    aes_key = core.text_or(image_item.aeskey or media.aes_key or media.aeskey, ""),
    mime = core.text_or(media.content_type or media.mime_type or media.mime, DEFAULT_MIME),
  }
end

local function count_images(msg)
  if type(msg) ~= "table" or type(msg.item_list) ~= "table" then
    return 0
  end
  local count = 0
  for i = 1, #msg.item_list do
    local item = msg.item_list[i]
    if type(item) == "table" and tonumber(item.type) == 2 and type(item.image_item) == "table" then
      count = count + 1
    end
  end
  return count
end

local function cdn_download_url(download_param)
  local APP = M.APP
  local core = APP.core
  local base = core.trim(APP.config.wechat_cdn_base_url)
  if base == "" then
    base = APP.DEFAULT_WECHAT_CDN_BASE_URL
  end
  return base:gsub("/+$", "") .. "/download?encrypted_query_param=" .. core.url_encode(download_param)
end

local function download_once(url, max_bytes)
  local APP = M.APP
  local core = APP.core
  local ok_call, code, body, headers = pcall(function()
    return http.get(url, {
      timeout = 60000,
      bufsz = 4096,
      max_redirects = 2,
    })
  end)
  if not ok_call then
    return nil, nil, "download failed: " .. core.short_text(code, 160)
  end
  if not code or code < 200 or code >= 300 then
    return nil, nil, "download http " .. tostring(code) .. ": " .. core.short_text(body, 160)
  end
  if type(body) ~= "string" or body == "" then
    return nil, nil, "download body empty"
  end
  if #body > max_bytes then
    return nil, nil, "download body too large"
  end
  return body, headers, nil
end

local function download_plaintext(info)
  local APP = M.APP
  local crypto = APP.wechat_crypto
  if not http or not http.get then
    return nil, nil, "http.get missing"
  end

  local max_bytes = tonumber(APP.config.wechat_max_image_bytes) or (4 * 1024 * 1024)
  local fallback = info.download_param ~= "" and cdn_download_url(info.download_param) or ""
  local body, headers, err
  if info.full_url ~= "" then
    body, headers, err = download_once(info.full_url, max_bytes + 32)
  end
  if not body and fallback ~= "" then
    body, headers, err = download_once(fallback, max_bytes + 32)
  end
  if not body then
    return nil, nil, err or "download url missing"
  end

  if info.aes_key ~= "" then
    local key, key_err = crypto.parse_aes_key(info.aes_key)
    if not key then
      return nil, nil, key_err or "bad aes key"
    end
    local plain, dec_err = crypto.aes_128_ecb_pkcs7_decrypt(body, key)
    if not plain then
      return nil, nil, dec_err or "decrypt failed"
    end
    body = plain
  end

  if #body > max_bytes then
    return nil, nil, "image too large"
  end
  return body, headers, nil
end

local function media_filename(ctx, info, mime)
  local APP = M.APP
  local core = APP.core
  local message_id = core.text_or(ctx.message_id, "")
  local base = message_id ~= "" and message_id or tostring(core.now_ms())
  local ext = ext_from_mime(mime or info.mime, info.full_url)
  return safe_name(base, "image") .. "_" .. tostring(info.index or 1) .. ext
end

local function process_image(ctx, info)
  local APP = M.APP
  local core = APP.core
  local S = APP.state.wechat_media
  local meta = {
    kind = info.kind,
    chat_id = ctx.chat_id,
    sender_id = ctx.sender_id,
    message_id = ctx.message_id,
    item_index = info.index,
    full_url_set = info.full_url ~= "",
    download_param_set = info.download_param ~= "",
    aes_key_set = info.aes_key ~= "",
    encrypted = info.aes_key ~= "",
    status = "pending",
    at = core.now_ms(),
  }

  local dir, dir_err = ensure_media_dir(ctx.chat_id)
  if not dir then
    meta.status = "error"
    meta.error = dir_err
    write_metadata(meta)
    S.failed = (S.failed or 0) + 1
    S.last_error = core.text_or(dir_err, "")
    return false, dir_err, meta
  end

  local body, headers, dl_err = download_plaintext(info)
  if not body then
    meta.status = "error"
    meta.error = dl_err
    write_metadata(meta)
    S.failed = (S.failed or 0) + 1
    S.last_error = core.text_or(dl_err, "")
    return false, dl_err, meta
  end

  local mime = header_value(headers, "content-type")
  if mime == "" then
    mime = info.mime
  end
  local path = dir .. "/" .. media_filename(ctx, info, mime)
  local ok, write_err = core.write_text_file(path, body)
  if not ok then
    meta.status = "error"
    meta.error = write_err
    write_metadata(meta)
    S.failed = (S.failed or 0) + 1
    S.last_error = core.text_or(write_err, "")
    return false, write_err, meta
  end

  meta.status = "saved"
  meta.path = path
  meta.mime = mime
  meta.bytes = #body
  write_metadata(meta)
  S.saved = (S.saved or 0) + 1
  S.last_path = path
  S.last_error = ""
  core.append_log("wechat", "image saved " .. core.short_text(path, 120))
  return true, path, meta
end

local function handle_msg(msg, ctx)
  if type(msg) ~= "table" or type(msg.item_list) ~= "table" then
    return {}
  end
  ctx = type(ctx) == "table" and ctx or {}
  local results = {}
  for i = 1, #msg.item_list do
    local item = msg.item_list[i]
    if type(item) == "table" and tonumber(item.type) == 2 and type(item.image_item) == "table" then
      local info = extract_image_item(item, i)
      if info then
        local ok, result, meta = process_image(ctx, info)
        results[#results + 1] = {
          ok = ok,
          result = result,
          meta = meta,
        }
      end
    end
  end
  return results
end

function M.init(APP)
  M.APP = APP
  APP.state.wechat_media = type(APP.state.wechat_media) == "table" and APP.state.wechat_media or {
    saved = 0,
    failed = 0,
    last_path = "",
    last_error = "",
  }
  APP.wechat_media = {
    count_images = count_images,
    handle_msg = handle_msg,
    media_root = media_root,
  }
end

return M
