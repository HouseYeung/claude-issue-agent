---
name: claude-issue-agent
description: 用 GitHub Issue 驱动本机 Claude Code。用于安装、启停 watcher、接入仓库、配置模型标签，或排查不响应、会话中断和推送失败。
license: MIT
compatibility: macOS or Linux; requires authenticated gh and claude CLIs, jq and git.
metadata:
  version: "2.0"
---

# Claude Issue Agent

Issue 是远程输入面。先确认仓库、允许用户和权限模式。

## 操作

首次接入必须取得：机器代号、权限模式、`owner/repo`。公共仓库还必须设置非空允许用户列表。

```bash
AGENT_CODENAME=<name> PERMISSION_MODE=<mode> \
  scripts/setup.sh <owner/repo> [local-clone]
scripts/ctl.sh install <owner/repo>
```

日常命令：

```bash
scripts/ctl.sh status <owner/repo>
scripts/ctl.sh logs <owner/repo>
scripts/ctl.sh stop <owner/repo>
scripts/ctl.sh uninstall <owner/repo>
```

模型、服务和故障处理见 `references/`。

## 规则

- wrapper 负责 GitHub 评论、Git fetch/rebase/commit/push 和 PR；Claude 不做这些副作用。
- 一个 Issue 对应一个会话、worktree、分支和 PR；评论继续或中断同一会话。
- 只以有效路由标签和允许用户触发；以 `//` 开头的评论只是备注。
- 安装后不要自行创建测试 Issue；报告 setup/ctl 的真实结果。
- 真实配置和状态留在本机；仓库只保留 `config.example.env`。

确认是本 Skill 缺陷时登记到本地问题记录。
