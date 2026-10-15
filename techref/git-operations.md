<a id="top"></a>

# Git / GitHub 速查

## 目录

- [1. GitHub HTTPS / PAT / Credential 认证](#section-1)
- [2. `gh auth` 成功，但 `git push` 还是失败](#section-2)
- [3. PAT 有效，但 `git push` 还是 403](#section-3)
- [4. `git pull` 到底做了什么](#section-4)
- [5. `git pull --rebase`](#section-5)
- [6. Rebase vs Merge](#section-6)
- [7. `divergent branches` 怎么处理](#section-7)
- [8. Rebase 遇到 Conflict](#section-8)
- [9. 用 `origin/main` 完全覆盖本地](#section-9)
- [10. 覆盖 tracked 文件，但保留 untracked 文件](#section-10)
- [11. `git add .` vs `git add -A` vs `git add -u`](#section-11)
- [12. Untrack 文件，但保留本地文件](#section-12)
- [13. `.gitignore` 为什么通常应该提交到 Repo](#section-13)
- [14. `.gitignore` 为什么对已经 tracked 的文件无效](#section-14)
- [15. 不 Merge 整个 Branch，只拿一个文件](#section-15)
- [16. 从另一个 Branch 拿整个目录](#section-16)
- [17. 只拿一个 Commit：Cherry-pick](#section-17)
- [18. 先比较两个 Branch 的文件，再决定拿哪些修改](#section-18)
- [19. `pathspec did not match any file(s) known to git`](#section-19)
- [20. `git merge --abort` 失败](#section-20)
- [21. Push 出现 `non-fast-forward`](#section-21)
- [22. `--force` vs `--force-with-lease`](#section-22)
- [23. Sparse Checkout：只需要 Repo 的某些目录](#section-23)
- [24. Sparse Checkout 是不是还是 Clone 了整个 Repo？](#section-24)
- [25. Sparse Checkout 后增加第二个目录](#section-25)
- [26. Git 操作总决策树](#section-26)
- [⭐ 高频命令索引](#command-index)
- [⚠️ 高风险命令](#dangerous-commands)
- [🧠 最容易混淆的 Git 概念](#git-concepts)
- [一句话原则](#summary)

---

<a id="section-1"></a>

## 1. GitHub HTTPS / PAT / Credential 认证

### 场景

使用 HTTPS GitHub Remote：

```bash
git remote -v
```

例如：

```text
https://github.com/OWNER/REPO.git
```

进行 `clone / pull / push` 时需要 GitHub Credential。

### HTTPS 认证

```text
Username: GitHub username
Password: GitHub PAT
```

这里的 Password 不是 GitHub Account Password，而是 **Personal Access Token (PAT)**。

### HTTPS vs SSH

```text
HTTPS:
https://github.com/OWNER/REPO.git

SSH:
git@github.com:OWNER/REPO.git
```

### 检查

```bash
git remote -v
gh auth status
git config --show-origin --get-all credential.helper
```

### 注意

GitHub 已不支持用账号密码进行 Git HTTPS 操作。

⚠️ 不要把 PAT 放进：

- Chat
- Screenshot
- Shell history
- Git Repo
- 配置文件

如果 Token 已泄露，应立即 revoke / rotate。

---

<a id="section-2"></a>

## 2. `gh auth` 成功，但 `git push` 还是失败

### 场景

```bash
gh auth status
```

显示已登录，但：

```bash
git push
```

仍然出现 Authentication / 403。

### 原因

需要区分：

```text
GitHub CLI Authentication
        ≠
Git HTTPS Credential
```

`gh` 有自己的认证状态，而 Git HTTPS 的 credential 可能来自：

```text
Credential Helper
~/.git-credentials
Git Credential Manager
其他 credential store
```

### 排查

```bash
gh auth status
git remote -v
git config --show-origin --get-all credential.helper
```

如果 Git 使用错误或旧 Credential，需要清理/更新 Credentials。

### 选项：让 Git 使用 GitHub CLI Credential

```bash
gh auth setup-git
```

### 关键点

> `gh auth status` 成功，不等于 `git push` 一定使用相同 Token。

---

<a id="section-3"></a>

## 3. PAT 有效，但 `git push` 还是 403

### 场景

```text
Permission to OWNER/REPO.git denied
403
```

但你认为自己已经拥有 Repo 权限。

### 检查 Repo 权限

```bash
gh api repos/OWNER/REPO --jq '.permissions'
```

### 排查顺序

```text
GitHub Account
      ↓
PAT 是否有效
      ↓
PAT Scope / Permission
      ↓
Organization Authorization
      ↓
Repository Permission
      ↓
Git Credential Helper 实际用了哪个 Token
      ↓
Repository / Branch Policy
```

### 关键点

> `403` 不一定等于“账号没有 Repo 权限”。

尤其应该检查：

```bash
git config --show-origin --get-all credential.helper
```

确认 Git 实际从哪里取得 Credential。

---

<a id="section-4"></a>

## 4. `git pull` 到底做了什么

### 操作

```bash
git pull origin main
```

可以近似理解成：

```bash
git fetch origin
git merge origin/main
```

### 解释

`fetch`：

```text
更新 Remote Tracking Branch
不直接改变当前 Working Tree
```

`merge`：

```text
把远端变化合入当前 Branch
```

因此：

```bash
git pull
```

不是：

```text
“远端直接覆盖本地”
```

### 如果只想查看远端变化

使用：

```bash
git fetch origin
```

然后：

```bash
git log --oneline HEAD..origin/main
git diff HEAD..origin/main
```

---

<a id="section-5"></a>

## 5. `git pull --rebase`

### 操作

```bash
git pull --rebase origin main
```

注意语法是：

```bash
git pull --rebase
```

不是：

```bash
git pull rebase
```

### 原理

假设：

```text
Remote:
A---B---E---F

Local:
A---B---C---D
```

执行 Rebase 后：

```text
A---B---E---F---C'---D'
```

逻辑：

```text
1. Fetch 远端提交
2. 暂时取下本地 commits
3. 更新到最新远端状态
4. 把本地 commits 重新应用到最上面
```

### 关键点

> Rebase 不等于丢弃本地 Commit。

但是 Commit 被重新生成，所以：

```text
C → C'
D → D'
```

Commit SHA 会变化。

---

<a id="section-6"></a>

## 6. Rebase vs Merge

### Merge

```bash
git pull --no-rebase
```

历史可能成为：

```text
      C---D
     /     \
A---B       M
     \     /
      E---F
```

特点：

- 保留原有 Commit SHA
- 可能产生 Merge Commit
- 保留分支真实合并结构

### Rebase

```bash
git pull --rebase
```

结果类似：

```text
A---B---E---F---C'---D'
```

特点：

- 历史更加线性
- 不额外创建 Merge Commit
- 会重写本地 Commit SHA

### 怎么选

```text
希望线性历史
    → Rebase

希望明确保留 Merge 关系
    → Merge
```

---

<a id="section-7"></a>

## 7. `divergent branches` 怎么处理

### 场景

Git 提示：

```text
You have divergent branches and need to specify
how to reconcile them.
```

表示：

```text
Local 有自己的 Commit
+
Remote 也有新的 Commit
```

双方已经分叉。

### Option A：Rebase

```bash
git pull --rebase origin <branch>
```

### Option B：Merge

```bash
git pull --no-rebase origin <branch>
```

### Option C：只允许 Fast-forward

```bash
git pull --ff-only
```

如果发生真正分叉，Git 直接拒绝。

### 设置默认 Rebase

当前 Repo：

```bash
git config pull.rebase true
```

全局：

```bash
git config --global pull.rebase true
```

### 设置默认只允许 Fast-forward

```bash
git config --global pull.ff only
```

---

<a id="section-8"></a>

## 8. Rebase 遇到 Conflict

### 开始 Rebase

```bash
git pull --rebase origin <branch>
```

发生：

```text
CONFLICT
```

### Step 1：查看

```bash
git status
```

### Step 2：手工解决冲突

文件可能包含：

```text
<<<<<<<
=======
>>>>>>>
```

决定正确内容，然后保存。

### Step 3：标记已解决

```bash
git add <file>
```

### Step 4：继续

```bash
git rebase --continue
```

如果还有 Conflict，继续重复：

```text
Resolve
→ git add
→ git rebase --continue
```

### 放弃整个 Rebase

```bash
git rebase --abort
```

---

<a id="section-9"></a>

## 9. 用 `origin/main` 完全覆盖本地

### 场景

你明确不要：

- 本地 tracked 修改
- staged 修改
- 本地 Branch 上尚未保留的不同提交状态

目标是让当前 Branch 回到：

```text
origin/main
```

### 操作

```bash
git fetch origin
git reset --hard origin/main
```

### 不是

```bash
git pull --rebase origin main
```

因为 Rebase 的目标是：

> 尽量保留你的本地 commits，并重新应用它们。

而 Reset 的目标是：

> 让当前 Branch 指针和 tracked Working Tree 回到指定 Commit。

### ⚠️ 注意

`--hard` 是 destructive 操作。

先检查：

```bash
git status
git log --oneline --decorate -10
```

---

<a id="section-10"></a>

## 10. 覆盖 tracked 文件，但保留 untracked 文件

### 需求

希望：

```text
tracked 修改       → 丢弃
staged 修改        → 丢弃
本地分支状态       → origin/main
untracked 文件     → 保留
```

### 操作

```bash
git fetch origin
git reset --hard origin/main
```

### 结果

```text
Tracked files       → Reset
Staged changes      → Reset
Untracked files     → 保留
```

### 查看 Untracked 文件

```bash
git ls-files --others --exclude-standard
```

### ⚠️ 不要执行

```bash
git clean -fd
```

因为它会删除 Untracked 文件/目录。

### 先预览 `clean`

```bash
git clean -nd
```

确认真的全部不要，才：

```bash
git clean -fd
```

---

<a id="section-11"></a>

## 11. `git add .` vs `git add -A` vs `git add -u`

### 当前目录及子目录

```bash
git add .
```

### 所有变化

```bash
git add -A
```

包括：

```text
New
Modified
Deleted
```

### 只 Stage 已经被 Git Track 的文件

```bash
git add -u
```

包括：

```text
Modified
Deleted
```

但不自动加入新的 Untracked 文件。

### 简单记忆

```text
git add -A
    → All changes

git add -u
    → Update tracked files
```

### 检查

```bash
git status
git diff --cached
```

---

<a id="section-12"></a>

## 12. Untrack 文件，但保留本地文件

### 场景

文件已经 Commit 到 Git，但现在希望：

```text
GitHub / Git 不再 Track
本地文件继续保留
```

### 单文件

```bash
git rm --cached <file>
```

### 整个目录

```bash
git rm -r --cached <directory>/
```

### 然后 Commit

```bash
git commit -m "Stop tracking files"
```

### 如果以后也不要重新 Track

把文件加入：

```text
.gitignore
```

### 关键点

不要使用：

```bash
git rm <file>
```

如果你的目标是保留本地文件。

---

<a id="section-13"></a>

## 13. `.gitignore` 为什么通常应该提交到 Repo

### 原因

`.gitignore` 通常代表项目级共享规则，例如：

```gitignore
.env
*.log
node_modules/
terraform.tfstate
```

团队成员 Clone Repo 后应该获得相同的 Ignore 规则。

因此通常：

```bash
git add .gitignore
git commit -m "Add gitignore"
```

### 如果只是个人 Ignore

不希望影响团队，可以使用：

```text
.git/info/exclude
```

### 简单理解

```text
.gitignore
    → 项目/团队共享 Ignore

.git/info/exclude
    → 本地个人 Ignore
```

---

<a id="section-14"></a>

## 14. `.gitignore` 为什么对已经 tracked 的文件无效

### 场景

文件已经被 Git Track：

```text
.env
```

然后才加入：

```gitignore
.env
```

Git 仍然显示 `.env` 的变化。

### 原因

`.gitignore` 主要决定：

> 一个尚未跟踪的文件是否应该被 Git 自动纳入 Track。

它不会自动把已经存在于 Git Index 中的文件移除。

### 解决

```bash
git rm --cached .env
git commit -m "Stop tracking .env"
```

之后：

```gitignore
.env
```

才会对未来状态生效。

---

<a id="section-15"></a>

## 15. 不 Merge 整个 Branch，只拿一个文件

### 场景

当前：

```text
main
```

只希望拿：

```text
feature
```

中的：

```text
path/to/file
```

### 推荐

```bash
git restore --source feature -- path/to/file
```

然后：

```bash
git add path/to/file
git commit -m "Sync file from feature"
```

### 旧语法

```bash
git checkout feature -- path/to/file
```

### 关键点

这不会：

```text
切换到 feature
Merge feature
复制 feature 的所有 Commit
```

只是把：

```text
feature 中该文件的状态
```

写到当前 Working Tree。

---

<a id="section-16"></a>

## 16. 从另一个 Branch 拿整个目录

和拿单文件一样：

```bash
git restore --source <branch> -- path/to/directory/
```

例如：

```bash
git restore --source feature -- agenthost/module-00/
```

然后：

```bash
git status
git add agenthost/module-00/
git commit -m "Sync module-00 from feature"
```

旧写法：

```bash
git checkout feature -- agenthost/module-00/
```

### 适合

```text
我要另一个 Branch 中某个目录的当前版本
```

而不是：

```text
我要那个 Branch 的整个提交历史
```

---

<a id="section-17"></a>

## 17. 只拿一个 Commit：Cherry-pick

### 场景

另一个 Branch 有一个完整 Commit，希望把这个 Commit 应用到当前 Branch。

### 查看 Commit

```bash
git log <branch> --oneline
```

例如找到：

```text
abc1234 Fix AKS documentation
```

### 应用

```bash
git switch main
git cherry-pick abc1234
```

### 与 Restore 区别

```text
git restore
    → 拿文件/目录状态

git cherry-pick
    → 拿整个 Commit 的 Change Set
```

### ⚠️ 注意

如果该 Commit 改了：

```text
file1
file2
file3
...
file10
```

Cherry-pick 默认会应用这个 Commit 的全部变化。

如果只需要其中一个文件，更适合：

```bash
git restore --source <branch> -- <file>
```

---

<a id="section-18"></a>

## 18. 先比较两个 Branch 的文件，再决定拿哪些修改

### 比较某个文件

```bash
git diff main..feature -- path/to/file
```

### 比较整个目录

```bash
git diff main..feature -- path/to/directory/
```

### 确认全部都要

```bash
git restore --source feature -- path/to/file
```

### 只希望选择部分 Diff

```bash
git checkout -p feature -- path/to/file
```

Git 会逐个 Hunk 询问是否应用。

### 决策

```text
整个文件
    → restore

部分 Hunk
    → checkout -p

整个 Commit
    → cherry-pick

整个 Branch
    → merge
```

---

<a id="section-19"></a>

## 19. `pathspec did not match any file(s) known to git`

### 错误

```text
error: pathspec 'path/to/file'
did not match any file(s) known to git
```

### Step 1：确认文件是否在目标 Branch

```bash
git ls-tree -r <branch> --name-only | grep <filename>
```

### Step 2：搜索所有 Git 历史

```bash
git log --all --name-only --pretty=format: | grep <filename>
```

### Step 3：搜索本地 Working Tree

```bash
find . -name "<filename>"
```

### 常见原因

```text
1. 路径拼错
2. 文件不在那个 Branch
3. 文件只是本地文件，从未 Commit
4. 文件只存在于另一个 Commit / Branch
5. 目录名称不同
6. 大小写错误
```

---

<a id="section-20"></a>

## 20. `git merge --abort` 失败

### 场景

执行：

```bash
git merge --abort
```

出现类似：

```text
Entry 'path/to/file' not uptodate.
Cannot merge.
fatal: Could not reset index file to revision 'HEAD'.
```

### 原因

Merge 过程中 Working Tree 又有额外变化，Git 不敢直接覆盖。

### 第一步永远是

```bash
git status
```

### 该文件修改不要

```bash
git restore path/to/file
git merge --abort
```

### 确定整个 Working Tree 修改都不要

```bash
git reset --hard HEAD
```

### 恢复到 Merge 前

```bash
git reset --hard ORIG_HEAD
```

### ⚠️ 注意

`reset --hard` 会丢弃修改。

执行之前先：

```bash
git status
git diff
```

确认没有需要保存的内容。

---

<a id="section-21"></a>

## 21. Push 出现 `non-fast-forward`

### 错误

```text
! [rejected] <branch> -> <branch> (non-fast-forward)
```

### 含义

Remote 上存在本地没有的提交。

例如：

```text
Remote:
A---B---C

Local:
A---B---D
```

Git 不允许直接让：

```text
D
```

覆盖：

```text
C
```

### 先 Fetch

```bash
git fetch origin
```

### 看分叉

```bash
git log --oneline --left-right HEAD...origin/<branch>
```

### 通常推荐

```bash
git pull --rebase origin <branch>
git push origin <branch>
```

### 如果发生 Conflict

```bash
git status
# resolve files

git add <file>
git rebase --continue
```

---

<a id="section-22"></a>

## 22. `--force` vs `--force-with-lease`

### 场景

你明确知道 Remote History 需要由本地 History 替换。

### 不推荐直接使用

```bash
git push --force
```

### 更安全的选择

```bash
git push --force-with-lease origin <branch>
```

### 区别

```text
--force

直接要求覆盖 Remote History
```

而：

```text
--force-with-lease

只有当 Remote 状态仍符合本地预期时才覆盖
```

如果别人已经 Push 了你还没有 Fetch 到的新提交，`--force-with-lease` 可以降低误覆盖的风险。

### 原则

```text
正常 Push
    → git push

Remote 比 Local 新
    → pull --rebase + push

明确需要 Rewrite Remote History
    → --force-with-lease

--force
    → 尽量避免
```

---

<a id="section-23"></a>

## 23. Sparse Checkout：只需要 Repo 的某些目录

### 场景

Repo 非常大，只需要：

```text
path/to/directory
```

### Clone

```bash
git clone \
  --filter=blob:none \
  --no-checkout \
  --branch <branch> \
  <repo>
```

进入 Repo：

```bash
cd <repo>
```

初始化 Sparse Checkout：

```bash
git sparse-checkout init --cone
```

指定目录：

```bash
git sparse-checkout set \
  path/to/directory
```

然后：

```bash
git checkout
```

### 如果只需要很浅的 History

```bash
git clone \
  --depth 1 \
  --filter=blob:none \
  --no-checkout \
  --branch <branch> \
  <repo>
```

---

<a id="section-24"></a>

## 24. Sparse Checkout 是不是还是 Clone 了整个 Repo？

### 需要区分三个概念

#### Sparse Checkout

```bash
git sparse-checkout
```

主要控制：

```text
Working Tree 中显示哪些路径
```

#### Partial Clone

```bash
--filter=blob:none
```

主要减少：

```text
初始获取不需要的 Blob 内容
```

Git 需要文件内容时可以再获取相应对象。

#### Shallow Clone

```bash
--depth 1
```

控制：

```text
获取多少 Commit History
```

### 因此

不要简单理解：

```text
Sparse Checkout = 只 Clone 一个目录
```

更准确：

```text
Sparse Checkout
    → Working Tree 范围

Partial Clone
    → Git Object 获取策略

Shallow Clone
    → Commit History 深度
```

### 常用组合

```bash
git clone \
  --depth 1 \
  --filter=blob:none \
  --no-checkout \
  <repo>
```

再：

```bash
git sparse-checkout init --cone
git sparse-checkout set path/to/directory
```

---

<a id="section-25"></a>

## 25. Sparse Checkout 后增加第二个目录

### 场景

最开始只需要：

```text
directory1
```

后来又需要：

```text
directory2
```

不需要重新 Clone Repo。

### 查看当前 Sparse 设置

```bash
git sparse-checkout list
```

### 设置需要的目录

```bash
git sparse-checkout set \
  path/to/directory1 \
  path/to/directory2
```

### 注意 `set` 的语义

如果原来有：

```text
directory1
```

现在执行：

```bash
git sparse-checkout set directory2
```

最终 Sparse Set 以新的设置为准。

所以如果两个都需要，应一起指定：

```bash
git sparse-checkout set \
  directory1 \
  directory2
```

### 如果 Git 版本支持，也可以使用 `add`

```bash
git sparse-checkout add path/to/directory2
```

适合表达：

```text
在现有 Sparse Checkout 范围基础上增加目录
```

---

<a id="section-26"></a>

## 26. Git 操作总决策树

### A. 我要同步 Remote

```text
我要同步 Remote
│
├── 我要保留自己的 Local Commits
│   │
│   ├── 希望历史线性
│   │      ↓
│   │   git pull --rebase
│   │
│   └── 接受 Merge Commit
│          ↓
│       git pull --no-rebase
│
├── 我只想看看 Remote 更新，不改变 Working Tree
│      ↓
│   git fetch
│
├── 我的 Local tracked 修改和 Commit 都不要
│      ↓
│   git fetch
│   git reset --hard origin/<branch>
│
└── 连 Untracked 文件也不要
       ↓
    git clean -nd     # 先预览
    git clean -fd     # ⚠️ 删除
```

### B. 我要另一个 Branch 的内容

```text
我要拿另一个 Branch 的内容
│
├── 一个文件
│      ↓
│   git restore --source <branch> -- <file>
│
├── 一个目录
│      ↓
│   git restore --source <branch> -- <directory>
│
├── 文件中的部分修改
│      ↓
│   git checkout -p <branch> -- <file>
│
├── 一个完整 Commit
│      ↓
│   git cherry-pick <commit>
│
└── 整个 Branch
       ↓
    git merge <branch>
```

### C. 我要停止 Track 一个文件

```text
文件已经被 Git Track
│
├── 本地文件也要删除
│      ↓
│   git rm <file>
│
└── 本地文件保留
       ↓
    git rm --cached <file>
       +
    加入 .gitignore
```

### D. Push 被拒绝

```text
git push 被拒绝
│
├── Authentication / 403
│      ↓
│   gh auth status
│   git remote -v
│   git config --show-origin --get-all credential.helper
│   gh api repos/OWNER/REPO --jq '.permissions'
│
├── non-fast-forward
│      ↓
│   git fetch
│   git log --left-right HEAD...origin/<branch>
│   git pull --rebase
│   git push
│
└── 明确需要 Rewrite Remote History
       ↓
    git push --force-with-lease
```

---

<a id="command-index"></a>

# ⭐ 高频命令索引

## 状态检查

```bash
git status
git branch -a
git remote -v
git log --oneline --graph --all
```

## Remote

```bash
git fetch origin
git pull --rebase origin main
git push origin <branch>
```

## 强制回到 Remote

```bash
git fetch origin
git reset --hard origin/main
```

## Stage

```bash
git add .
git add -A
git add -u
```

## 跨 Branch 获取内容

```bash
git restore --source <branch> -- <file>
git restore --source <branch> -- <directory>
git cherry-pick <commit>
```

## 停止 Track

```bash
git rm --cached <file>
git rm -r --cached <directory>
```

## Conflict

```bash
git status
git add <resolved-file>
git rebase --continue
git rebase --abort
git merge --abort
```

## Force Push

```bash
git push --force-with-lease origin <branch>
```

## GitHub Auth

```bash
gh auth status
gh auth setup-git
git config --show-origin --get-all credential.helper
```

## Sparse Checkout

```bash
git sparse-checkout init --cone
git sparse-checkout list
git sparse-checkout set <directory1> <directory2>
git sparse-checkout add <directory>
```

---

<a id="dangerous-commands"></a>

# ⚠️ 高风险命令

执行以下命令前先停一下：

```bash
git reset --hard ...
git clean -fd
git push --force
git push --force-with-lease
```

推荐先运行：

```bash
git status
git diff
git log --oneline --decorate -10
git fetch origin
```

对于 `git clean`：

```bash
git clean -nd
```

先 Preview，再决定是否：

```bash
git clean -fd
```

---

<a id="git-concepts"></a>

# 🧠 最容易混淆的 Git 概念

```text
fetch
    获取 Remote 信息，不合并

pull
    fetch + merge/rebase

merge
    合并两个开发历史

rebase
    把自己的 Commits 重新应用到新的 Base 上

reset --hard
    把当前 Branch / Index / Working Tree 重置到指定 Commit

restore
    从指定来源恢复文件/目录

cherry-pick
    把另一个 Commit 的 Change Set 应用到当前 Branch

.gitignore
    防止未 Track 文件被正常加入 Git

rm --cached
    从 Git Index 移除，但本地文件保留

sparse-checkout
    控制 Working Tree 中需要哪些路径

--filter=blob:none
    Partial Clone，减少不必要 Blob 的初始下载

--depth 1
    Shallow Clone，减少获取的 Commit History
```

---

<a id="summary"></a>

# 一句话原则

> **不确定时先 `git status`，需要了解 Remote 时先 `git fetch`，需要比较时先 `git diff/log`，确认之后才执行 `reset --hard`、`clean` 或 Force Push。**