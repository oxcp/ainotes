const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'markdown-viewer.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const navigationScript = script.slice(0, script.indexOf('        configureSidebar();'));
const moduleRoot = 'agenthost/module-06/';
const sourceRoot = `${moduleRoot}agent-src/`;

function element() {
    return {
        dataset: {},
        attributes: {},
        children: [],
        classList: { add() {} },
        append(child) { this.children.push(child); },
        after(child) { this.following = child; },
        setAttribute(name, value) { this.attributes[name] = value; },
        querySelector() { return this.span ??= element(); },
    };
}

function descendants(node) {
    return node.children.flatMap((child) => [child, ...descendants(child)]);
}

function load(file) {
    const title = element();
    const links = element();
    const sidebar = element();
    sidebar.querySelector = (selector) => selector === '.sidebar-title' ? title : links;
    const context = vm.createContext({
        URL,
        URLSearchParams,
        window: {
            location: new URL(`https://example.test/ainotes/markdown-viewer.html?file=${encodeURIComponent(file)}`),
            matchMedia: () => ({ matches: false }),
        },
        document: {
            getElementById: element,
            createElement: element,
            querySelector: () => sidebar,
            body: element(),
        },
    });
    vm.runInContext(`${navigationScript}
        globalThis.navigation = {
            getAgenthostPath, getAgenthostLanguage, configureSidebar,
            navigationSections, module06Navigation
        };`, context);
    return { ...context.navigation, title, links, sidebar };
}

function assertExactFile(relative) {
    let current = root;
    for (const segment of relative.split('/')) {
        assert.ok(fs.readdirSync(current).includes(segment), `Exact-case path missing: ${relative}`);
        current = path.join(current, segment);
    }
    assert.ok(fs.statSync(current).isFile());
}

test('Module 06 root and five Agent language mappings preserve actual filename casing', () => {
    const nav = load(`${moduleRoot}readme_CN.md`);
    assert.equal(nav.getAgenthostLanguage(), 'zh-CN');
    assert.equal(nav.getAgenthostPath(`${moduleRoot}readme.md`, 'zh-CN'), `${moduleRoot}readme_CN.md`);
    assert.equal(nav.getAgenthostPath(`${moduleRoot}readme_CN.md`, 'en'), `${moduleRoot}readme.md`);
    const moduleLink = nav.navigationSections[0].links.find(([, target]) => target === `${moduleRoot}readme.md`);
    assert.ok(moduleLink);
    for (const [, target] of [moduleLink, ...nav.module06Navigation.links, ...nav.module06Navigation.documents.links]) {
        for (const language of ['en', 'zh-CN']) {
            assertExactFile(nav.getAgenthostPath(target, language));
        }
    }
    for (const agent of ['chat_agent', 'orchestrator_agent', 'data_processing_agent', 'rag_agent', 'sql_agent']) {
        assert.equal(nav.getAgenthostPath(`${sourceRoot}${agent}/README.md`, 'zh-CN'),
            `${sourceRoot}${agent}/README_CN.md`);
        assert.equal(nav.getAgenthostPath(`${sourceRoot}${agent}/README_CN.md`, 'en'),
            `${sourceRoot}${agent}/README.md`);
    }
});

test('Module 06 groups eight documents alongside five Agents and a source overview', () => {
    const current = `${sourceRoot}rag_agent/README_CN.md`;
    const nav = load(current);
    nav.configureSidebar();
    const links = descendants(nav.links).filter((child) => child.dataset.file);
    assert.equal(nav.module06Navigation.links.length, 6);
    assert.equal(nav.module06Navigation.documents.links.length, 8);
    const group = nav.links.children.find((child) => child.className === 'sidebar-group');
    assert.ok(group);
    assert.equal(group.open, false);
    assert.equal(group.children[0].span.textContent, '设计与部署文档');
    assert.equal(group.children[1].children.length, 8);
    assert.ok(!nav.links.children.some((child) => child.dataset.file?.startsWith(`${sourceRoot}docs/`)));
    for (const [, target] of nav.module06Navigation.links) {
        assert.ok(nav.links.children.some((child) => child.dataset.file === nav.getAgenthostPath(target, 'zh-CN')));
    }
    for (const [, target] of [...nav.module06Navigation.links, ...nav.module06Navigation.documents.links]) {
        assert.ok(links.some((link) => link.dataset.file === nav.getAgenthostPath(target, 'zh-CN')));
    }
    assert.deepEqual(links.filter((link) => link.attributes['aria-current'] === 'page')
        .map((link) => link.dataset.file), [current]);
    assert.equal(nav.title.following.children.length, 2);
    for (const option of nav.title.following.children) {
        const target = new URL(option.href, 'https://example.test/').searchParams.get('file');
        assertExactFile(target);
    }
});

test('both root languages link to each other and mark Module 06 as current', () => {
    for (const filename of ['readme.md', 'readme_CN.md']) {
        const current = `${moduleRoot}${filename}`;
        const nav = load(current);
        nav.configureSidebar();
        const selected = nav.links.children.filter((child) => child.attributes['aria-current'] === 'page');
        assert.equal(selected.length, 1);
        assert.equal(selected[0].dataset.file, current);
        const targets = nav.title.following.children.map((option) =>
            new URL(option.href, 'https://example.test/').searchParams.get('file'));
        assert.deepEqual(targets, [`${moduleRoot}readme.md`, `${moduleRoot}readme_CN.md`]);
    }
});

test('Module 06 titles and workshop navigation use the bilingual business-scenario name', () => {
    const englishTitle = 'Multi-Agent Business Scenarios';
    const chineseTitle = '多智能体业务场景';
    for (const [relative, title] of [
        [`${moduleRoot}readme.md`, englishTitle],
        [`${moduleRoot}readme_CN.md`, chineseTitle],
        [`${sourceRoot}README.md`, englishTitle],
        [`${sourceRoot}readme_CN.md`, chineseTitle],
    ]) {
        const heading = fs.readFileSync(path.join(root, relative), 'utf8').split(/\r?\n/)[0];
        assert.ok(heading.endsWith(title), relative);
    }
    for (const [relative, title] of [
        ['agenthost/readme.md', englishTitle],
        ['agenthost/README_CN.md', chineseTitle],
    ]) {
        assert.ok(fs.readFileSync(path.join(root, relative), 'utf8').includes(title), relative);
    }
    const nav = load(`${moduleRoot}readme.md`);
    const moduleLink = nav.navigationSections[0].links.find(([, target]) => target === `${moduleRoot}readme.md`);
    assert.equal(moduleLink[0], `Module 6: ${englishTitle}`);
    assert.equal(moduleLink[3], `模块 6：${chineseTitle}`);
    assert.equal(nav.module06Navigation.title, `${englishTitle} resources`);
    assert.equal(nav.module06Navigation.titleZh, `${chineseTitle}资源`);
});

test('unpaired Module 06 documents never invent a translation or language switch', () => {
    for (const document of ['docs/not-translated.md', 'sample-data/README.md']) {
        const current = sourceRoot + document;
        const nav = load(current);
        assert.equal(nav.getAgenthostPath(current, 'en'), current);
        assert.equal(nav.getAgenthostPath(current, 'zh-CN'), current);
        nav.configureSidebar();
        assert.equal(nav.title.following, undefined);
    }
});

test('other workshop modules gain the Module 06 entry but not its detailed resource section', () => {
    const nav = load('agenthost/module-04/README_CN.md');
    nav.configureSidebar();
    const targets = nav.links.children.filter((child) => child.dataset.file).map((child) => child.dataset.file);
    assert.ok(targets.includes(`${moduleRoot}readme_CN.md`));
    assert.ok(!targets.includes(`${sourceRoot}rag_agent/README_CN.md`));
    assert.ok(targets.includes('agenthost/README_CN.md'));
    assert.ok(targets.includes('agenthost/module-04/README_CN.md'));
});

test('existing source README links retain their original bilingual targets', () => {
    const nav = load(`${sourceRoot}README.md`);
    assert.equal(nav.getAgenthostPath(`${sourceRoot}README.md`, 'zh-CN'), `${sourceRoot}readme_CN.md`);
    assert.equal(nav.getAgenthostPath(`${sourceRoot}readme_CN.md`, 'en'), `${sourceRoot}README.md`);
    nav.configureSidebar();
    assert.deepEqual(descendants(nav.links).filter((child) => child.attributes['aria-current'] === 'page')
        .map((child) => child.dataset.file), [`${sourceRoot}README.md`]);
    for (const option of nav.title.following.children) {
        assertExactFile(new URL(option.href, 'https://example.test/').searchParams.get('file'));
    }
});

test('sidebars contain only links from the current category', () => {
    const sections = load('agenthost/readme.md').navigationSections;
    for (const section of sections) {
        const nav = load(section.links[0][1]);
        nav.configureSidebar();
        const targets = nav.links.children.filter((child) => child.dataset.file)
            .map((child) => child.dataset.file);
        assert.equal(targets.length, section.links.length);
        assert.ok(targets.every((target) => target.startsWith(section.root)));
        assert.ok(!nav.links.children.some((child) => child.textContent === 'Web Slides'));
    }
});

test('root pages and navigation no longer advertise Web Slides', () => {
    for (const filename of ['README.md', 'README_CN.md', 'index.html', 'markdown-viewer.html']) {
        assert.doesNotMatch(fs.readFileSync(path.join(root, filename), 'utf8'), /web[- ]slides/i, filename);
    }
    for (const file of ['web-slides/README.md', 'README.md', 'unknown/guide.md']) {
        const unmatched = load(file);
        unmatched.configureSidebar();
        assert.equal(unmatched.links.children.length, 0);
        assert.notEqual(unmatched.sidebar.hidden, false);
    }
});

test('homepage merges technical documents into references with Git last', () => {
    const homepage = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
    assert.doesNotMatch(homepage, /<h2>Technical Documents?<\/h2>/);
    const sections = [...homepage.matchAll(/<section\b[^>]*>([\s\S]*?)<\/section>/g)]
        .filter((match) => match[1].includes('<h2>Technical References</h2>'));
    assert.equal(sections.length, 1);
    const links = [...sections[0][1].matchAll(/<a href="([^"]+)">([^<]+)<\/a>/g)];
    assert.deepEqual(links.map((match) => match[1]), [
        'markdown-viewer.html?file=codegen-compare-across-models/README.md',
        'codegen-compare-across-models/compare-codegen-realcases.html',
        'markdown-viewer.html?file=models-healthcare/models-in-Bio-Healthcare-industry.md',
        'markdown-viewer.html?file=models-healthcare/model-4-SKH-TC.md',
        'markdown-viewer.html?file=multi-k8s-mgmt/multiclustermgmt.md',
        'markdown-viewer.html?file=techref/git-operations.md',
    ]);
    assert.equal(links.at(-1)[2], 'Git / GitHub Quick Reference');
    for (const [, href] of links) {
        const url = new URL(href, 'https://example.test/');
        assertExactFile(url.searchParams.get('file') ?? url.pathname.slice(1));
    }
});

test('workshop publication trees stay bilingual and describe the current Module 06 layout', () => {
    const trees = ['agenthost/readme.md', 'agenthost/README_CN.md'].map((relative) => {
        const text = fs.readFileSync(path.join(root, relative), 'utf8');
        return text.match(/```\r?\n(agenthost\/[\s\S]*?)```/)[1];
    });
    const paths = (tree) => tree.split(/\r?\n/).map((line) => line.split('←')[0].trimEnd()).join('\n');
    assert.equal(paths(trees[0]), paths(trees[1]));
    for (const tree of trees) {
        const introduction = tree.split('├── module-00/')[1].split('├── module-01/')[0];
        for (const entry of ['.gitignore', 'README.md', 'README_CN.md', 'design.html',
            'design_CN.html', 'timer-en.html', 'timer.html']) {
            assert.ok(introduction.split(/\r?\n/).some((line) => line.split('←')[0].includes(entry)), entry);
        }
        assert.doesNotMatch(paths(introduction), /index\.html|slides\/|notused/);
        const module = tree.split('└── module-06/')[1];
        for (const entry of ['common/', 'bicep/', 'shared/', 'migrations/', '001_initial.sql',
            'pyproject.toml', 'MANIFEST.in', '.dockerignore', '.env.example', 'split_samples.py', 'raw/', 'docs/']) {
            assert.ok(module.includes(entry), entry);
        }
        for (const name of ['architecture', 'cli-deployment', 'data-processing', 'implementation-report',
            'orchestration', 'sandbox-deployment', 'security', 'workshop-guide']) {
            assert.ok(module.includes(`${name}*.md`));
            assertExactFile(`${sourceRoot}docs/${name}.md`);
            assertExactFile(`${sourceRoot}docs/${name}_CN.md`);
        }
        for (const excluded of ['prompt/', 'notmust/', 'tests/', 'deploy/', '.local/', '.venv/']) {
            assert.ok(!module.includes(excluded), excluded);
        }
        assert.equal((module.match(/── sample-data\//g) || []).length, 1);
    }
});

test('Module 01 is 30 minutes, Module 06 is 60 minutes and the full workshop totals 205 minutes', () => {
    for (const relative of ['agenthost/readme.md', 'agenthost/README_CN.md']) {
        const text = fs.readFileSync(path.join(root, relative), 'utf8');
        const rows = text.split(/\r?\n/).filter((line) => /^\| \[module-\d\d\]/.test(line));
        const durations = rows.map((line) => Number(line.split('|')[3].match(/\d+/)[0]));
        assert.deepEqual(durations, [10, 30, 30, 40, 30, 5, 60]);
        assert.equal(durations.slice(0, 6).reduce((sum, duration) => sum + duration, 0), 145);
        assert.equal(durations.slice(1, 5).reduce((sum, duration) => sum + duration, 0), 130);
        assert.equal(durations.reduce((sum, duration) => sum + duration, 0), 205);
        assert.match(text, /145 (?:minutes|分钟)/, relative);
        assert.match(text, /130 (?:minutes|分钟)/, relative);
        assert.match(text, /205 (?:minutes|分钟)/, relative);
    }
    for (const relative of ['module-01/README.md', 'module-01/README_CN.md']) {
        const heading = fs.readFileSync(path.join(root, 'agenthost', relative), 'utf8').split(/\r?\n/)[0];
        assert.match(heading, /30 (?:min|分钟)/, relative);
    }
    for (const relative of ['module-00/design.html', 'module-00/design_CN.html']) {
        const text = fs.readFileSync(path.join(root, 'agenthost', relative), 'utf8');
        const module = text.match(/<article class="module reveal"><h3>01<br>[\s\S]*?<\/article>/)[0];
        assert.match(module, /class="time">30 (?:MIN|分钟)</, relative);
    }
    for (const relative of ['module-00/design.html', 'module-00/design_CN.html',
        'module-05/README.md', 'module-05/README_CN.md', 'module-06/readme.md', 'module-06/readme_CN.md']) {
        const text = fs.readFileSync(path.join(root, 'agenthost', relative), 'utf8');
        assert.match(text, /60(?: minutes| 分钟|-minute)/, relative);
        assert.match(text, /205 (?:minutes|分钟)/, relative);
    }
});

function flowchartStructure(diagram) {
    return diagram.replace(/"[^"\n]*"/g, '""').replace(/\|[^|\n]*\|/g, '||');
}

test('Chinese Module 06 architecture labels are localized without changing the graph', () => {
    const diagrams = ['readme.md', 'readme_CN.md'].map((name) =>
        fs.readFileSync(path.join(root, moduleRoot, name), 'utf8').replace(/\r/g, '')
            .match(/```mermaid\n([\s\S]*?)```/)[1]);
    assert.deepEqual(flowchartStructure(diagrams[0]), flowchartStructure(diagrams[1]));
    const labels = [...diagrams[1].matchAll(/"([^"\n]*)"|\|([^|\n]*)\|/g)]
        .map((match) => match[1] ?? match[2]);
    assert.equal(labels.length, 17);
    for (const label of labels) {
        assert.match(label, /\p{Script=Han}/u, label);
    }
});

test('consolidated guides match structure, commands and table sizes with valid relative links', () => {
    const docs = ['readme.md', 'readme_CN.md'].map((name) =>
        fs.readFileSync(path.join(root, moduleRoot, name), 'utf8').replace(/\r/g, ''));
    const blocks = (text) => [...text.matchAll(/```([^\n]*)\n([\s\S]*?)```/g)]
        .map((match) => [match[1], match[1] === 'mermaid' ? flowchartStructure(match[2]) : match[2]]);
    assert.deepEqual(blocks(docs[0]), blocks(docs[1]));
    const headingLevels = (text) => [...text.matchAll(/^(#+) /gm)].map((match) => match[1]);
    assert.deepEqual(headingLevels(docs[0]), headingLevels(docs[1]));
    const tableRows = (text) => text.split('\n').filter((line) => line.startsWith('|')).length;
    assert.equal(tableRows(docs[0]), tableRows(docs[1]));
    for (const [index, text] of docs.entries()) {
        assert.equal((text.match(/^## (?:Step|步骤) \d/gm) ?? []).length, 8);
        for (const [, link] of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
            if (/^[a-z]+:/i.test(link)) continue;
            const [relative, anchor] = link.split('#');
            const target = path.resolve(root, moduleRoot, relative || ['readme.md', 'readme_CN.md'][index]);
            assert.ok(fs.existsSync(target), `Missing link: ${link}`);
            if (fs.statSync(target).isFile()) {
                assertExactFile(path.relative(root, target).split(path.sep).join('/'));
            }
            if (anchor) {
                const headings = [...fs.readFileSync(target, 'utf8').matchAll(/^#+ (.+)$/gm)]
                    .map((match) => match[1].trim().toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, '').replace(/\s+/g, '-'));
                assert.ok(headings.includes(anchor), `Missing anchor: ${link}`);
            }
        }
    }
});

const docsRoot = `${sourceRoot}docs/`;
const englishDocs = fs.readdirSync(path.join(root, docsRoot))
    .filter((name) => name.endsWith('.md') && !name.endsWith('_CN.md'));

test('all eight documentation pages switch languages and select their localized sidebar entry', () => {
    assert.equal(englishDocs.length, 8);
    for (const name of englishDocs) {
        const english = docsRoot + name;
        const chinese = english.replace(/\.md$/, '_CN.md');
        for (const [current, language] of [[english, 'en'], [chinese, 'zh-CN']]) {
            assertExactFile(current);
            const nav = load(current);
            assert.equal(nav.getAgenthostLanguage(), language);
            assert.equal(nav.getAgenthostPath(current, 'en'), english);
            assert.equal(nav.getAgenthostPath(current, 'zh-CN'), chinese);
            nav.configureSidebar();
            const selected = descendants(nav.links).filter((child) => child.attributes['aria-current'] === 'page');
            assert.deepEqual(selected.map((child) => child.dataset.file), [current]);
            const targets = nav.title.following.children.map((option) =>
                new URL(option.href, 'https://example.test/').searchParams.get('file'));
            assert.deepEqual(targets, [english, chinese]);
            const group = nav.links.children.find((child) => child.className === 'sidebar-group');
            assert.equal(group.open, true);
            assert.equal(group.children[0].span.textContent,
                language === 'zh-CN' ? '设计与部署文档' : 'Design and deployment docs');
            const docs = descendants(group).filter((child) => child.dataset.file?.startsWith(docsRoot));
            assert.equal(docs.length, 8);
            assert.ok(docs.every((child) => child.dataset.file.endsWith('_CN.md') === (language === 'zh-CN')));
        }
    }
});

test('documentation translations preserve fenced examples, structure and top language links', () => {
    const blocks = (text) => [...text.matchAll(/```([^\n]*)\n([\s\S]*?)```/g)]
        .map((match) => [match[1], match[2]]);
    const structure = (text) => text.replace(/```[^\n]*\n[\s\S]*?```/g, '')
        .split('\n').map((line) => {
            if (/^#+ /.test(line)) return line.match(/^#+/)[0];
            if (/^\s*[-*] /.test(line)) return 'bullet';
            if (/^\d+\. /.test(line)) return line.match(/^\d+/)[0];
            if (line.startsWith('|')) return 'table-row';
            return null;
        }).filter(Boolean);
    for (const name of englishDocs) {
        const chineseName = name.replace(/\.md$/, '_CN.md');
        const english = fs.readFileSync(path.join(root, docsRoot, name), 'utf8').replace(/\r/g, '');
        const chinese = fs.readFileSync(path.join(root, docsRoot, chineseName), 'utf8').replace(/\r/g, '');
        assert.deepEqual(blocks(chinese), blocks(english), `${name}: fenced examples`);
        assert.deepEqual(structure(chinese), structure(english), `${name}: document structure`);
        assert.ok(english.split('\n').slice(0, 5).join('\n').includes(`[中文](${chineseName})`));
        assert.ok(chinese.split('\n').slice(0, 5).join('\n').includes(`[English](${name})`));
        for (const [text, isChinese] of [[english, false], [chinese, true]]) {
            for (const [, link] of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
                if (/^[a-z]+:/i.test(link)) continue;
                const [relative, anchor] = link.split('#');
                const target = path.resolve(root, docsRoot, relative || (isChinese ? chineseName : name));
                assert.ok(fs.existsSync(target), `${name}: missing link ${link}`);
                if (fs.statSync(target).isFile()) {
                    assertExactFile(path.relative(root, target).split(path.sep).join('/'));
                }
                if (anchor) {
                    const headings = [...fs.readFileSync(target, 'utf8').matchAll(/^#+ (.+)$/gm)]
                        .map((match) => match[1].trim().toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, '').replace(/\s+/g, '-'));
                    assert.ok(headings.includes(anchor), `${name}: missing anchor ${link}`);
                }
                if (isChinese && path.dirname(target) === path.resolve(root, docsRoot) &&
                    target.endsWith('.md') && path.basename(target) !== name) {
                    assert.ok(target.endsWith('_CN.md'), `${chineseName}: English document link ${link}`);
                }
            }
        }
    }
});

test('Module 06 deployment layout keeps consolidated helpers and single-copy bicep templates', () => {
    for (const file of ['deploy.sh', 'deploy-storage.sh', 'deploy-database.sh', 'build-images.sh', 'deploy-aca.sh',
        'deploy-models.sh']) {
        assertExactFile(moduleRoot + file);
    }
    for (const file of ['aca-config.jq', 'resolve-identity.sh']) {
        assertExactFile(`${moduleRoot}common/${file}`);
        assert.ok(!fs.existsSync(path.join(root, moduleRoot, file)));
    }
    for (const file of ['storage.bicep', 'database.bicep', 'horizondb.bicep', 'postgresql.bicep', 'embedding.bicep']) {
        assertExactFile(`${moduleRoot}bicep/${file}`);
        assert.ok(!fs.existsSync(path.join(root, moduleRoot, file)));
    }
    for (const file of ['resolve-common.sh', 'ensure-horizon-admin.sh', 'configure-horizon-cluster.sh',
        'embeddings-gateway.bicep']) {
        assert.ok(!fs.existsSync(path.join(root, moduleRoot, file)));
    }
    assert.ok(!fs.existsSync(path.join(root, moduleRoot, 'bicep', 'embeddings-gateway.bicep')));
    for (const file of ['horizondb.bicep', 'postgresql.bicep', 'aca-config.jq']) {
        assert.ok(!fs.existsSync(path.join(root, sourceRoot, 'deploy', file)));
    }
    for (const file of ['deploy-database.sh', 'build-images.sh', 'deploy-aca.sh']) {
        assert.ok(!fs.existsSync(path.join(root, sourceRoot, 'deploy', file)));
        const wrapper = fs.readFileSync(path.join(root, moduleRoot, 'notmust', 'deploy', file), 'utf8');
        assert.ok(wrapper.includes('exec bash'));
        assert.ok(wrapper.includes('/../..'));
        assert.ok(!wrapper.includes('az ') && !wrapper.includes('jq '));
    }
    assert.ok(!fs.existsSync(path.join(root, sourceRoot, 'Dockerfile')));
    assert.ok(fs.existsSync(path.join(root, moduleRoot, 'notmust', 'agent-src', 'Dockerfile')));
    assert.ok(fs.existsSync(path.join(root, sourceRoot, 'chat_agent', 'Dockerfile')));
    const builder = fs.readFileSync(path.join(root, moduleRoot, 'build-images.sh'), 'utf8');
    assert.ok(builder.includes('/agent-src'));
    assert.ok(builder.includes('images_preflight'));
    assert.ok(!builder.includes('--apply') && !builder.includes('--check'));
    const database = fs.readFileSync(path.join(root, moduleRoot, 'deploy-database.sh'), 'utf8');
    assert.ok(database.includes('$root/bicep/database.bicep'));
    assert.ok(database.includes('ensure_horizon_admin() ('));
    assert.ok(database.includes('configure_horizon_cluster() ('));
    const entry = fs.readFileSync(path.join(root, moduleRoot, 'deploy.sh'), 'utf8');
    assert.ok(entry.includes('resolve_common() ('));
    assert.ok(entry.includes('common_settings="$(resolve_common)"'));
    const aca = fs.readFileSync(path.join(root, moduleRoot, 'deploy-aca.sh'), 'utf8');
    assert.ok(aca.includes('$root/common/aca-config.jq'));
    for (const script of ['deploy.sh', 'deploy-aca.sh', 'deploy-models.sh']) {
        const content = fs.readFileSync(path.join(root, moduleRoot, script), 'utf8');
        assert.ok(content.includes('$root/common/resolve-identity.sh'));
        assert.ok(!content.includes('$root/resolve-identity.sh'));
        assert.ok(!content.includes('$root/aca-config.jq'));
    }
});

test('Module 06 workshop guides use actual sample parts instead of legacy synthetic fixtures', () => {
    for (const file of [
        `${moduleRoot}readme.md`, `${moduleRoot}readme_CN.md`,
        `${sourceRoot}README.md`, `${sourceRoot}readme_CN.md`,
        `${sourceRoot}docs/workshop-guide.md`, `${sourceRoot}docs/workshop-guide_CN.md`,
    ]) {
        const text = fs.readFileSync(path.join(root, file), 'utf8');
        const actualSamples = path.resolve(root, moduleRoot, 'sample-data');
        const targets = [...text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)]
            .filter(([, link]) => !/^[a-z]+:/i.test(link))
            .map(([, link]) => path.resolve(path.dirname(path.join(root, file)), link.split('#')[0]));
        assert.ok(targets.includes(actualSamples), `${file}: link to actual workshop inputs`);
        assert.ok(!text.includes('consumer-trends.md'), `${file}: legacy Markdown upload`);
        assert.ok(!/France[^\n]*4000|Germany[^\n]*3300/.test(text), `${file}: synthetic expected totals`);
        if (file.startsWith(`${sourceRoot}docs/`) || !file.startsWith(sourceRoot)) {
            for (const name of [
                '01_capgemini_consumer_trends_2025-pages-000001-000020.pdf',
                '02_ryder_ecommerce_consumer_study_2025-pages-000001-000020.pdf',
                '03_customer_reviews-rows-000001-002000.csv',
                '04_financial_sample-rows-000001-000700.csv',
            ]) {
                assert.ok(text.includes(name), `${file}: prepared upload part ${name}`);
            }
        }
        if (!file.startsWith(sourceRoot)) {
            assert.ok(text.includes('python sample-data/split_samples.py --csv-rows 2000 --pdf-pages 20'),
                `${file}: run the relocated splitter from the module root`);
            assert.ok(text.includes('python -m pip install -e ./agent-src'),
                `${file}: install shared extraction dependencies for the external script`);
            assert.ok(!text.includes('agent-src/split_samples.py'), `${file}: obsolete splitter path`);
        }
    }
    const dockerignore = fs.readFileSync(path.join(root, sourceRoot, '.dockerignore'), 'utf8');
    const manifest = fs.readFileSync(path.join(root, sourceRoot, 'MANIFEST.in'), 'utf8');
    assert.match(dockerignore, /^sample-data\/?\r?$/m);
    assert.match(manifest, /^prune sample-data\r?$/m);
    assert.ok(!manifest.includes('recursive-include sample-data'));
    assert.ok(fs.existsSync(path.join(root, moduleRoot, 'sample-data', 'split_samples.py')));
    assert.ok(!fs.existsSync(path.join(root, sourceRoot, 'split_samples.py')));
});

test('storage ownership and root stage changes stay synchronized in bilingual guides', () => {
    for (const file of ['agenthost/module-01/README.md', 'agenthost/module-01/README_CN.md']) {
        const text = fs.readFileSync(path.join(root, file), 'utf8');
        const description = text.split('\n').find((line) => line.startsWith('> 2.'));
        assert.ok(description.includes('`agent-state`') && description.includes('Module 06'));
        assert.ok(!description.includes('two private containers') && !description.includes('两个专用容器'));
    }
    for (const file of [
        `${moduleRoot}readme.md`, `${moduleRoot}readme_CN.md`,
        `${sourceRoot}README.md`, `${sourceRoot}readme_CN.md`,
        `${docsRoot}cli-deployment.md`, `${docsRoot}cli-deployment_CN.md`,
        `${docsRoot}workshop-guide.md`, `${docsRoot}workshop-guide_CN.md`,
    ]) {
        const text = fs.readFileSync(path.join(root, file), 'utf8');
        assert.ok(text.includes('storage → models → database → config → images → aca'), file);
        assert.ok(text.includes('--stage storage'), file);
    }
    for (const file of [`${moduleRoot}readme.md`, `${moduleRoot}readme_CN.md`]) {
        const text = fs.readFileSync(path.join(root, file), 'utf8');
        for (const input of ['STORAGE_ACCOUNT_NAME', 'STORAGE_SUBSCRIPTION_ID', 'STORAGE_RESOURCE_GROUP']) {
            assert.ok(text.includes(input), `${file}: ${input}`);
        }
        assert.ok(text.includes('export KB_STORAGE_CONTAINER_ID="$(bash deploy-storage.sh --resolve)"'));
    }
});

test('Module 06 bilingual guides cover embedding deployment, UAMI and selectable databases', () => {
    for (const file of ['agenthost/readme.md', 'agenthost/README_CN.md']) {
        const text = fs.readFileSync(path.join(root, file), 'utf8');
        assert.ok(text.includes('Azure HorizonDB') && text.includes('Azure Database for PostgreSQL Flexible Server'));
        assert.ok(text.includes('A2A') && text.includes('LangGraph'));
    }
    for (const file of [`${moduleRoot}readme.md`, `${moduleRoot}readme_CN.md`]) {
        const text = fs.readFileSync(path.join(root, file), 'utf8');
        assert.ok(text.includes('DB_PROVIDER=horizondb') && text.includes('postgresql'));
        assert.ok(text.includes('--stage models') && text.includes('UAMI'));
        for (const required of ['deploy-models.sh', 'bicep/embedding.bicep', 'AGENT_IDENTITY_RESOURCE_ID',
            'DB_AUTH_MODE=entra', 'INSERT/UPDATE/SELECT/DELETE']) {
            assert.ok(text.includes(required), `${file}: ${required}`);
        }
        assert.ok(!text.includes('"AZURE_CLIENT_SECRET":'));
    }
});

test('Module 06 bilingual instructions use direct Bash deployment without obsolete mode flags', () => {
    for (const file of [
        'agenthost/readme.md', 'agenthost/README_CN.md',
        `${moduleRoot}readme.md`, `${moduleRoot}readme_CN.md`,
        `${sourceRoot}README.md`, `${sourceRoot}readme_CN.md`,
        ...fs.readdirSync(path.join(root, docsRoot)).filter((name) => name.endsWith('.md'))
            .map((name) => `${docsRoot}${name}`),
    ]) {
        const text = fs.readFileSync(path.join(root, file), 'utf8');
        const lines = text.replace(/\\\r?\n/g, ' ').split(/\r?\n/);
        for (const line of lines) {
            if (/\b(?:deploy(?:-[\w-]+)?|build-images)\.sh\b|--stage\b/.test(line)) {
                assert.ok(!/--(?:check|apply)\b/.test(line), `${file}: obsolete Bash mode ${line}`);
                assert.ok(!/read-only check|只读 check/.test(line), `${file}: stale validation-only description`);
            }
            if (/--(?:check|apply)\b/.test(line) &&
                !/sandbox-deployment|implementation-report/.test(file)) {
                assert.match(line, /(?:ruff\s+format|node)\s+--check\b/,
                    `${file}: obsolete mode description ${line}`);
            }
        }
        assert.ok(!text.includes('check/apply'), file);
        for (const [, block] of text.matchAll(/```bash\n([\s\S]*?)```/g)) {
            const commands = [...block.matchAll(/^bash\s+(?:\.\.\/)?(deploy-database|deploy-aca|build-images)\.sh\b/gm)]
                .map((match) => match[1]);
            assert.equal(new Set(commands).size, commands.length,
                `${file}: repeated direct deployment in one example`);
        }
        if (file.startsWith(moduleRoot) && (!file.startsWith(docsRoot) || file.includes('cli-deployment'))) {
            assert.ok(text.includes('deploy.sh --migrate'), file);
        }
    }
    for (const file of ['deploy.sh', 'deploy-storage.sh', 'deploy-models.sh', 'deploy-database.sh',
        'build-images.sh', 'deploy-aca.sh']) {
        const script = fs.readFileSync(path.join(root, moduleRoot, file), 'utf8');
        assert.ok(!/--(?:check|apply)\b/.test(script), `${file}: obsolete deployment mode`);
    }
});
