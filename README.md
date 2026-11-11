# 拾文输入法 · Eleven Input

一个**纯本地**的 macOS 拼音输入法：除了普通输入法的候选之外，它会在你开始输入时读取一次当前窗口的文字，用这些文字来判断同音词/多音字，把更可能的词排到第一位。

经典例子：

```
输入 goujian
没有上下文：      构建 / 构件 / 勾践 / 沟涧
屏幕上有 8 次构件：构件 / 构建 / 勾践 / 沟涧   ← 面板上会标注「屏幕 ×8」
```

不联网、不实时截屏、不保存屏幕内容。所有计算在本机完成。

---

## 1. 为什么不用「实时屏幕识别」

实时 OCR 的问题很明显：功耗高、发热、延迟大，而且等于持续录屏，隐私上很难接受。这里用的是**事件驱动的按需读取**：

| 来源 | 成本 | 说明 |
| --- | --- | --- |
| **辅助功能（AX）文本** | 极低 | 直接读焦点编辑器的 `AXValue`、光标前后文本和窗口里的静态文本。精确、无截图、无 GPU |
| **本输入法刚提交的字** | 零 | 用户自己打的字是最高信号，直接进内存环形缓冲区 |
| **本地学习** | 零 | 只记录你实际提交过的词和前后词搭配，存在本机 JSON |
| **剪贴板** | 零 | 可选，默认关闭 |
| **截图 OCR（Vision）** | 较高 | 只在 AX 拿不到文字时兜底，默认关闭，≥4 秒节流，只截当前窗口 |

触发策略：

- 只在**开始一次输入**（第一个字母）时采集，不是持续监听；
- 每个窗口最多 1.2 秒一次，结果缓存 180 秒；
- 只读**焦点窗口**，数据只存在内存（`ContextStore`），超时丢弃；
- OCR 只在 AX 返回不足 80 字时才考虑，且最多 4 秒一次。

这比「实时 OCR」省几个数量级的电，也更容易解释隐私边界。

> 更强的长期方案：本地学习 + 你自己的文档。用上一周之后，`构件/构建` 这类选择基本会直接被你的用词习惯解决，屏幕上下文只是加速这个过程。

## 2. 排序是怎么做的

候选分三层，先按层再按分数：

1. **整词精确匹配**：`goujian` → 构建、构件、勾践、沟涧
2. **短语切分**：`woaibeijing` → 我爱北京（词格 + beam search）
3. **前缀补全**：`gouj` → 构建、构件…（打到一半时的候选）

层内分数：

```
score = log(词频)
      + 3.0 * log(1 + 前文加权次数)
      + 2.0 * log(1 + 与光标前一个字的搭配次数)
      + 本地学习加成
```

`ContextModel` 会给每个候选算屏幕/前文里的出现次数，并在候选下方显示来源（`屏幕 ×12`、`前文 ×8`、`刚输入`、`接续`、`常用`）。

## 3. 目录

```
Sources/ElevenCore/        拼音引擎（可单独复用）
  Dictionary.swift         紧凑二进制词库 + 前缀索引
  Engine.swift             候选生成、词格切分、上下文排序
  Context.swift            上下文快照 / 内存环形缓冲 / 评分
  AccessibilityContext.swift  AX 读取光标前后与窗口文本
  ScreenOCR.swift          ScreenCaptureKit + Vision 兜底
  ContextHarvester.swift   采集策略（节流、优先级）
  Learning.swift           本地个性化（JSON）
  Settings.swift           UserDefaults 偏好

Sources/ElevenIME/         正式输入法（InputMethodKit）
  main.swift               IMKServer 启动
  ElevenInputController.swift  按键、组合、提交
  CandidatePanel.swift     自绘候选窗（带来源提示）
  PreferencesWindow.swift  设置窗口

Sources/ElevenDemo/        独立演示 App（不需要系统输入法注册）
Sources/ElevenProbe/       命令行调试工具
Tests/SelfTest/            引擎自检
tools/                     词典构建、图标生成
```

## 4. 快速体验（推荐先跑这个）

```bash
./build.sh
open build/ElevenDemo.app
```

- 按 `⌃⌥Space` 唤起输入板；
- 第一次会请求「辅助功能」权限（读当前窗口文字、以及把选中的词粘回去）；
- 先在一个有很多「构件」的窗口（比如本 README 或一份结构文档）里试，输入 `goujian`；
- `↑↓` 选择，`↵` 提交（会自动粘贴回刚才的 App），`esc` 关闭。

Demo 不注册为系统输入法，所以不受下面第 5 节的签名限制，可以立刻验证核心能力。

命令行也可以直接看排序：

```bash
.build/release/eleven-probe goujian --context-file 你的文档.txt
.build/release/eleven-probe goujian --show-scores
```

## 5. 安装为系统输入法（重要限制）

正式输入法在 `build/ElevenInput.app`。安装：

```bash
./install.sh
```

但请注意：**从 macOS 26/27 开始，系统只把「Developer ID 签名 + 公证」的第三方 App 当作输入法扫描。** 本机实测：

- ad-hoc 签名、甚至自签名证书：能编译、能启动、`TISRegisterInputSource` 返回成功，但系统输入法列表里**不会出现**；
- 微信输入法 / 豆包输入法能出现，是因为它们有 Apple Team ID 且已公证（`spctl` 显示 `Notarized Developer ID`）。

如果你有 Apple Developer 账号（$99/年）：

```bash
./sign.sh "Developer ID Application: 你的名字 (TEAMID)"
# 然后按提示用 notarytool 公证、staple
sudo cp -R build/ElevenInput.app "/Library/Input Methods/"
# 注销并重新登录，再到 系统设置 → 键盘 → 输入法 里添加「拾文拼音」
```

签名脚本会做 hardened runtime + 时间戳；公证需要 Xcode 的 `notarytool` 和一次性的 keychain profile：

```bash
xcrun notarytool store-credentials eleven-notary --apple-id ... --team-id ... --password ...
```

安装后第一次切换到拾文拼音时，会请求「辅助功能」权限。没有它也能输入，只是候选只按词频/学习排序，读不到屏幕。

> 没有开发者账号时：Demo App 是完整可用的替代体验；或者把 `ElevenCore` 接到你已有的开源输入法（Rime 等）里，只借用它的候选排序。

## 6. 隐私

- 没有网络代码、没有网络 entitlement；词库和代码都在本地。
- 屏幕文本只在内存里存在，180 秒过期；输入法退出即消失。
- 学习文件只包含你**提交过的词**和词对：`~/Library/Application Support/ElevenInput/learning.json`。
- OCR 默认关闭；开启后只截当前焦点窗口，不录屏、不落盘。
- 权限可以随时在 系统设置 → 隐私与安全性 里撤销。

## 7. 调参

`Sources/ElevenCore/Context.swift` 的 `RankingWeights`：

| 参数 | 默认 | 作用 |
| --- | --- | --- |
| `contextBefore` | 2.6 | 光标前文本的权重 |
| `contextWindow` | 1.1 | 窗口内文本的权重 |
| `contextCommitted` | 1.6 | 刚提交文本的权重 |
| `contextGain` | 3.0 | 上下文总增益 |
| `contextCap` | 11 | 上下文增益上限 |
| `adjacencyGain` | 2.0 | 「前一个字 + 候选」搭配加成 |
| `exactBonus` | 8.0 | 整词精确匹配优先级 |

改完 `swift run ElevenSelfTest`，再跑 `eleven-probe` 对比。

## 8. 已知限制 / 可以继续做的

- 长句切分没有真正的 n-gram 语言模型，靠词频 + 长度先验；`我爱北京` 这种可以，但冷僻长句会不如商业输入法。
- 没有模糊音（`zh/z`、`n/l`）、双拼、手写、表情。
- 候选窗是自绘的，缺少辅助功能朗读和触控板支持。
- 输入法注册受签名限制（见第 5 节）。
- 字号 / 深色模式已使用系统语义色，但没有专门的皮肤系统。

## 9. 数据来源

- 词条与读音：[CC-CEDICT](https://www.mdbg.net/chinese/dictionary?page=cc-cedict)（CC BY-SA 3.0）。
- 词频：[jieba](https://github.com/fxsjy/jieba) 的 `dict.txt`（MIT）。
- 构建时下载到 `tools/data/`，生成 `Resources/pinyin.bin`（约 2.9 MB，12.2 万词条）；运行时只读本地文件。
