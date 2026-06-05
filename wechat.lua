local M = {}

-- 构造微信接口请求头，auth 为 true 时带 bot token。
local function wechat_headers(auth)
  local APP = M.APP
  local headers = {
    ["Content-Type"] = "application/json",
    ["iLink-App-Id"] = "bot",
    ["iLink-App-ClientVersion"] = "131329",
  }
  if auth then
    headers["AuthorizationType"] = "ilink_bot_token"
    headers["Authorization"] = "Bearer " .. APP.config.wechat_token
  end
  return headers
end

-- 规范化微信接口 base URL。
local function wechat_base_url(value)
  local APP = M.APP
  local base = APP.core.trim(value)
  if base == "" then
    base = APP.DEFAULT_WECHAT_BASE_URL
  end
  return base:gsub("/+$", "")
end

-- 规范化微信 CDN base URL，用于加密媒体上传。
local function wechat_cdn_base_url()
  local APP = M.APP
  local base = APP.core.trim(APP.config.wechat_cdn_base_url)
  if base == "" then
    base = APP.DEFAULT_WECHAT_CDN_BASE_URL
  end
  return base:gsub("/+$", "")
end

-- 发送微信 POST 请求，支持同步和回调两种底层形态。
local function wechat_post(endpoint, root, callback)
  local APP = M.APP
  local core = APP.core
  local base = wechat_base_url(APP.config.wechat_base_url)
  local raw = core.safe_json_encode(root)
  if not raw then
    if callback then
      callback(nil, "encode failed")
    end
    return nil, "encode failed"
  end
  return http.post(base .. "/" .. endpoint, {
    headers = wechat_headers(true),
    timeout = 40000,
    bufsz = 4096,
  }, raw, callback)
end

-- 查找 HTTP 响应头，底层通常会把 header 名收口成小写。
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

-- 生成 QR 登录状态快照，按需带 token。
local function qr_snapshot(include_token)
  local APP = M.APP
  local q = APP.state.wechat_qr
  local out = {
    ok = true,
    active = q.active,
    completed = q.completed,
    configured = APP.config.wechat_token ~= "",
    status = q.status,
    message = q.message,
    qr_data_url = q.qr_data_url,
    user_id = q.user_id,
    base_url = q.base_url,
  }
  if include_token and q.completed and q.token ~= "" then
    out.token = q.token
  end
  return out
end

-- 重置 QR 登录状态。
local function qr_reset(status, message)
  local q = M.APP.state.wechat_qr
  q.active = false
  q.completed = false
  q.status = status or "idle"
  q.message = message or "QR idle"
  q.qrcode = ""
  q.qr_data_url = ""
  q.token = ""
  q.user_id = ""
  q.base_url = ""
  q.current_api_base_url = ""
  q.started_ms = 0
end

-- 同步 GET JSON，用于 QR 获取和轮询。
local function wechat_get_json_wait(base_url, endpoint, timeout_ms, label)
  local APP = M.APP
  local core = APP.core
  if not http or not http.get then
    return nil, "http.get missing"
  end
  label = core.text_or(label, "wechat qr")
  local base = wechat_base_url(base_url)
  local ok_call, code, body = pcall(function()
    return http.get(base .. "/" .. endpoint, {
      headers = wechat_headers(false),
      timeout = timeout_ms or 15000,
      bufsz = 4096,
      max_redirects = 2,
    })
  end)
  if not ok_call then
    return nil, label .. " request failed: " .. core.short_text(code, 160)
  end
  if not code then
    return nil, label .. " timeout"
  end
  if code < 200 or code >= 300 then
    return nil, label .. " http " .. tostring(code) .. ": " .. core.short_text(body, 160)
  end
  local doc, err = core.safe_json_decode(body)
  if type(doc) ~= "table" then
    return nil, label .. " json " .. core.text_or(err, "bad")
  end
  return doc, nil
end

-- 开始微信扫码登录流程。
local function qr_start(force, base_url)
  local APP = M.APP
  local core = APP.core
  local q = APP.state.wechat_qr
  if q.active and not force then
    return true, qr_snapshot(false)
  end
  qr_reset("starting", "Fetching QR code")
  q.active = true
  q.started_ms = core.now_ms()
  q.current_api_base_url = wechat_base_url(base_url or APP.config.wechat_base_url)

  local doc, err = wechat_get_json_wait(q.current_api_base_url, "ilink/bot/get_bot_qrcode?bot_type=3", 15000, "wechat qr")
  if type(doc) ~= "table" then
    qr_reset("error", err or "failed to fetch QR code")
    core.append_log("error", APP.state.wechat_qr.message)
    APP.ui_api.redraw()
    return false, APP.state.wechat_qr.message
  end

  local qrcode = core.text_or(doc.qrcode, "")
  local qr_data_url = core.text_or(doc.qrcode_img_content, "")
  if qrcode == "" or qr_data_url == "" then
    qr_reset("error", "QR response missing fields")
    core.append_log("error", APP.state.wechat_qr.message)
    APP.ui_api.redraw()
    return false, APP.state.wechat_qr.message
  end

  q.qrcode = qrcode
  q.qr_data_url = qr_data_url
  q.status = "waiting_scan"
  q.message = "Scan the QR code with WeChat."
  core.append_log("wechat", "qr waiting")
  APP.ui_api.redraw()
  return true, qr_snapshot(false)
end

-- 轮询一次 QR 登录状态。
local function qr_poll_once()
  local APP = M.APP
  local core = APP.core
  local q = APP.state.wechat_qr
  if not q.active or q.qrcode == "" then
    return true, qr_snapshot(true)
  end

  local base = q.current_api_base_url ~= "" and q.current_api_base_url or APP.DEFAULT_WECHAT_BASE_URL
  local endpoint = "ilink/bot/get_qrcode_status?qrcode=" .. core.url_encode(q.qrcode)
  local doc, err = wechat_get_json_wait(base, endpoint, 12000, "wechat qr status")
  if type(doc) ~= "table" then
    local err_text = core.text_or(err, "")
    if err_text:find("timeout", 1, true)
      or err_text:find("ESP_ERR_HTTP_EAGAIN", 1, true)
      or err_text:find("http -1", 1, true) then
      if q.status == "scanned" then
        q.message = "Scanned. Confirm in WeChat."
      elseif q.status == "redirected" then
        q.message = "Login node redirected. Continue waiting."
      else
        q.status = "waiting_scan"
        q.message = "Waiting for scan."
      end
      APP.ui_api.redraw()
      return true, qr_snapshot(true)
    end
    q.status = "error"
    q.message = err or "QR status failed"
    core.append_log("warn", q.message)
    APP.ui_api.redraw()
    return false, q.message
  end

  local status = core.text_or(doc.status, "")
  if status == "wait" then
    q.status = "waiting_scan"
    q.message = "Waiting for scan."
  elseif status == "scanned" then
    q.status = "scanned"
    q.message = "Scanned. Confirm in WeChat."
  elseif status == "scaned_but_redirect" then
    local redirect_host = core.text_or(doc.redirect_host, "")
    if redirect_host ~= "" then
      q.current_api_base_url = "https://" .. redirect_host
    end
    q.status = "redirected"
    q.message = "Login node redirected. Continue waiting."
  elseif status == "expired" then
    q.active = false
    q.status = "expired"
    q.message = "QR code expired."
  elseif status == "confirmed" then
    q.active = false
    q.completed = true
    q.status = "confirmed"
    q.message = "WeChat login confirmed. Review and Save."
    q.token = core.text_or(doc.bot_token, q.token)
    q.user_id = core.text_or(doc.ilink_user_id, q.user_id)
    q.base_url = core.text_or(doc.baseurl, q.current_api_base_url ~= "" and q.current_api_base_url or APP.DEFAULT_WECHAT_BASE_URL)
    core.append_log("wechat", "qr confirmed")
  else
    q.status = "error"
    q.message = "Unknown QR status."
  end
  APP.ui_api.redraw()
  return true, qr_snapshot(true)
end

-- 取消 QR 登录。
local function qr_cancel()
  local APP = M.APP
  qr_reset("cancelled", "WeChat login cancelled.")
  APP.core.append_log("wechat", "qr cancelled")
  APP.ui_api.redraw()
  return true, qr_snapshot(false)
end

-- 向微信会话发送文本。
local function send_text(chat_id, message)
  local APP = M.APP
  local core = APP.core
  if not APP.config.wechat_enabled or APP.config.wechat_token == "" then
    return false, "wechat not configured"
  end
  local client_id = "esp-" .. tostring(core.now_ms()) .. "-" .. tostring(math.random(1000, 9999))
  local root = {
    msg = {
      from_user_id = "",
      to_user_id = chat_id,
      client_id = client_id,
      message_type = 2,
      message_state = 2,
      item_list = {
        {
          type = 1,
          text_item = { text = message },
        },
      },
    },
    base_info = {
      channel_version = "esp-claw-wechat",
    },
  }
  local context_token = core.text_or(APP.state.wechat_context[chat_id], "")
  if context_token ~= "" then
    root.msg.context_token = context_token
  end
  local ok_call, code, body = pcall(function()
    return wechat_post("ilink/bot/sendmessage", root)
  end)
  if not ok_call then
    return false, "wechat send failed: " .. core.short_text(code, 160)
  end
  if not code or code < 200 or code >= 300 then
    return false, "wechat send http " .. tostring(code) .. ": " .. core.short_text(body, 160)
  end
  return true, nil
end

-- 上传已加密图片密文，返回 image message 需要的 encrypt_query_param。
local function upload_ciphertext(upload_full_url, upload_param, filekey, ciphertext)
  local APP = M.APP
  local core = APP.core
  local url = core.trim(upload_full_url)
  if url == "" then
    upload_param = core.trim(upload_param)
    filekey = core.trim(filekey)
    if upload_param == "" or filekey == "" then
      return nil, "upload url missing"
    end
    url = wechat_cdn_base_url() ..
      "/upload?encrypted_query_param=" .. core.url_encode(upload_param) ..
      "&filekey=" .. core.url_encode(filekey)
  end

  local ok_call, code, body, headers = pcall(function()
    return http.post(url, {
      headers = { ["Content-Type"] = "application/octet-stream" },
      timeout = 60000,
      bufsz = 4096,
    }, ciphertext)
  end)
  if not ok_call then
    return nil, "wechat image upload failed: " .. core.short_text(code, 160)
  end
  if not code or code < 200 or code >= 300 then
    return nil, "wechat image upload http " .. tostring(code) .. ": " .. core.short_text(body, 160)
  end

  local encrypted_param = header_value(headers, "x-encrypted-param")
  if encrypted_param == "" then
    return nil, "wechat image upload missing x-encrypted-param"
  end
  return encrypted_param, nil
end

-- 执行官方 ESP-Claw 同款图片加密上传流程。
local function upload_image_file(chat_id, path)
  local APP = M.APP
  local core = APP.core
  local crypto = APP.wechat_crypto
  if not crypto then
    return nil, "wechat crypto missing"
  end
  if not file then
    return nil, "file api missing"
  end
  if not http or not http.post then
    return nil, "http client missing"
  end

  path = core.trim(path)
  if path == "" then
    return nil, "image path is required"
  end
  if not path:match("^/sd/") then
    return nil, "image path must be under /sd"
  end
  if file.stat then
    local st = file.stat(path)
    if not st or st.is_dir then
      return nil, "image file not found"
    end
    local size = tonumber(st.size) or 0
    if size <= 0 then
      return nil, "image file is empty"
    end
    if size > APP.config.wechat_max_image_bytes then
      return nil, "image file too large"
    end
  end

  local plaintext, read_err = core.read_text_file(path)
  if not plaintext then
    return nil, read_err or "read image failed"
  end
  if #plaintext > APP.config.wechat_max_image_bytes then
    return nil, "image file too large"
  end

  local md5_hex, md5_err = crypto.md5_hex(plaintext)
  if not md5_hex then
    return nil, md5_err or "md5 failed"
  end
  local aes_key_raw = crypto.random_bytes(16)
  local aes_key_hex = crypto.bytes_to_hex(aes_key_raw)
  local aes_key_base64 = crypto.base64_encode(aes_key_hex)
  local filekey_hex = crypto.random_hex(16)
  local cipher_size = (math.floor(#plaintext / 16) + 1) * 16

  local root = {
    filekey = filekey_hex,
    media_type = 1,
    to_user_id = chat_id,
    rawsize = #plaintext,
    rawfilemd5 = md5_hex,
    filesize = cipher_size,
    no_need_thumb = true,
    aeskey = aes_key_hex,
    base_info = {
      channel_version = "esp-claw-wechat",
    },
  }

  local ok_call, code, body = pcall(function()
    return wechat_post("ilink/bot/getuploadurl", root)
  end)
  if not ok_call then
    return nil, "wechat getuploadurl failed: " .. core.short_text(code, 160)
  end
  if not code or code < 200 or code >= 300 then
    return nil, "wechat getuploadurl http " .. tostring(code) .. ": " .. core.short_text(body, 160)
  end

  local doc, dec_err = core.safe_json_decode(body)
  if type(doc) ~= "table" then
    return nil, "wechat getuploadurl json " .. core.text_or(dec_err, "bad")
  end
  local upload_full_url = core.text_or(doc.upload_full_url, "")
  local upload_param = core.text_or(doc.upload_param, "")
  if upload_full_url == "" and upload_param == "" then
    return nil, "wechat getuploadurl missing upload url"
  end

  local ciphertext, enc_err = crypto.aes_128_ecb_pkcs7_encrypt(plaintext, aes_key_raw)
  plaintext = nil
  if not ciphertext then
    return nil, enc_err or "aes encrypt failed"
  end

  local download_param, upload_err = upload_ciphertext(upload_full_url, upload_param, filekey_hex, ciphertext)
  if not download_param then
    return nil, upload_err
  end
  return {
    download_param = download_param,
    aes_key_base64 = aes_key_base64,
    ciphertext_size = #ciphertext,
  }, nil
end

-- 发送微信图片消息；caption 会先单独发文本，保持官方 ESP-Claw 行为。
local function send_image(chat_id, path, caption)
  local APP = M.APP
  local core = APP.core
  if not APP.config.wechat_enabled or APP.config.wechat_token == "" then
    return false, "wechat not configured"
  end
  chat_id = core.trim(chat_id)
  if chat_id == "" then
    return false, "chat_id is required"
  end
  caption = core.trim(caption)
  if caption ~= "" then
    local ok, err = send_text(chat_id, caption)
    if not ok then
      return false, err
    end
  end

  local media, upload_err = upload_image_file(chat_id, path)
  if not media then
    return false, upload_err
  end

  local client_id = "esp-img-" .. tostring(core.now_ms()) .. "-" .. tostring(math.random(1000, 9999))
  local msg = {
    from_user_id = "",
    to_user_id = chat_id,
    client_id = client_id,
    message_type = 2,
    message_state = 2,
    item_list = {
      {
        type = 2,
        image_item = {
          media = {
            encrypt_query_param = media.download_param,
            aes_key = media.aes_key_base64,
            encrypt_type = 1,
          },
          mid_size = media.ciphertext_size,
        },
      },
    },
  }
  local context_token = core.text_or(APP.state.wechat_context[chat_id], "")
  if context_token ~= "" then
    msg.context_token = context_token
  end
  local ok_call, code, body = pcall(function()
    return wechat_post("ilink/bot/sendmessage", {
      msg = msg,
      base_info = {
        channel_version = "esp-claw-wechat",
      },
    })
  end)
  if not ok_call then
    return false, "wechat image send failed: " .. core.short_text(code, 160)
  end
  if not code or code < 200 or code >= 300 then
    return false, "wechat image send http " .. tostring(code) .. ": " .. core.short_text(body, 160)
  end
  return true, nil
end

-- 从微信消息里抽取纯文本内容。
local function text_from_msg(msg)
  local APP = M.APP
  local core = APP.core
  if type(msg) ~= "table" or type(msg.item_list) ~= "table" then
    return ""
  end
  local parts = {}
  for i = 1, #msg.item_list do
    local item = msg.item_list[i]
    if type(item) == "table" and tonumber(item.type) == 1 and type(item.text_item) == "table" then
      local text = core.text_or(item.text_item.text, "")
      if text ~= "" then
        parts[#parts + 1] = text
      end
    end
  end
  return table.concat(parts, "\n")
end

-- 查找微信 getupdates 返回的下一轮同步 key。
local function next_sync(doc)
  if type(doc) ~= "table" then
    return nil
  end
  local keys = {
    "get_updates_buf",
    "getupdates_buf",
    "next_get_updates_buf",
    "sync_buf",
  }
  for i = 1, #keys do
    local value = doc[keys[i]]
    if type(value) == "string" then
      return value, keys[i]
    end
  end
  return nil, nil
end

-- 生成微信消息调试标签。
local function msg_label(msg)
  local APP = M.APP
  local core = APP.core
  if type(msg) ~= "table" then
    return "bad"
  end
  local id = core.text_or(msg.message_id, "")
  if type(msg.message_id) == "number" then
    id = "num:" .. id
  end
  local from = core.text_or(msg.from_user_id, "")
  local group = core.text_or(msg.group_id, "")
  return "id=" .. core.short_text(id, 20) .. " from=" .. core.short_text(from ~= "" and from or group, 18)
end

-- 生成消息去重 key，优先用消息字段，最后带短文本兜底。
local function seen_key(chat_id, from_user_id, msg, text)
  local core = M.APP.core
  local message_id = core.text_or(type(msg) == "table" and msg.message_id or "", "")
  local t = core.text_or(type(msg) == "table" and (msg.create_time or msg.timestamp or msg.time) or "", "")
  local client_id = core.text_or(type(msg) == "table" and msg.client_id or "", "")
  return table.concat({
    "wxmsg",
    core.text_or(chat_id, ""),
    core.text_or(from_user_id, ""),
    message_id,
    t,
    client_id,
    core.short_text(core.normalize_space(text), 180),
  }, "|")
end

-- 判断消息是否已经处理，并限制 seen 表大小。
local function seen_message(id)
  local S = M.APP.state
  id = M.APP.core.text_or(id, "")
  if id == "" then
    return false
  end
  if S.seen[id] then
    return true
  end
  S.seen[id] = true
  local count = 0
  for _ in pairs(S.seen) do
    count = count + 1
  end
  if count > 80 then
    S.seen = { [id] = true }
  end
  return false
end

-- 处理一条微信消息：抽文本、调用 agent、回发。
local function handle_msg(msg)
  local APP = M.APP
  local core = APP.core
  if type(msg) ~= "table" then
    return
  end

  local from_user_id = core.text_or(msg.from_user_id, "")
  local group_id = core.text_or(msg.group_id, "")
  local chat_id = group_id ~= "" and group_id or from_user_id
  if chat_id == "" then
    return
  end

  local context_token = core.text_or(msg.context_token, "")
  if context_token ~= "" then
    APP.state.wechat_context[chat_id] = context_token
  end

  local text = core.trim(text_from_msg(msg))
  local image_count = 0
  if APP.wechat_media and APP.wechat_media.count_images then
    image_count = APP.wechat_media.count_images(msg)
  end
  local media_results = {}

  local key_text = text ~= "" and text or ("[image:" .. tostring(image_count) .. "]")
  local key = seen_key(chat_id, from_user_id, msg, key_text)
  if seen_message(key) then
    return
  end

  if image_count > 0 and APP.wechat_media and APP.wechat_media.handle_msg then
    local ok, result = pcall(APP.wechat_media.handle_msg, msg, {
      chat_id = chat_id,
      sender_id = from_user_id,
      message_id = core.text_or(msg.message_id, ""),
    })
    if ok and type(result) == "table" then
      media_results = result
    elseif not ok then
      core.append_log("error", "wechat image " .. core.short_text(result, 140))
    end
  end

  if image_count > 0 then
    local image_path = ""
    local image_err = ""
    for i = 1, #media_results do
      local item = media_results[i]
      if type(item) == "table" and item.ok and type(item.result) == "string" and item.result ~= "" then
        image_path = item.result
        break
      elseif type(item) == "table" and image_err == "" then
        image_err = core.text_or(item.result, "")
      end
    end

    if image_path ~= "" then
      local prompt = text ~= "" and text or "请简要描述这张图片。"
      local reply, err = APP.agent.handle_user_message(prompt, {
        channel = "wechat",
        chat_id = chat_id,
        sender_id = from_user_id,
        message_id = core.text_or(msg.message_id, ""),
        image_path = image_path,
      })
      if not reply then
        reply = "图片已收到，但我暂时看不了：" .. core.short_text(err, 160)
      end
      local ok, send_err = send_text(chat_id, reply)
      if not ok then
        core.append_log("error", send_err or "wechat send failed")
      end
      return
    end

    if text == "" then
      local reply = "图片已收到，但保存失败。"
      if image_err ~= "" then
        reply = reply .. "原因：" .. core.short_text(image_err, 120)
      end
      local ok, send_err = send_text(chat_id, reply)
      if not ok then
        core.append_log("error", send_err or "wechat send failed")
      end
      return
    end
  end

  if text == "" then
    return
  end

  local reply, err = APP.agent.handle_user_message(text, {
    channel = "wechat",
    chat_id = chat_id,
    sender_id = from_user_id,
    message_id = core.text_or(msg.message_id, ""),
  })
  if not reply then
    reply = "ESP Claw error: " .. core.short_text(err, 180)
  end
  local ok, send_err = send_text(chat_id, reply)
  if not ok then
    core.append_log("error", send_err or "wechat send failed")
  end
end

-- 轮询一次微信消息。
local function poll_once()
  local APP = M.APP
  local core = APP.core
  local S = APP.state
  if not APP.config.wechat_enabled or APP.config.wechat_token == "" or not http or not http.post then
    return
  end

  local now = core.now_ms()
  if S.wechat_inflight then
    if now > 0 and S.wechat_poll_started_ms > 0 and now - S.wechat_poll_started_ms > 55000 then
      core.append_log("warn", "wechat poll watchdog reset")
      S.wechat_inflight = false
    else
      return
    end
  end
  if S.busy then
    return
  end

  S.wechat_inflight = true
  S.wechat_poll_started_ms = now
  local root = {
    get_updates_buf = S.wechat_sync_buf or "",
    base_info = {
      channel_version = "esp-claw-wechat",
    },
  }

  local function finish_poll()
    S.wechat_inflight = false
    S.wechat_poll_started_ms = 0
    S.last_wechat_poll_ms = core.now_ms()
  end

  local function handle_poll_response(code, body)
    if code ~= 200 then
      core.append_log("warn", "wechat poll http " .. tostring(code))
      finish_poll()
      APP.ui_api.redraw()
      return
    end
    local doc, err = core.safe_json_decode(body)
    if type(doc) ~= "table" then
      core.append_log("warn", "wechat json " .. core.text_or(err, "bad"))
      finish_poll()
      APP.ui_api.redraw()
      return
    end
    local ret = tonumber(doc.ret or 0) or 0
    local errcode = tonumber(doc.errcode or 0) or 0
    if ret ~= 0 or errcode ~= 0 then
      core.append_log("warn", "wechat api ret=" .. tostring(ret) .. " err=" .. tostring(errcode))
      finish_poll()
      APP.ui_api.redraw()
      return
    end

    local sync, sync_key = next_sync(doc)
    if sync ~= nil then
      local old_len = #(S.wechat_sync_buf or "")
      S.wechat_sync_buf = sync
      if #sync ~= old_len then
        core.append_log("wechat", "sync " .. tostring(old_len) .. "->" .. tostring(#sync) .. " " .. core.text_or(sync_key, ""))
      end
    else
      core.append_log("warn", "wechat no sync key")
    end

    local msgs = type(doc.msgs) == "table" and doc.msgs or {}
    if #msgs > 0 then
      core.append_log("wechat", "msgs " .. tostring(#msgs) .. " " .. msg_label(msgs[1]))
    end
    for i = 1, #msgs do
      local ok, msg_err = pcall(handle_msg, msgs[i])
      if not ok then
        core.append_log("error", "wechat msg " .. core.short_text(msg_err, 140))
      end
    end
    finish_poll()
    APP.ui_api.redraw()
  end

  local ok_call, code, body = pcall(function()
    return wechat_post("ilink/bot/getupdates", root, handle_poll_response)
  end)
  if not ok_call then
    core.append_log("error", "wechat poll start " .. core.short_text(code, 140))
    finish_poll()
    APP.ui_api.redraw()
  elseif type(code) == "number" then
    handle_poll_response(code, body)
  end
end

-- 启动微信定时轮询。
local function start_timer()
  local APP = M.APP
  local core = APP.core
  if not tmr or not tmr.create then
    return
  end
  local timer = tmr.create()
  APP.wechat_timer = timer
  APP.add_timer(timer)
  timer:alarm(1000, tmr.ALARM_AUTO, function()
    local ok, err = pcall(function()
      local now = core.now_ms()
      if APP.running
        and APP.config.wechat_enabled
        and now - (APP.state.last_wechat_poll_ms or 0) >= APP.config.wechat_poll_ms then
        poll_once()
      end
    end)
    if not ok then
      APP.state.wechat_inflight = false
      core.append_log("error", "wechat timer " .. core.short_text(err, 140))
      APP.ui_api.redraw()
    end
  end)
end

-- 初始化微信模块。
function M.init(APP)
  M.APP = APP
  math.randomseed((APP.core.now_ms() or 0) + 17)
  APP.wechat = {
    qr_start = qr_start,
    qr_poll_once = qr_poll_once,
    qr_cancel = qr_cancel,
    send_text = send_text,
    send_image = send_image,
    poll_once = poll_once,
    start_timer = start_timer,
  }
end

-- 停止微信轮询 timer，并清理 inflight 状态。
function M.stop(APP)
  if APP.wechat_timer then
    pcall(function() APP.wechat_timer:stop() end)
    pcall(function() APP.wechat_timer:unregister() end)
    APP.wechat_timer = nil
  end
  APP.state.wechat_inflight = false
end

return M
