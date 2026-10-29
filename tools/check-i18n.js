#!/usr/bin/env node
// 双语文案一致性检查（零依赖）：
//   1. 所有 ui_msg / inst_msg 中文字面量都能在对应英文表找到精确标签
//   2. 前端 TEXTS.zh / TEXTS.en 键集合完全相等
//   3. HTML data-i18n / data-i18n-attr / t('key') 用到的键都存在于 TEXTS.zh
// 未引用的英文标签只告警，不失败。
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
let errors = 0;
let warnings = 0;

function err(msg) {
    errors++;
    console.log('FAIL ' + msg);
}

function warn(msg) {
    warnings++;
    console.log('WARN ' + msg);
}

function read(rel) {
    return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

function lineOf(text, index) {
    return text.slice(0, index).split('\n').length;
}

// ---------- 后端文案 ----------
const shellFiles = [
    'action.sh', 'service.sh', 'supervisor.sh', 'httpd.sh', 'uninstall.sh',
    'lib.sh', 'customize.sh', 'webroot/cgi-bin/api.cgi',
];
for (const f of fs.readdirSync(path.join(ROOT, 'lib')).sort()) {
    if (f.endsWith('.sh')) shellFiles.push('lib/' + f);
}

const callRe = /\b(ui_msg|inst_msg|json_fail)\s+'((?:[^'\\]|\\.)*)'/g;
const usedUi = new Map();
const usedInst = new Map();

function addUsed(map, key, loc) {
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(loc);
}

for (const rel of shellFiles) {
    const text = read(rel);
    let m;
    callRe.lastIndex = 0;
    while ((m = callRe.exec(text)) !== null) {
        addUsed(m[1] === 'inst_msg' ? usedInst : usedUi, m[2], rel + ':' + lineOf(text, m.index));
    }
    // 无引号的中文实参（如 ui_msg 未登录）；跳过注释行与 lib/i18n.sh 自身
    if (rel !== 'lib/i18n.sh') {
        text.split('\n').forEach((line, i) => {
            if (/^\s*#/.test(line)) return;
            const re = /\bui_msg\s+([^\s'"$();{}]+)/g;
            let u;
            while ((u = re.exec(line)) !== null) {
                if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(u[1])) continue; // 变量名，不是文案
                addUsed(usedUi, u[1], rel + ':' + (i + 1));
            }
            // 文案经参数传给封装函数（末参数为单引号字面量）
            const carrier = /\bapply_name_list\s+[^\n]*?'((?:[^'\\]|\\.)*)'/g;
            let c;
            while ((c = carrier.exec(line)) !== null) {
                addUsed(usedUi, c[1], rel + ':' + (i + 1));
            }
        });
    }
}

const i18n = read('lib/i18n.sh');
const enLabels = new Set();
for (const m of i18n.matchAll(/^\s*'((?:[^'\\]|\\.)*)'\)\s+printf/gm)) enLabels.add(m[1]);

const inst = read('customize.sh');
const instLabels = new Set();
for (const m of inst.matchAll(/^\s*'((?:[^'\\]|\\.)*)'\)\s+_im_out=/gm)) instLabels.add(m[1]);

for (const [key, locs] of usedUi) {
    if (!enLabels.has(key)) err('ui_msg 缺英文条目: ' + JSON.stringify(key) + ' @ ' + locs[0]);
}
for (const [key, locs] of usedInst) {
    if (!instLabels.has(key)) err('inst_msg 缺英文条目: ' + JSON.stringify(key) + ' @ ' + locs[0]);
}
for (const key of enLabels) {
    if (!usedUi.has(key)) warn('英文条目未被引用: ' + JSON.stringify(key));
}
for (const key of instLabels) {
    if (!usedInst.has(key)) warn('安装期英文条目未被引用: ' + JSON.stringify(key));
}

// ---------- 前端文案 ----------
const html = read('webroot/index.html');

// 从 const TEXTS = 起按字符串/转义规则找配对花括号，取出对象字面量
function extractObject(text, marker) {
    const at = text.indexOf(marker);
    if (at < 0) return '';
    const open = text.indexOf('{', at);
    if (open < 0) return '';
    let depth = 0;
    let quote = '';
    let escaped = false;
    for (let i = open; i < text.length; i++) {
        const c = text[i];
        if (quote) {
            if (escaped) escaped = false;
            else if (c === '\\') escaped = true;
            else if (c === quote) quote = '';
            continue;
        }
        if (c === "'" || c === '"' || c === '`') { quote = c; continue; }
        if (c === '{') depth++;
        else if (c === '}') {
            depth--;
            if (depth === 0) return text.slice(open, i + 1);
        }
    }
    return '';
}

const objText = extractObject(html, 'const TEXTS = ');
if (!objText) {
    err('未找到 TEXTS 对象');
} else {
    let TEXTS;
    try {
        TEXTS = new Function('return (' + objText + ')')();
    } catch (e) {
        err('TEXTS 解析失败: ' + e.message);
    }
    if (TEXTS) {
        const zh = new Set(Object.keys(TEXTS.zh || {}));
        const en = new Set(Object.keys(TEXTS.en || {}));
        for (const k of zh) if (!en.has(k)) err('TEXTS.en 缺键: ' + k);
        for (const k of en) if (!zh.has(k)) err('TEXTS.zh 缺键: ' + k);

        const usedKeys = new Map();
        function addKey(key, line) {
            if (!usedKeys.has(key)) usedKeys.set(key, []);
            usedKeys.get(key).push(line);
        }
        for (const m of html.matchAll(/data-i18n="([^"]+)"/g)) {
            addKey(m[1], 'data-i18n@' + lineOf(html, m.index));
        }
        for (const m of html.matchAll(/data-i18n-attr="([^"]+)"/g)) {
            for (const part of m[1].split(/\s+/)) {
                const idx = part.indexOf(':');
                if (idx >= 0) addKey(part.slice(idx + 1), 'data-i18n-attr@' + lineOf(html, m.index));
            }
        }
        for (const m of html.matchAll(/\bt\(\s*'([^']+)'/g)) {
            addKey(m[1], 't()@' + lineOf(html, m.index));
        }
        for (const [key, locs] of usedKeys) {
            if (!zh.has(key)) err('前端文案键不存在: ' + key + ' @ ' + locs[0]);
        }
    }
}

console.log(`i18n check: ${errors} error(s), ${warnings} warning(s)`);
process.exit(errors ? 1 : 0);
