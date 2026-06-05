local prev = rawget(_G, "ESP_CLAW_APP")
if prev and prev.stop then
  pcall(function()
    prev.stop("reload")
  end)
end

ESP_CLAW_APP = {
  VERSION = "2026-05-16-esp-claw-v3",
  APP_ID = "esp_claw",
  APP_DIR = "/sd/apps/esp_claw",
  ROUTE_BASE = (app and app.route_base and app.route_base()) or "/esp_claw",
  SCREEN_W = 320,
  SCREEN_H = 240,
  MAX_BODY_BYTES = 64 * 1024,
  MAX_REPLY_CHARS = 2800,
  DEFAULT_LLM_BASE_URL = "http://47.251.91.47/v1",
  DEFAULT_WECHAT_BASE_URL = "https://ilinkai.weixin.qq.com",
  DEFAULT_WECHAT_CDN_BASE_URL = "https://novac2c.cdn.weixin.qq.com/c2c",
  running = true,
  shutting_down = false,
  modules = {},
  module_order = {},
  routes = {},
  timers = {},
}

local APP = ESP_CLAW_APP
APP.API_PREFIX = APP.ROUTE_BASE .. "/api"

-- 载入一个同目录模块，所有模块都返回 table。
local function load_app_module(name)
  local path = APP.APP_DIR .. "/" .. name .. ".lua"
  local chunk, load_err = loadfile(path)
  if not chunk then
    error("load module failed: " .. name .. " " .. tostring(load_err))
  end

  local ok, mod = pcall(chunk)
  if not ok then
    error("module failed: " .. name .. " " .. tostring(mod))
  end
  if type(mod) ~= "table" then
    error("module invalid: " .. name)
  end

  APP.modules[name] = mod
  APP.module_order[#APP.module_order + 1] = name
  return mod
end

-- 注册 timer 到统一生命周期，stop 时会兜底停止。
function APP.add_timer(timer)
  if timer then
    APP.timers[#APP.timers + 1] = timer
  end
  return timer
end

-- 注册动态路由记录，Web 模块释放时按记录反注册。
function APP.add_route(method, route)
  APP.routes[#APP.routes + 1] = { method = method, route = route }
end

-- 应用停止入口，负责倒序释放模块和兜底关闭 timer。
function APP.stop(reason)
  if APP.shutting_down then
    return
  end
  APP.shutting_down = true
  APP.running = false

  for i = #APP.module_order, 1, -1 do
    local name = APP.module_order[i]
    local mod = APP.modules[name]
    if mod and mod.stop then
      pcall(function()
        mod.stop(APP, reason)
      end)
    end
  end

  for _, timer in ipairs(APP.timers) do
    pcall(function() timer:stop() end)
    pcall(function() timer:unregister() end)
  end
  APP.timers = {}

  if app and app.set_webui then
    pcall(function()
      app.set_webui(false)
    end)
  end

  print("[esp_claw] stop", tostring(reason or ""))
end

local module_names = {
  "config",
  "core",
  "wechat_crypto",
  "wechat_media",
  "vision",
  "code_runner",
  "memory",
  "skills",
  "diagnostics",
  "ui",
  "tools",
  "agent",
  "wechat",
  "web",
}

for i = 1, #module_names do
  local mod = load_app_module(module_names[i])
  if mod.init then
    mod.init(APP)
  end
end

APP.core.load_config()
APP.ui_api.build()
APP.web.start()
APP.wechat.start_timer()
APP.core.append_log("ready", APP.ROUTE_BASE)
APP.ui_api.redraw()

print("[esp_claw] ready", APP.VERSION, APP.ROUTE_BASE)
