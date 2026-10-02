# 本地额度文件扩展

在「AI 额度 → 添加应用」中选择 JSON 文件，即可把其他来源加入总览。工具保存文件位置，每分钟重新读取；数据更新时间取必填的 `observedAt`，不会用读取文件的时间冒充新数据。文件应保留在本机稳定位置，由你自己的工具更新。

这是只读数据接入。AI 额度不执行文件中的命令、脚本或网络地址。文件只能包含下面列出的额度字段；不要放入 token、cookie、API key、账号标识或其他登录凭据。未知字段会被拒绝。

## 示例

完整文件见 [examples/quota-provider.json](../examples/quota-provider.json)。更新示例的 `observedAt` 为实际采集时间后再用于日常显示：

```json
{
  "schemaVersion": 1,
  "id": "custom.example",
  "name": "示例应用",
  "observedAt": "2026-10-02T00:00:00Z",
  "metrics": [
    {
      "id": "weekly",
      "label": "每周额度",
      "kind": "periodic",
      "remainingPercent": 75,
      "reset": {"at": "2026-10-09T00:00:00+08:00", "precision": "day"}
    },
    {
      "id": "extra",
      "label": "额外积分",
      "kind": "balance",
      "remaining": 200,
      "unit": "积分",
      "contributesToSummary": false
    }
  ]
}
```

## 字段

| 字段 | 规则 |
| --- | --- |
| `schemaVersion` | 必填，当前为整数 `1` |
| `id` | 必填、稳定、以 `custom.` 开头；仅小写字母、数字、点和连字符，最多 64 字符；不能覆盖内置来源 |
| `name` | 必填显示名称，非空，最多 80 字符 |
| `observedAt` | 必填带时区的 ISO 8601 实际采集时间，例如 `2026-10-02T08:00:00+08:00`；不能超前当前时间五分钟以上 |
| `metrics` | 必填，1–20 个指标；每个指标的 `id` 唯一 |

| 指标字段 | 规则 |
| --- | --- |
| `id`、`label` | 必填、非空；分别最多 64、80 字符 |
| `kind` | `periodic` 或 `balance`，省略时为 `periodic` |
| `remainingPercent` | 可选，剩余百分比，有限数值且在 0–100 之间 |
| `remaining`、`limit` | 可选余额与总量，有限数值；`limit` 提供时必须大于零 |
| `unit` | 可选单位，最多 20 字符 |
| `reset` | 可选对象，含必填 `at` 和可选 `precision`；`at` 为带时区 ISO 8601 时间 |
| `reset.precision` | `instant` 或 `day`，省略时为 `instant` |
| `contributesToSummary` | 是否参与主要周期摘要，省略时为 `true`；余额建议显式设为 `false` |

显式 `remainingPercent` 优先；未提供时，只有同时提供 `remaining` 和有效 `limit` 才能算出百分比。缺失字段或 `null` 表示未知，已知耗尽的额度应明确写 `0`。不要用总余额、购买积分或多个周期相加来伪造周期百分比。

菜单栏取参与摘要的 `periodic` 指标中最低的剩余百分比；`balance` 始终独立显示，不参与该摘要。所有指标都没有可用周期百分比时，菜单栏显示未知。点击详情不会更改默认来源；在选中应用下方的操作栏或设置中明确设为默认后才保存选择。

若服务只给出日期，使用该日期对应时区的午夜作为 `at` 的日期载体，并设置 `precision: "day"`。界面仅显示日期和「时间未明确」，不会把午夜当作确切重置时刻。确切时刻使用 `instant`；显示统一换算为北京时间。

文件必须是普通文件且不超过 1 MB。格式、标识或时间无效时会提示错误；旧数据会标注同步失败或过期。修改文件内容时保持顶层 `id` 不变，换来源应导入另一份文件。不要填写账号身份：本地文件没有登录或账号切换协议，生成工具应在退出登录时把旧额度改为未知或停止提供旧结果。
