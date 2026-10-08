# 开发流程 —— 走 PR，不走直推 main

> 本文是**仓库的规矩**，不是建议。
> 起因：业主希望「以后功能迭代按『提交 PR → 审核 → 完善 → 合并』的方式走」
>（参考 https://github.com/dsh-tauri/deepseek-harness-desktop/pull/965 的做法）。

## ★ 这条规矩已经**强制生效**了，不是靠自觉

`main` 上已开启分支保护。**直推会被服务端拒绝**，实测读数：

```text
$ git push origin main
remote: error: GH006: Protected branch update failed for refs/heads/main.
remote:
remote: - Changes must be made through a pull request.
remote:
remote: - 2 of 2 required status checks are expected.
 ! [remote rejected] main -> main (protected branch hook declined)
```

生效的规则：

| 规则 | 值 | 说明 |
|---|---|---|
| 必须走 PR | 是 | 任何直推 main 都被拒 |
| 必需状态检查 | `Windows` / `macOS` | ★ 只列**每次都会跑**的那两个 job |
| 分支必须最新 | 是 | main 前进后，PR 要 rebase 才能合 |
| 必须 resolve 所有对话 | 是 | CodeRabbit 的每条意见都得处理（修 / 或回帖说明） |
| 批准人数 | 0 | 单人开发，不需要第二个人批 —— 但 PR + CI + 评审意见仍必须走完 |
| 对管理员也生效 | 是 | 连仓主也绕不过 |
| 允许强推 / 删除 main | 否 | |

> ⚠️ **为什么必需状态检查里没有 `Android` 和 `发 Release`**：
> 这两个 job 在 PR 上会被 `if:` 判成 **skipped**，而 GitHub
> **不把 skipped 当作通过** —— 把它们列进必需检查，PR 会**永远无法合并**。
> 这是分支保护最常见的坑。

> ⚠️ **破坏性操作要临时放开保护**（例如紧急回滚 main）。
> 那需要去 Settings → Branches 临时改规则，**改完记得改回来**。

---

## 为什么（先说清楚，避免当成形式主义）

直接推 main 的问题不是「不规范」，而是**没有第二双眼睛**：

| 只有 CI 时能拦住 | 需要有人看才能拦住 |
|---|---|
| 编译不过、测试红、analyze error | 某个分支在某种平台组合下永远走不到 |
| 依赖缺失、格式不符 | 一条断言其实**恒真**（假门禁） |
| 版本号对不上 | 改了 A 忘了同步 B（如 .nsi 的安装侧 / 卸载侧） |
|  | 并发 / 时序问题（测试改进程级全局量） |

右列这几类，本仓**每一条都真踩过**。它们共同的特征是：**CI 全绿，问题在用户那里才爆**。

---

## 流程

```text
① 开分支        git switch -c feat/<短描述>
② 提交          git commit（一个 PR 可以多个 commit）
③ 推送 + 开 PR   git push -u origin <branch>  →  在 GitHub 上开 PR
④ 自动评审      CI 跑起来；CodeRabbit 几分钟内贴出评审
               ★ 自动评审的触发条件：App 已装 + PR 目标为 main +
                 非草稿 + 标题未命中排除词（WIP / DO NOT MERGE / chore(release)）
                 四条都满足才会自动评。
⑤ 完善          按评审意见改（逐条判断：真问题就修，误报就回帖说明并 resolve）
⑥ 再评审        推新 commit 后 CodeRabbit 会自动复审增量
⑦ 合并          评审意见都处理完 + CI 全绿 → 合并到 main
```

## 每一步的具体要求

### ③ 开 PR 时写清楚

PR 描述里**必须**有：

1. **为什么改**（不是「改了什么」—— 那个 diff 自己能看出来）
2. **怎么验证的**（跑了什么命令、看到什么读数、有没有反面对照）
3. **没做什么 / 已知边界**（诚实标注未验证的部分）

本仓的惯例是「读数级证据」：贴真实的命令输出，而不是「测试通过」。

### ④⑤ 处理评审意见的纪律

★ **不要为了让评审闭嘴而改代码。** 每条意见只有三种正当处置：

| 处置 | 什么时候用 |
|---|---|
| **修** | 确认是真问题 |
| **回帖说明 + resolve** | 是误报，或本仓有意为之（把「为什么」写进回帖） |
| **改成硬失败** | 意见指出某处门禁是假的（只 warning 不 exit）—— 这类必须修成真门禁 |

⚠️ **不许**用「加个 ignore 注释」「放宽断言」「删掉那行」来消掉意见。
本仓已有一条同类教训：为了让 CI 变绿而放宽断言，等于把缺陷藏进绿里。

### ⑦ 合并前必须满足

- [ ] CI 全绿（Windows / macOS 必跑；Android 看是否勾了 `build_android`）
- [ ] CodeRabbit 的意见都处理过（修了，或回帖说明并 resolve）
- [ ] PR 描述里的「怎么验证的」是**真跑过**的，不是「应该能行」
- [ ] 如果改了 `lib/` 或 `rust/`，**自己启动一次真实例**确认能用
      （编译通过 / 单测绿 / SHA256 都不算实测 —— 这是业主的硬规则）

## 什么可以自己合，什么要走完整流程

> ⚠️ **注意：现在 `main` 有分支保护，任何直推都会被服务端拒绝**（见文首的 GH006 读数）。
> 所以本节讲的不是「直推」，而是「**哪些改动可以自己合 PR、不用等人看**」。

以下改动可以自己开 PR 后**立即合并**，不需要额外讨论：

- 修错别字、改注释、更新文档
- 只改 `.gitignore` / `.gitattributes` 这类元数据
- 回滚一个刚推上去的错误改动
- CI 配置的紧急修复（当 main 的构建已经红了，先修好再补流程）

判断标准很简单：**这个改动有没有可能悄悄改变产品的行为？**
有 → 走完整流程（等 CI + 处理评审意见）。
没有 → 还是要开 PR，但可以直接合。

> 真的要绕过保护（例如 main 已经红得没法开 PR 了），
> 只能去 Settings → Branches 临时改规则，**改完必须改回来**。

## 分支命名

```text
feat/<描述>      新功能
fix/<描述>       缺陷修复
ci/<描述>        CI / 构建相关
docs/<描述>      文档
chore/<描述>     杂项
```

## CodeRabbit

配置在仓库根的 [`.coderabbit.yaml`](.coderabbit.yaml)，里面写了本仓的几条
反直觉硬约束（避免 AI 给出错误的「优化建议」）。

交互命令（在 PR 评论里发）：

```text
@coderabbitai review          重新评审（★ 见下方说明，是**增量**的）
@coderabbitai full review     完整评审（重看所有文件，不只看增量）
@coderabbitai resolve         把它的评论标记为已解决
@coderabbitai configuration   打印当前生效的完整配置
@coderabbitai help            全部命令
```

> ⚠️ **`@coderabbitai review` 是增量评审** —— 它**不会**重新评审已经评过的提交，
> 且主要用途是「自动评审被暂停时手动触发」。
> 想要它把所有文件从头再看一遍，用 `@coderabbitai full review`。

**公开仓库免费**。装它需要在 GitHub 上给 `coderabbitai` 这个 App 授权本仓 ——
详见仓库 README 的「开发流程」一节。
