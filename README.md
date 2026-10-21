# wubi86-pinyin

五笔字形 86 版 + 拼音混输的 [Rime](https://rime.im) 输入方案，面向 Windows（小狼毫）和 macOS（鼠须管）。

目标是解决一个具体的问题：**五笔打到一半忘了码，想要的字又不在首位，只能按数字去选。**

分两个安装包，在 [Releases](https://github.com/senk-io/wubi86-pinyin/releases) 下载：

| 安装包 | 方案 | 适合 |
|---|---|---|
| `wubi86-pinyin.zip` | 五笔86·拼音 | 用五笔为主，忘码时直接打拼音；一、二级简码固定在首位，全码打出有简码的字会提示简码 |
| `pinyin.zip` | 拼音 | 只用拼音：全拼、简拼、整句连打，不含五笔 |

两个包都支持项目术语补全和可选的拼音语言模型；可以先后都装，在方案菜单（`` Control+` ``）里切换。

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

### 项目术语补全（可选，需要本地模型）

每个项目都有自己的叫法：项目名、系统名、模块名、内部代号、专业术语。这些词码表里没有，用五笔或拼音都很难打。装上常驻进程 `wubi86d` 后，本机的 7B 模型会从你指定的项目资料文件夹里把这些叫法抽出来做成术语表；打字时，只要输入码是某个术语的五笔词码、全拼或拼音首字母的开头，这个术语就出现在第 2 位，注释为〔术语·项目名〕。首选不变，不会打乱五笔简码的空格习惯。

例如资料里有「星辰数据平台」，打 `xcsj`、`xingchen` 或五笔词码 `jdoc` 都能补全；英文名按字母拼写匹配，`senkn` 能补全 `SenkNet-API`。

```sh
sh scripts/install-helper-macos.sh   # 安装 Ollama、qwen2.5:7b、bge-m3 和 wubi86d，并设为登录后自动运行
```

- **项目资料文件夹**：在 `~/Library/Rime/wubi86d/config.json` 的 `folders` 里添加，例如 `{"name": "星辰", "path": "~/work/星辰/docs"}`。可以添加多个，每个项目一个。目前读取 `.md` 和 `.txt`。
- **切换项目**：打字时按 `Control+Shift+R` 轮换，也可以运行 `wubi86d use 星辰`；`wubi86d folders` 查看全部。
- **查看和更新术语表**：`wubi86d terms` 查看当前项目抽出的术语；`wubi86d index` 立即重新抽取（平时每 5 分钟检查一次，只处理新增或改动的文件）。
- **后台抽取占用**：第一次抽取大文件夹会让本地模型忙一阵（之后只处理改动过的文件）。默认干一秒歇一秒（`config.json` 的 `index_duty` 为 `0.5`）；想更省电就调小，例如 `0.25`，设为 `1` 则全速。随时可以暂停：`launchctl bootout gui/$(id -u)/io.senk.wubi86d`，重新运行 `install-helper-macos.sh` 会从停下的地方接着抽。
- 开关 `terms` 可以临时关闭术语补全。
- **续写联想**（默认关闭）：根据上文猜下一个词。在 `config.json` 里把 `continuation` 设为 `true` 并打开开关 `predict` 后启用；这个模式会把上屏文字记入本机输入历史用于检索，`history` 设为 `false` 可以不记，`wubi86d forget-history` 可以清空。
- 不开任何端口，模型地址默认只允许本机。细节见 [docs/architecture.md](docs/architecture.md)。

### 拼音语言模型（可选）

装上后长拼音的整句首选更准：基准 36 句里，整句全对从 29 句提高到 35 句（`tests/bench.sh`），每次按键多花不到 0.1 毫秒，五笔输入不受影响。

```sh
sh scripts/install-grammar-macos.sh            # 下载约 39MB 的模型并校验，可重复运行；两个方案都会配置
sh scripts/install-grammar-macos.sh --remove   # 卸载
```

模型是 [lotem/rime-octagram-data](https://github.com/lotem/rime-octagram-data) 的 `zh-hans-t-essay-bgw.gram`，采用 LGPL-3.0，所以不随本仓库分发，由脚本从固定版本下载。脚本会为已安装的方案写入 `~/Library/Rime/<方案>.custom.yaml`；如果你已经有自己的这个文件，脚本会停下来，不会覆盖。之后再装另一个包时，重新运行一次即可。

## 安装

1. 下载并解压其中一个安装包，然后在解压出的目录里运行安装脚本（脚本根据包里的 `VARIANT` 文件决定装哪个方案；从源码安装时可以在命令后加 `pinyin` 或 `wubi86-pinyin` 指定）。脚本会从官方 GitHub Release 下载最新的 Rime 前端（macOS 是鼠须管，Windows 是小狼毫），校验签名后安装，过程中会要求输入密码或进行管理员授权。macOS 上如果已经装过鼠须管，会先卸载再重新安装，`~/Library/Rime` 里的用户数据保留。
   - macOS（13 或更高）：`sh scripts/install-macos.sh`
   - Windows：`powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1`
2. 在输入法菜单里选择「鼠须管」或「小狼毫」，默认方案就是所装的包对应的方案。

macOS 上如果装完在菜单栏看不到鼠须管，注销后重新登录一次即可。

卸载：`sh scripts/uninstall-macos.sh`。它会删除鼠须管应用、安装记录和偏好设置；`~/Library/Rime`（含词频记录）会先询问再删。

如果你原来自己写的 `default.custom.yaml` 里没有启用本方案，脚本会把它备份成 `default.custom.yaml.bak-时间戳` 再替换，备份路径会打印出来。

## 目录结构

| 路径 | 内容 | 许可证 |
|---|---|---|
| `schema/` | 方案配置与 Lua 过滤器（`wubi86_pinyin` 五笔86·拼音，`senk_pinyin` 拼音） | MIT |
| `data/` | 第三方码表与拼音词库（未修改） | Apache-2.0，见 [data/NOTICE.md](data/NOTICE.md) |
| `scripts/` | 汇总与安装脚本 | MIT |
| `helper/` | 常驻进程 wubi86d（Go） | MIT |
| `tests/` | 用 librime 驱动方案的端到端测试 | MIT |
| `docs/` | 设计文档 | MIT |

## 开发与测试

在 Ubuntu 上：

```sh
sudo apt-get install librime-dev librime-bin librime-data librime-plugin-lua
tests/run.sh            # 两个方案分别比对 tests/expected.txt 和 tests/pinyin_expected.txt
tests/run.sh --update   # 修改方案后重新生成期望结果
```

`tests/cases.txt`（五笔86·拼音）和 `tests/pinyin_cases.txt`（拼音）每行一个输入码；`!k 码` 表示输入后选第 k 个候选上屏；`$ 命令` 交给 shell 执行（用来模拟 wubi86d）；`@ 按键` 只发送按键；`+ 开关` / `- 开关` 打开或关闭方案开关。

拼音长句基准：`tests/bench.sh [模型.gram] [最少正确句数] [安装包]`，句子在 `tests/pinyin_bench.txt`；带模型时需要 `librime-plugin-octagram`。

常驻进程：`cd helper && go test ./...`。

## 路线图

见 [docs/architecture.md](docs/architecture.md)。

1. 基础方案（本版本）
2. 记忆与纠错：记录"忘码"的字并加强提示（已完成）；常见拆字错误容错（进行中）
3. 本地模型（可选）：常驻进程 wubi86d 调用 Ollama，从项目资料文件夹抽取术语供补全；可选的续写联想（已完成 macOS）
4. 打包与发布
5. 语音输入（按住说话）
6. 扩展：提示词片段与本地脚本入口

## 许可证

MIT，`data/` 目录除外（Apache-2.0）。
