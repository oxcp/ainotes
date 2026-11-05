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
    for (const [, target] of [moduleLink, ...nav.module06Navigation.links]) {
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

test('Chinese sidebar exposes all thirteen Module 06 resources and selects the exact Agent', () => {
    const current = `${sourceRoot}rag_agent/README_CN.md`;
    const nav = load(current);
    nav.configureSidebar();
    const links = nav.links.children.filter((child) => child.dataset.file);
    assert.equal(nav.module06Navigation.links.length, 13);
    for (const [, target] of nav.module06Navigation.links) {
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

test('Web Slides appears only within its own category, not for unmatched documents', () => {
    const nav = load('web-slides/README.md');
    nav.configureSidebar();
    assert.equal(nav.title.textContent, 'Web Slides');
    const targets = nav.links.children.filter((child) => child.dataset.file)
        .map((child) => child.dataset.file);
    assert.ok(targets.length > 0);
    assert.ok(targets.every((target) => target.startsWith('web-slides/')));
    for (const file of ['README.md', 'unknown/guide.md']) {
        const unmatched = load(file);
        unmatched.configureSidebar();
        assert.equal(unmatched.links.children.length, 0);
        assert.notEqual(unmatched.sidebar.hidden, false);
    }
});

test('consolidated guides match structure, commands and table sizes with valid relative links', () => {
    const docs = ['readme.md', 'readme_CN.md'].map((name) =>
        fs.readFileSync(path.join(root, moduleRoot, name), 'utf8').replace(/\r/g, ''));
    const blocks = (text) => [...text.matchAll(/```([^\n]*)\n([\s\S]*?)```/g)]
        .map((match) => [match[1], match[2]]);
    assert.deepEqual(blocks(docs[0]), blocks(docs[1]));
    const headingLevels = (text) => [...text.matchAll(/^(#+) /gm)].map((match) => match[1]);
    assert.deepEqual(headingLevels(docs[0]), headingLevels(docs[1]));
    const tableRows = (text) => text.split('\n').filter((line) => line.startsWith('|')).length;
    assert.equal(tableRows(docs[0]), tableRows(docs[1]));
    for (const text of docs) {
        assert.equal((text.match(/^## (?:Step|步骤) \d/gm) ?? []).length, 8);
        for (const [, link] of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
            if (/^[a-z]+:/i.test(link)) continue;
            const [relative, anchor] = link.split('#');
            const target = path.resolve(root, moduleRoot, relative);
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
            const selected = nav.links.children.filter((child) => child.attributes['aria-current'] === 'page');
            assert.deepEqual(selected.map((child) => child.dataset.file), [current]);
            const targets = nav.title.following.children.map((option) =>
                new URL(option.href, 'https://example.test/').searchParams.get('file'));
            assert.deepEqual(targets, [english, chinese]);
            const docs = nav.links.children.filter((child) => child.dataset.file?.startsWith(docsRoot));
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
