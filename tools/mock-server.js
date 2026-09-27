// SvcHub WebUI 电脑联调桥（Node 内置模块，零依赖）。
//
// 用法：
//   node tools/mock-server.js          # 正常联调（固定沙盒，config/ 不覆盖）
//   node tools/mock-server.js reflash  # 沙盒在跑→热更新文件；不在跑→完整启动（可带 --wifi on --ssid Home）
//   node tools/mock-server.js stop     # 停桥 + 停全部沙盒服务（同 Ctrl+C 清理）
//   node tools/mock-server.js reset    # 恢复出厂（删 config/run/log 重建示例）
//   联调页 http://127.0.0.1:8090；Ctrl+C 退出保留 config 复用，仓库真 config（含密钥）碰不到。
//   Wi-Fi 模拟：curl "http://127.0.0.1:8090/__wifi?state=on&ssid=Home"
//   屏幕/锁屏模拟：curl "http://127.0.0.1:8090/__screen?screen=off&lock=unlock"（screen=on/off，lock=lock/unlock）
//
// 原理：GET / 下发 index.html 并注入 ksu 垫片（同步 XHR → POST /__exec → bash 真执行）；
//   action.sh 子命令按 WHITE 白名单放行，runcmd 走假 su 真执行，execboot/open 拒绝；
//   沙盒固定 .mock-sandbox/modules/SvcHub，每次启动覆盖拷贝脚本，fakebin 垫片绕开 PC 无 su；
//   改 supervisor/service.sh 逻辑热更新不覆盖，需先 stop 再启动。
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFile, execFileSync } = require('child_process');

const PORT = 8090;
const REPO = path.resolve(__dirname, '..');
const WHITE = new Set(['status', 'getconfig', 'getsettings', 'getservices', 'saveconfig', 'savesettings', 'saveservices', 'readlog', 'logs', 'start', 'stop', 'clearlog', 'runcmd', 'runcmdtermux', 'webuistart', 'webuistop', 'webuistatus', 'webuipasswd', 'webuiregen', 'webuitoken']);
const OUT_MAX = 512 * 1024;

// 定位本机 Git Bash（找不到回退 PATH）
function findBash() {
    const cands = [
        'D:\\Git\\usr\\bin\\bash.exe',
        'C:\\Program Files\\Git\\usr\\bin\\bash.exe',
        'C:\\Program Files\\Git\\bin\\bash.exe',
    ];
    for (const c of cands) {
        if (fs.existsSync(c)) return c;
    }
    return 'bash';
}
const BASH = findBash();

// ---- 固定沙盒：<repo>/.mock-sandbox/modules/SvcHub ----
const sandboxRoot = path.join(REPO, '.mock-sandbox');
const sandbox = path.join(sandboxRoot, 'modules', 'SvcHub');
const fakebin = path.join(sandbox, 'fakebin');

// Wi-Fi 模拟态文件：行1 on/off，行2 SSID，lib.sh 在 SVCHUB_MOCK=1 时直读
const mockWifiFile = path.join(sandbox, 'mock_wifi');

// 写 Wi-Fi 模拟态，参数缺省保留原值
function setMockWifi(state, ssid) {
    let cur = ['off', 'Home'];
    try { cur = fs.readFileSync(mockWifiFile, 'utf8').split('\n'); } catch (e) { /* 用默认 */ }
    const st = state !== undefined ? state.trim() : (cur[0] || '').trim();
    const sd = ssid !== undefined ? ssid.trim() : (cur[1] || '').trim();
    fs.writeFileSync(mockWifiFile, (st || 'off') + '\n' + sd + '\n');
}

// 命令行 --wifi/--ssid 写模拟态（冷热启动均生效）
function applyWifiArgs() {
    const a = process.argv.slice(2);
    const i = a.indexOf('--wifi'), j = a.indexOf('--ssid');
    const st = i >= 0 && a[i + 1] && !a[i + 1].startsWith('--') ? a[i + 1] : undefined;
    const sd = j >= 0 && a[j + 1] && !a[j + 1].startsWith('--') ? a[j + 1] : undefined;
    if (st !== undefined || sd !== undefined) setMockWifi(st, sd);
}

// 屏幕/锁屏模拟态文件：行1 on/off（屏幕），行2 lock/unlock（锁屏），lib.sh 在 SVCHUB_MOCK=1 时直读
const mockScreenFile = path.join(sandbox, 'mock_screen');

// 写屏幕/锁屏模拟态，参数缺省保留原值；默认亮屏未锁（文件不存在等同此态）
function setMockScreen(screen, lock) {
    let cur = ['on', 'unlock'];
    try { cur = fs.readFileSync(mockScreenFile, 'utf8').split('\n'); } catch (e) { /* 用默认 */ }
    const sc = screen !== undefined ? screen.trim() : (cur[0] || '').trim();
    const lk = lock !== undefined ? lock.trim() : (cur[1] || '').trim();
    fs.writeFileSync(mockScreenFile, (sc || 'on') + '\n' + (lk || 'unlock') + '\n');
}

// 覆盖拷贝脚本、页面与配置模板到沙盒
function copyScripts() {
    fs.mkdirSync(path.join(sandbox, 'log'), { recursive: true });
    fs.mkdirSync(path.join(sandbox, 'run'), { recursive: true });
    fs.mkdirSync(path.join(sandbox, 'config'), { recursive: true });
    fs.mkdirSync(path.join(sandbox, 'webroot', 'cgi-bin'), { recursive: true });
    fs.mkdirSync(path.join(sandbox, 'run', 'session'), { recursive: true });
    for (const f of ['action.sh', 'service.sh', 'supervisor.sh', 'customize.sh', 'uninstall.sh', 'httpd.sh']) {
        fs.copyFileSync(path.join(REPO, f), path.join(sandbox, f));
    }
    fs.copyFileSync(path.join(REPO, 'lib.sh'), path.join(sandbox, 'lib.sh'));
    fs.copyFileSync(path.join(REPO, 'config', 'web.conf'), path.join(sandbox, 'config', 'web.conf'));
    fs.copyFileSync(path.join(REPO, 'webroot', 'index.html'), path.join(sandbox, 'webroot', 'index.html'));
    fs.copyFileSync(path.join(REPO, 'webroot', 'cgi-bin', 'api.cgi'), path.join(sandbox, 'webroot', 'cgi-bin', 'api.cgi'));
}

// 生成 fakebin 垫片：假 su/dumpsys/getprop/setsid
function writeFakebin() {
    fs.mkdirSync(fakebin, { recursive: true });
    // 假 su：取 -c 后 exec 替换为目标命令（不套 sh -c，否则 pid 错位对不上 pid 文件）
    fs.writeFileSync(path.join(fakebin, 'su'),
        '#!/bin/sh\n' +
        'while [ $# -gt 0 ]; do case "$1" in -c) shift; exec sh -c "$1";; *) shift;; esac; done\n' +
        'exec sh -c "$0"\n');
    // 假 dumpsys：恒报 Wi-Fi 断开（策略 block 可测）
    fs.writeFileSync(path.join(fakebin, 'dumpsys'), '#!/bin/sh\necho "no wifi in mock"\nexit 0\n');
    fs.writeFileSync(path.join(fakebin, 'getprop'), '#!/bin/sh\nexit 0\n');
    // 假 setsid：Git Bash 无 setsid，exec 同进程替换，pid 文件记的就是服务进程本身
    fs.writeFileSync(path.join(fakebin, 'setsid'), '#!/bin/sh\nexec "$@"\n');
}

// 首次运行写演示配置（循环打日志的 demo 服务，覆盖 start/stop/端口/extra 形态），已有则保留
function writeSampleConfig() {
    const setting = path.join(sandbox, 'config', 'setting.conf');
    const services = path.join(sandbox, 'config', 'services.conf');
    if (fs.existsSync(setting) || fs.existsSync(services)) return false;
    const demoCmd = (tag) => 'i=0; while [ $i -lt 200 ]; do echo "' + tag + ' tick $i"; sleep 3; i=$((i+1)); done';
    const escJs = (s) => s.replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/\t/g, '\\t');
    const settingLines = [
        'sleep_interval=60',
        'server_dir=.',
        'boot_commands=' + escJs('echo boot'),
        'wifi_service_enabled=0',
        'wifi_service_names=',
        'wifi_service_names_off=',
        'wifi_ssids=',
        'schedule_enabled=0',
        'schedule_stop=',
        'schedule_start=',
        'webui_enabled=1',
        'webui_password_hash=',
        'webui_token=',
    ];
    fs.writeFileSync(setting, settingLines.join('\n') + '\n');
    const svcLines = [
        'termux|demo-termux|8080||start|' + demoCmd('demo-termux'),
        'termux|termux-web|3000|-g 3003|start|' + demoCmd('termux-web'),
        'termux|termux-idle|||stop|' + demoCmd('termux-idle'),
        'termux|termux-db|5432|-g 3003|stop|' + demoCmd('termux-db'),
        '# binary',
        'binary|demo-bin|9090||start|' + demoCmd('demo-bin'),
        'binary|bin-api|9000||start|' + demoCmd('bin-api'),
        'binary|bin-worker|||stop|' + demoCmd('bin-worker'),
        'binary|bin-cron|9100||stop|' + demoCmd('bin-cron'),
    ];
    fs.writeFileSync(services, svcLines.join('\n') + '\n');
    return true;
}

// reset：删配置与运行数据后重建（copyScripts + 示例配置）
function factoryReset() {
    for (const f of [path.join('config', 'setting.conf'), path.join('config', 'services.conf')]) {
        try { fs.rmSync(path.join(sandbox, f), { force: true }); } catch (e) { /* 忽略 */ }
    }
    for (const d of ['run', 'log']) {
        try { fs.rmSync(path.join(sandbox, d), { recursive: true, force: true }); } catch (e) { /* 忽略 */ }
    }
    copyScripts();
    writeFakebin();
    writeSampleConfig();
    console.log('沙盒已恢复出厂');
}

// ---- 启动初始化 ----
if (process.argv[2] === 'reset') {
    factoryReset();
    process.exit(0);
}

// 杀残留联调桥：bridge.pid 优先，无记录按端口 8090 PowerShell 反查兜底
function killStaleBridge() {
    let pid = 0;
    try {
        pid = parseInt(fs.readFileSync(path.join(sandboxRoot, 'bridge.pid'), 'utf8').trim(), 10);
    } catch (e) { /* 无记录 */ }
    if (!(pid > 1 && pid !== process.pid)) {
        try {
            const out = execFileSync('powershell', ['-NoProfile', '-Command',
                '(Get-NetTCPConnection -LocalPort ' + PORT + ' -State Listen -ErrorAction SilentlyContinue).OwningProcess'
            ], { timeout: 8000 }).toString().trim();
            if (out) pid = parseInt(out.split('\n')[0].trim(), 10);
        } catch (e) { /* powershell 不可用 */ }
    }
    if (pid > 1 && pid !== process.pid) {
        try {
            execFileSync('taskkill', ['/F', '/PID', String(pid)], { timeout: 5000 });
            console.log('已停止旧桥（pid=' + pid + '）');
        } catch (e) { console.log('旧桥进程已不在'); }
    } else {
        console.log('未发现运行中的桥');
    }
    try { fs.rmSync(path.join(sandboxRoot, 'bridge.pid'), { force: true }); } catch (e) { /* 忽略 */ }
}

// 桥进程是否存活（bridge.pid 存 Windows pid，同域 process.kill(pid,0) 可验）
function bridgeAlive() {
    try {
        const pid = parseInt(fs.readFileSync(path.join(sandboxRoot, 'bridge.pid'), 'utf8').trim(), 10);
        if (pid > 1 && pid !== process.pid) { process.kill(pid, 0); return true; }
    } catch (e) { /* 无记录或已死 */ }
    return false;
}

// reflash：桥活着→热更新（只覆盖文件）；桥不在→杀旧桥走完整冷启动，config 保留
let hotReflash = false;
if (process.argv[2] === 'reflash') {
    hotReflash = bridgeAlive();
    if (!hotReflash) killStaleBridge();
}
// stop：停桥 + 停 supervisor/服务/pid/log（stopAll 与 Ctrl+C 同一逻辑）
if (process.argv[2] === 'stop') {
    killStaleBridge();
    stopAll();
    console.log('已停止 supervisor 与各服务，沙盒保留供下次复用：' + sandboxRoot);
    process.exit(0);
}
copyScripts();
writeFakebin();
const created = writeSampleConfig();
applyWifiArgs();
console.log(created ? '沙盒初始化：已生成示例 config/setting.conf + config/services.conf' : '沙盒复用：保留已有 config/');
if (hotReflash) {
    console.log('热更新完成：沙盒文件已就位，桥与服务保持运行（刷新浏览器即见）');
    process.exit(0);
}

// Windows 盘符路径转 MSYS 风格（引号内盘符不会被 shell 转换，moduleInfo 等需要）
function toMsys(p) {
    const m = /^([A-Za-z]):[\\/]?(.*)$/.exec(p);
    if (!m) return p;
    return '/' + m[1].toLowerCase() + '/' + m[2].replace(/\\/g, '/');
}
const sandboxMsys = toMsys(sandbox);

// 组装沙盒执行环境：fakebin 优先 + SVCHUB_* 路径覆盖；PATH 必须留系统目录，否则 sh 找不到全员 127
function mockEnv(extra) {
    const env = Object.assign({}, process.env, extra || {});
    const fb = sandboxMsys + '/fakebin';
    const sysPath = '/usr/local/bin:/usr/bin:/bin';
    env.PATH = fb + ':' + sysPath + ':' + (env.PATH || '');
    env.SVCHUB_MOCK = '1';
    env.SVCHUB_TERMUX_HOME = sandboxMsys;
    env.SVCHUB_SERVER_DIR = sandboxMsys;
    env.SVCHUB_SU_BIN = fb + '/su';
    env.SVCHUB_BUSYBOX = toMsys(path.join(REPO, 'tools', 'busybox.exe'));
    return env;
}

// 清上次残留：pid 活着就强杀，连同 pid 文件一起删（本次 service.sh 会重建）
function reapStale() {
    const runDir = path.join(sandbox, 'run');
    let pids = [];
    try {
        for (const f of fs.readdirSync(runDir)) {
            if (!f.endsWith('.pid')) continue;
            const pid = parseInt(fs.readFileSync(path.join(runDir, f), 'utf8').trim(), 10);
            if (pid > 1) pids.push({ file: f, pid });
        }
    } catch (e) { return; }
    if (!pids.length) return;
    const list = pids.map((p) => p.pid).join(' ');
    try {
        execFileSync(BASH, ['-c', 'for p in ' + list + '; do kill -0 $p 2>/dev/null && kill -9 $p 2>/dev/null; done; echo ok'], { cwd: sandbox, env: mockEnv(), timeout: 15000 });
    } catch (e) { /* 忽略 */ }
    for (const { file } of pids) {
        try { fs.rmSync(path.join(runDir, file), { force: true }); } catch (e) { /* 忽略 */ }
    }
    console.log('已清理上次残留进程');
}

// reap 必须在 service.sh 之前；service.sh 清旧 pid、跑开机命令、拉起 supervisor 真巡检
reapStale();
try {
    execFileSync(BASH, ['-c', 'sh ./service.sh'], { cwd: sandbox, env: mockEnv(), timeout: 15000 });
    console.log('service.sh 已执行（supervisor 巡检中）');
} catch (e) {
    console.log('service.sh 执行异常（supervisor 可能未拉起）: ' + e.message);
}

// 内联垫片（注入到主 script 之前，CSP 允许内联）；exec 用同步 XHR，返回 Promise 会被页面误判为空对象
const SHIM = `<script>
window.ksu = {
    exec: function (cmd) {
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/__exec', false);
        xhr.setRequestHeader('Content-Type', 'application/json');
        try { xhr.send(JSON.stringify({ cmd: cmd })); } catch (e) {
            return { errno: -1, stdout: '', stderr: 'bridge unreachable: ' + e.message };
        }
        try { return JSON.parse(xhr.responseText); } catch (e) {
            return { errno: -1, stdout: '', stderr: 'bridge bad json' };
        }
    },
    moduleInfo: async function () { return { moduleDir: ${JSON.stringify(sandboxMsys)} }; }
};
</script>`;

let pageCache = null;
let pageCacheMtime = 0;
// 下发页面：按 mtime 缓存，reflash 热更新覆盖文件后下一次请求自动换新页
function getPage() {
    const p = path.join(REPO, 'webroot', 'index.html');
    const mtime = fs.statSync(p).mtimeMs;
    if (pageCache && mtime === pageCacheMtime) return pageCache;
    let html = fs.readFileSync(p, 'utf8');
    html = html.replace('<script>', SHIM + '\n<script>');
    pageCache = html;
    pageCacheMtime = mtime;
    return html;
}

// bash 执行命令（cwd=沙盒，20s 超时），stdout/stderr 超长截断
function execReal(cmd, cb) {
    execFile(BASH, ['-c', cmd], { cwd: sandbox, timeout: 20000, maxBuffer: OUT_MAX, env: mockEnv() }, (err, stdout, stderr) => {
        let out = String(stdout || '');
        let er = String(stderr || '');
        if (out.length > OUT_MAX) out = out.slice(-OUT_MAX);
        if (er.length > 4096) er = er.slice(-4096);
        cb({ errno: err ? (err.code || 1) : 0, stdout: out, stderr: er });
    });
}

// 识别 action.sh 子命令并查 WHITE 白名单，其余命令（如 find 探测）直通真执行
function runCmd(cmd, cb) {
    // 正则锚定 sh '…action.sh' + 子命令，避免 MODDIR 探测的 find 被误判成子命令
    const m = /^\s*sh\s+'[^']*action\.sh'\s+([A-Za-z_][A-Za-z0-9_-]*)/.exec(cmd);
    if (!m) {
        execReal(cmd, cb);
        return;
    }
    const sub = m[1];
    if (!WHITE.has(sub)) {
        cb({ errno: 0, stdout: '', stderr: '', json: '{"success":false,"error":"联调桥：该子命令不在本次测试范围"}' });
        return;
    }
    // 改写 MODDIR 为沙盒绝对 MSYS 路径：引号内盘符可能不转换，否则项目根误建 run/log
    const fixed = cmd.replace(/sh\s+'[^']*action\.sh'/, "sh '" + sandboxMsys + "/action.sh'");
    execReal(fixed, cb);
}

const server = http.createServer((req, res) => {
    if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
        const page = getPage();
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(page);
        return;
    }
    // Wi-Fi 模拟：/__wifi?state=on|off&ssid=名 写 mock_wifi，supervisor 下一分片读取
    if (/^\/__wifi/.test(req.url)) {
        const u = new URL(req.url, 'http://127.0.0.1');
        const st = u.searchParams.get('state');
        const sd = u.searchParams.get('ssid');
        if (st !== null || sd !== null) setMockWifi(st !== null ? st : undefined, sd !== null ? sd : undefined);
        let cur = ['off', 'Home'];
        try { cur = fs.readFileSync(mockWifiFile, 'utf8').split('\n'); } catch (e) { /* 用默认 */ }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ state: (cur[0] || '').trim(), ssid: (cur[1] || '').trim() }));
        return;
    }
    // 屏幕/锁屏模拟：/__screen?screen=on|off&lock=lock|unlock 写 mock_screen，监督器下一分片读取
    if (/^\/__screen/.test(req.url)) {
        const u = new URL(req.url, 'http://127.0.0.1');
        const sc = u.searchParams.get('screen');
        const lk = u.searchParams.get('lock');
        if (sc !== null || lk !== null) setMockScreen(sc !== null ? sc : undefined, lk !== null ? lk : undefined);
        let cur = ['on', 'unlock'];
        try { cur = fs.readFileSync(mockScreenFile, 'utf8').split('\n'); } catch (e) { /* 用默认 */ }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ screen: (cur[0] || '').trim(), lock: (cur[1] || '').trim() }));
        return;
    }
    if (req.method === 'POST' && req.url === '/__exec') {
        let body = '';
        req.on('data', (c) => { body += c; if (body.length > 2 * 1024 * 1024) req.destroy(); });
        req.on('end', () => {
            let cmd = '';
            try { cmd = JSON.parse(body).cmd || ''; } catch (e) { /* 空命令走白名单拒绝 */ }
            if (!cmd) {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ errno: -1, stdout: '', stderr: 'empty cmd' }));
                return;
            }
            runCmd(cmd, (r) => {
                if (r.json) {
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ errno: 0, stdout: r.json, stderr: '' }));
                    return;
                }
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(r));
            });
        });
        return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
});

// 端口被占先 800ms 重试一次（reflash 杀旧桥后端口瞬时未释放），再失败给人话提示
let listenRetried = false;
server.on('error', (err) => {
    if (err && err.code === 'EADDRINUSE') {
        if (!listenRetried) {
            listenRetried = true;
            setTimeout(() => server.listen(PORT, '127.0.0.1'), 800);
            return;
        }
        console.log('端口 127.0.0.1:' + PORT + ' 被占用，旧桥进程可能没退出。');
        console.log('先杀掉残留 node 进程再启动：taskkill /F /IM node.exe');
        process.exit(1);
    }
    throw err;
});

// 按进程归属清杀沙盒全部进程（pid 文件只当种子）并删 pid、清日志，config 保留。
// 不能只按 pid 杀：假 setsid 不建进程组（组杀失效），run/ 被清过的服务是没户口的孤儿。
// 扫描自保：排除自身+祖先链（本机 MSYS ps 不支持 -o，走 /proc/N/stat），命令行含 mock-server 的跳过，防反杀调用方。
function stopAll() {
    const runDir = path.join(sandbox, 'run');
    let pids = [];
    try {
        for (const f of fs.readdirSync(runDir)) {
            if (!f.endsWith('.pid')) continue;
            const pid = parseInt(fs.readFileSync(path.join(runDir, f), 'utf8').trim(), 10);
            if (pid > 1) pids.push({ file: f, pid });
        }
    } catch (e) { /* 无 run 目录 */ }
    // supervisor.pid 优先 TERM（先停巡检）
    pids.sort((a, b) => (a.file === 'supervisor.pid' ? -1 : 1));
    const seed = pids.map((p) => p.pid).join(' ');
    const script = [
        'targets="' + seed + '"',
        'skip="$$ $PPID"; p=$PPID; i=0; while [ $i -lt 8 ]; do read -r _ _ _ pp _ 2>/dev/null < /proc/$p/stat; case "$pp" in ""|"$p"|1) break;; esac; skip="$skip $pp"; p=$pp; i=$((i + 1)); done',
        'for p in $(ls /proc | grep -E "^[0-9]+$"); do',
        '  case " $skip " in *" $p "*) continue;; esac',
        '  case " $targets " in *" $p "*) continue;; esac',
        '  cw=$(readlink /proc/$p/cwd 2>/dev/null)',
        '  cl=$(tr "\\0" " " 2>/dev/null < /proc/$p/cmdline)',
        '  case "$cl" in *mock-server*) continue;; esac',
        // cwd 落沙盒内的全收（supervisor/服务/各级 sleep）；httpd cwd 不在沙盒，靠命令行 busybox+沙盒路径命中
        '  case "$cw" in */.mock-sandbox/modules/SvcHub*) targets="$targets $p"; continue;; esac',
        '  case "$cl" in *busybox*mock-sandbox*) targets="$targets $p";; esac',
        'done',
        'for p in $targets; do kill -15 $p 2>/dev/null; done',
        'sleep 2',
        'for p in $targets; do kill -0 $p 2>/dev/null && kill -9 $p 2>/dev/null; done',
        'echo done',
    ].join('\n');
    // 不能用 mockEnv()：stop 先于 sandboxMsys 初始化（TDZ）；清理失败必须打印，不能静默
    const killEnv = Object.assign({}, process.env);
    killEnv.PATH = '/usr/local/bin:/usr/bin:/bin:' + (killEnv.PATH || '');
    try {
        execFileSync(BASH, ['-c', script], { cwd: sandbox, env: killEnv, timeout: 15000 });
    } catch (e) { console.log('清理脚本失败: ' + e.message); }
    try {
        for (const f of fs.readdirSync(runDir)) {
            if (f.endsWith('.pid')) try { fs.rmSync(path.join(runDir, f), { force: true }); } catch (e) { /* 忽略 */ }
        }
    } catch (e) { /* 无 run 目录 */ }
    // 清空沙盒日志：退出不清用户会看混，下次启动 service.sh 本来也会清；config 保留复用
    try {
        for (const f of fs.readdirSync(path.join(sandbox, 'log'))) {
            if (f.endsWith('.log')) try { fs.rmSync(path.join(sandbox, 'log', f), { force: true }); } catch (e) { /* 忽略 */ }
        }
    } catch (e) { /* 无 log 目录 */ }
}

// 清理退出入口：停服务 + 清桥 pid 记录，config 留给下次复用
function cleanupAndExit(code) {
    stopAll();
    try { fs.rmSync(path.join(sandboxRoot, 'bridge.pid'), { force: true }); } catch (e) { /* 忽略 */ }
    console.log('已停止 supervisor 与各服务，沙盒保留供下次复用：' + sandboxRoot);
    process.exit(code || 0);
}
// Windows 跨进程 SIGINT 送达不可靠、taskkill 强杀无信号——这两种清理跑不起来的残留交给下次 reapStale
process.on('SIGINT', () => cleanupAndExit(0));
process.on('SIGTERM', () => cleanupAndExit(0));
process.on('SIGBREAK', () => cleanupAndExit(0));

server.listen(PORT, '127.0.0.1', () => {
    // 记录桥 pid：reflash/stop 据此找旧桥（指向已死进程也无害，会被识别）
    try { fs.writeFileSync(path.join(sandboxRoot, 'bridge.pid'), String(process.pid)); } catch (e) { /* 忽略 */ }
    console.log('SvcHub 联调桥已启动');
    console.log('  页面: http://127.0.0.1:' + PORT);
    console.log('  沙盒: ' + sandboxRoot + ' （固定，退出保留；reset 恢复出厂）');
    console.log('  模块: ' + sandbox);
    console.log('  Bash: ' + BASH);
    console.log('按 Ctrl+C 退出（先停服务再退出）');
});
