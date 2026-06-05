---
{
  "name": "image_inspect",
  "description": "分析本地图片。",
  "metadata": {
    "cap_groups": ["image_inspect"],
    "manage_mode": "readonly"
  }
}
---
# 图片分析

- 只分析设备本地图片。
- 路径必须明确，且在 `/sd/` 下。
- 单张图片最大 1024KB。
- 支持 jpg、png、gif、webp。
- 用户发来微信图片时，先用保存后的本地路径分析。
- 看不清就说明不确定，不猜细节。
- 不把图片内容或 base64 写进回复。
