# SENK五笔 / SENK拼音

基于 [Rime](https://rime.im) 的五笔 86 版 + 拼音混输输入方案，面向 macOS 和 Windows（小狼毫）。包括两款：**SENK五笔混拼输入法86版** 和 **SENK拼音输入法**。

macOS 上用自己的输入法程序 SENK（源码在 [senk-io/senk-input-macos](https://github.com/senk-io/senk-input-macos)，GPL-3.0）。菜单栏的输入法菜单里直接显示「SENK五笔」「SENK拼音」两项，选哪个就用哪个方案。

目标是解决一个具体的问题：**五笔打到一半忘了码，想要的字又不在首位，只能按数字去选。**

分两个安装包，在 [Releases](https://github.com/senk-io/wubi86-pinyin/releases) 下载：

| 安装包 | 方案 | 适合 |
|---|---|---|
| `wubi86-pinyin.zip` | SENK五笔混拼输入法86版（菜单里显示「SENK五笔」） | 用五笔为主，忘码时直接打拼音；一、二级简码固定在首位，全码打出有简码的字会提示简码 |
| `pinyin.zip` | SENK拼音输入法（菜单里显示「SENK拼音」） | 只用拼音：全拼、简拼、整句连打，不含五笔 |

两个包都支持可选的拼音语言模型；可以先后都装，在菜单栏的输入法菜单里切换「SENK五笔」「SENK拼音」。

## 现在能做什么（v0.4）

- **五笔 86 为主，拼音随时混输**：不用切换模式，直接打拼音。五笔候选总是排在前面。
- **拼音候选显示五笔编码**：例如打 `nihao` 会看到 `你好〔wqvb〕`、`你〔wq〕`，打一次就顺便学会。
- **学码模式**：以反引号开头，例如 `` `shu ``，只出拼音候选并附带编码。
- **简码提示**：一、二级简码（`g` 一、`wq` 你）始终在首位，选过别的字也不会挤掉。用全码打出有简码的字时提示简码，例如 `wqiy` → `你〔简 wq〕`，下次少打两键。
- **混输去噪**：四码五笔不会被误当成拼音简拼。比如 `adnt` 只出"藏 茂 荿"，不会冒出"安东尼他"。
- **拼音整句连打**：一口气打一长串拼音直接出整句，例如 `wozhengzaixiedaima` → 我正在写代码。五笔打满四码后接着打字母会自动顶字上屏，但只要整串还可能是拼音就不顶，长拼音不会被打断。
- **用户词频**：同码字里你选过的会排到前面，下次直接按空格上屏。
- **记住你忘码的字**：用拼音打出来的字词会记为"忘码"。之后用五笔打到它、但还没打全编码时，候选会提示完整编码和忘记次数，例如 `器〔kkd 忘1〕`。用五笔全码打对一次，次数减一，减到 0 自动移除。
  记录只保存在本机 Rime 用户目录的 `wubi86_pinyin_weak.txt`，只记上屏的字词，不记按键过程，也不联网。
- **emoji 开关**：码表自带的 emoji 默认不出现，不占候选位置；需要时打开开关 `emoji`。
- 开关 `code_hint` 可以关闭编码提示；只想关简码提示时，把方案里 `wubi_mixed_filter/short_hint` 设为 `false`。

### 拼音语言模型（可选）

装上后长拼音的整句首选更准：基准 36 句里，整句全对从 29 句提高到 35 句（`tests/bench.sh`），每次按键多花不到 0.1 毫秒，五笔输入不受影响。

```sh
sh scripts/install-grammar-macos.sh            # 下载约 39MB 的模型并校验，可重复运行；两个方案都会配置
sh scripts/install-grammar-macos.sh --remove   # 卸载
```

模型是 [lotem/rime-octagram-data](https://github.com/lotem/rime-octagram-data) 的 `zh-hans-t-essay-bgw.gram`，采用 LGPL-3.0，所以不随本仓库分发，由脚本从固定版本下载。脚本会为已安装的方案写入 `~/Library/Rime/<方案>.custom.yaml`；如果你已经有自己的这个文件，脚本会停下来，不会覆盖。之后再装另一个包时，重新运行一次即可。

## 安装

1. 下载并解压其中一个安装包，然后在解压出的目录里运行安装脚本（脚本根据包里的 `VARIANT` 文件决定装哪个方案；从源码安装时可以在命令后加 `pinyin` 或 `wubi86-pinyin` 指定）。
   - macOS（13 或更高）：
     ```sh
     sh scripts/install-macos.sh           # 预览：列出检查结果和将要执行的每一步，不做任何改动
     sh scripts/install-macos.sh --apply   # 执行：输入 yes 确认后才开始
     ```
     - 从 [senk-io/senk-input-macos](https://github.com/senk-io/senk-input-macos/releases) 下载固定版本的 SENK 程序，校验 sha256 和签名后装到 `~/Library/Input Methods`，不需要输入密码。已装的是同一版本时不重装。
     - 装好后在系统里启用「SENK五笔」「SENK拼音」（只启用已装方案对应的那一项），选中刚装的那一项，通知 SENK 重新部署并等待完成。
     - 开始前检查系统版本、磁盘空间、内存压力（活动监视器里内存压力是黄或红时不安装）和是否有别的安装在进行；任何一项不满足就退出，不做改动。
     - 改动前把 `~/Library/Rime`、SENK 的偏好设置和原来的程序备份到 `~/Library/Application Support/senk-input/backup-时间`；任何一步失败都会停止并自动恢复。日志在 `~/Library/Logs/senk-input/`。
   - Windows：`powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1`（会从官方 GitHub Release 下载最新的小狼毫，校验签名后安装）
2. 在菜单栏的输入法菜单里选择「SENK五笔」或「SENK拼音」（Windows 上选「小狼毫」）。

「系统设置 → 键盘 → 输入法 → 添加」的列表由系统缓存，新装后可能要注销并重新登录才出现 SENK；脚本已经直接启用了它，不用再手动添加。脚本不会替你注销，也不会强行启动输入法。

卸载：`sh scripts/uninstall-macos.sh` 预览，加 `--apply` 执行。它会停用并删除 SENK 程序和偏好设置，不需要输入密码；`~/Library/Rime`（含词频记录）默认保留，加 `--remove-user-data` 才删除。改动前都会备份到 `~/Library/Application Support/senk-input/uninstall-时间`。

如果你原来自己写的 `default.custom.yaml` 里没有启用本方案，安装脚本会替换它，原文件在上面的备份目录里。

## 目录结构

| 路径 | 内容 | 许可证 |
|---|---|---|
| `schema/` | 方案配置与 Lua 过滤器（`wubi86_pinyin` SENK五笔混拼输入法86版，`senk_pinyin` SENK拼音输入法） | MIT |
| `data/` | 第三方码表与拼音词库（未修改） | Apache-2.0，见 [data/NOTICE.md](data/NOTICE.md) |
| `scripts/` | 汇总与安装脚本 | MIT |
| `tests/` | 用 librime 驱动方案的端到端测试 | MIT |
| `docs/` | 设计文档 | MIT |

## 开发与测试

在 Ubuntu 上：

```sh
sudo apt-get install librime-dev librime-bin librime-data librime-plugin-lua
tests/run.sh            # 两个方案分别比对 tests/expected.txt 和 tests/pinyin_expected.txt
tests/run.sh --update   # 修改方案后重新生成期望结果
```

`tests/cases.txt`（SENK五笔混拼输入法86版）和 `tests/pinyin_cases.txt`（SENK拼音输入法）每行一个输入码；`!k 码` 表示输入后选第 k 个候选上屏；`$ 命令` 交给 shell 执行；`@ 按键` 只发送按键；`+ 开关` / `- 开关` 打开或关闭方案开关。

拼音长句基准：`tests/bench.sh [模型.gram] [最少正确句数] [安装包]`，句子在 `tests/pinyin_bench.txt`；带模型时需要 `librime-plugin-octagram`。

## 路线图

见 [docs/architecture.md](docs/architecture.md)。

1. 基础方案（本版本）
2. 记忆与纠错：记录"忘码"的字并加强提示（已完成）；常见拆字错误容错（进行中）
3. 本地模型：已移除。输入法不接入任何大模型，所有功能都在输入法内同步完成
4. 打包与发布
5. 语音输入（按住说话）
6. 扩展：提示词片段与本地脚本入口

## 许可证

MIT，`data/` 目录除外（Apache-2.0）。
