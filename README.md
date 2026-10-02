# AI 额度

macOS 菜单栏里的多应用 AI 额度面板：集中查看 **Codex、Grok Bot、Manus、Cue 和 Muse** 的剩余额度与重置时间。

这是独立的个人工具，并非 OpenAI 或其他服务商的官方产品。当前版本 **0.3.5**，以源码和本地 Codex 插件的形式提供，需要在自己的 Mac 上编译。

## 本次新增与改进

- **五个应用集中查看**：各来源独立读取和刷新，周期额度与额外余额分开显示。
- **菜单栏默认来源可切换**：菜单栏只显示一个百分比，初始为 Codex；查看其他应用详情不会改变默认来源。
- **更紧凑的原生界面**：44 pt 应用图标横排，图标下直接显示额度与北京时间重置摘要。取消名称和更多按钮，将当前应用的操作集中在图标区下方。
- **明确的连接反馈**：刷新、授权和连接显示忙碌状态；旧数据有警示，网络问题可以重试。缺失数据不会显示为零。
- **减少更新后的重复授权**：本机固定代码签名身份在后续构建中复用，日常查询优先使用固定安装路径。
- **可扩展**：导入本地 JSON 即可增加额度来源，不执行外部脚本。

完整说明见 [更新日志](CHANGELOG.md) 与 [0.3.5 发布说明](docs/releases/0.3.5.md)。

## 安装

需要 macOS 13 或更新版本、Python 3，以及包含 Swift 5.9+ 的 Xcode Command Line Tools。

```sh
# 未安装开发工具时执行
xcode-select --install

git clone https://github.com/HuiAnnn/ai-quota.git
cd ai-quota

# 检查依赖，初始化本机固定签名，再构建安装
bash skills/codex-quota/scripts/quota.sh check
bash skills/codex-quota/scripts/quota.sh signing-setup
bash skills/codex-quota/scripts/quota.sh install
bash skills/codex-quota/scripts/quota.sh open
```

安装后点击菜单栏百分比打开面板。首次初始化签名或读取其他应用登录信息时，macOS 可能要求你本人授权。构建使用本机签名，不需要付费开发者会员；本项目不提供经过 Apple 公证的预编译应用。

`install` 不会覆盖已有应用。升级已有安装时，先用 `build` 生成新版本，再退出旧应用、保留备份并替换到相同安装路径。保留原固定签名身份；已有待确认重置时先处理该操作，不要通过删除记录来绕过保护。

## 使用

1. 点击应用图标查看详情；悬停可查看应用名。
2. 在图标区下方使用“设为菜单栏默认”“打开应用”或对应登录操作。
3. 通过“设置 → 显示的应用”选择显示哪些来源。
4. 通过“添加应用”导入符合格式的本地额度文件。

| 来源 | 登录方式 | 额度信息 |
| --- | --- | --- |
| Codex | 复用本机 Codex 桌面应用或 CLI 登录 | 额度周期、自动重置、可用重置机会 |
| Grok Bot | 原应用登录后，按需授权读取本机登录信息 | 周期额度及接口提供的其他额度 |
| Manus | 原应用登录后，按需授权读取本机登录信息 | 月度积分、刷新积分及独立余额 |
| Cue | 原应用登录后，按需授权读取本机登录信息 | 周期额度及独立余额 |
| Muse | 工具内的独立网页登录窗口 | 周期额度及额外词元余额 |

各服务的接口和权限可能变化。每个来源会独立显示连接结果；来源未提供重置时间时会明确标注未知。所有时间以北京时间显示，不以同步时间替代重置时间。

Codex 预告和历史动态保留在详情的折叠区域。公告来自免费的第三方公开数据源，可能存在延迟；公告本身不会自动执行额度重置。

Codex 每个可用重置机会旁的“重置”按钮会立即使用该机会。查询、自动刷新、构建和预览不会使用重置机会。结果不确定时保留原请求标识，避免重复消耗。

## 数据与权限

本仓库只包含程序源码、通用产品图标、文档和虚构测试样例，不附带账户登录、个人额度记录或开发者的签名材料。

应用读取用户在本机授权的登录信息，用于请求对应服务的额度接口；不将其写入额度诊断输出。Muse 使用独立网页登录会话。后台钥匙串读取不会弹出授权窗口，授权通过明确的前台操作发起。

额度查询、自动刷新和公告解析不调用 AI 模型、不发起 AI 对话。联网功能用于各服务的登录、额度查询和公开公告。账号切换或无法确认身份时，程序清除旧账号的额度缓存。

本地签名解决的是构建身份变化引起的重复授权。首次迁移、登录项更换或钥匙串锁定后仍可能需要授权；不要删除原签名记录、证书或私钥。

## 开发与扩展

原生源码位于 [`skills/codex-quota/assets/native`](skills/codex-quota/assets/native)，使用 Swift、SwiftUI 和 AppKit。插件入口为 [`.codex-plugin/plugin.json`](.codex-plugin/plugin.json)，技能说明为 [`SKILL.md`](skills/codex-quota/SKILL.md)。

```sh
cd skills/codex-quota/assets/native
swift test
python3 -B scripts/test-local-signing.py
```

独立构建原生应用：

```sh
python3 scripts/local-signing.py setup
bash scripts/build-app.sh
open dist/Codex额度.app
```

只读额度查询：

```sh
# 从仓库根目录执行
bash skills/codex-quota/scripts/quota.sh query-all
```

新来源可使用 [JSON 扩展格式](skills/codex-quota/assets/native/docs/quota-provider-extension.md) 和 [示例文件](skills/codex-quota/assets/native/examples/quota-provider.json)。扩展文件只保存额度数据，不应包含账号身份、Cookie、Token 或其他凭据。

问题反馈请使用 [GitHub Issues](https://github.com/HuiAnnn/ai-quota/issues)。提交问题时请勿附上登录文件或未经检查的诊断内容。
