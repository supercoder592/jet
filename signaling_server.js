/**
 * 極簡 WebRTC 信令伺服器（配合 MainGame.gd 使用）
 *
 *   npm install ws
 *   node signaling_server.js            # 預設 ws://0.0.0.0:9080
 *
 * 只負責房間配對與 SDP/ICE 轉發，不碰任何遊戲邏輯。
 * 房主固定拿到 peer id = 1（對應 Godot 的 server peer）。
 *
 * 正式部署到 GitHub Pages 時，網頁是 https，瀏覽器會擋 ws://，
 * 請把本服務放在有 TLS 的主機上並改用 wss://（render.yaml 就是幹這件事的）。
 */

const http = require('http');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 9080;

// 閒置多久算死連線。房主開著房等人的期間不會有任何訊息流動，
// 光靠 TCP 是分不出「安靜地等」與「網路早就斷了」的 ─ 得主動探。
const HEARTBEAT_MS = 30000;
// 一間房最多幾個人（Godot 那邊 5v5，留點餘裕）
const MAX_PEERS = 16;
// 房間總數上限。沒有這個，隨便一支腳本就能無限開房把記憶體吃光。
const MAX_ROOMS = 500;
// SIG_VERBOSE=1 會把每一則轉發都印出來。交握失敗時這是唯一能看出
// 「誰沒把 SDP 送出來」的地方 ─ 兩邊的遊戲各自只看得到自己那一半。
const VERBOSE = process.env.SIG_VERBOSE === '1';

const server = http.createServer((req, res) => {
  // Render / Railway / Fly 這類平台會對根路徑做健康檢查，純 WebSocket 埠會被判定成掛掉
  res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(`signaling ok — rooms=${rooms.size} peers=${wss.clients.size}\n`);
});
const wss = new WebSocketServer({ server });

/** code -> { peers: Map<id, ws>, nextId: number } */
const rooms = new Map();

function send(ws, obj) {
  if (ws && ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

// 錯誤一律同時帶 code 與 msg：code 給程式判斷（例如撞號要自動重抽），
// msg 給玩家看。只靠中文訊息比對太脆弱，改一個字客戶端就壞掉。
function fail(ws, code, msg) {
  send(ws, { cmd: 'error', code, msg });
}

function leave(ws) {
  const room = rooms.get(ws.roomCode);
  if (!room) return;
  room.peers.delete(ws.peerId);
  for (const [, other] of room.peers) send(other, { cmd: 'peer_left', id: ws.peerId });
  // 房主離開 → 整間關掉
  if (ws.peerId === 1) {
    for (const [, other] of room.peers) other.close(4000, 'host left');
    rooms.delete(ws.roomCode);
  } else if (room.peers.size === 0) {
    rooms.delete(ws.roomCode);
  }
  console.log(`[room ${ws.roomCode}] peer ${ws.peerId} left`);
  ws.roomCode = null;
}

wss.on('connection', (ws) => {
  ws.peerId = 0;
  ws.roomCode = null;
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    ws.isAlive = true;

    switch (msg.cmd) {
      // 應用層的 keepalive。Godot 的 WebSocketPeer 沒有辦法主動發 protocol-level ping，
      // 而 Render 之類的反向代理會砍掉閒置太久的連線 ─ 房主開著房等人正好就是那種情況。
      case 'ping':
        send(ws, { cmd: 'pong' });
        break;

      case 'host': {
        const code = String(msg.room || '');
        if (!/^\d{4}$/.test(code)) return fail(ws, 'bad_room', '房號必須是 4 位數字');
        if (ws.roomCode) return fail(ws, 'already_in_room', '這條連線已經在房間裡了');
        if (rooms.has(code)) return fail(ws, 'room_taken', '房號已被使用');
        if (rooms.size >= MAX_ROOMS) return fail(ws, 'server_full', '伺服器房間數已達上限，請稍後再試');
        const room = { peers: new Map(), nextId: 2 };
        rooms.set(code, room);
        ws.peerId = 1;
        ws.roomCode = code;
        room.peers.set(1, ws);
        send(ws, { cmd: 'welcome', id: 1, room: code, host: true });
        console.log(`[room ${code}] created`);
        break;
      }

      case 'join': {
        const code = String(msg.room || '');
        if (ws.roomCode) return fail(ws, 'already_in_room', '這條連線已經在房間裡了');
        const room = rooms.get(code);
        if (!room) return fail(ws, 'no_room', '找不到房間 ' + code);
        if (room.peers.size >= MAX_PEERS) return fail(ws, 'room_full', '房間人數已滿');
        const host = room.peers.get(1);
        if (!host) return fail(ws, 'no_host', '房主已離線');
        const id = room.nextId++;
        ws.peerId = id;
        ws.roomCode = code;
        room.peers.set(id, ws);
        send(ws, { cmd: 'welcome', id, room: code, host: false });
        // 只通知房主，客戶端一律只跟房主 (id 1) 建立 P2P 連線
        send(host, { cmd: 'peer_join', id });
        console.log(`[room ${code}] peer ${id} joined`);
        break;
      }

      case 'sdp':
      case 'ice': {
        const room = rooms.get(ws.roomCode);
        if (!room) return;
        const target = room.peers.get(Number(msg.to));
        if (!target) return;
        const out = Object.assign({}, msg, { from: ws.peerId });
        delete out.to;
        send(target, out);
        if (VERBOSE) {
          const what = msg.cmd === 'sdp' ? `sdp/${msg.type}` : `ice ${String(msg.name).slice(0, 46)}`;
          console.log(`[room ${ws.roomCode}] ${ws.peerId} → ${msg.to}  ${what}`);
        }
        break;
      }
    }
  });

  ws.on('close', () => leave(ws));
  ws.on('error', () => leave(ws));
});

// 定期探活。沒有這段，一個沒有正常斷線的房主（關筆電、斷網）會把房號永遠佔住，
// 之後所有抽到同一個號碼的人都會拿到 room_taken。
const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) {
      console.log(`[room ${ws.roomCode}] peer ${ws.peerId} 沒有回應，斷開`);
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    try { ws.ping(); } catch { /* 正在關的連線，下一輪就被清掉 */ }
  }
}, HEARTBEAT_MS);
wss.on('close', () => clearInterval(heartbeat));

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Signaling server listening on port ${PORT}`);
});
