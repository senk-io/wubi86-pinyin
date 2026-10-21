# wubi86-pinyin

五笔字形 86 版 + 拼音混输的 [Rime](https://rime.im) 输入方案，面向 Windows（小狼毫）和 macOS（鼠须管）。

目标是解决一个具体的问题：**五笔打到一半忘了码，想要的字又不在首位，只能按数字去选。**

## 现在能做什么（v0.1）

- **五笔 86 为主，拼音随时混输**：不用切换模式，直接打拼音。五笔候选总是排在前面。
- **拼音候选显示五笔编码**：例如打 `nihao` 会看到 `你好〔wqvb〕`、`你〔wq〕`，打一次就顺便学会。
- **学码模式**：以反引号开头，例如 `` `shu ``，只出拼音候选并附带编码。
- **混输去噪**：四码五笔不会被误当成拼音简拼。比如 `adnt` 只出"藏 茂 荿"，不会冒出"安东尼他"。
- **用户词频**：同码字里你选过的会排到前面，下次直接按空格上屏。
- 开关 `code_hint` 可以关闭编码提示。

## 安装

1. 下载本仓库，然后运行安装脚本。脚本会从官方 GitHub Release 下载最新的 Rime 前端（macOS 是鼠须管，Windows 是小狼毫），校验签名后安装，过程中会要求输入密码或进行管理员授权。macOS 上如果已经装过鼠须管，会先卸载再重新安装，`~/Library/Rime` 里的用户数据保留。
   - macOS（13 或更高）：`sh scripts/install-macos.sh`
   - Windows：`powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1`
2. 在输入法菜单里选择「鼠须管」或「小狼毫」，默认方案就是「五笔86·拼音」。

macOS 上如果装完在菜单栏看不到鼠须管，注销后重新登录一次即可。

卸载：`sh scripts/uninstall-macos.sh`。它会删除鼠须管应用、安装记录和偏好设置；`~/Library/Rime`（含词频记录）会先询问再删。

如果你原来已经有 `default.custom.yaml`，脚本不会覆盖它，会提示你手动把 `wubi86_pinyin` 加进 `schema_list`。

## 目录结构

| 路径 | 内容 | 许可证 |
|---|---|---|
| `schema/` | 方案配置与 Lua 过滤器 | MIT |
| `data/` | 第三方码表与拼音词库（未修改） | Apache-2.0，见 [data/NOTICE.md](data/NOTICE.md) |
| `scripts/` | 汇总与安装脚本 | MIT |
| `tests/` | 用 librime 驱动方案的端到端测试 | MIT |
| `docs/` | 设计文档 | MIT |

## 开发与测试

在 Ubuntu 上：

```sh
sudo apt-get install librime-dev librime-bin librime-data librime-plugin-lua
tests/run.sh            # 比对 tests/expected.txt
tests/run.sh --update   # 修改方案后重新生成期望结果
```

`tests/cases.txt` 每行一个输入码；`!k 码` 表示输入后选第 k 个候选上屏，用来测试用户词频。

## 路线图

见 [docs/architecture.md](docs/architecture.md)。

1. 基础方案（本版本）
2. 记忆与纠错：记录"忘码"的字并加强提示，常见拆字错误容错
3. 本地模型（可选）：常驻进程调用 Ollama / llama.cpp，做候选重排与联想
4. 打包与发布
5. 语音输入（按住说话）
6. 扩展：提示词片段与本地脚本入口

## 许可证

MIT，`data/` 目录除外（Apache-2.0）。
