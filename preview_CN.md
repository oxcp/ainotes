# 本地预览 AI Notes

> 🌐 语言 / Language: [English](preview.md) | **中文**

通过 [preview.html](./preview.html) 可以浏览本地仓库中的文件，包括尚未提交的文件，无需推送到 GitHub。页面通过 [preview.cjs](./preview.cjs) 提供的 HTTP 服务读取本地目录，不要直接双击 HTML 文件打开。

## 方式一：本地启动 Node 服务

前提：已安装 Node.js 18 或更高版本，无需安装 npm 依赖。

1. 将仓库克隆到本地目录 `<AINOTES_CLONE_DIR>`，并进入该目录：

   ```bash
   git clone https://github.com/oxcp/ainotes.git "<AINOTES_CLONE_DIR>"
   cd "<AINOTES_CLONE_DIR>"
   ```

   请将 `<AINOTES_CLONE_DIR>` 替换为实际的本地目录路径；如果已有仓库，可以直接进入仓库根目录。

2. 启动预览服务：

   ```bash
   node preview.cjs
   ```

3. 浏览器访问：<http://localhost:3000/preview.html>。

保持终端运行，按 `Ctrl+C` 停止服务。如果端口 3000 已被占用，可以指定其他端口：

```bash
node preview.cjs 3001
```

此时访问 <http://localhost:3001/preview.html>。

## 方式二：使用容器启动

前提：已安装并启动 Docker，且能够拉取 `dhi.io/node:26-alpine-sfw-ent-dev` 镜像；如镜像仓库要求认证，请先完成登录。宿主机无需安装 Node.js。

1. 将仓库克隆到本地目录 `<AINOTES_CLONE_DIR>`：

   ```bash
   git clone https://github.com/oxcp/ainotes.git "<AINOTES_CLONE_DIR>"
   ```

   请将 `<AINOTES_CLONE_DIR>` 替换为仓库的实际绝对路径；如果已有仓库，可以使用现有目录。

2. 启动容器（以下多行命令使用 Bash 续行语法）：

   ```bash
   docker run -d \
     --restart unless-stopped \
     -p 13000:3000 \
     -v "<AINOTES_CLONE_DIR>:/preview" \
     --name preview \
     --entrypoint node \
     dhi.io/node:26-alpine-sfw-ent-dev \
     /preview/preview.cjs
   ```

   在 Windows PowerShell 中，可使用等价的单行命令：

   ```powershell
   docker run -d --restart unless-stopped -p 13000:3000 -v "<AINOTES_CLONE_DIR>:/preview" --name preview --entrypoint node dhi.io/node:26-alpine-sfw-ent-dev /preview/preview.cjs
   ```

   本地仓库挂载到容器的 `/preview`，宿主机端口 13000 映射到容器服务端口 3000。`--restart unless-stopped` 使容器在 Docker 重启后自动启动，除非手动停止。

3. 浏览器访问：<http://localhost:13000/preview.html>。

查看启动日志或停止、重新启动容器：

```bash
docker logs preview
docker stop preview
docker start preview
```

如果已有名为 `preview` 的容器，使用 `docker start preview` 启动现有容器，不要重复执行 `docker run`。

## 页面使用说明

- 在左侧目录树选择 Markdown 文件，右侧显示文档内容。
- Shell 脚本、PowerShell、JSON、Bicep、YAML、Terraform、JavaScript、CSS、Dockerfile（包括 `.dockerfile` 文件）、Python（`.py`）、XML（`.xml`）和纯文本（`.txt`）使用[代码阅读器](./code-viewer.html)显示。图片、视频、PDF 等已支持的媒体类型直接打开。不支持的文件类型标注 **not previewable（不可预览）**，不提供其内容访问。
- 使用搜索框按目录或文件名筛选。
- 使用 **File types (multi-select)** 同时勾选多个扩展名，例如 `.md`、`.sh` 和 `.yaml`。类型从本地文件列表自动生成，不区分大小写；标准 `Dockerfile` 文件名单独归入 **Dockerfile** 类型，其他无扩展名的文件归入 **No extension**。默认全选；点击 **Select all** 恢复全选，点击 **Clear** 清空选择。类型筛选与搜索关键词同时生效，刷新目录时保留类型选择。
- 新增或删除文件后，点击 **Refresh directories** 重新扫描目录；修改文档后刷新页面查看最新内容。容器方式直接读取挂载的本地仓库，无需重新构建镜像。
- Markdown 阅读器和 Shiki 语法高亮的外部 CDN 依赖需要互联网连接。如果高亮加载失败，代码阅读器会显示错误，并保留带行号的纯文本源码。
- 服务为只读预览，不提供文件编辑功能；隐藏路径、依赖目录、测试目录和符号链接不会显示。
- 请使用 `localhost` 或 `127.0.0.1` 访问，服务会拒绝其他 Host 名称。服务监听 `0.0.0.0`，上述 Docker 命令也会发布到所有宿主机接口；如需限制为本机访问，可将端口映射改为 `-p 127.0.0.1:13000:3000`。

### 代码和 JSON 阅读器

- 代码阅读器使用 Shiki，提供 VS Code 风格的浅色主题和行号。**Wrap lines** 切换自动换行；**Copy source** 始终复制原始文件内容，包括原有格式和换行符。
- TXT 使用带行号的纯文本显示，不加载 Shiki。Dockerfile、Python 和 XML 使用各自的语言语法进行高亮。XML 作为原始文本显示，不渲染为 XML 文档。
- JSON 支持 **Source（源码）**、**Formatted（格式化）** 和 **Tree（树形）** 视图，树形视图可展开或折叠对象与数组。格式化和树形视图只改变显示，不修改文件。
- 无效 JSON 仍可查看源码。选择格式化或树形视图时会明确显示解析错误，不会静默替换内容。
- **Open raw** 在新标签页打开原始文件；**Local preview** 返回目录页面并选中当前文件。
- 源码和 JSON 作为文本显示，不会执行。语法高亮在浏览器内完成，文件内容不会发送到 CDN。
- **已开放仓库可见路径下的 JSON 内容访问，包括运行时配置。** 