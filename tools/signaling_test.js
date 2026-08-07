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

    // ── 7b. 房主離開 → 交棒給剩下的人（主機遷移）─────────────────
    {
      const mroom = code4();
      const h = peer(); alive.push(h);
      await h.open; h.send({ cmd: 'host', room: mroom }); await h.next();
      const c1 = peer(); alive.push(c1);
      await c1.open; c1.send({ cmd: 'join', room: mroom });
      check((await c1.next()).id === 2, '遷移前：第一個客戶端拿到 id 2');
      await h.next();  // 房主的 peer_join
      const c2 = peer(); alive.push(c2);
      await c2.open; c2.send({ cmd: 'join', room: mroom });
      check((await c2.next()).id === 3, '遷移前：第二個客戶端拿到 id 3');
      await h.next();  // 房主的 peer_join

      h.close();
      // 兩個人各自收到重新編號的通知
      const [m1, m2] = await Promise.all([c1.next(30000), c2.next(30000)]);
      check(m1.cmd === 'host_changed' && m1.id === 1 && m1.host === 1,
        '原 id 最小的客戶端被指派為新房主（id 變成 1）', JSON.stringify(m1));
      check(m2.cmd === 'host_changed' && m2.id === 2 && m2.host === 1,
        '另一個人被重新編號成 id 2，並被告知房主是 1', JSON.stringify(m2));
      // 新房主還要收到剩下那個人的 peer_join，才會去建連線
      const pj = await c1.next(15000);
      check(pj.cmd === 'peer_join' && pj.id === 2, '新房主收到剩餘玩家的 peer_join',
        JSON.stringify(pj));
      // 交接完之後這一間房要還在（房號沒被釋放，其他人才連得進來）
      const late = peer(); alive.push(late);
      await late.open; late.send({ cmd: 'join', room: mroom });
      const lm = await late.next(15000);
      check(lm.cmd === 'welcome', '交接後房間還在，新玩家仍然加得進來', JSON.stringify(lm));
    }

    // ── 8. 房主離開、只剩一個人 → 那個人接手，而不是被踢出去 ──────
    //
    // 這裡的秒數線上線下差很多：本機 TCP FIN 直接到，是瞬間的；
    // 線上 Render 的反向代理完全不轉發乾淨的 WebSocket 關閉，
    // 要等伺服器探活探到沒回應才知道房主走了（遊戲裡是由客戶端主動送
    // host_gone 來加速，這支測試沒有模擬那一步，所以會等滿一個探活週期）。
    const t0 = Date.now();
    host.close();
    const handover = await Promise.race([
      cli.next(70000).catch(() => null),
      new Promise((r) => setTimeout(() => r(null), 70000)),
    ]);
    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    check(handover != null && handover.cmd === 'host_changed' && handover.id === 1,
      '房主離開後，剩下的人被指派接手（而不是被踢）',
      `${secs} 秒，${JSON.stringify(handover)}`);

    // ── 9. 最後一個人也走了 → 房號才釋放 ───────────────────────
    cli.close();
    const again = peer(); alive.push(again);
    await again.open;
    let freed = null;
    for (let i = 0; i < 10 && !freed; i++) {
      again.send({ cmd: 'host', room });
      const r = await again.next();
      if (r.cmd === 'welcome') freed = r;
      else await new Promise((res) => setTimeout(res, 5000));
    }
    check(!!freed, '房間裡的人都走光之後房號才釋放',
      freed ? JSON.stringify(freed) : '一直是 room_taken');
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
