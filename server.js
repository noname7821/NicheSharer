// NicheShare signaling server (Phase 1).
// Room-based pairing like FlashDrop: the iPhone (receiver) opens a room
// and shows a 6-digit code, the PC joins with that code. This server only
// relays small messages (status, input events, offers/answers). Screen
// frames will go peer-to-peer (WebRTC) in Phase 2, not through here.
//
// REST:
//   POST /api/room                 -> { code }            (phone creates room)
//   GET  /api/room/:code           -> { exists, hasPhone, viewers, status }
//   POST /api/room/:code/heartbeat { status }            (phone keep-alive)
// WS:
//   /ws?code=XXXXXX&role=phone|pc  JSON messages:
//     pc   -> phone : { t:'input', kind:'tap'|'key', x, y, key }
//     phone-> pc    : { t:'status', sharing, note }
//     either        : { t:'ping' } -> { t:'pong' }

const express = require('express');
const http = require('http');
const path = require('path');
const WebSocket = require('ws');

const app = express();
const PORT = process.env.PORT || 3001;
const ROOM_TTL_MS = 10 * 60 * 1000;

app.use(express.json({ limit: '256kb' }));
app.use(express.static(path.join(__dirname, 'public')));

const rooms = new Map(); // code -> { createdAt, phone, pcs:Set, status }

function makeCode() {
  let code;
  do {
    code = String(Math.floor(100000 + Math.random() * 900000));
  } while (rooms.has(code));
  return code;
}

function getRoom(code) {
  const room = rooms.get(code);
  if (!room) return null;
  if (Date.now() - room.createdAt > ROOM_TTL_MS) {
    rooms.delete(code);
    return null;
  }
  return room;
}

function publicRoom(code, room) {
  return {
    exists: true,
    hasPhone: !!room.phone,
    viewers: room.pcs.size,
    status: room.status || null,
  };
}

app.post('/api/room', (req, res) => {
  const code = makeCode();
  rooms.set(code, { createdAt: Date.now(), phone: null, pcs: new Set(), status: null });
  res.json({ code });
});

app.get('/api/room/:code', (req, res) => {
  const room = getRoom(req.params.code);
  if (!room) return res.status(404).json({ exists: false });
  res.json(publicRoom(req.params.code, room));
});

app.post('/api/room/:code/heartbeat', (req, res) => {
  const room = getRoom(req.params.code);
  if (!room) return res.status(404).json({ exists: false });
  room.status = req.body && req.body.status ? req.body.status : room.status;
  const msg = JSON.stringify({ t: 'status', status: room.status });
  for (const pc of room.pcs) {
    if (pc.readyState === WebSocket.OPEN) pc.send(msg);
  }
  res.json({ ok: true });
});

const server = http.createServer(app);
const wss = new WebSocket.Server({ server, path: '/ws' });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const code = url.searchParams.get('code');
  const role = url.searchParams.get('role');
  const room = code ? getRoom(code) : null;
  if (!room || (role !== 'phone' && role !== 'pc')) {
    ws.close(4404, 'no such room');
    return;
  }

  if (role === 'phone') {
    if (room.phone) room.phone.close(4409, 'replaced');
    room.phone = ws;
    ws.on('close', () => {
      if (room.phone === ws) room.phone = null;
    });
  } else {
    room.pcs.add(ws);
    ws.on('close', () => room.pcs.delete(ws));
    if (room.status) {
      ws.send(JSON.stringify({ t: 'status', status: room.status }));
    }
  }

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (msg && msg.t === 'ping') {
      ws.send(JSON.stringify({ t: 'pong' }));
      return;
    }
    if (role === 'pc' && msg && msg.t === 'input') {
      if (room.phone && room.phone.readyState === WebSocket.OPEN) {
        room.phone.send(JSON.stringify(msg));
      }
      return;
    }
    if (role === 'phone' && msg && (msg.t === 'status' || msg.t === 'frame')) {
      room.status = msg.t === 'status' ? msg.status : room.status;
      const out = JSON.stringify(msg);
      for (const pc of room.pcs) {
        if (pc.readyState === WebSocket.OPEN) pc.send(out);
      }
    }
  });
});

// Sweep expired rooms every minute.
setInterval(() => {
  const now = Date.now();
  for (const [code, room] of rooms) {
    if (now - room.createdAt > ROOM_TTL_MS) rooms.delete(code);
  }
}, 60 * 1000).unref();

server.listen(PORT, () => console.log(`NicheShare signaling on port ${PORT}`));
