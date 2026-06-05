---
{
  "name": "self_check",
  "description": "一键检查 ESP Claw 的 LLM 配置、HTTP、SD、WeChat、Claw Panel 和 memory 健康状态。",
  "metadata": {
    "cap_groups": ["self_check"],
    "manage_mode": "readonly"
  }
}
---

# 自检

用户要求检查健康状态、排查 ESP Claw 是否可用、检查 LLM/HTTP/SD/微信/Panel/记忆时使用。

## 规则

1. 调用 `self_check`。
2. 用中文简短说明每项状态。
3. `warn` 不等于失败；说明需要配置或当前未启用。
4. 不主动请求外部 LLM，不消耗 token。
5. 不读取或输出 API key、微信 token 等敏感值。
