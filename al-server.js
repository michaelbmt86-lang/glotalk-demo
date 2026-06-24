/**
 * GloTalk Alibaba Server
 * 完全独立的 alibaba 项目服务器
 * 参考：LiveKit Server SDK 官方文档 + 阿里云 qwen3.5-livetranslate 官方文档
 */

'use strict';

const http   = require('http');
const fs     = require('fs');
const crypto = require('crypto');
const path   = require('path');

// ═══ 配置（从专属 .env 加载）═══
require('dotenv').config({ path: path.join(__dirname, 'config/.env') });

const PORT           = 3001;  // 独立端口，不与主服务器冲突
const DASHSCOPE_KEY  = process.env.DASHSCOPE_API_KEY;
const ALIBABA_WS_URL = process.env.ALIBABA_WS_URL;
const LK_API_KEY     = process.env.LIVEKIT_API_KEY;
const LK_API_SECRET  = process.env.LIVEKIT_API_SECRET;
const LK_URL         = process.env.LIVEKIT_URL;
const ADMIN_PASS     = process.env.ADMIN_AL_PASS;
const ACCESS_TOKEN   = process.env.ACCESS_TOKEN;

// ═══ 数据存储（专属路径）═══
const DATA_DIR       = path.join(__dirname, 'data');
const INVITES_FILE   = path.join(DATA_DIR, 'invites.json');
const AGENTS_FILE    = path.join(DATA_DIR, 'agents.json');

// ═══ 工具函数 ═══
function log(msg) {
  console.log(`[${new Date().toISOString()}] [alibaba] ${msg}`);
}

function jsonResp(res, body, status = 200) {
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-GloTalk-Token',
    'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
  });
  res.end(JSON.stringify(body));
}

function loadJSON(file) {
  try {
    if (fs.existsSync(file)) return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch(e) {}
  return {};
}

function saveJSON(file, data) {
  try { fs.writeFileSync(file, JSON.stringify(data, null, 2)); } catch(e) {}
}

function generateCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return Array.from({length: 3}, () => chars[Math.floor(Math.random() * chars.length)]).join('');
}

function generateRoomId() {
  return String(Math.floor(Math.random() * 90) + 10);
}

function generateAgentId() {
  return 'AG-' + crypto.randomBytes(3).toString('hex').toUpperCase();
}

// ═══ 数据初始化 ═══
let invites = loadJSON(INVITES_FILE);
let agents  = loadJSON(AGENTS_FILE);

// ═══ Bot 管理（完全独立）═══
const activeBots = new Map();

function spawnBot(room, srcLang, tgtLang, userIdentity) {
  const { spawn } = require('child_process');
  const botKey = `${room}:${srcLang}`;

  // 停止旧Bot
  if (activeBots.has(botKey)) {
    const old = activeBots.get(botKey);
    try { process.kill(old.pid, 'SIGTERM'); } catch(e) {}
    activeBots.delete(botKey);
    log(`终止旧Bot: ${botKey}`);
  }

  const bot = spawn('python3', [
    path.join(__dirname, 'bot/translation_bot.py'),
    room, srcLang, tgtLang, userIdentity
  ], {
    env: { ...process.env, ...require('dotenv').config({ path: path.join(__dirname, 'config/.env') }).parsed },
    detached: true,
    stdio: 'ignore'
  });

  bot.on('exit', () => {
    if (activeBots.get(botKey) === bot) activeBots.delete(botKey);
    log(`Bot退出: ${botKey}`);
    // 连带停止另一个Bot
    const otherKey = `${room}:${tgtLang}`;
    if (activeBots.has(otherKey)) {
      const other = activeBots.get(otherKey);
      try { process.kill(other.pid, 'SIGTERM'); } catch(e) {}
      activeBots.delete(otherKey);
      log(`连带停止Bot: ${otherKey}`);
    }
  });

  activeBots.set(botKey, bot);
  bot.unref();
  log(`启动Bot: room=${room} ${srcLang}→${tgtLang} for ${userIdentity}`);
}

// ═══ HTTP 服务器 ═══
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-GloTalk-Token',
      'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
    });
    res.end(); return;
  }


  if (req.method === 'GET' && url.pathname === '/al/admin/data') {
    const pass = url.searchParams.get('admin') || '';
    if (pass !== ADMIN_PASS) { jsonResp(res, {error: 'Unauthorized'}, 403); return; }
    jsonResp(res, { invites: Object.entries(invites).map(([code, inv]) => ({code, ...inv})), agents });
    return;
  }
  if (req.method === 'POST' && url.pathname === '/al/admin/agent/create') {
    const pass = url.searchParams.get('admin') || '';
    if (pass !== ADMIN_PASS) { jsonResp(res, {error: 'Unauthorized'}, 403); return; }
    let body = ''; req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const { name, monthlyBudgetRMB = 200 } = JSON.parse(body || '{}');
        const agentId = generateAgentId();
        const monthlyBudgetUSD = parseFloat((monthlyBudgetRMB / 7).toFixed(2));
        agents[agentId] = { name, monthlyBudgetRMB, monthlyBudgetUSD, active: true, createdAt: Date.now(), inviteCount: 0 };
        saveJSON(AGENTS_FILE, agents);
        jsonResp(res, { agentId, name, monthlyBudgetRMB, monthlyBudgetUSD });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  if (req.method === 'POST' && url.pathname === '/al/admin/agent/toggle') {
    const pass = url.searchParams.get('admin') || '';
    if (pass !== ADMIN_PASS) { jsonResp(res, {error: 'Unauthorized'}, 403); return; }
    let body = ''; req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const { agentId, action } = JSON.parse(body || '{}');
        agents[agentId].active = (action === 'enable');
        saveJSON(AGENTS_FILE, agents);
        jsonResp(res, { ok: true });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  if (req.method === 'POST' && url.pathname === '/al/admin/invite/revoke') {
    const pass = url.searchParams.get('admin') || '';
    if (pass !== ADMIN_PASS) { jsonResp(res, {error: 'Unauthorized'}, 403); return; }
    let body = ''; req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const { code } = JSON.parse(body || '{}');
        delete invites[code]; saveJSON(INVITES_FILE, invites);
        jsonResp(res, { ok: true });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  if (req.method === 'GET' && url.pathname === '/al/agent/status') {
    const agentId = url.searchParams.get('id');
    const ag = agents[agentId];
    if (ag == null) { jsonResp(res, {error: 'invalid'}, 403); return; }
    const myInvites = Object.entries(invites).filter(([, inv]) => inv.agentId === agentId).map(([code, inv]) => ({code, name: inv.name, status: Date.now() > inv.expiresAt ? 'expired' : 'active', duration: inv.duration}));
    jsonResp(res, { agentId, name: ag.name, active: ag.active, invites: myInvites });
    return;
  }
  // ── 健康检查 ──
  if (req.method === 'GET' && url.pathname === '/al/health') {
    jsonResp(res, { status: 'ok', service: 'GloTalk Alibaba Server', port: PORT });
    return;
  }

  // ── 邀请码验证 ──
  if (req.method === 'POST' && url.pathname === '/al/invite/verify') {
    let body = ''; req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const { code } = JSON.parse(body || '{}');
        const inv = invites[code];
        if (!inv) { jsonResp(res, {ok: false, error: '邀请码不存在'}); return; }
        if (Date.now() > inv.expiresAt) { jsonResp(res, {ok: false, error: '邀请码已过期'}); return; }
        jsonResp(res, {ok: true, roomId: inv.roomId, name: inv.name, duration: inv.duration});
      } catch(e) { jsonResp(res, {ok: false, error: e.message}); }
    }); return;
  }

  // ── LiveKit Token ──
  if (req.method === 'GET' && url.pathname === '/al/token') {
    const room     = url.searchParams.get('room') || generateRoomId();
    const identity = url.searchParams.get('identity') || ('用户-' + Date.now().toString(36));
    const lang     = url.searchParams.get('lang') || 'zh';
    try {
      const { AccessToken } = require('livekit-server-sdk');
      const at = new AccessToken(LK_API_KEY, LK_API_SECRET, { identity, ttl: 7200, attributes: { lang } });
      at.addGrant({ roomJoin: true, room, canPublish: true, canSubscribe: true, roomCreate: true });
      const token = await at.toJwt();
      jsonResp(res, { token, url: LK_URL, room, identity, lang });
      log(`Token: ${identity} room:${room} lang:${lang}`);
    } catch(e) { jsonResp(res, {error: e.message}, 500); }
    return;
  }

  // ── 启动Bot ──
  if (req.method === 'GET' && url.pathname === '/al/start-bot') {
    const { room, identity, source, target } = Object.fromEntries(url.searchParams);
    if (!room || !identity || !source || !target) {
      jsonResp(res, {ok: false, error: 'missing params'}, 400); return;
    }
    spawnBot(room, source, target, identity);
    jsonResp(res, {ok: true});
    return;
  }

  // ── 停止Bot ──
  if (req.method === 'GET' && url.pathname === '/al/stop-bot') {
    const { room, source } = Object.fromEntries(url.searchParams);
    const botKey = `${room}:${source}`;
    if (activeBots.has(botKey)) {
      const bot = activeBots.get(botKey);
      try { process.kill(bot.pid, 'SIGTERM'); } catch(e) {}
      activeBots.delete(botKey);
      log(`手动停止Bot: ${botKey}`);
    }
    jsonResp(res, {ok: true});
    return;
  }

  // ── 超管：生成邀请码 ──
  if (req.method === 'POST' && url.pathname === '/al/admin/invite') {
    const pass = url.searchParams.get('admin') || '';
    if (pass !== ADMIN_PASS) { jsonResp(res, {error: 'Unauthorized'}, 403); return; }
    let body = ''; req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const { name = '客户', duration = 1440 } = JSON.parse(body || '{}');
        const code = generateCode();
        const roomId = generateRoomId();
        const expiresAt = Date.now() + duration * 60 * 1000;
        invites[code] = { name, duration, expiresAt, roomId, createdAt: Date.now() };
        saveJSON(INVITES_FILE, invites);
        log(`邀请码生成: ${code}`);
        jsonResp(res, { ok: true, code, roomId, expiresAt, duration });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  // ── 代理：生成邀请码 ──
  if (req.method === 'POST' && url.pathname === '/al/agent/invite') {
    let body = ''; req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const { agentId, guestName = '客户', duration = 1440 } = JSON.parse(body || '{}');
        const ag = agents[agentId];
        if (!ag) { jsonResp(res, {error: '代理ID无效'}, 403); return; }
        if (!ag.active) { jsonResp(res, {error: '代理已停用'}, 403); return; }
        const code = generateCode();
        const roomId = code;
        const expiresAt = Date.now() + duration * 60 * 1000;
        invites[code] = { name: guestName, duration, expiresAt, roomId, agentId, createdAt: Date.now() };
        ag.inviteCount = (ag.inviteCount || 0) + 1;
        saveJSON(INVITES_FILE, invites);
        saveJSON(AGENTS_FILE, agents);
        log(`代理${agentId}生成邀请码: ${code}`);
        jsonResp(res, { ok: true, code, roomId, expiresAt, duration });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  // 404
  res.writeHead(404, {'Access-Control-Allow-Origin': '*'});
  res.end('Not found');
});

server.listen(PORT, () => {
  log(`Alibaba Server 启动，端口${PORT}`);
  log(`DASHSCOPE_KEY: ${DASHSCOPE_KEY ? '已配置' : '⚠️未配置'}`);
  log(`ALIBABA_WS_URL: ${ALIBABA_WS_URL || '⚠️未配置'}`);
  log(`LiveKit: ${LK_API_KEY ? '已配置' : '⚠️未配置'}`);
});
