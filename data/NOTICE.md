# 第三方数据说明

本目录下的文件不属于本项目的 MIT 许可范围，均按 Apache License 2.0 分发（全文见 `LICENSE-Apache-2.0`），保持上游原样，未做修改。

| 文件 | 上游 | 版本 | 许可证 |
|---|---|---|---|
| `wubi86_jidian.dict.yaml`、`wubi86_jidian_extra.dict.yaml`、`wubi86_jidian_user.dict.yaml`、`wubi86_jidian_user_hamster.dict.yaml` | [KyleBing/rime-wubi86-jidian](https://github.com/KyleBing/rime-wubi86-jidian) | `18a6016c3d08a20f713f8f8e1791a2e79e0be081` | Apache-2.0 |
| `pinyin_simp.dict.yaml`、`pinyin_simp.schema.yaml` | [rime/rime-pinyin-simp](https://github.com/rime/rime-pinyin-simp)（词库源自 Android Pinyin IME） | `0c6861ef7420ee780270ca6d993d18d4101049d0` | Apache-2.0 |

可选的拼音语言模型 `zh-hans-t-essay-bgw.gram`（[lotem/rime-octagram-data](https://github.com/lotem/rime-octagram-data)，LGPL-3.0）不在本仓库中，由 `scripts/install-grammar-macos.sh` 在用户本机下载。

不使用 [rime/rime-wubi](https://github.com/rime/rime-wubi)，因为它采用 LGPL-3.0。

更新数据时请同步修改上表中的版本号。
