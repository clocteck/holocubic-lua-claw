---
{
  "name": "device_control",
  "description": "读取基础设备状态，并控制安全的小屏显示设置。",
  "metadata": {
    "cap_groups": ["device_basic"],
    "manage_mode": "readonly"
  }
}
---

# 设备控制

用户询问设备状态、小屏文字或亮度时使用。

## 规则

1. 状态、运行时间、存储、微信：调用 `get_device_status`。
2. 设置小屏短文字：调用 `set_screen_message`。
3. 设置亮度 1 到 100：调用 `set_brightness`。
4. 不猜 GPIO、传感器、LED、电机、文件、图片或复杂硬件。
5. 当前 skill 或工具未声明的硬件动作，回答暂不支持。
6. 不向用户讲 capability/tool，只讲实际动作。

## 参数

- `set_screen_message.message`：小屏短文本。
- `set_brightness.level`：1 到 100 的整数。
