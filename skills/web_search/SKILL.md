---
{
  "name": "web_search",
  "description": "Current public information lookup fallback using HTTP from device Lua when a hosted web search tool is not available.",
  "metadata": {
    "cap_groups": ["code_runner"],
    "manage_mode": "execute"
  }
}
---

# Web Search Fallback

Use this skill only for current external facts such as weather, prices, news, exchange rates, or other public information that may change.

This environment may not provide a hosted `web_search` function tool. Do not call a `web_search` tool unless it is explicitly present in the tool list.

Prefer the structured local lookup tools when they are visible:

- `web_probe`: check 1-5 URLs and compare status. Use this before saying the network is unavailable. It is status-only and does not prove page contents.
- `web_fetch`: fetch one page and return `{url,status,source,title,excerpt,items}` without dumping large HTML. This also updates `lookup_context`.
- `lookup_context`: read the most recent lookup sources and numbered items for follow-up questions such as "第7具体讲讲" or "你从哪个网址查的".

Rules:

- Do not infer "no Wi-Fi" or "network unavailable" from a single failed URL. Try another relevant source or report that the specific source failed.
- Realtime answers must include concise source names.
- For professional/API/model/spec questions, prefer official pages first and compare 2-3 relevant pages when possible.
- For follow-up questions, use `lookup_context` before fetching again.
- If the user asks to read a page, list titles/items/headlines, summarize page content, or explain an item number, use `web_fetch` or `lookup_context`; `web_probe` alone is not enough.

When these structured tools are not available, use `lua_run` with `target="service"` and the `http` module to fetch a small public HTTP endpoint, then print the status and a concise body excerpt.

Prefer synchronous HTTP so the result is captured in the same turn:

```lua
local code, body = http.get(url, { timeout = 8000, bufsz = 32768, max_redirects = 2 })
print("HTTP_STATUS " .. tostring(code))
print(string.sub(tostring(body or ""), 1, 2000))
```

For weather, use a public no-key endpoint if possible, for example:

```lua
local url = "https://wttr.in/Ningbo?format=3"
local code, body = http.get(url, { timeout = 8000, bufsz = 8192, max_redirects = 2 })
print("HTTP_STATUS " .. tostring(code))
print(tostring(body or ""))
```

If the HTTP request fails, times out, or the endpoint is unreachable, tell the user that realtime lookup is unavailable from the device right now and include the observed status/error. Do not invent current data.
