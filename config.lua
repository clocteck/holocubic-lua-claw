local M = {}

-- 初始化常量、默认配置和共享状态。
function M.init(APP)
  local main_style = (rawget(_G, "LV_PART_MAIN") or 0) | (rawget(_G, "LV_STATE_DEFAULT") or 0)

  APP.lv = {
    MAIN_STYLE = main_style,
    ALIGN_LEFT = rawget(_G, "LV_TEXT_ALIGN_LEFT") or 0,
    ALIGN_CENTER = rawget(_G, "LV_TEXT_ALIGN_CENTER") or 1,
    LABEL_LONG_CLIP = rawget(_G, "LV_LABEL_LONG_CLIP") or rawget(_G, "LABEL_LONG_CLIP"),
    FONT_10 = rawget(_G, "LV_FONT_MONTSERRAT_10") or 10,
    FONT_12 = rawget(_G, "LV_FONT_MONTSERRAT_12") or 12,
    FONT_16 = rawget(_G, "LV_FONT_MONTSERRAT_16") or 16,
    FONT_20 = rawget(_G, "LV_FONT_MONTSERRAT_20") or 20,
  }
  APP.lv.LABEL_LONG_WRAP = rawget(_G, "LV_LABEL_LONG_WRAP") or APP.lv.LABEL_LONG_CLIP

  APP.colors = {
    bg = 0x05070A,
    panel = 0x101820,
    panel2 = 0x17212B,
    line = 0x2A3542,
    text = 0xF4F7FA,
    sub = 0xAAB4C2,
    dim = 0x6E7B8A,
    blue = 0x4DA3FF,
    green = 0x4DD88A,
    amber = 0xF4B860,
    red = 0xFF6B5F,
  }

  APP.config = {
    llm_base_url = APP.DEFAULT_LLM_BASE_URL,
    llm_api_key = "",
    llm_model = "gpt-4o-mini",
    llm_timeout_ms = 45000,
    llm_thinking_enabled = true,
    llm_thinking_for_code_only = true,
    llm_reasoning_effort = "high",
    max_tool_rounds = 32,
    history_limit = 10,
    history_token_limit = 12000,
    history_message_char_limit = 2400,
    progress_level = "normal",
    memory_enabled = true,
    memory_fact_limit = 80,
    memory_prompt_limit = 6,
    memory_session_chars = 1200,
    vision_enabled = true,
    vision_max_image_bytes = 1024 * 1024,
    vision_detail = "auto",
    panel_app_id = "claw_panel",
    panel_mailbox_dir = "/sd/apps/claw_panel/inbox",
    panel_auto_open = true,
    wechat_enabled = false,
    wechat_token = "",
    wechat_base_url = APP.DEFAULT_WECHAT_BASE_URL,
    wechat_cdn_base_url = APP.DEFAULT_WECHAT_CDN_BASE_URL,
    wechat_poll_ms = 3500,
    wechat_max_image_bytes = 4 * 1024 * 1024,
    wechat_media_dir = APP.APP_DIR .. "/media/wechat",
  }

  APP.state = {
    online = false,
    busy = false,
    request_count = 0,
    tool_count = 0,
    wechat_inflight = false,
    wechat_sync_buf = "",
    last_error = "",
    last_user = "",
    last_reply = "Open WebUI",
    chat_job = {
      id = "",
      status = "idle",
      message = "",
      reply = "",
      error = "",
      created_ms = 0,
      started_ms = 0,
      finished_ms = 0,
    },
    screen_note = "",
    brightness = 80,
    last_channel = "web",
    last_chat_id = "",
    started_ms = 0,
    last_wechat_poll_ms = 0,
    logs = {},
    seen = {},
    lookup_context = {},
    memory = {
      facts_loaded = 0,
      facts_saved = 0,
      session_saved = 0,
      last_error = "",
    },
    skills = {
      loaded = 0,
      active = 0,
      last_error = "",
      active_by_session = {},
    },
    wechat_context = {},
    wechat_media = {
      saved = 0,
      failed = 0,
      last_path = "",
      last_error = "",
    },
    vision = {
      analyzed = 0,
      failed = 0,
      last_path = "",
      last_error = "",
      last_reply = "",
    },
    code_runner = {
      runs = 0,
      last_ok = false,
      last_error = "",
      last_elapsed_ms = 0,
    },
    panel = {
      opened = 0,
      queued = 0,
      last_seq = "",
      last_error = "",
      heartbeat_ms = 0,
      launch_pending = false,
      last_launch_ms = 0,
    },
    wechat_poll_started_ms = 0,
    chat_runtime = {
      max_running = 2,
      running = 0,
      queued = 0,
      active_sessions = {},
    },
    tool_lock = {
      active = false,
      owner = "",
      since_ms = 0,
    },
    wechat_qr = {
      active = false,
      completed = false,
      status = "idle",
      message = "QR idle",
      qrcode = "",
      qr_data_url = "",
      token = "",
      user_id = "",
      base_url = "",
      current_api_base_url = "",
      started_ms = 0,
    },
  }

  APP.history = {}
  APP.histories = {}
  APP.sessions = {}
  APP.chat_jobs = {}
  APP.chat_job_order = {}
  APP.ui = {}
end

return M
