local M = {}

local MAX_SKILL_BYTES = 12 * 1024
local MAX_SKILL_PROMPT_CHARS = 5200

-- Skill 根目录，和官方 ESP-Claw 的 /fatfs/skills 布局保持同构。
local function skills_root()
  return M.APP.APP_DIR .. "/skills"
end

local function skill_path(skill_id)
  return skills_root() .. "/" .. skill_id .. "/SKILL.md"
end

-- 只允许简单目录名，避免模型通过 skill id 逃逸目录。
local function valid_skill_id(skill_id)
  return type(skill_id) == "string" and skill_id:match("^[%w_%-]+$") ~= nil
end

local function session_key(source)
  local APP = M.APP
  local core = APP.core
  source = type(source) == "table" and source or {}
  local channel = core.text_or(source.channel, APP.state.last_channel ~= "" and APP.state.last_channel or "web")
  local chat_id = core.text_or(source.chat_id, APP.state.last_chat_id ~= "" and APP.state.last_chat_id or "web")
  return channel .. ":" .. chat_id
end

local function ensure_state()
  local S = M.APP.state
  S.skills = type(S.skills) == "table" and S.skills or {}
  S.skills.active_by_session = type(S.skills.active_by_session) == "table" and S.skills.active_by_session or {}
  S.skills.loaded = tonumber(S.skills.loaded) or 0
  S.skills.active = tonumber(S.skills.active) or 0
  S.skills.last_error = S.skills.last_error or ""
  return S.skills
end

local function split_cap_groups(value)
  local out = {}
  if type(value) ~= "table" then
    return out
  end
  for i = 1, #value do
    local item = M.APP.core.trim(value[i])
    if item ~= "" then
      out[#out + 1] = item
    end
  end
  return out
end

local function first_heading(body)
  body = M.APP.core.text_or(body, "")
  for line in body:gmatch("[^\r\n]+") do
    local title = line:match("^%s*#+%s+(.+)%s*$")
    if title and title ~= "" then
      return title
    end
  end
  return ""
end

-- 解析 SKILL.md 顶部 JSON frontmatter；解析失败时仍保留正文作为只读 skill。
local function parse_skill(skill_id, raw)
  local core = M.APP.core
  raw = core.text_or(raw, ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local meta = {}
  local body = raw
  local frontmatter, rest = raw:match("^%s*%-%-%-%s*\n(.-)\n%-%-%-%s*\n?(.*)$")
  if frontmatter then
    local decoded = core.safe_json_decode(frontmatter)
    if type(decoded) == "table" then
      meta = decoded
    end
    body = rest or ""
  end

  local metadata = type(meta.metadata) == "table" and meta.metadata or {}
  local name = core.trim(meta.name)
  if not valid_skill_id(name) then
    name = skill_id
  end
  local description = core.trim(meta.description)
  if description == "" then
    description = first_heading(body)
  end
  if description == "" then
    description = "Skill " .. skill_id
  end

  return {
    id = skill_id,
    name = name,
    description = core.short_text(description, 220),
    cap_groups = split_cap_groups(metadata.cap_groups),
    manage_mode = core.text_or(metadata.manage_mode, "readonly"),
    body = core.trim(body),
  }
end

local function read_skill(skill_id)
  local APP = M.APP
  local core = APP.core
  if not valid_skill_id(skill_id) then
    return nil, "invalid skill id"
  end

  local path = skill_path(skill_id)
  if file and file.stat then
    local st = file.stat(path)
    if not st then
      return nil, "skill not found: " .. skill_id
    end
    if st.is_dir then
      return nil, "skill path is a directory"
    end
    if tonumber(st.size) and st.size > MAX_SKILL_BYTES then
      return nil, "skill file too large"
    end
  end

  local raw, err = core.read_text_file(path)
  if not raw or raw == "" then
    return nil, err or "skill file empty"
  end
  if #raw > MAX_SKILL_BYTES then
    raw = raw:sub(1, MAX_SKILL_BYTES)
  end
  return parse_skill(skill_id, raw), nil
end

local function list_skill_ids()
  local ids = {}
  if not file or not file.listdir then
    return ids
  end
  local entries = file.listdir(skills_root()) or {}
  for i = 1, #entries do
    local entry = entries[i]
    local name = type(entry) == "table" and entry.name or ""
    if type(entry) == "table" and entry.is_dir and valid_skill_id(name) then
      ids[#ids + 1] = name
    end
  end
  table.sort(ids)
  return ids
end

local function load_catalog()
  local APP = M.APP
  local S = ensure_state()
  local catalog = {}
  local ids = list_skill_ids()
  for i = 1, #ids do
    local skill, err = read_skill(ids[i])
    if skill then
      catalog[#catalog + 1] = {
        id = skill.id,
        name = skill.name,
        description = skill.description,
        cap_groups = skill.cap_groups,
        manage_mode = skill.manage_mode,
      }
    elseif err then
      S.last_error = err
      APP.core.append_log("skill", APP.core.short_text(err, 120))
    end
  end
  S.loaded = #catalog
  return catalog
end

local function get_session(source)
  local S = ensure_state()
  local key = session_key(source)
  local sess = S.active_by_session[key]
  if type(sess) ~= "table" then
    sess = { ids = {}, map = {}, groups = {} }
    S.active_by_session[key] = sess
  end
  sess.ids = type(sess.ids) == "table" and sess.ids or {}
  sess.map = type(sess.map) == "table" and sess.map or {}
  sess.groups = type(sess.groups) == "table" and sess.groups or {}
  return sess
end

local function recount_active()
  local S = ensure_state()
  local count = 0
  for _, sess in pairs(S.active_by_session) do
    if type(sess) == "table" and type(sess.ids) == "table" then
      count = count + #sess.ids
    end
  end
  S.active = count
end

local function activate(skill_id, source)
  local APP = M.APP
  local core = APP.core
  skill_id = core.trim(skill_id)
  local skill, err = read_skill(skill_id)
  if not skill then
    ensure_state().last_error = err or "activate skill failed"
    return false, ensure_state().last_error
  end

  local sess = get_session(source)
  if not sess.map[skill.id] then
    sess.ids[#sess.ids + 1] = skill.id
    sess.map[skill.id] = true
  end
  for i = 1, #skill.cap_groups do
    sess.groups[skill.cap_groups[i]] = true
  end
  recount_active()
  core.append_log("skill", "activate " .. skill.id)
  return true, skill
end

local function is_group_active(group_id, source)
  group_id = M.APP.core.trim(group_id)
  if group_id == "" then
    return false
  end
  local sess = get_session(source)
  return sess.groups[group_id] == true
end

local function catalog_context()
  local catalog = load_catalog()
  if #catalog == 0 then
    return ""
  end
  local lines = {
    "Skills List（技能列表）:",
    "这些是可选的用户可见能力。只有用户明确要求执行某个 skill 覆盖的流程时，才调用 activate_skill；询问你是谁或能做什么时不要激活 skill。",
  }
  for i = 1, #catalog do
    lines[#lines + 1] = "- " .. catalog[i].id .. ": " .. catalog[i].description
  end
  return table.concat(lines, "\n")
end

local function active_docs_context(source)
  local core = M.APP.core
  local sess = get_session(source)
  if #sess.ids == 0 then
    return ""
  end
  local parts = { "Activated Skill Docs（已激活 Skill 文档）:" }
  for i = 1, #sess.ids do
    local skill = read_skill(sess.ids[i])
    if skill and skill.body ~= "" then
      local body = skill.body
      if #body > MAX_SKILL_PROMPT_CHARS then
        body = body:sub(1, MAX_SKILL_PROMPT_CHARS) .. "\n...(truncated)"
      end
      parts[#parts + 1] = "<skill_content id=\"" .. skill.id .. "\">\n" .. body .. "\n</skill_content>"
    end
  end
  return core.trim(table.concat(parts, "\n"))
end

local function build_context(source)
  local parts = {}
  local catalog = catalog_context()
  if catalog ~= "" then
    parts[#parts + 1] = catalog
  end
  local docs = active_docs_context(source)
  if docs ~= "" then
    parts[#parts + 1] = docs
  end
  return table.concat(parts, "\n\n")
end

local function active_ids(source)
  local sess = get_session(source)
  local out = {}
  for i = 1, #sess.ids do
    out[#out + 1] = sess.ids[i]
  end
  return out
end

local function clear_session(source)
  local S = ensure_state()
  S.active_by_session[session_key(source)] = nil
  recount_active()
  return true
end

local function snapshot(source)
  return {
    ok = true,
    catalog = load_catalog(),
    active = active_ids(source),
  }
end

function M.init(APP)
  M.APP = APP
  ensure_state()
  APP.skills = {
    activate = activate,
    is_group_active = is_group_active,
    build_context = build_context,
    clear_session = clear_session,
    snapshot = snapshot,
  }
end

return M
