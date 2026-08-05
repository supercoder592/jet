#!/usr/bin/env node
/**
 * 網頁版連線煙霧測試 ─ 兩個真實的瀏覽器分頁跑真正的遊戲，透過 WebRTC 連起來。
 *
 *   node tools/web_net_smoke.js                                  # 打線上的 GitHub Pages
 *   node tools/web_net_smoke.js --url http://127.0.0.1:8123/      # 打本機匯出的 build/web
 *   node tools/web_net_smoke.js --signal ws://127.0.0.1:9080      # 順便換信令伺服器
 *   node tools/web_net_smoke.js --headful                         # 想親眼看它跑
 *
 * 跟 tools/net_smoke.ps1 的關係：
 *   net_smoke.ps1   桌面 headless × 2，走 **ENet**   ─ 驗遊戲邏輯與同步
 *   web_net_smoke   瀏覽器分頁 × 2，走 **WebRTC**   ─ 驗網頁版真的連得起來
 * 兩者跑的是同一份 NetSmoke.gd，只是情境不同（網頁跑 link，不等到戰鬥階段）。
 *
 * 網頁版沒有環境變數，所以參數是用網址帶的：?netsmoke=host&netsmoke_room=4242…
 * 對應 MainGame.test_flag()。
 */

'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const WebSocket = require('ws');

function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const BASE = arg('url', 'https://supercoder592.github.io/jet/');
const SIGNAL = arg('signal', '');
const ROOM = arg('room', String(1000 + Math.floor(Math.random() * 9000)));
const STEP_TIMEOUT = Number(arg('steptimeout', '120')); // NetSmoke 單步逾時
const TOTAL_TIMEOUT = Number(arg('timeout', '420')) * 1000;
// 房主要等多久才算開房失敗。Godot 在 headless 的軟體算圖下開機就要十幾秒，
// 再加上 Render 冷啟動，這個等待一定要比直覺長很多。
const HOST_READY_TIMEOUT = Number(arg('hostready', '150')) * 1000;
const HEADFUL = process.argv.includes('--headful');
const LOG_DIR = path.join(__dirname, '.websmoke');

// NetSmoke 跑完會呼叫 get_tree().quit()，Godot 的網頁版在關閉時本來就會抱怨
// 執行緒池還有頁面沒回收。真人玩家不會走到這條路，別讓它把測試判成失敗。
const IGNORED_ERRORS = [
  /Pages in use exist at exit in PagedAllocator/,
  // Godot 自己的網頁音訊 glue（index.js 是引擎產生的）。headless 沒有音效裝置，
  // AudioContext 一直是 null，暫停取樣時就會踩到。真人的瀏覽器不會走到這裡。
  /SampleNode\._pause|godot_audio_sample_set_pause/,
];

const CHROME_CANDIDATES = [
  arg('chrome', ''),
  process.env.CHROME_PATH || '',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  '/usr/bin/google-chrome',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
].filter(Boolean);

function pageUrl(role) {
  const u = new URL(BASE);
  u.searchParams.set('netsmoke', role);
  u.searchParams.set('netsmoke_scenario', 'link');
  u.searchParams.set('netsmoke_room', ROOM);
  u.searchParams.set('netsmoke_timeout', String(STEP_TIMEOUT));
  u.searchParams.set('netdebug', '1');   // 交握每一步都印出來，壞掉時才看得出是誰沒回話
  if (SIGNAL) u.searchParams.set('signal', SIGNAL);
  return u.toString();
}

function httpJson(url, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = require('http').request(url, { method }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => {
        try { resolve(JSON.parse(body)); } catch { reject(new Error(`${url} 回的不是 JSON`)); }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

async function waitFor(fn, ms, what) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const v = await fn().catch(() => null);
    if (v) return v;
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`等 ${what} 逾時`);
}

/** 開一個分頁、導到 url，把 console 輸出全部收下來 */
async function openTab(port, url, role, onLine) {
  const target = await httpJson(`http://127.0.0.1:${port}/json/new?about:blank`, 'PUT');
  const ws = new WebSocket(target.webSocketDebuggerUrl, { maxPayload: 64 * 1024 * 1024 });
  await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });

  let id = 0;
  const send = (method, params = {}) => {
    ws.send(JSON.stringify({ id: ++id, method, params }));
  };

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    if (msg.method === 'Runtime.consoleAPICalled') {
      const text = (msg.params.args || [])
        .map((a) => (a.value !== undefined ? String(a.value) : (a.description || '')))
        .join(' ');
      text.split('\n').forEach((l) => { if (l.trim()) onLine(role, l.trimEnd()); });
    } else if (msg.method === 'Runtime.exceptionThrown') {
      const d = msg.params.exceptionDetails;
      onLine(role, `JS EXCEPTION: ${d.text} ${d.exception ? d.exception.description || '' : ''}`);
    }
  });

  send('Runtime.enable');
  send('Page.enable');
  // 只有前景分頁會拿到 requestAnimationFrame，而 Godot 的網頁版主迴圈就跑在 rAF 上。
  // 兩個分頁同時要跑遊戲的話，非作用中的那個會整個凍住（連信令都不處理）─
  // 命令列的 --disable-*-throttling 只擋得住計時器節流，擋不住 rAF 暫停，
  // 得靠這個把「我是被聚焦的」直接假造給頁面。
  send('Emulation.setFocusEmulationEnabled', { enabled: true });
  send('Page.setWebLifecycleState', { state: 'active' });
  send('Page.navigate', { url });
  return { ws, role, evaluate: (expr) => send('Runtime.evaluate', { expression: expr }) };
}

const fails = [];
let checks = 0;
function check(ok, label, detail) {
  checks++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '  ─ ' + detail : ''}`);
  if (!ok) fails.push(label);
  return ok;
}

(async function main() {
  console.log('網頁版連線煙霧測試（WebRTC）');
  console.log(`  網址  ${BASE}`);
  console.log(`  信令  ${SIGNAL || '（用遊戲內建的預設值）'}`);
  console.log(`  房號  ${ROOM}\n`);

  const chromePath = CHROME_CANDIDATES.find((p) => fs.existsSync(p));
  if (!chromePath) {
    console.error('找不到 Chrome。用 --chrome 指定路徑，或設 CHROME_PATH。');
    process.exit(1);
  }

  const port = 9700 + Math.floor(Math.random() * 200);
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'aircombat-web-'));
  const flags = [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--autoplay-policy=no-user-gesture-required',
    // headless 沒有真的 GPU，Godot 的 WebGL2 要靠 SwiftShader 軟體算
    '--enable-unsafe-swiftshader',
    // 這三個是這支腳本能不能動的關鍵。Godot 的網頁版主迴圈跑在 requestAnimationFrame 上，
    // 而 Chrome 會把背景分頁的 rAF 節流到幾乎停住 ─ 第二個分頁一開，
    // 房主那頁的遊戲就整個凍結，連信令訊息都不再處理，看起來會像「房主不回應」。
    '--disable-background-timer-throttling',
    '--disable-backgrounding-occluded-windows',
    '--disable-renderer-backgrounding',
    'about:blank',
  ];
  if (!HEADFUL) flags.unshift('--headless=new');

  const chrome = spawn(chromePath, flags, { stdio: ['ignore', 'pipe', 'pipe'] });
  const cleanup = () => {
    try { chrome.kill(); } catch { /* 已經死了 */ }
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* 被鎖著，無所謂 */ }
  };
  process.on('exit', cleanup);

  // 兩端各自的 [SMOKE] 判定結果
  const smoke = { host: { lines: [], result: null }, client: { lines: [], result: null } };
  const engineErrors = { host: [], client: [] };
  let hostRoomReady = false;
  let clientBooted = false;

  // 整份 console 都留下來。判定只看得到 [SMOKE] 那幾行，
  // 但真的壞掉的時候（例如 wasm crash）線索往往在它前面那幾行普通輸出裡。
  fs.mkdirSync(LOG_DIR, { recursive: true });
  const logFiles = {
    host: fs.createWriteStream(path.join(LOG_DIR, 'host.log')),
    client: fs.createWriteStream(path.join(LOG_DIR, 'client.log')),
  };

  const onLine = (role, line) => {
    logFiles[role].write(line + '\n');
    if (role === 'host' && line.includes('房間已開啟')) hostRoomReady = true;
    if (role === 'client' && line.includes('訪客登入成功')) clientBooted = true;
    if (line.includes('[SMOKE]')) {
      smoke[role].lines.push(line);
      const m = line.match(/RESULT\s+(.*)$/);
      if (m) smoke[role].result = m[1].trim();
      console.log(`  [${role}] ${line.replace(/^\[SMOKE\]\[[A-Z]+\]\s*/, '')}`);
    } else if (IGNORED_ERRORS.some((re) => re.test(line))) {
      /* 引擎自己的收尾雜訊，不是遊戲的問題 */
    } else if (/SCRIPT ERROR|^\s*ERROR:|Node not found|JS EXCEPTION/.test(line)) {
      engineErrors[role].push(line);
      console.log(`  [${role}] !! ${line}`);
    } else if (/\[NET\]|\[RTC\]/.test(line)) {
      console.log(`  [${role}] ${line}`);
    }
  };

  const tabs = [];
  try {
    const version = await waitFor(
      () => httpJson(`http://127.0.0.1:${port}/json/version`).catch(() => null),
      20000, 'Chrome DevTools 埠');
    console.log(`  Chrome ${version['Browser']}\n`);

    // 兩個分頁同時開，讓 51 MB 的下載與 wasm 編譯平行跑 ─
    // 一前一後開的話，後開的那個要跟已經在算 3D 世界的前一個搶 CPU，慢到會逾時。
    tabs.push(await openTab(port, pageUrl('host'), 'host', onLine));
    const client = await openTab(port, pageUrl('client'), 'client', onLine);
    tabs.push(client);

    // 客戶端不能靠固定秒數搶跑（先前的版本就撞上「客戶端先到，信令回 no_room」），
    // 改成兩邊都就緒了才由這裡發車。
    console.log('  等兩端開機、房主把房間開起來…');
    await waitFor(async () => hostRoomReady && clientBooted, HOST_READY_TIMEOUT, '房主開好房間且客戶端已開機');
    console.log('  兩端就緒，發車\n');
    client.evaluate('window.__smoke_go = true');

    await waitFor(async () => smoke.host.result && smoke.client.result,
      TOTAL_TIMEOUT, '兩端都跑完（房主 / 客戶端的 RESULT）');
  } catch (e) {
    console.log('');
    check(false, '兩端都在時限內跑完', e.message);
  } finally {
    tabs.forEach((t) => { try { t.ws.close(); } catch { /* 已經關了 */ } });
    cleanup();
  }

  console.log('\n── 判定 ──');
  for (const role of ['host', 'client']) {
    const r = smoke[role].result;
    check(!!r, `${role} 有跑完並印出 RESULT`, r || '沒有拿到 RESULT');
    if (r) check(r.startsWith('ALL PASS'), `${role} 的所有斷言都通過`, r);
    check(engineErrors[role].length === 0, `${role} 沒有引擎錯誤`,
      engineErrors[role].length ? engineErrors[role].slice(0, 3).join(' / ') : '');
  }

  // 兩端抽到的地圖與種子必須完全一致，否則各打各的世界
  const setLine = (role) => (smoke[role].lines.find((l) => l.includes('SETTINGS')) || '')
    .replace(/^.*SETTINGS\s*/, '');
  const hs = setLine('host'), cs = setLine('client');
  check(hs !== '' && hs === cs, '兩端的地圖／種子／天氣完全一致',
    hs === cs ? hs : `房主 ${hs || '(無)'} vs 客戶端 ${cs || '(無)'}`);

  console.log('');
  if (fails.length === 0) {
    console.log(`RESULT  ALL PASS（${checks} 項）`);
    process.exit(0);
  }
  console.log(`RESULT  FAILED ${fails.length}/${checks} ─ ${fails.join('、')}`);
  process.exit(1);
})();
