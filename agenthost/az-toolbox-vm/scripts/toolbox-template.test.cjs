const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8').replace(/\r\n/g, '\n');
const cloudInit = read('cloud-init.yaml');
const bicep = read('main.bicep');
const arm = JSON.parse(read('main.json'));
const ui = JSON.parse(read('uiFormDefinition.json')).view;
const bash = process.env.BASH || 'bash';

function scriptAt(filePath) {
  const section = cloudInit.split(`  - path: ${filePath}\n`)[1];
  assert.ok(section, `Missing cloud-init file ${filePath}`);
  const content = section.split('    content: |\n')[1];
  assert.ok(content, `Missing inline content for ${filePath}`);
  const lines = [];
  for (const line of content.split('\n')) {
    if (line && !line.startsWith('      ')) break;
    lines.push(line.slice(6));
  }
  return lines.join('\n');
}

const installer = scriptAt('/usr/local/sbin/install-toolbox.sh');
const verifier = read('scripts/verify-tools.sh');

function runShell(input, syntaxOnly = false) {
  const result = spawnSync(bash, [syntaxOnly ? '-n' : '-s'], {
    input, encoding: 'utf8', timeout: 15000,
  });
  assert.ifError(result.error);
  return result;
}

test('all embedded Bash scripts and the existing verifier parse', () => {
  for (const script of [installer, verifier, read('scripts/verify-tools.sh')]) {
    const result = runShell(script, true);
    assert.equal(result.status, 0, result.stderr);
  }
});

test('compiled ARM embeds current cloud-init and shared verifier', () => {
  assert.ok(Object.values(arm.variables).some((value) => value === cloudInit));
  assert.ok(Object.values(arm.variables).some((value) => value === read('scripts/verify-tools.sh')));
  assert.doesNotMatch(JSON.stringify(arm), /installPython|__INSTALL_PYTHON__|verify-module06-tools/);
});

test('ARM, Bicep and Portal parameter names agree without a Python option', () => {
  const parameters = [...bicep.matchAll(/^param (\w+) /gm)].map((match) => match[1]).sort();
  assert.deepEqual(Object.keys(arm.parameters).sort(), parameters);
  assert.deepEqual(Object.keys(ui.outputs.parameters).sort(), parameters);
  assert.doesNotMatch(bicep + JSON.stringify(ui), /installPython/);
  const controls = ui.properties.steps.flatMap((step) => step.elements);
  for (const control of controls) {
    if (!arm.parameters[control.name] || control.defaultValue === undefined) continue;
    const options = control.constraints?.allowedValues;
    const defaultValue = Array.isArray(options)
      ? options.find((option) => option.label === control.defaultValue).value
      : control.defaultValue;
    assert.equal(defaultValue, arm.parameters[control.name].defaultValue, control.name);
  }
});

test('VM resource footprint and secure credentials remain unchanged', () => {
  assert.deepEqual(arm.resources.map((resource) => resource.type).sort(), [
    'Microsoft.Compute/virtualMachines',
    'Microsoft.Network/networkInterfaces',
    'Microsoft.Network/networkSecurityGroups',
    'Microsoft.Network/publicIPAddresses',
    'Microsoft.Network/virtualNetworks',
  ]);
  assert.equal(arm.parameters.adminPassword.type.toLowerCase(), 'securestring');
  assert.doesNotMatch(cloudInit, /adminPassword|__.*PASSWORD.*BASE64__/);
  assert.equal(arm.parameters.authenticationType.defaultValue, 'sshPublicKey');
  assert.doesNotMatch(installer, /\baz login\b|\baca auth login\b|\baz acr build\b|\bdocker\b/);
  assert.match(installer, /as_admin az bicep install --version v0\.48\.1/);
  assert.match(installer, /https:\/\/aka\.ms\/aca-cli-install/);
  assert.match(installer, /INSTALL_DIR=\/usr\/local\/bin sh "\$\{INSTALLER_DIR\}\/aca\.sh"/);
});

test('one unified admin-user verifier gates success and Python tooling is not installed', () => {
  const shared = installer.indexOf('as_admin /usr/local/bin/verify-tools.sh');
  const marker = installer.indexOf('touch /var/lib/toolbox-install-complete');
  assert.ok(shared > 0 && marker > shared);
  assert.match(installer, /set -euo pipefail/);
  assert.doesNotMatch(cloudInit + verifier, /python|verify-module06-tools/i);
  assert.doesNotMatch(cloudInit.split('write_files:')[0], /python|docker/);
  for (const name of ['bash', 'openssl', 'coreutils', 'tar', 'jq', 'curl']) {
    assert.ok(cloudInit.includes(`  - ${name}\n`), name);
  }
});

function verifyWith(options = {}) {
  const settings = {
    bicep: '0.48.1', aca: '1.0.0-preview.5', az: '2.85.0',
    foundry: 'microsoft.foundry', aks: '--workload-runtime', containerapp: '1.3.0b4',
    missing: '', timeout: 'timeout (GNU coreutils) 9.4',
    ...options,
  };
  // Functions replace every external operation; tests never install, authenticate or call Azure.
  const setup = `
    bash() { printf '%s\\n' 'GNU bash'; }
    az() {
      case "$*" in
        'bicep version') printf '%s\\n' 'Bicep CLI version ${settings.bicep} (test)' ;;
        'acr build --help') : ;;
        'version --output json') echo '{}' ;;
        'aks create --help') echo '${settings.aks}' ;;
        'extension list --output table') : ;;
        'extension show --name containerapp --query version --output tsv') echo '${settings.containerapp}' ;;
        *) echo "Unexpected az call: $*" >&2; return 90 ;;
      esac
    }
    aca() {
      case "$*" in
        --version) printf '%s\\n' 'aca ${settings.aca}' ;;
        'sandbox --help'|'sandboxgroup --help') : ;;
        *) echo "Unexpected aca call: $*" >&2; return 91 ;;
      esac
    }
    jq() { if [[ "$1" == '-er' ]]; then echo '${settings.az}'; fi; }
    git() { :; }
    azd() {
      case "$*" in
        version) : ;;
        'ext list --installed --no-prompt') echo '${settings.foundry}' ;;
        *) echo "Unexpected azd call: $*" >&2; return 92 ;;
      esac
    }
    kubectl() { :; }
    curl() { :; }
    openssl() { :; }
    timeout() { printf '%s\\n' '${settings.timeout}'; }
    dpkg() {
      printf 'COMPARE %s %s %s\\n' "$2" "$3" "$4"
      case "$2:$4" in
        '2.79.0:2.80.0'|'0.48.0:0.48.1'|'1.0.0~preview.4:1.0.0~preview.5') return 1 ;;
        *) return 0 ;;
      esac
    }
    command() {
      if [[ "$1" == '-v' && "$2" == '${settings.missing}' ]]; then return 1; fi
      builtin command "$@"
    }
  `;
  return runShell(`${setup}\n${verifier}`);
}

test('unified verification covers all module tools without Python or cloud calls', () => {
  const result = verifyWith({ missing: 'python3' });
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stdout, /PYTHON_CHECK/);
  assert.match(result.stdout, /COMPARE 1\.0\.0~preview\.5 ge 1\.0\.0~preview\.5/);
  for (const heading of ['Azure CLI', 'Git', 'curl', 'jq', 'Azure Developer CLI',
    'Foundry azd Extensions', 'kubectl', 'AKS Pod Sandboxing CLI capability', 'Azure CLI Extensions',
    'Bash', 'OpenSSL', 'GNU timeout', 'Bicep', 'Independent ACA CLI']) {
    assert.ok(result.stdout.includes(`=== ${heading} ===`), heading);
  }
  assert.match(result.stdout, /All required toolbox checks passed/);
});

for (const [name, options, message] of [
  ['missing aca', { missing: 'aca' }, /not in PATH/],
  ['old Bicep', { bicep: '0.48.0' }, /requires Bicep/],
  ['unparseable Bicep', { bicep: 'invalid' }, /could not parse/],
  ['old ACA preview', { aca: '1.0.0-preview.4' }, /requires the independent aca CLI/],
  ['unparseable ACA', { aca: 'invalid' }, /could not parse/],
  ['non-GNU timeout', { timeout: 'BusyBox timeout' }, /GNU timeout/],
  ['missing azd', { missing: 'azd' }, /not in PATH/],
  ['missing kubectl', { missing: 'kubectl' }, /not in PATH/],
  ['old Azure CLI', { az: '2.79.0' }, /older than required/],
  ['missing Foundry extension', { foundry: '' }, /microsoft.foundry is not installed/],
  ['missing AKS capability', { aks: '' }, /--workload-runtime option/],
  ['missing Container Apps extension', { containerapp: '' }, /no installed version/],
]) {
  test(`unified verification fails explicitly for ${name}`, () => {
    const result = verifyWith(options);
    assert.notEqual(result.status, 0, result.stdout);
    assert.match(result.stderr, message);
    assert.doesNotMatch(result.stdout, /All required toolbox checks passed/);
  });
}

test('stable and newer preview ACA versions are parsed without losing prerelease ordering', () => {
  for (const version of ['1.0.0', '1.0.0-preview.6', '1.1.0+build.1']) {
    const result = verifyWith({ aca: version });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /COMPARE 1\./);
  }
});

test('English and Chinese examples and new defaults remain synchronized', () => {
  const english = read('README.md');
  const chinese = read('README_CN.md');
  const fences = (text) => [...text.matchAll(/```([^\n]*)\n([\s\S]*?)```/g)]
    .filter((match) => match[1] !== 'text')
    .map((match) => [match[1], match[2]]);
  assert.deepEqual(fences(english), fences(chinese));
  for (const text of [english, chinese]) {
    for (const token of [
      'az bicep install --version v0.48.1',
      '1.0.0-preview.5', '/usr/local/bin/verify-tools.sh',
    ]) assert.ok(text.includes(token), token);
    assert.doesNotMatch(text, /installPython|verify-module06-tools/);
  }
});
