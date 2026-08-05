#!/usr/bin/env node
/**
 * WebRTC 端到端驗證 ─ 兩個真實的瀏覽器分頁，透過真實的信令伺服器連起來。
 *
 *   node tools/webrtc_check.js                                  # 打 Render 上的正式信令
 *   node tools/webrtc_check.js --signal ws://127.0.0.1:9080     # 打本機的
 *   node tools/webrtc_check.js --chrome "C:\\path\\to\\chrome.exe"
 *
 * 為什麼要這樣測：`MainGame.gd` 的 WebRTC 那條路只有網頁版跑得到，
 * 桌面版沒裝 webrtc GDExtension 根本進不去，headless 的 NetSmoke 也只驗得了 ENet。
 * 所以這裡把 Godot 那套信令協定原封不動地用瀏覽器原生 RTCPeerConnection 重跑一次 ─
 * 訊息格式（host/join/sdp/ice 的欄位名稱）與 ICE 設定都跟 GDScript 那邊一模一樣。
 * 這支過了，代表「信令伺服器 + STUN + 交握順序」是通的；
 * 剩下沒被涵蓋的只有 Godot 自己那層 WebRTCMultiplayerPeer 的包裝。
 *
 * 判定：exit code 0 = 全過。任何一項失敗都會印出原因並回 1。
 */

'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const WebSocket = require('ws');

// ─────────────────────────────── 參數 ───────────────────────────────
function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const SIGNAL = arg('signal', 'wss://aircombat-signaling.onrender.com');
const ROOM = arg('room', String(1000 + Math.floor(Math.random() * 9000)));
// 冷啟動的 Render free 方案第一個連線要等很久，逾時要給得比遊戲裡還寬
const TIMEOUT_MS = Number(arg('timeout', '90')) * 1000;
const KEEP_OPEN = process.argv.includes('--keep-open');

const CHROME_CANDIDATES = [
  arg('chrome', ''),
  process.env.CHROME_PATH || '',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
].filter(Boolean);

// ─────────────────────────────── 判定 ───────────────────────────────
const fails = [];
let checks = 0;

function check(ok, label, detail) {
  checks++;
  if (ok) {
    console.log(`  PASS  ${label}${detail ? '  ─ ' + detail : ''}`);
  } else {
    fails.push(label);
    console.log(`  FAIL  ${label}${detail ? '  ─ ' + detail : ''}`);
  }
  return ok;
}

// ─────────────────────────── 極簡 CDP 客戶端 ───────────────────────────
// 只用得到 Runtime.evaluate，不值得為此拉進 puppeteer（那要多下載一整包 Chromium）。
class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    ws.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw.toString()); } catch { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      }
    });
  }

  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  /** 在分頁裡跑一段回傳 Promise 的程式碼，把結果原樣拿回來 */
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
      timeout: TIMEOUT_MS,
    });
    if (r.exceptionDetails) {
      const e = r.exceptionDetails;
      throw new Error(e.exception ? (e.exception.description || e.exception.value) : e.text);
    }
    return r.result.value;
  }

  close() { try { this.ws.close(); } catch { /* 已經關了 */ } }
}

function httpJson(url, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = require('http').request(url, { method }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => {
        try { resolve(JSON.parse(body)); } catch (e) { reject(new Error(`${url} 回傳的不是 JSON：${body.slice(0, 200)}`)); }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

async function waitFor(fn, ms, what) {
  const t0 = Date.now();
  let last;
  while (Date.now() - t0 < ms) {
    try { last = await fn(); if (last) return last; } catch (e) { last = e.message; }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`等 ${what} 逾時（${ms} ms），最後狀態：${JSON.stringify(last)}`);
}

// ─────────────────────────── 分頁裡跑的 peer ───────────────────────────
// 這段字串會被丟進瀏覽器執行。刻意寫成跟 MainGame.gd 同樣的訊息格式：
//   host  { cmd:'host', room }              →  welcome { id:1 }
//   join  { cmd:'join', room }              →  welcome { id:N }，房主同時收到 peer_join
//   sdp   { cmd:'sdp',  to, type, sdp }     →  對方收到時多一個 from、少一個 to
//   ice   { cmd:'ice',  to, mid, index, name }
// 其中 ice 的三個欄位對應 Godot 的 ice_candidate_created(mid, index, name)。
function peerScript(role, signal, room) {
  return `(async () => {
  const LOG = [];
  const log = (m) => LOG.push(m);
  const ICE_CONFIG = { iceServers: [{ urls: ['stun:stun.l.google.com:19302'] }] };
  const isHost = ${role === 'host'};

  const result = {
    role: ${JSON.stringify(role)},
    ok: false, error: null, log: LOG,
    myId: 0, sawSrflx: false, dcOpen: false, echo: null,
    iceState: '', selectedPair: null,
  };

  try {
    const ws = new WebSocket(${JSON.stringify(signal)});
    window.__ws = ws;
    const wsOpen = new Promise((res, rej) => {
      ws.onopen = res;
      ws.onerror = () => rej(new Error('信令 WebSocket 連不上 ${signal}'));
      ws.onclose = (e) => rej(new Error('信令 WebSocket 被關閉，code=' + e.code));
    });
    const t0 = performance.now();
    await wsOpen;
    log('信令已連上，耗時 ' + Math.round(performance.now() - t0) + ' ms');

    let pc = null, dc = null, remoteId = 0;
    let resolveDone; const done = new Promise((r) => (resolveDone = r));

    const send = (o) => ws.send(JSON.stringify(o));

    function makePc(peerId) {
      remoteId = peerId;
      pc = new RTCPeerConnection(ICE_CONFIG);
      window.__pc = pc;
      pc.onicecandidate = (e) => {
        if (!e.candidate) { log('ICE 候選蒐集完畢'); return; }
        // srflx = 經由 STUN 問到的公網位址。沒有它就代表 STUN 沒通，
        // 兩個不同網路的玩家會連不起來（同機測試靠 host 候選也會通，會蓋掉問題）
        if (e.candidate.candidate.includes('typ srflx')) result.sawSrflx = true;
        send({ cmd: 'ice', to: peerId,
               mid: e.candidate.sdpMid || '',
               index: e.candidate.sdpMLineIndex || 0,
               name: e.candidate.candidate });
      };
      pc.oniceconnectionstatechange = () => {
        result.iceState = pc.iceConnectionState;
        log('ICE 狀態 → ' + pc.iceConnectionState);
        if (pc.iceConnectionState === 'failed') resolveDone();
      };
      pc.ondatachannel = (e) => {
        dc = e.channel;
        wireDc();
      };
      return pc;
    }

    function wireDc() {
      dc.onopen = () => {
        result.dcOpen = true;
        log('資料通道已開啟');
        // 房主等對方先講話再回聲；客戶端主動送
        if (!isHost) dc.send('PING-FROM-CLIENT');
      };
      dc.onmessage = (e) => {
        log('收到：' + e.data);
        if (isHost) { dc.send('PONG-FROM-HOST'); }
        else { result.echo = e.data; resolveDone(); }
      };
    }

    ws.onmessage = async (ev) => {
      const m = JSON.parse(ev.data);
      log('信令 ← ' + m.cmd);
      if (m.cmd === 'error') { result.error = '信令錯誤：' + m.msg; resolveDone(); return; }

      if (m.cmd === 'welcome') {
        result.myId = m.id;
        if (!isHost) {
          // 客戶端一律只跟房主 (id 1) 連，並且由它發 offer ─ 跟 GDScript 同一套
          makePc(1);
          dc = pc.createDataChannel('game', { ordered: true });
          wireDc();
          const offer = await pc.createOffer();
          await pc.setLocalDescription(offer);
          send({ cmd: 'sdp', to: 1, type: offer.type, sdp: offer.sdp });
        }
        return;
      }

      if (m.cmd === 'peer_join') { if (isHost) makePc(m.id); return; }

      if (m.cmd === 'sdp') {
        if (!pc) makePc(m.from);
        await pc.setRemoteDescription({ type: m.type, sdp: m.sdp });
        if (m.type === 'offer') {
          const answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          send({ cmd: 'sdp', to: m.from, type: answer.type, sdp: answer.sdp });
        }
        return;
      }

      if (m.cmd === 'ice') {
        if (!pc) return;
        try {
          await pc.addIceCandidate({ candidate: m.name, sdpMid: m.mid, sdpMLineIndex: m.index });
        } catch (e) { log('addIceCandidate 失敗：' + e.message); }
        return;
      }
    };

    send(isHost ? { cmd: 'host', room: ${JSON.stringify(room)} }
                : { cmd: 'join', room: ${JSON.stringify(room)} });

    // 房主沒有「收到回聲」這個終點，連上且回過話就算完成
    if (isHost) {
      const guard = setInterval(() => { if (result.dcOpen && result.iceState === 'connected') { clearInterval(guard); resolveDone(); } }, 200);
    }
    await Promise.race([done, new Promise((r) => setTimeout(r, ${TIMEOUT_MS}))]);

    // 抓實際選中的候選對，看是走本機直連還是繞了 STUN
    if (pc) {
      const stats = await pc.getStats();
      let pair = null, locals = new Map(), remotes = new Map();
      stats.forEach((s) => {
        if (s.type === 'local-candidate') locals.set(s.id, s);
        if (s.type === 'remote-candidate') remotes.set(s.id, s);
      });
      stats.forEach((s) => {
        if (s.type === 'candidate-pair' && (s.selected || s.state === 'succeeded')) pair = s;
      });
      if (pair) {
        const l = locals.get(pair.localCandidateId), r = remotes.get(pair.remoteCandidateId);
        result.selectedPair = (l ? l.candidateType : '?') + ' ↔ ' + (r ? r.candidateType : '?');
      }
      result.iceState = pc.iceConnectionState;
    }

    result.ok = result.dcOpen && (isHost ? result.iceState === 'connected' : result.echo === 'PONG-FROM-HOST');
  } catch (e) {
    result.error = e && e.message ? e.message : String(e);
  }
  return result;
})()`;
}

// ─────────────────────────────── 主流程 ───────────────────────────────
(async function main() {
  console.log('WebRTC 端到端驗證');
  console.log(`  信令  ${SIGNAL}`);
  console.log(`  房號  ${ROOM}`);
  console.log('');

  const chromePath = CHROME_CANDIDATES.find((p) => fs.existsSync(p));
  if (!chromePath) {
    console.error('找不到 Chrome。用 --chrome 指定路徑，或設 CHROME_PATH。');
    console.error('找過：\n  ' + CHROME_CANDIDATES.join('\n  '));
    process.exit(1);
  }

  const port = 9300 + Math.floor(Math.random() * 400);
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'aircombat-cdp-'));
  const chrome = spawn(chromePath, [
    KEEP_OPEN ? '--auto-open-devtools-for-tabs' : '--headless=new',
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });

  let chromeErr = '';
  chrome.stderr.on('data', (d) => (chromeErr += d.toString()));

  const cleanup = () => {
    try { chrome.kill(); } catch { /* 已經死了 */ }
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* 檔案還被鎖著，無所謂 */ }
  };
  process.on('exit', cleanup);

  const sessions = [];
  try {
    // 等 DevTools 埠起來
    const version = await waitFor(
      () => httpJson(`http://127.0.0.1:${port}/json/version`).catch(() => null),
      20000, 'Chrome DevTools 埠');
    console.log(`  Chrome ${version['Browser']}\n`);

    // 兩個獨立分頁，各自扮演房主與客戶端
    for (const role of ['host', 'client']) {
      const target = await httpJson(`http://127.0.0.1:${port}/json/new?about:blank`, 'PUT');
      const ws = new WebSocket(target.webSocketDebuggerUrl, { maxPayload: 32 * 1024 * 1024 });
      await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
      const cdp = new Cdp(ws);
      await cdp.send('Runtime.enable');
      sessions.push({ role, cdp });
    }

    const host = sessions[0], client = sessions[1];

    // 房主要先把房間開起來，客戶端才 join 得到 ─ 所以不能兩邊同時發車
    const hostRun = host.cdp.eval(peerScript('host', SIGNAL, ROOM));
    await new Promise((r) => setTimeout(r, 1500));
    const clientRun = client.cdp.eval(peerScript('client', SIGNAL, ROOM));

    const [hr, cr] = await Promise.all([hostRun, clientRun]);

    console.log('── 房主 ──');
    hr.log.forEach((l) => console.log('   ' + l));
    console.log('── 客戶端 ──');
    cr.log.forEach((l) => console.log('   ' + l));
    console.log('');
    console.log('── 判定 ──');

    check(hr.myId === 1, '房主拿到 peer id 1', `實際 ${hr.myId}`);
    check(cr.myId > 1, '客戶端拿到大於 1 的 peer id', `實際 ${cr.myId}`);
    check(!hr.error, '房主沒有信令錯誤', hr.error || '');
    check(!cr.error, '客戶端沒有信令錯誤', cr.error || '');
    check(hr.sawSrflx || cr.sawSrflx, 'STUN 有回應（拿得到 srflx 公網候選）',
      `房主 ${hr.sawSrflx} / 客戶端 ${cr.sawSrflx}`);
    check(hr.iceState === 'connected' || hr.iceState === 'completed', '房主 ICE 已連線', hr.iceState);
    check(cr.iceState === 'connected' || cr.iceState === 'completed', '客戶端 ICE 已連線', cr.iceState);
    check(hr.dcOpen && cr.dcOpen, '兩端的資料通道都開啟');
    check(cr.echo === 'PONG-FROM-HOST', '訊息真的來回跑過一趟', `收到 ${cr.echo}`);
    if (cr.selectedPair) console.log(`  （實際走的候選對：${cr.selectedPair}）`);
  } catch (e) {
    check(false, '驗證流程本身沒有爆掉', e.message);
    if (chromeErr.trim()) console.error('Chrome stderr:\n' + chromeErr.trim().split('\n').slice(-8).join('\n'));
  } finally {
    sessions.forEach((s) => s.cdp.close());
    cleanup();
  }

  console.log('');
  if (fails.length === 0) {
    console.log(`RESULT  ALL PASS（${checks} 項）`);
    process.exit(0);
  }
  console.log(`RESULT  FAILED ${fails.length}/${checks} ─ ${fails.join('、')}`);
  process.exit(1);
})();
