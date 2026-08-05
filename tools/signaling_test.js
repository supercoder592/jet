#!/usr/bin/env node
/**
 * 信令伺服器的協定測試 ─ 不開瀏覽器，只驗 signaling_server.js 的行為。
 *
 *   node tools/signaling_test.js                    # 自己起一台來測（預設）
 *   node tools/signaling_test.js --url wss://aircombat-signaling.onrender.com
 *
 * webrtc_check.js 驗的是「正常流程走得通」，這支驗的是**不正常的時候**：
 * 撞號、房間不存在、房主落跑、keepalive。這些路徑在遊戲裡都有對應的處理
 * （例如撞號會自動重抽房號），錯誤碼一改就會靜悄悄地壞掉。
 */

'use strict';

const { spawn } = require('child_process');
const path = require('path');
const WebSocket = require('ws');

function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const EXTERNAL = arg('url', '');
const PORT = Number(arg('port', '9481'));
const URL = EXTERNAL || `ws://127.0.0.1:${PORT}`;

const fails = [];
let checks = 0;

function check(ok, label, detail) {
  checks++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '  ─ ' + detail : ''}`);
  if (!ok) fails.push(label);
  return ok;
}

/** 一條連線 + 收到的訊息佇列，可以 await 下一則 */
function peer() {
  const ws = new WebSocket(URL);
  const queue = [];
  const waiters = [];
  ws.on('message', (raw) => {
    const m = JSON.parse(raw.toString());
    if (waiters.length) waiters.shift()(m);
    else queue.push(m);
  });
  return {
    ws,
    open: new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); }),
    send: (o) => ws.send(JSON.stringify(o)),
    next: (ms = 15000) => new Promise((res, rej) => {
      if (queue.length) return res(queue.shift());
      const t = setTimeout(() => rej(new Error('等訊息逾時')), ms);
      waiters.push((m) => { clearTimeout(t); res(m); });
    }),
    closed: new Promise((res) => ws.once('close', (code) => res(code))),
    close: () => ws.close(),
  };
}

const code4 = () => String(1000 + Math.floor(Math.random() * 9000));

(async function main() {
  console.log(`信令協定測試  ${URL}\n`);

  let child = null;
  if (!EXTERNAL) {
    child = spawn(process.execPath, [path.join(__dirname, '..', 'signaling_server.js')], {
      env: { ...process.env, PORT: String(PORT) },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('伺服器沒有在 10 秒內起來')), 10000);
      child.stdout.on('data', (d) => {
        if (d.toString().includes('listening')) { clearTimeout(t); res(); }
      });
      child.on('error', rej);
    });
    console.log(`  （已在 127.0.0.1:${PORT} 起一台來測）\n`);
  }

  const alive = [];
  try {
    const room = code4();

    // ── 1. 開房 ──────────────────────────────────────────────
    const host = peer(); alive.push(host);
    await host.open;
    host.send({ cmd: 'host', room });
    let m = await host.next();
    check(m.cmd === 'welcome' && m.id === 1, '房主開房後拿到 welcome / id=1', JSON.stringify(m));

    // ── 2. 撞號要回 room_taken（遊戲靠這個碼自動重抽房號）────────
    const dup = peer(); alive.push(dup);
    await dup.open;
    dup.send({ cmd: 'host', room });
    m = await dup.next();
    check(m.cmd === 'error' && m.code === 'room_taken', '同房號再開房被擋且 code=room_taken',
      JSON.stringify(m));

    // ── 3. 房間不存在 ────────────────────────────────────────
    const ghost = peer(); alive.push(ghost);
    await ghost.open;
    ghost.send({ cmd: 'join', room: '0001' });
    m = await ghost.next();
    check(m.cmd === 'error' && m.code === 'no_room', '加入不存在的房間回 no_room', JSON.stringify(m));

    // ── 4. 房號格式 ─────────────────────────────────────────
    const badfmt = peer(); alive.push(badfmt);
    await badfmt.open;
    badfmt.send({ cmd: 'host', room: 'abc' });
    m = await badfmt.next();
    check(m.cmd === 'error' && m.code === 'bad_room', '非 4 位數房號被擋', JSON.stringify(m));

    // ── 5. 正常加入：客戶端拿 welcome，房主同時拿 peer_join ──────
    const cli = peer(); alive.push(cli);
    await cli.open;
    cli.send({ cmd: 'join', room });
    const [cm, hm] = await Promise.all([cli.next(), host.next()]);
    check(cm.cmd === 'welcome' && cm.id === 2, '客戶端拿到 welcome / id=2', JSON.stringify(cm));
    check(hm.cmd === 'peer_join' && hm.id === 2, '房主收到 peer_join', JSON.stringify(hm));

    // ── 6. SDP / ICE 轉發：to 換成 from，其餘欄位原樣 ───────────
    cli.send({ cmd: 'sdp', to: 1, type: 'offer', sdp: 'v=0-TEST' });
    m = await host.next();
    check(m.cmd === 'sdp' && m.from === 2 && m.to === undefined && m.sdp === 'v=0-TEST',
      'SDP 轉給房主，to 換成 from', JSON.stringify(m));

    host.send({ cmd: 'ice', to: 2, mid: '0', index: 0, name: 'candidate:TEST' });
    m = await cli.next();
    check(m.cmd === 'ice' && m.from === 1 && m.name === 'candidate:TEST' && m.mid === '0',
      'ICE 轉給客戶端，mid/index/name 都在', JSON.stringify(m));

    // ── 7. keepalive ────────────────────────────────────────
    host.send({ cmd: 'ping' });
    m = await host.next();
    check(m.cmd === 'pong', 'ping 有回 pong（閒置的房主靠它撐住連線）', JSON.stringify(m));

    // ── 8. 房主離開 → 整間關掉，客戶端被踢 ─────────────────────
    host.close();
    const closeCode = await Promise.race([
      cli.closed,
      new Promise((r) => setTimeout(() => r('沒被關'), 8000)),
    ]);
    check(closeCode === 4000, '房主離開後客戶端被關（code 4000）', String(closeCode));

    // ── 9. 房間真的被釋放：同一個房號可以重開 ────────────────────
    const again = peer(); alive.push(again);
    await again.open;
    again.send({ cmd: 'host', room });
    m = await again.next();
    check(m.cmd === 'welcome', '房主走後同房號可以重新開房（房間有被釋放）', JSON.stringify(m));
  } catch (e) {
    check(false, '測試流程本身沒有爆掉', e.message);
  } finally {
    alive.forEach((p) => { try { p.close(); } catch { /* 已經關了 */ } });
    if (child) child.kill();
  }

  console.log('');
  if (fails.length === 0) {
    console.log(`RESULT  ALL PASS（${checks} 項）`);
    process.exit(0);
  }
  console.log(`RESULT  FAILED ${fails.length}/${checks} ─ ${fails.join('、')}`);
  process.exit(1);
})();
