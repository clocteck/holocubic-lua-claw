---
{
  "name": "wechat_image",
  "description": "发送微信图片。",
  "metadata": {
    "cap_groups": ["wechat_image"],
    "manage_mode": "readonly"
  }
}
---
# 微信图片

- 只发送设备本地图片文件。
- 路径必须明确，且在 `/sd/` 下。
- 不猜图片路径，不猜 chat_id。
- 需要复杂说明时，先发文字，再发图片。
- caption 会先作为文本发送，再发送图片。
- 收到图片时，系统会保存文件和 metadata。
- 不把图片内容或 base64 放进回复。
