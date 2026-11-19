# 做一份 dsh-go 主题包（作者指南）

dsh-go 的主题包是一个 `.dshTheme.zip`：根目录放一份 `theme.json`，可选再放一张预览图（路径由 `preview` 指定，可在子目录）。
App 只读这份 JSON 和预览图，不执行包里的任何代码。首版真正改变的只有强调色、中性色的色相/彩度和明暗模式；
其余字段会被解析、校验，并在 App 里提示「当前未应用」。

> 主题包是 App 自己的功能，不是原生插件，也不替换官方界面。插件只能往 App 里加卡片和面板；
> 换肤走主题包这条路。

## 1. 包结构

```text
christmas.dshTheme.zip
├─ theme.json     主题定义（必需，schema 1）
└─ preview.png    预览图（可选）
```

- `theme.json` 必须在 **zip 根目录**。不要套顶层文件夹（`my-theme/theme.json` 不认）；预览图可以放在子目录，由 `preview` 指定。
- `theme.json` 必需，只能有一个；`preview.png` 可选，文件名不强制叫 `preview.png`，
  由 `theme.json` 的 `preview` 字段指定。
- 包里的其它文件不会被保存，也不会被执行。
- 首版**只导入 `.dshTheme.zip`**，不单独导入裸 `theme.json`。

## 2. 字段

`theme.json` 是 UTF-8 JSON，schema 固定为 1。

| 字段 | 类型 | 必填 | 首版生效 | 说明 |
|---|---|---|---|---|
| `schema` | 整数 | 是 | — | 只能是 `1`。其它值会被拒绝并提示更新 App。 |
| `id` | 字符串 | 是 | — | 小写字母开头，只含小写字母/数字/`-`，2–48 字符。保持稳定，App 用它识别已导入的主题。 |
| `name` | 字符串或 `{zh,en}` | 是 | 是 | 显示名，≤24 字符。双语对象时 `zh` 必填。 |
| `version` | 字符串 | 是 | — | 形如 `1.0.0`，最多 32 个字符。主题自身的版本，不是 App 版本。 |
| `author` | 字符串 | 否 | — | 署名，≤64 字符。 |
| `description` | 字符串或 `{zh,en}` | 否 | — | 一句话说明，≤160 字符。 |
| `mode` | `system` / `light` / `dark` | 是 | **是** | 明暗模式：跟随系统、固定浅色、固定深色。 |
| `colors.accent` | `#RRGGBB` | 是 | **是** | 强调色种子，App 据此推整套色阶。 |
| `colors.neutralTint` | `#RRGGBB` | 否 | **是** | 中性面的色相和彩度倾向；明度阶梯保持不变。 |
| `colors.highlight` | `#RRGGBB` | 否 | 否，仅提示 | 节日高亮色，预留给勋章/描边一类的点缀。 |
| `decorations.snow` | 布尔 | 否 | 否，仅提示 | 轻雪背景。 |
| `decorations.whaleHat` | 布尔 | 否 | 否，仅提示 | 给鲸鱼戴帽子；后续需要宠物素材和逐帧锚点方案，首版不加载任何素材。 |
| `dates.from` / `dates.to` | `MM-DD` | 否 | 否，仅提示 | 期望的生效区间。 |
| `preview` | 字符串 | 否 | 仅保存/展示 | 预览图在包内的相对路径，必须是 `.png`。 |
| 其它任何字段 | — | — | — | 未知字段直接拒绝（`additionalProperties: false`）。拼错字段名不会静默忽略。 |

机器可读定义见 [schema.json](schema.json)。

### 尚未应用的能力

首版**不会**下雪、**不会**给鲸鱼戴帽子、**不会**用 `highlight` 上色，也**不会**按 `dates` 自动切换季节主题。
这四项在导入时会被解析并给出提示，作者可以现在就写进去，等 App 支持后自动生效；但不要在发布说明里
宣传「节日自动生效」。

`dates` 首版不参与任何切换，格式仍必须合法：`MM-DD`，`from` 晚于 `to` 表示跨年区间，且 `from` 与 `to` 必须成对出现。
写错日期会让整个包校验失败。

## 3. 颜色是「意图」，不是像素结果

`accent` 和 `neutralTint` 只是种子，App 仍会：

- 用同一套规则推导浅色/深色两套色阶，并对正文与背景做对比度校正（至少 4.5:1）。
- 对过艳或过灰的种子做低彩度校正，所以最终颜色可能与你填的十六进制值有偏差。
- 使用 `neutralTint` 时借它的色相和彩度，中性色的明度阶梯保持不变。

想要可预期的结果，选一个能读出主色的种子，别把期望压在精确色值上。

## 4. 安全与限制

App 把主题包当外部输入处理：

| 项 | 限制 |
|---|---|
| zip 文件 | ≤ 8 MiB；声明的展开总量也 ≤ 8 MiB |
| `theme.json` | ≤ 64 KiB |
| 预览图 | ≤ 2 MiB，单边 ≤ 4096 px，总像素 ≤ 400 万 |
| 条目 | ≤ 16（含目录条目；目录条目本身会被忽略，不解压） |
| 读取范围 | 只读 `theme.json` 和它指定的预览 PNG；不跟随符号链接，不允许绝对路径、`..` 或其它路径穿越 |
| 执行 | 不执行包内 HTML/CSS/JS，不联网，不安装任何东西 |
| 保存 | 只保存规范化后的 `theme.json` 和预览 PNG（打包成一个主题文件），不落其它文件 |

包不合格会被整体拒绝，不会部分导入；错误码会说明是哪一项不通过。
主题包也不会替换官方界面，更不等同于原生插件。

## 5. 最小可运行示例

```json
{
  "schema": 1,
  "id": "christmas",
  "name": { "zh": "圣诞限定", "en": "Christmas" },
  "version": "1.0.0",
  "author": "dsh-Go",
  "description": {
    "zh": "松针绿、浆果红和香槟金。",
    "en": "Pine, berry and champagne gold."
  },
  "mode": "system",
  "colors": {
    "accent": "#B4232C",
    "neutralTint": "#14503C",
    "highlight": "#C9973F"
  },
  "decorations": { "snow": true, "whaleHat": true },
  "dates": { "from": "12-01", "to": "12-26" },
  "preview": "preview.png"
}
```

这份定义里真正生效的是 `mode`、`accent`、`neutralTint` 和预览图；`highlight`、`snow`、`whaleHat`、
`dates` 只会解析并提示。

打包（`theme.json` 必须在根目录；预览图的路径由 `preview` 指定）：

```sh
cd christmas
zip -r ../christmas.dshTheme.zip theme.json preview.png
```

导入：在 App 设置的外观入口选择这个 `.dshTheme.zip`；主题会出现在主题列表里，可随时切回内置主题。
需要替换时改内容、升 `version`、保持 `id` 不变再导入。

## 6. 发布前校验

在仓库里用 CLI 校验包结构、schema 和限额，不经过手机：

```sh
cd app && dart run tool/theme_pack_check.dart ../christmas.dshTheme.zip
```

退出码、输出字段和「当前未应用」提示的含义见 [cli.md](cli.md)。
