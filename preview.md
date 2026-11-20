# Preview AI Notes Locally

> 🌐 语言 / Language: **English** | [中文](preview_CN.md)

Use [preview.html](./preview.html) to browse files in your local repository, including uncommitted files, without pushing to GitHub. The page reads local directories through the HTTP service provided by [preview.cjs](./preview.cjs). Do not open the HTML file directly by double-clicking it.

## Option 1: Start a Local Node Service

Prerequisite: Node.js 18 or later. No npm dependencies need to be installed.

1. Clone the repository into `<AINOTES_CLONE_DIR>` and enter that directory:

   ```bash
   git clone https://github.com/oxcp/ainotes.git "<AINOTES_CLONE_DIR>"
   cd "<AINOTES_CLONE_DIR>"
   ```

   Replace `<AINOTES_CLONE_DIR>` with your actual local directory path. If you already have the repository, go directly to its root directory.

2. Start the preview service:

   ```bash
   node preview.cjs
   ```

3. Open <http://localhost:3000/preview.html> in your browser.

Keep the terminal running; press `Ctrl+C` to stop the service. If port 3000 is already in use, specify another port:

```bash
node preview.cjs 3001
```

Then open <http://localhost:3001/preview.html>.

## Option 2: Run in a Container

Prerequisites: Docker is installed and running, and you can pull the `dhi.io/node:26-alpine-sfw-ent-dev` image. If the registry requires authentication, sign in first. Node.js does not need to be installed on the host.

1. Clone the repository into `<AINOTES_CLONE_DIR>`:

   ```bash
   git clone https://github.com/oxcp/ainotes.git "<AINOTES_CLONE_DIR>"
   ```

   Replace `<AINOTES_CLONE_DIR>` with the actual absolute path to the repository. If you already have a clone, you can use that directory.

2. Start the container (the multiline command below uses Bash line continuation syntax):

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

   In Windows PowerShell, use the equivalent single-line command:

   ```powershell
   docker run -d --restart unless-stopped -p 13000:3000 -v "<AINOTES_CLONE_DIR>:/preview" --name preview --entrypoint node dhi.io/node:26-alpine-sfw-ent-dev /preview/preview.cjs
   ```

   The local repository is mounted at `/preview` inside the container, and host port 13000 maps to service port 3000 in the container. `--restart unless-stopped` automatically starts the container after Docker restarts, unless you have manually stopped it.

3. Open <http://localhost:13000/preview.html> in your browser.

View startup logs, stop the container, or start it again:

```bash
docker logs preview
docker stop preview
docker start preview
```

If a container named `preview` already exists, start it with `docker start preview` instead of running `docker run` again.

## Using the Preview Page

- Select a Markdown file in the directory tree on the left to display its contents on the right.
- Shell scripts, PowerShell, JSON, Bicep, YAML, Terraform, JavaScript, CSS, Dockerfile (including `.dockerfile` files), Python (`.py`), XML (`.xml`), and plain text (`.txt`) open in the [code reader](./code-viewer.html). Images, videos, PDFs, and other supported media open directly. Unsupported file types are listed as **not previewable**, and their contents are not served.
- Use the search box to filter by directory or filename.
- Use **File types (multi-select)** to select multiple extensions, such as `.md`, `.sh`, and `.yaml`, at once. Types are detected from the local file list and matched case-insensitively; conventional `Dockerfile` filenames have their own **Dockerfile** category, while other files without an extension appear under **No extension**. All types are selected by default. **Select all** restores all types; **Clear** deselects them all. Type selections are combined with the search text and retained when refreshing directories.
- After adding or deleting files, click **Refresh directories** to rescan the directory tree. After editing a document, refresh the page to see the latest content. The container reads the mounted local repository directly; no image rebuild is needed.
- The Markdown reader and Shiki syntax highlighter use external CDN dependencies that require internet access. If highlighting fails, the code reader reports the error and keeps the plain source visible with line numbers.
- The service provides read-only previews, not file editing. Hidden paths, dependency directories, test directories, and symbolic links are not shown.
- Access the service using `localhost` or `127.0.0.1`; requests with other Host names are rejected. The service listens on `0.0.0.0`, and the Docker command above publishes the port on all host interfaces. To restrict access to the local machine, change the port mapping to `-p 127.0.0.1:13000:3000`.

### Code and JSON Reader

- The code reader uses Shiki with a VS Code-style light theme and line numbers. **Wrap lines** toggles line wrapping; **Copy source** always copies the original file, including its original formatting and line endings.
- TXT uses plain text with line numbers and does not load Shiki. Dockerfile, Python, and XML use their respective language grammars. XML is displayed as literal text, not rendered as an XML document.
- JSON supports **Source**, **Formatted**, and **Tree** views. The tree expands and collapses objects and arrays. Formatting and tree views only change the display; files are never modified.
- Invalid JSON remains readable as source. Selecting a formatted or tree view reports the parsing error instead of silently replacing the content.
- **Open raw** opens the original file in another tab; **Local preview** returns to the directory page with the file selected.
- Source code and JSON are rendered as text and never executed. Highlighting runs in the browser; file contents are not sent to the CDN.
- **JSON access is enabled for visible repository paths, including runtime configuration.** 