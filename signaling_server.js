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
 * 請把本服務放在有 TLS 的主機上並改用 wss://。
 */

const http = require('http');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 9080;

// 掛一個最小的 HTTP server 再把 WebSocket 接上去：
// Render / Railway / Fly 這類平台會對根路徑做健康檢查，純 WebSocket 埠會被判定成掛掉。
const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(`signaling ok — rooms=${rooms.size}\n`);
});
const wss = new WebSocketServer({ server });

/** code -> { peers: Map<id, ws>, nextId: number } */
const rooms = new Map();

function send(ws, obj) {
  if (ws && ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
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
}

wss.on('connection', (ws) => {
  ws.peerId = 0;
  ws.roomCode = null;

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }

    switch (msg.cmd) {
      case 'host': {
        const code = String(msg.room || '');
        if (rooms.has(code)) return send(ws, { cmd: 'error', msg: '房號已被使用' });
        rooms.set(code, { peers: new Map(), nextId: 2 });
        const room = rooms.get(code);
        ws.peerId = 1;
        ws.roomCode = code;
        room.peers.set(1, ws);
        send(ws, { cmd: 'welcome', id: 1, room: code, host: true });
        console.log(`[room ${code}] created`);
        break;
      }

      case 'join': {
        const code = String(msg.room || '');
        const room = rooms.get(code);
        if (!room) return send(ws, { cmd: 'error', msg: '找不到房間 ' + code });
        const id = room.nextId++;
        ws.peerId = id;
        ws.roomCode = code;
        room.peers.set(id, ws);
        send(ws, { cmd: 'welcome', id, room: code, host: false });
        // 只通知房主，客戶端一律只跟房主 (id 1) 建立 P2P 連線
        send(room.peers.get(1), { cmd: 'peer_join', id });
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
        break;
      }
    }
  });

  ws.on('close', () => leave(ws));
  ws.on('error', () => leave(ws));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Signaling server listening on port ${PORT}`);
});
