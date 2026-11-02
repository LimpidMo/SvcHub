#!/usr/bin/env node
// 端到端冒烟测试（零依赖，需 Git Bash）：隔离沙盒 + 管理器通道 + 外部访问通道。
// 用法：node tools/smoke.js
//
// 所有用例共享一个沙盒，顺序固定，新增用例不要依赖前序状态：
//   页面/状态 → 设置 → 服务启停 → 服务配置 → 命令 → 外部通道 → 登录锁定 → disable
// 其中「服务启停」必须在「服务配置」之前（后者会替换示例服务）。
// 测试结束（含失败）会停桥、停沙盒服务、删临时沙盒根。
'use strict';

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const REPO = path.resolve(__dirname, '..');
const MOCK = path.join(REPO, 'tools', 'mock-server.js');
const NODE = process.execPath;

let pass = 0;
let fail = 0;
// 外部通道强制改密后的新密码（沙盒首次登录用 admin，随后立即改掉）
const EXT_PW = 'SmokePass123';

function ok(name, cond, detail) {
    if (cond) {
        pass++;
        console.log('PASS ' + name);
    } else {
        fail++;
        console.log('FAIL ' + name + (detail ? ': ' + detail : ''));
    }
}

function eq(name, expected, actual) {
    ok(name, expected === actual, 'expected ' + JSON.stringify(expected) + ' got ' + JSON.stringify(actual));
}

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function freePort() {
    return new Promise((resolve, reject) => {
        const srv = http.createServer();
        srv.on('error', reject);
        srv.listen(0, '127.0.0.1', () => {
            const p = srv.address().port;
            srv.close(() => resolve(p));
        });
    });
}

function request(url, opts) {
    opts = opts || {};
    return new Promise((resolve, reject) => {
        const u = new URL(url);
        // 显式长度：Node 对 write(body) 默认 chunked，busybox httpd 不认，CGI 会读不到 CONTENT_LENGTH
        const headers = Object.assign({}, opts.headers || {});
        if (opts.body !== undefined && headers['Content-Length'] === undefined) {
            headers['Content-Length'] = Buffer.byteLength(opts.body);
        }
        const req = http.request({
            hostname: u.hostname,
            port: u.port,
            path: u.pathname + u.search,
            method: opts.method || 'GET',
            headers,
            timeout: opts.timeout || 20000,
            // busybox httpd 的 CGI 头用裸 LF（真机正常），Node 严格解析器会拒收
            insecureHTTPParser: true,
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({
                status: res.statusCode,
                headers: res.headers,
                body: Buffer.concat(chunks).toString('utf8'),
            }));
        });
        req.on('timeout', () => req.destroy(new Error('timeout ' + url)));
        req.on('error', reject);
        if (opts.body !== undefined) req.write(opts.body);
        req.end();
    });
}

async function waitFor(fn, timeout, label) {
    const end = Date.now() + timeout;
    while (Date.now() < end) {
        try {
            if (await fn()) return true;
        } catch (e) { /* 继续等 */ }
        await sleep(200);
    }
    throw new Error('timeout waiting for ' + label);
}

async function waitPortClosed(port, timeout) {
    await waitFor(async () => {
        try {
            await request('http://127.0.0.1:' + port + '/', { timeout: 500 });
            return false;
        } catch (e) {
            return true;
        }
    }, timeout, 'bridge port close');
}

async function waitForBridge(base) {
    await waitFor(async () => (await request(base + '/')).status === 200, 30000, 'bridge');
}

function execRaw(bridgePort, cmd) {
    return request('http://127.0.0.1:' + bridgePort + '/__exec', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cmd }),
    }).then((r) => JSON.parse(r.body));
}

function execSub(bridgePort, sub, stdin) {
    let cmd = "sh '/x/action.sh' " + sub;
    if (stdin !== undefined) {
        const tag = 'SVCHUB_EOF_' + Math.random().toString(36).slice(2, 10);
        cmd += " <<'" + tag + "'\n" + stdin + "\n" + tag;
    }
    return execRaw(bridgePort, cmd);
}

async function execJson(bridgePort, sub, stdin) {
    const r = await execSub(bridgePort, sub, stdin);
    try {
        return JSON.parse(r.stdout);
    } catch (e) {
        return null;
    }
}

function kv(obj) {
    return Object.keys(obj).map((k) => k + '=' + Buffer.from(String(obj[k]), 'utf8').toString('base64')).join('\n');
}

function cookieFrom(res) {
    const list = res.headers['set-cookie'] || [];
    for (const c of list) {
        const m = /^SVC_SESS=([^;]+)/.exec(c);
        if (m) return m[1];
    }
    return '';
}

function parseJson(text) {
    try {
        return JSON.parse(text);
    } catch (e) {
        return null;
    }
}

async function startSandbox() {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'svchub-smoke-'));
    const bridgePort = await freePort();
    const webPort = await freePort();
    const child = spawn(NODE, [MOCK,
        '--sandbox-root', root,
        '--bridge-port', String(bridgePort),
        '--web-port', String(webPort)], { stdio: ['ignore', 'pipe', 'pipe'] });
    const ctx = {
        root,
        sandbox: path.join(root, 'modules', 'SvcHub'),
        bridgePort,
        webPort,
        base: 'http://127.0.0.1:' + bridgePort,
        ext: 'http://127.0.0.1:' + webPort,
        child,
        log: '',
    };
    child.stdout.on('data', (d) => { ctx.log += d; });
    child.stderr.on('data', (d) => { ctx.log += d; });
    try {
        await waitForBridge(ctx.base);
    } catch (e) {
        child.kill();
        throw e;
    }
    return ctx;
}

async function stopSandbox(ctx) {
    try { ctx.child.kill(); } catch (e) { /* 忽略 */ }
    try { await waitPortClosed(ctx.bridgePort, 5000); } catch (e) { /* 交给 stop 清理 */ }
    spawnSync(NODE, [MOCK, 'stop',
        '--sandbox-root', ctx.root,
        '--bridge-port', String(ctx.bridgePort)], { stdio: 'ignore' });
    // Windows 上进程退出后文件句柄可能短暂占用，重试删除
    for (let i = 0; i < 10; i++) {
        try {
            fs.rmSync(ctx.root, { recursive: true, force: true });
            return;
        } catch (e) {
            await sleep(200);
        }
    }
    console.log('WARN 临时沙盒未删除: ' + ctx.root);
}

async function testPageAndStatus(ctx) {
    const page = await request(ctx.base + '/');
    eq('page status', 200, page.status);
    ok('page injects ksu shim', page.body.includes('window.ksu'));

    await waitFor(async () => {
        const s = await execJson(ctx.bridgePort, 'status');
        return !!(s && s.termux_services.some((x) => x.name === 'demo-termux' && x.status === 'running'));
    }, 20000, 'supervisor patrol');

    const st = await execJson(ctx.bridgePort, 'status');
    ok('status json', !!st);
    ok('status boot_id', !!(st && st.boot_id));
    ok('status server_dir', !!(st && typeof st.server_dir === 'string'));
    ok('status service arrays', !!(st && Array.isArray(st.termux_services) && Array.isArray(st.binary_services)));
    ok('patrol started sample service', !!(st && st.termux_services.some((x) => x.name === 'demo-termux' && x.status === 'running')));
}

async function testSettings(ctx) {
    const gs = await execJson(ctx.bridgePort, 'getsettings');
    eq('getsettings key count', 20, gs ? Object.keys(gs).length : 0);
    ok('getsettings hides secrets', !!(gs && !('webui_password_hash' in gs) && !('webui_token' in gs)));
    eq('getsettings webui_enabled', '1', gs && gs.webui_enabled);
    const ws = await execJson(ctx.bridgePort, 'webuistatus');
    ok('webuistatus', !!(ws && ws.success === true && ws.enabled === '1' && typeof ws.port === 'number'), JSON.stringify(ws));
    ok('webuistatus must change', !!(ws && ws.must_change_password === true), JSON.stringify(ws));
    // 仍是默认密码：管理器通道开启外部访问被拒绝（外部已在运行，不受影响）
    const en = await execJson(ctx.bridgePort, 'webuistart');
    ok('enable blocked by default password', !!(en && en.success === false), JSON.stringify(en));

    // 值里故意放一行设置键名：验证不会被当成下一键的边界
    const boot = 'echo "a b"\nwifi_service_enabled=1\nprintf \'%s\\n\' x';
    let r = await execJson(ctx.bridgePort, 'savesettings', kv({ boot_commands: boot, sleep_interval: '600' }));
    ok('savesettings ok', !!(r && r.success === true), JSON.stringify(r));
    const gs2 = await execJson(ctx.bridgePort, 'getsettings');
    eq('boot_commands roundtrip', boot, gs2 && gs2.boot_commands);
    eq('next setting not shifted', '0', gs2 && gs2.wifi_service_enabled);
    eq('sleep_interval roundtrip', '600', gs2 && gs2.sleep_interval);

    const conf = fs.readFileSync(path.join(ctx.sandbox, 'config', 'setting.conf'), 'utf8');
    const bootLine = conf.split(/\r?\n/).find((l) => l.startsWith('boot_commands=')) || '';
    ok('boot_commands stored escaped', bootLine.indexOf('\\n') >= 0);
        eq('setting.conf key count', 23, conf.split(/\r?\n/).filter((l) => /^[a-z_]+=/.test(l)).length);

    let e = await execJson(ctx.bridgePort, 'savesettings', kv({ nope: 'x' }));
    ok('unknown key rejected', !!(e && e.success === false));
    e = await execJson(ctx.bridgePort, 'savesettings', kv({ sleep_interval: 'abc' }));
    ok('bad interval rejected', !!(e && e.success === false));
    e = await execJson(ctx.bridgePort, 'savesettings', kv({ schedule_enabled: '1', schedule_stop: '08:00', schedule_start: '08:00' }));
    ok('same schedule rejected', !!(e && e.success === false));
    e = await execJson(ctx.bridgePort, 'savesettings', kv({ wifi_service_names: 'bad name' }));
    ok('bad name list rejected', !!(e && e.success === false), JSON.stringify(e));
    const gs3 = await execJson(ctx.bridgePort, 'getsettings');
    eq('failed save not persisted', '600', gs3 && gs3.sleep_interval);

    r = await execJson(ctx.bridgePort, 'savesettings', kv({ language: 'en' }));
    ok('language switch to en', !!(r && r.success === true));
    e = await execJson(ctx.bridgePort, 'savesettings', kv({ nope: 'x' }));
    eq('english error text', 'Unknown config key', e && e.error);
    r = await execJson(ctx.bridgePort, 'savesettings', kv({ language: 'zh' }));
    ok('language restore to zh', !!(r && r.success === true));
}

async function testServiceLifecycle(ctx) {
    let r = await execJson(ctx.bridgePort, 'start termux termux-idle');
    ok('start service', !!(r && r.success === true), JSON.stringify(r));
    const pidf = path.join(ctx.sandbox, 'run', 'termux-idle.pid');
    const logf = path.join(ctx.sandbox, 'log', 'termux-idle.log');
    await waitFor(() => fs.existsSync(pidf), 5000, 'pid file');
    ok('pid file created', fs.existsSync(pidf));
    ok('service log created', fs.existsSync(logf));
    const st = await execJson(ctx.bridgePort, 'status');
    ok('status reports running', !!(st && st.termux_services.some((x) => x.name === 'termux-idle' && x.status === 'running')));
    r = await execJson(ctx.bridgePort, 'stop termux-idle');
    ok('stop service', !!(r && r.success === true));
    ok('pid file removed', !fs.existsSync(pidf));
    ok('service log removed', !fs.existsSync(logf));
}

async function testServicesConfig(ctx) {
    const termRows = 'svc-a|80|start|echo a|echo end | tee /dev/null\nsvc-b||stop|echo b|';
    let r = await execJson(ctx.bridgePort, 'saveservices', kv({ termux_services: termRows }));
    ok('saveservices ok', !!(r && r.success === true), JSON.stringify(r));
    const svcs = await execJson(ctx.bridgePort, 'getservices');
    eq('termux rows roundtrip', termRows, svcs && svcs.termux_services);
    ok('getservices has both kinds', !!(svcs && typeof svcs.termux_services === 'string' && typeof svcs.binary_services === 'string'));
    const svcFile = fs.readFileSync(path.join(ctx.sandbox, 'config', 'services.conf'), 'utf8');
    ok('services marker', svcFile.indexOf('# svc-v1.4.0') === 0);
    ok('end_cmd pipe kept', svcFile.indexOf('echo end | tee /dev/null') >= 0);
    const e = await execJson(ctx.bridgePort, 'saveservices', kv({ termux_services: 'bad name|80|start|echo x|' }));
    ok('invalid row rejected with line', !!(e && e.success === false && /第 1 行/.test(e.error)), JSON.stringify(e));
    eq('services file unchanged on reject', svcFile, fs.readFileSync(path.join(ctx.sandbox, 'config', 'services.conf'), 'utf8'));
}

async function testUpdates(ctx) {
    // 条目 CRUD：保存 → 读回 → 校验 → 删除
    const rows = 'memos|usememos/memos|memos_{ver}_linux_arm64.tar.gz|./memos/memos|file||v0.30.9|version|v0.31.0';
    let r = await execJson(ctx.bridgePort, 'saveupdates', kv({ update_entries: rows }));
    ok('saveupdates ok', !!(r && r.success === true), JSON.stringify(r));
    const gu = await execJson(ctx.bridgePort, 'getupdates');
    ok('getupdates returns items', !!(gu && gu.success === true && Array.isArray(gu.items) && gu.items.length === 1), JSON.stringify(gu));
    eq('update entry name', 'memos', gu && gu.items[0] && gu.items[0].name);
    eq('update entry repo', 'usememos/memos', gu && gu.items[0] && gu.items[0].repo);
    eq('update entry ins_ver', 'v0.30.9', gu && gu.items[0] && gu.items[0].ins_ver);
    eq('update entry vercmd', 'version', gu && gu.items[0] && gu.items[0].vercmd);
    eq('update entry update_ver', 'v0.31.0', gu && gu.items[0] && gu.items[0].update_ver);
    eq('update entry has_update persisted', true, gu && gu.items[0] && gu.items[0].has_update);
    const upConf = fs.readFileSync(path.join(ctx.sandbox, 'config', 'update.conf'), 'utf8');
    ok('update.conf written', upConf.indexOf('usememos/memos') >= 0);

    // 非法条目整单拒绝（repo 格式错）
    let e = await execJson(ctx.bridgePort, 'saveupdates', kv({ update_entries: 'bad|notarepo|f.zip|p|file||' }));
    ok('invalid update row rejected', !!(e && e.success === false && /第 1 行/.test(e.error)), JSON.stringify(e));
    eq('update file unchanged on reject', upConf, fs.readFileSync(path.join(ctx.sandbox, 'config', 'update.conf'), 'utf8'));

    // 关联不存在的二进制服务时拒绝
    e = await execJson(ctx.bridgePort, 'saveupdates', kv({ update_entries: 'm2|usememos/memos|f.zip|p|file|nosuchsvc|' }));
    ok('missing linked service rejected', !!(e && e.success === false && /不存在/.test(e.error)), JSON.stringify(e));

    // 版本查询命令含管道符：会被当分隔符切成 9 段，必须整单拒绝
    e = await execJson(ctx.bridgePort, 'saveupdates', kv({ update_entries: 'm3|usememos/memos|f.zip|p|file|||app --version | head -1' }));
    ok('vercmd pipe rejected', !!(e && e.success === false), JSON.stringify(e));

    // 未知键拒绝
    e = await execJson(ctx.bridgePort, 'saveupdates', kv({ nope: 'x' }));
    ok('unknown update key rejected', !!(e && e.success === false));

    // 检查周期校验
    let s = await execJson(ctx.bridgePort, 'savesettings', kv({ update_check_interval: '3600' }));
    ok('update_check_interval saved', !!(s && s.success === true), JSON.stringify(s));
    const gs = await execJson(ctx.bridgePort, 'getsettings');
    eq('update_check_interval value', '3600', gs && gs.update_check_interval);
    s = await execJson(ctx.bridgePort, 'savesettings', kv({ update_check_interval: '123' }));
    ok('bad interval rejected', !!(s && s.success === false));
    s = await execJson(ctx.bridgePort, 'savesettings', kv({ update_proxy_prefix: 'ftp://x' }));
    ok('bad proxy prefix rejected', !!(s && s.success === false));
    s = await execJson(ctx.bridgePort, 'savesettings', kv({ update_proxy_prefix: 'https://v4.gh-proxy.org' }));
    ok('proxy prefix saved', !!(s && s.success === true));
    // 末尾无 / 自动补
    const gs3 = await execJson(ctx.bridgePort, 'getsettings');
    eq('proxy prefix trailing slash', 'https://v4.gh-proxy.org/', gs3 && gs3.update_proxy_prefix);

    // 运行状态与停止：空闲时 running=false，无任务时 stop 拒绝
    let st = await execJson(ctx.bridgePort, 'updatestatus');
    ok('updatestatus idle', !!(st && st.success === true && st.running === false), JSON.stringify(st));
    st = await execJson(ctx.bridgePort, 'updatestop');
    ok('updatestop idle rejected', !!(st && st.success === false && /没有正在运行/.test(st.error)), JSON.stringify(st));

    // 更新子命令：条目名走 shell 参数（与前端 sq() 包裹同范式），不是 stdin
    let u = await execJson(ctx.bridgePort, "updateone 'nosuchentry'");
    ok('updateone unknown entry rejected', !!(u && u.success === false && /未找到/.test(u.error)), JSON.stringify(u));
    // 名称不合法（空参数）同样拒绝
    u = await execJson(ctx.bridgePort, 'updateone');
    ok('updateone empty name rejected', !!(u && u.success === false && /名称不合法/.test(u.error)), JSON.stringify(u));

    // 清空条目：空载荷应被接受（前端删光最后一条靠它清空）
    r = await execJson(ctx.bridgePort, 'saveupdates', kv({ update_entries: '' }));
    ok('saveupdates empty accepted', !!(r && r.success === true), JSON.stringify(r));
    const gu2 = await execJson(ctx.bridgePort, 'getupdates');
    eq('update entries cleared', 0, gu2 && gu2.items ? gu2.items.length : -1);

    // updateall 放在清空之后断言：避免冒烟环境对真实仓库触发 20MB 下载
    u = await execJson(ctx.bridgePort, 'updateall');
    ok('updateall accepted', !!(u && u.success === true), JSON.stringify(u));
}

async function testCommands(ctx) {
    let e = await execJson(ctx.bridgePort, 'runcmd', 'rm -rf /');
    ok('dangerous command blocked', !!(e && e.success === false && /拒绝执行/.test(e.error)), JSON.stringify(e));
    e = await execJson(ctx.bridgePort, 'runcmd', 'echo smoke-ok');
    ok('normal command runs', !!(e && e.success === true));
    const runLog = fs.readFileSync(path.join(ctx.sandbox, 'log', 'run_test.log'), 'utf8');
    ok('run command logged', runLog.indexOf('echo smoke-ok') >= 0);
}

async function testExternalAuth(ctx) {
    let res = await request(ctx.ext + '/cgi-bin/api.cgi?a=status');
    eq('ext status', 200, res.status);
    const statusJson = parseJson(res.body);
    ok('ext online', !!(statusJson && statusJson.online === true));

    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=getsettings');
    eq('ext unauth', 401, res.status);

    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=login', {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'password=wrong',
    });
    eq('ext wrong password', 401, res.status);

    // 默认密码 admin 登录：会话有效，但业务接口被门禁挡住
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=login', {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'password=admin',
    });
    eq('ext default login', 200, res.status);
    const sess = cookieFrom(res);
    ok('ext session cookie', !!sess);

    const hdr = { 'X-Requested-With': 'XMLHttpRequest', 'Cookie': 'SVC_SESS=' + sess };
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=whoami', { headers: hdr });
    eq('ext whoami', 200, res.status);
    const who = parseJson(res.body);
    ok('must change password flag', !!(who && who.must_change_password === true), res.body);
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=whoami', { headers: { 'Cookie': 'SVC_SESS=' + sess } });
    eq('ext csrf header required', 401, res.status);
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=getsettings', { headers: hdr });
    eq('ext business blocked before change', 403, res.status);

    // 强制改密：旧密码 admin 换新密码
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=webuipasswd', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest', 'Cookie': 'SVC_SESS=' + sess },
        body: 'password=' + encodeURIComponent(EXT_PW) + '&old=' + encodeURIComponent('admin'),
    });
    eq('ext forced change', 200, res.status);
    ok('ext forced change ok', !!(parseJson(res.body) && parseJson(res.body).success === true), res.body);

    // 改密清全部会话：旧 Cookie 失效，用新密码回登
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=whoami', { headers: hdr });
    eq('ext old session invalid', 401, res.status);
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=login', {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'password=' + encodeURIComponent(EXT_PW),
    });
    eq('ext login new password', 200, res.status);
    const sess2 = cookieFrom(res);
    ok('ext new session cookie', !!sess2);
    const hdr2 = { 'X-Requested-With': 'XMLHttpRequest', 'Cookie': 'SVC_SESS=' + sess2 };
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=whoami', { headers: hdr2 });
    const who2 = parseJson(res.body);
    ok('must change flag cleared', !!(who2 && who2.must_change_password === false), res.body);
    // 新密码不允许回设默认值（后端拒绝，前端预检只是 UX）
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=webuipasswd', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest', 'Cookie': 'SVC_SESS=' + sess2 },
        body: 'password=admin&old=' + encodeURIComponent(EXT_PW),
    });
    eq('ext re-set default rejected', 200, res.status);
    ok('ext re-set default blocked', !!(parseJson(res.body) && parseJson(res.body).success === false), res.body);
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=getsettings', { headers: hdr2 });
    eq('ext getsettings after change', 200, res.status);
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=savesettings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest', 'Cookie': 'SVC_SESS=' + sess2 },
        body: kv({ boot_commands: 'echo ext' }),
    });
    eq('ext savesettings', 200, res.status);
    const saveJson = parseJson(res.body);
    ok('ext savesettings ok', !!(saveJson && saveJson.success === true));
    const ws2 = await execJson(ctx.bridgePort, 'webuistatus');
    ok('manager sees flag cleared', !!(ws2 && ws2.must_change_password === false), JSON.stringify(ws2));
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=logout', { headers: hdr2 });
    eq('ext logout', 200, res.status);
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=whoami', { headers: hdr2 });
    eq('ext logged out', 401, res.status);
}

function clearFailFiles(ctx) {
    const runDir = path.join(ctx.sandbox, 'run');
    for (const f of fs.readdirSync(runDir)) {
        if (f.indexOf('webui_fail_') === 0) fs.rmSync(path.join(runDir, f), { force: true });
    }
}

async function testLoginLock(ctx) {
    clearFailFiles(ctx);
    let res;
    for (let i = 1; i <= 5; i++) {
        res = await request(ctx.ext + '/cgi-bin/api.cgi?a=login', {
            method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'password=bad',
        });
        eq('lock: attempt ' + i + ' is 401', 401, res.status);
    }
    res = await request(ctx.ext + '/cgi-bin/api.cgi?a=login', {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'password=bad',
    });
    eq('lock: 6th attempt is 429', 429, res.status);
    ok('lock: Retry-After present', !!res.headers['retry-after']);
    clearFailFiles(ctx);
}

async function testDisable(ctx) {
    await execJson(ctx.bridgePort, 'stop supervisor');
    fs.writeFileSync(path.join(ctx.sandbox, 'disable'), '');
    await execRaw(ctx.bridgePort, 'sh service.sh');
    const pidf = path.join(ctx.sandbox, 'run', 'supervisor.pid');
    await waitFor(() => !fs.existsSync(pidf), 2000, 'supervisor pid removed');
    ok('disable skips supervisor', !fs.existsSync(pidf));
    fs.rmSync(path.join(ctx.sandbox, 'disable'), { force: true });
}

async function main() {
    let ctx = null;
    try {
        ctx = await startSandbox();
        // 顺序固定（见文件头）：启停用例必须在服务配置用例之前。
        await testPageAndStatus(ctx);
        await testSettings(ctx);
        await testServiceLifecycle(ctx);
        await testServicesConfig(ctx);
        await testUpdates(ctx);
        await testCommands(ctx);
        await testExternalAuth(ctx);
        await testLoginLock(ctx);
        await testDisable(ctx);
    } catch (err) {
        fail++;
        console.log('FAIL smoke: ' + err.message);
        if (ctx && ctx.log) console.log(ctx.log.slice(-4000));
    } finally {
        if (ctx) await stopSandbox(ctx);
        console.log('\nPASS ' + pass + ' / FAIL ' + fail);
        process.exit(fail ? 1 : 0);
    }
}

main();
