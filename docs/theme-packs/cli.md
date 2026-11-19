# 用 CLI 校验主题包

仓库自带一个命令行校验器，作者和模型在提交主题包前用它检查结构、schema 和限额，不必装到手机上。

```sh
cd app && dart run tool/theme_pack_check.dart <path/to/theme.dshTheme.zip>
```

- 参数只有一个：`.dshTheme.zip` 文件路径。
- 工具**只读**：不修改 zip、不写 App 数据、不安装主题、不联网。
- 它按 App 导入时的格式与限额规则检查，所以这里通过不代表手机上一定好看，但能挡住格式错误。

## 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 校验通过。可以带 `warning`，warning 不影响通过。 |
| `1` | 包本身有问题：schema/结构/大小/路径/PNG/IO 错误。 |
| `2` | 用法错误：缺参数、路径不存在、文件不是 `.dshTheme.zip`。 |

脚本/CI 里判断「能不能导入」只看退出码是否为 `0`，不要解析成功输出里的 `warning` 行。

## 输出

成功时 stdout 每行一个 `key: value`：

```text
ok: true
id: christmas
name: 圣诞限定
version: 1.0.0
mode: system
applied: accent, neutralTint, mode
parsedOnly: highlight, snow, whaleHat, dates
warning: snow_not_applied decorations.snow
```

| 字段 | 含义 |
|---|---|
| `ok` | 固定为 `true`，表示这个包可以导入。 |
| `id` / `name` / `version` / `mode` | 从 `theme.json` 读到的主题标识、显示名（取 `name.zh`）、版本和明暗模式。 |
| `applied` | 首版真正会生效的能力，固定是 `accent, neutralTint, mode`。 |
| `parsedOnly` | 已解析、但首版不会应用的能力，只列包里实际出现的：`highlight`、`snow`、`whaleHat`、`dates`。全都没有时这一行不输出。 |
| `warning` | 0 到多行。`<code> <field>` 形式，`code` 说明为什么没应用，`field` 是 `theme.json` 里的字段路径。warning 不是失败。 |

`warning` 的 `code` 固定为 `highlight_not_applied`、`snow_not_applied`、`whaleHat_not_applied`、`dates_not_applied`
之一；`field` 分别是 `colors.highlight`、`decorations.snow`、`decorations.whaleHat`、`dates`。

失败时写到 stderr：

```text
ok: false
error: noTheme
field: theme.json
reason: /path/to/theme.dshTheme.zip has no theme.json
```

- `error` 是稳定错误码，适合脚本判断；`field` 可能省略；`reason` 是给人看的原因。模型层的细分类错误（例如 `invalidMode`）会被压成 `badTheme`，具体细节在 `reason` 里。
- 失败一律是非 0 退出码，不要把 `ok: false` 当成通过。

用法错误（缺参数、文件不存在、不是 `.dshTheme.zip`）同样是退出码 `2`，但只打印用法和原因，没有 `ok:` 行：

```text
usage: dart run tool/theme_pack_check.dart <file.dshTheme.zip>
reason: file does not exist: theme.dshTheme.zip
```

## 注意

- 这个工具是仓库内的开发/作者工具，**不是手机端功能**，App 里没有对应入口。
- 手机端只接受 `.dshTheme.zip`；裸 `theme.json` 即使能过 CLI 的部分检查，也不能直接导入。
- 校验器不执行包内 HTML/CSS/JS，也不检查预览图在视觉上是否合适。
