---
{
  "name": "memory_ops",
  "description": "管理设备上的长期记忆：记住、回忆、列出和遗忘。",
  "metadata": {
    "cap_groups": ["claw_memory"],
    "manage_mode": "readonly"
  }
}
---

# 长期记忆

用户明确要求记住、回忆、列出或忘记长期信息时使用。

## 规则

1. 只保存简洁事实，不保存用户原话。
2. 记住或保存：调用 `memory_store`。
3. 依赖长期记忆回答：先调用 `memory_recall`。
4. 查看记忆：调用 `memory_list`。
5. 删除记忆：调用 `memory_forget`。
6. 不直接读写 `memory_records.jsonl`、`memory_index.json`、`memory_digest.log`、`MEMORY.md`。
7. 工具成功后，才说已保存或已删除。

## 参数

- `memory_store.content`：一条稳定事实。
- `memory_store.tags`：逗号分隔的标签，可选。
- `memory_store.keywords`：逗号分隔的关键词，可选。
- `memory_recall.query`：短检索词。
- `memory_forget.query`：要删除的事实或关键词。
