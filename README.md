# emacs-claude

Claude Code 的 Emacs 原生聊天界面，交互与 emacs-pi / emacs-dsh 保持一致。
**Claude 进程独立于 Emacs 运行**：关闭聊天 buffer 或退出 Emacs 后任务继续执行，
再次打开时回放期间的全部输出并继续交互（包括离线期间挂起的权限请求）。

## 原理

每个会话一个驻留进程（holder），不依赖 tmux：

```text
nohup sh:  FIFO `in`  →  claude -p (stream-json)  →  追加日志 `out.jsonl`
Emacs:     写 FIFO 发送请求；`tail -c +1 -f out.jsonl` 回放并跟随
```

holder 自己以读写方式打开 FIFO，因此没有写端时 Claude 也不会收到 EOF。
聊天 buffer 只是查看器，状态文件位于 `emacs-claude-directory/instances/<session-id>/`。
holder 已退出的会话通过 `claude --resume` 重新启动，历史从 Claude Code 自身的 transcript 读取。

## 安装

需要 Emacs 29.1+、`markdown-mode`、`claude` CLI，以及 POSIX 的 `sh`/`mkfifo`/`tail`/`nohup`（macOS、Linux）。

```elisp
(use-package emacs-claude
  :load-path "/path/to/emacs-claude"
  :commands (emacs-claude-chat emacs-claude-resume emacs-claude-attach)
  :bind ("<f8>" . emacs-claude-chat))
```

## 使用

`M-x emacs-claude-chat`：选目录，再选该目录的已有会话或最后一行的 `[New session]`。
`C-c C-r`（`/resume`）：从所有项目的会话中恢复；`M-x emacs-claude-attach`：只列仍在后台运行的会话。
三个列表与 `@session`、emacs-pi、emacs-dsh 使用同一表格：「最后交互｜用户首句｜用户末句｜项目｜ID」，按最后用户交互倒序，窄窗口隐藏项目列，仍在后台运行的会话行尾标记 `● running`。

| 操作 | 快捷键 |
| --- | --- |
| 发送 / 换行 | `RET`、`C-c C-c` / `S-RET` |
| 打断当前轮并立即发送草稿（steer） | `C-c C-s` |
| 打断当前轮 | `C-c C-k` |
| **关闭聊天，Claude 继续运行** | `C-c C-d`（直接 kill buffer、退出 Emacs 效果相同） |
| **停止 Claude 并关闭聊天** | `C-c C-q` |
| 回答挂起的权限请求 / 提问 | `C-c C-a` |
| 恢复会话 / 切换聊天 | `C-c C-r` / `C-c C-b` |
| 查看、编辑排队消息 | `C-c C-l`、`C-c C-u`、`/queue` |
| 添加图片 / 粘贴剪贴板图片或文本 | `M-x emacs-claude-attach-image`、`/image` / `C-c C-p`、`s-v` |
| 用系统查看器打开图片 | `C-c C-o` |
| 补全 `/命令`、`@文件`、`@session` | `TAB` |
| 输入历史 | `M-p` / `M-n` |
| 复制模式 / 返回输入 | `C-c C-t` / `C-c C-j`（历史区按 `i`） |
| 展开、折叠过程 | 标题上 `RET`、`TAB`、点击 |

运行中发送的消息由 Claude 排队，当前轮结束后执行。
权限请求在 minibuffer 中回答：`y` 仅本次、`a` 允许并保存建议规则、`n` 拒绝、`m` 拒绝并说明。
客户端命令：`/resume` `/new` `/attach` `/model` `/permission` `/queue` `/image` `/copy` `/detach` `/quit` `/help`；其余 `/命令` 交给 Claude。

### 图片

支持 PNG、JPEG、GIF、WebP，单张上限 `emacs-claude-image-max-bytes`（默认 10 MiB）。
待发送图片显示在输入区上方，点击或在 `×` 上按 `RET` 移除；可以只发图片不带文字。
`C-c C-p` 在 macOS 上通过 `pngpaste` 读取剪贴板图片，剪贴板不是图片或未安装 `pngpaste` 时按普通文本粘贴。
历史中的图片在图形界面显示缩略图，终端显示 `[image]`。

### 队列编辑

队列由 Claude 持有并记录在日志中，因此重新打开 Emacs 后仍然可见。队列窗口按键：

| 按键 | 动作 |
| --- | --- |
| `n` / `p` | 上下移动 |
| `RET` | 在独立 buffer 编辑文本（图片保留）；`C-c C-c` 暂存，`C-c C-k` 放弃 |
| `d` | 暂存删除（再按取消） |
| `M-↑` / `M-↓` | 暂存调整顺序 |
| `x` | 应用全部暂存修改 |
| `g` / `q` | 放弃暂存并刷新 / 关闭 |

Claude 只提供「按 uuid 撤回排队消息」的接口，因此应用时会撤回第一处差异之后的消息，
等每条撤回都得到确认后按新顺序重发；期间已经开始执行的消息不会被撤回，也不会重复发送。
只有本机 Emacs 发出的消息才有正文记录（`sent.jsonl`）；其他客户端发的消息可以删除，但不能移动或编辑。

### 引用其他会话

输入 `@session` 后按 `TAB`，从所有项目的已保存会话中选择（列：最后交互｜用户首句｜用户末句｜项目｜短 ID），
插入 `@[标题](claude-session:ID)`。发送时把被引用会话末尾的对话文本附加到消息后面，
所有引用合计不超过 `emacs-claude-session-reference-max-chars`（默认 20000 字符）；
聊天界面和输入历史只显示简短引用。附加内容会作为消息的一部分保存在 Claude 的会话记录里。

安装 [ashub](https://github.com/wowhxj/ashub.el) 后，输入 `@ashub` 再按 `TAB` 可引用任意 Agent 的会话：ashub 把对话导出为文件，插入 `@路径`，Claude 发送时读取该文件。其他包也可以通过 `emacs-claude-reference-providers` 注册 `@名称`（与 emacs-pi、emacs-dsh 的同名接口一致）。

顶部显示上下文用量、prompt 数、费用（**当前 holder 进程累计**，不是整个会话）、模型和权限模式。

## 配置

- `emacs-claude-executable`：默认 `claude`
- `emacs-claude-extra-arguments`：新 holder 的额外参数，如 `'("--model" "sonnet")`
- `emacs-claude-directory`：holder 状态目录
- `emacs-claude-config-directory`：Claude Code 配置目录，默认 `~/.claude`
- `emacs-claude-show-thinking`
- `emacs-claude-image-max-bytes`、`emacs-claude-pngpaste-executable`
- `emacs-claude-session-reference-max-chars`
- `emacs-claude-reference-providers`：`@名称` 引用提供者，`(名称 . 函数)` 列表

## 已知限制

- 空闲的 holder 不会自动退出；用 `C-c C-q` 关闭，或用 `emacs-claude-attach` 找回。
- `out.jsonl` 只追加、不轮转；重启 holder 时保留一份 `out.prev.jsonl`。
- `sent.jsonl` 同样只追加，包含已发送图片的 base64。
- 发送大图时 Emacs 会短暂停顿（实测两张 2.4 MB 图片约 2.4 秒），用于把数据写入 holder。
- 队列编辑依赖 CLI 的 `cancel_async_message` 与 `command_lifecycle`（2.1.322 实测可用，属于未公开接口，CLI 升级后可能变化）。
- 队列编辑器不能增删单条消息里的图片；Linux/WSL 没有剪贴板图片粘贴。
- 尚未实现：子智能体消息展示、fork/clone/export。
- `C-c C-k` 只打断当前轮，已排队的消息仍会执行。
- 不支持 TRAMP 目录。

## 测试

```sh
emacs -Q --batch -L /path/to/markdown-mode -L . -l test/emacs-claude-test.el -f ert-run-tests-batch-and-exit
```

使用 `test/fake-claude.py`，不调用真实模型。
