const { createReadStream } = require('node:fs');
const fs = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { pipeline } = require('node:stream/promises');

const excludedDirectories = new Set(['node_modules', 'tests', '__pycache__', 'venv', 'copilot-worktrees']);
const contentTypes = new Map([
    ['.html', 'text/html'], ['.md', 'text/plain'], ['.js', 'text/javascript'], ['.css', 'text/css'],
    ['.svg', 'image/svg+xml'], ['.png', 'image/png'], ['.jpg', 'image/jpeg'], ['.jpeg', 'image/jpeg'],
    ['.gif', 'image/gif'], ['.webp', 'image/webp'], ['.ico', 'image/x-icon'],
    ['.mp4', 'video/mp4'], ['.webm', 'video/webm'], ['.ogg', 'video/ogg'], ['.pdf', 'application/pdf'],
    ['.woff', 'font/woff'], ['.woff2', 'font/woff2'], ['.ttf', 'font/ttf'],
    ...['.sh', '.ps1', '.bicep', '.yaml', '.yml', '.tf'].map((extension) => [extension, 'text/plain']),
]);

function isVisible(parts) {
    return parts.every((part) => part && !part.startsWith('.') &&
        !excludedDirectories.has(part) && !/[\\:\u0000-\u001f]/.test(part));
}

function httpError(status, message) {
    return Object.assign(new Error(message), { status });
}

async function directoryTree(root) {
    const tree = [];
    let visited = 0;
    async function walk(parts) {
        const entries = await fs.readdir(path.join(root, ...parts), { withFileTypes: true });
        for (const entry of entries) {
            const segments = [...parts, entry.name];
            if (!isVisible(segments) || entry.isSymbolicLink()) continue;
            if (++visited > 20000 || segments.length > 30) {
                throw httpError(413, 'Local directory tree is too large for the documentation preview.');
            }
            if (entry.isDirectory()) {
                await walk(segments);
            } else if (entry.isFile() && /\.md$/i.test(entry.name)) {
                tree.push({ type: 'blob', path: segments.join('/') });
            }
        }
    }
    await walk([]);
    return { truncated: false, tree };
}

function createPreviewServer({ root = __dirname } = {}) {
    async function handle(request, response) {
        let host;
        try {
            host = new URL(`http://${request.headers.host}`);
        } catch {
            throw httpError(400, 'Invalid request host.');
        }
        if (!['localhost', '127.0.0.1', '[::1]'].includes(host.hostname)) {
            throw httpError(403, 'The documentation preview accepts loopback hosts only.');
        }
        response.setHeader('Cache-Control', 'no-store');
        response.setHeader('X-Content-Type-Options', 'nosniff');
        response.setHeader('X-Frame-Options', 'SAMEORIGIN');
        if (!['GET', 'HEAD'].includes(request.method)) {
            response.setHeader('Allow', 'GET, HEAD');
            throw httpError(405, 'The documentation preview is read-only.');
        }
        const pathname = new URL(request.url, host).pathname;
        const resolvedRoot = await fs.realpath(root);
        if (pathname === '/api/repository-tree') {
            const tree = await directoryTree(resolvedRoot);
            response.setHeader('Content-Type', 'application/json; charset=utf-8');
            response.end(request.method === 'HEAD' ? undefined : JSON.stringify(tree));
            return;
        }
        let parts;
        try {
            parts = decodeURIComponent(pathname === '/' ? '/preview.html' : pathname).slice(1).split('/');
        } catch {
            throw httpError(400, 'Invalid URL encoding.');
        }
        if (!isVisible(parts)) throw httpError(403, 'This path is not available in the documentation preview.');
        const target = await fs.realpath(path.join(resolvedRoot, ...parts));
        const relative = path.relative(resolvedRoot, target);
        if (path.isAbsolute(relative) || !isVisible(relative.split(path.sep))) {
            throw httpError(403, 'This path is outside the visible documentation tree.');
        }
        const type = contentTypes.get(path.extname(target).toLowerCase());
        if (!type) throw httpError(403, 'This file type is not served by the documentation preview.');
        if (!(await fs.stat(target)).isFile()) throw httpError(404, 'Document not found.');
        response.setHeader('Content-Type', `${type}${type.startsWith('text/') ? '; charset=utf-8' : ''}`);
        if (request.method === 'HEAD') {
            response.end();
            return;
        }
        await pipeline(createReadStream(target), response);
    }
    return http.createServer((request, response) => {
        handle(request, response).catch((error) => {
            if (response.destroyed) {
                if (error.code !== 'ERR_STREAM_PREMATURE_CLOSE') console.error('Documentation preview request failed:', error);
                return;
            }
            if (response.headersSent) {
                console.error('Documentation preview read failed:', error);
                response.destroy();
                return;
            }
            const status = error.status ?? (error.code === 'ENOENT' ? 404 : error.code === 'EACCES' ? 403 : 500);
            if (status === 500) console.error('Documentation preview request failed:', error);
            response.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
            response.end(status === 500 ? 'Documentation preview request failed.' :
                status === 404 ? 'Document not found.' : error.message);
        });
    });
}

if (require.main === module) {
    const port = process.argv[2] === undefined ? 3000 : Number(process.argv[2]);
    if (!Number.isInteger(port) || port < 0 || port > 65535) {
        console.error('Usage: node preview.cjs [port between 0 and 65535]');
        process.exitCode = 1;
    } else {
        const server = createPreviewServer();
        server.on('error', (error) => {
            console.error(`Local preview could not start: ${error.message}. Try node preview.cjs 3001.`);
            process.exitCode = 1;
        });
        server.listen(port, '127.0.0.1', () => {
            console.log(`Local AI Notes: http://127.0.0.1:${server.address().port}/preview.html`);
            console.log('Reading local Markdown, including uncommitted directories. Refresh directories after adding or deleting files.');
            console.log('Read-only, loopback-only preview. Hidden paths, dependencies/tests and runtime JSON are not served.');
            console.log('Node.js 18+; no package installation. Keep this terminal open; press Ctrl+C to stop.');
        });
    }
}

module.exports = { createPreviewServer };
