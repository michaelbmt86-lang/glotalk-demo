/**
 * GloTalk Server v3
 * 新增：一次性邀请码系统
 * 参考：Zoom会议室邀请码 + Discord服务器邀请链接设计
 */

const { handleGeminiRoutes } = require('./gemini-routes');
const https  = require("https");
const http   = require("http");
const fs     = require("fs");
const crypto = require("crypto");

// ═══ 配置 ═══
const PORT          = 3000;
const ACCESS_TOKEN  = process.env.ACCESS_TOKEN  || "glotalk2026";
const ADMIN_PASS    = process.env.ADMIN_PASS    || "gloAdmin2026";
const ADMIN_AL_PASS = process.env.ADMIN_AL_PASS || "gloAdminAL2026";
const OPENAI_KEY    = process.env.OPENAI_API_KEY;

const MAX_SESSIONS_PER_DAY = 50;
const MAX_SESSIONS_PER_IP  = 10;
const SESSION_MAX_MINUTES  = 30;
const BILLING_LOG = "/var/www/glotalk/billing.log";
const INVITE_FILE    = "/var/www/glotalk/invites.json";
const AGENT_FILE     = "/var/www/glotalk/agents.json";
const INVITE_AL_FILE = "/var/www/glotalk/invites-al.json";
const AGENT_AL_FILE  = "/var/www/glotalk/agents-al.json";

// ═══ 状态 ═══
let dailySessionCount = 0;
let dailyResetDate    = new Date().toDateString();
const ipSessionMap    = new Map();
const activeSessions  = new Map();

// ═══ 邀请码存储（持久化到文件）═══
function loadInvites() {
  try {
    if (fs.existsSync(INVITE_FILE)) {
      return JSON.parse(fs.readFileSync(INVITE_FILE, "utf8"));
    }
  } catch(e) {}
  return {};
}
function saveInvites(invites) {
  try { fs.writeFileSync(INVITE_FILE, JSON.stringify(invites, null, 2)); } catch(e) {}
}
let invites = loadInvites();

// ═══ 代理存储 ═══
function loadAgents() {
  try {
    if (fs.existsSync(AGENT_FILE)) return JSON.parse(fs.readFileSync(AGENT_FILE, "utf8"));
  } catch(e) {}
  return {};
}
function saveAgents(agents) {
  try { fs.writeFileSync(AGENT_FILE, JSON.stringify(agents, null, 2)); } catch(e) {}
}
let agents = loadAgents();
// alibaba-v1 独立数据
function loadInvitesAL() {
  try { if (fs.existsSync("/var/www/glotalk/invites-al.json")) return JSON.parse(fs.readFileSync("/var/www/glotalk/invites-al.json", "utf8")); } catch(e) {}
  return {};
}
function saveInvitesAL(data) {
  try { fs.writeFileSync("/var/www/glotalk/invites-al.json", JSON.stringify(data, null, 2)); } catch(e) {}
}
function loadAgentsAL() {
  try { if (fs.existsSync("/var/www/glotalk/agents-al.json")) return JSON.parse(fs.readFileSync("/var/www/glotalk/agents-al.json", "utf8")); } catch(e) {}
  return {};
}
function saveAgentsAL(data) {
  try { fs.writeFileSync("/var/www/glotalk/agents-al.json", JSON.stringify(data, null, 2)); } catch(e) {}
}
let invitesAL = loadInvitesAL();
let agentsAL  = loadAgentsAL();

// 生成代理ID
function generateAgentId() {
  return "AG-" + crypto.randomBytes(3).toString("hex").toUpperCase();
}

// 获取代理本月已使用费用（美元）
function getAgentMonthlyUsed(agentId) {
  try {
    const thisMonth = new Date().toISOString().slice(0, 7); // YYYY-MM
    const lines = fs.existsSync(BILLING_LOG)
      ? fs.readFileSync(BILLING_LOG, "utf8").trim().split("\n").filter(Boolean) : [];
    let total = 0;
    lines.filter(l => l.includes("CLOSE") && l.includes(agentId)).forEach(l => {
      const m = l.match(/\$(\d+\.\d+)/);
      if (m) total += parseFloat(m[1]);
    });
    return total;
  } catch(e) { return 0; }
}

// ═══ 工具函数 ═══
function log(msg) { console.log(`[${new Date().toISOString()}] ${msg}`); }

function jsonResp(res, body, status = 200) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-GloTalk-Token",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  });
  res.end(JSON.stringify(body));
}

function htmlResp(res, html) {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(html);
}

function verifyToken(req) {
  const url = new URL(req.url, "http://localhost");
  const h = req.headers["x-glotalk-token"] || "";
  const a = (req.headers["authorization"] || "").replace(/^Bearer\s+/i, "").trim();
  const q = url.searchParams.get("token") || "";
  return h === ACCESS_TOKEN || a === ACCESS_TOKEN || q === ACCESS_TOKEN;
}

function verifyAdmin(req) {
  const url = new URL(req.url, "http://localhost");
  const q = url.searchParams.get("admin") || "";
  const h = (req.headers["x-admin-pass"] || "");
  return q === ADMIN_PASS || h === ADMIN_PASS;
}

function getIP(req) {
  return req.headers["x-forwarded-for"]?.split(",")[0]?.trim() || req.socket?.remoteAddress || "unknown";
}

function checkDailyReset() {
  const today = new Date().toDateString();
  if (today !== dailyResetDate) {
    dailySessionCount = 0; dailyResetDate = today; ipSessionMap.clear();
    log("每日计数器已重置");
  }
}

function checkIPLimit(ip) {
  const now = Date.now(), oneHour = 3600000;
  const history = (ipSessionMap.get(ip) || []).filter(t => now - t < oneHour);
  if (history.length >= MAX_SESSIONS_PER_IP) return false;
  history.push(now); ipSessionMap.set(ip, history); return true;
}

function writeBillingLog(entry) {
  const line = [new Date().toISOString(), entry.sessionId, entry.outputLang||"-", entry.ip||"-",
    (entry.minutes||0)+"min", "$"+((entry.minutes||0)*0.034).toFixed(4), entry.event].join(" | ") + "\n";
  try { fs.appendFileSync(BILLING_LOG, line); } catch(e) {}
}

// ═══ 生成邀请码 ═══
function generateInviteCodeAL() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 3; i++) code += chars[Math.floor(Math.random() * chars.length)];
  return code;
}

function generateInviteCode() {
  // 用时间戳后4位+随机2位确保唯一性
  const ts = Date.now().toString(36).toUpperCase().slice(-4);
  const rnd = crypto.randomBytes(1).toString("hex").toUpperCase();
  return "GT-" + ts + rnd;
}

function generateRoomNumber() {
  // 生成2位数房间号（10-99，避免个位数）
  return String(Math.floor(Math.random() * 90) + 10);
}

// ═══ OpenAI session ═══
// [旧残留已禁用] fetchOpenAISession 函数已移除，由 _tlHandleTranslationToken 替代

// ═══ 管理员界面HTML ═══
function adminHTML() {
  const now = Date.now();
  const inviteList = Object.entries(invites).map(([code, inv]) => {
    const expired = now > inv.expiresAt;
    const used = inv.used;
    const remaining = expired ? 0 : Math.max(0, Math.floor((inv.expiresAt - now) / 60000));
    return `<tr class="${expired||used?'dim':''}">
      <td><b>${code}</b></td>
      <td>${inv.name||'-'}</td>
      <td>${used?'✅已使用':expired?'⏰已过期':'🟢可用'}</td>
      <td>${expired||used?'-':remaining+'分钟'}</td>
      <td>${inv.usedAt?new Date(inv.usedAt).toLocaleString():'-'}</td>
      <td>${inv.duration||30}分钟</td>
      <td><button onclick="revoke('${code}')">吊销</button></td>
    </tr>`;
  }).join("");

  // 读取代理列表
  const agentList = Object.entries(agents).map(([id, ag]) => {
    const used = getAgentMonthlyUsed(id);
    const remaining = Math.max(0, ag.monthlyBudgetUSD - used);
    const pct = ag.monthlyBudgetUSD > 0 ? Math.round(used/ag.monthlyBudgetUSD*100) : 0;
    return `<tr class="${!ag.active?'dim':''}">
      <td><b>${id}</b></td>
      <td>${ag.name}</td>
      <td>${ag.active?'🟢 活跃':'🔴 停用'}</td>
      <td>¥${ag.monthlyBudgetRMB} ($${ag.monthlyBudgetUSD.toFixed(2)})</td>
      <td style="color:${pct>80?'#ef4444':'#22c55e'}">$${used.toFixed(4)} (${pct}%)</td>
      <td>$${remaining.toFixed(4)}</td>
      <td>${ag.createdAt?new Date(ag.createdAt).toLocaleDateString():'-'}</td>
      <td>
        <button onclick="toggleAgent('${id}','${ag.active?'disable':'enable'}')" style="background:${ag.active?'#ef444422':'#22c55e22'};color:${ag.active?'#ef4444':'#22c55e'};border:1px solid;border-radius:6px;padding:3px 8px;cursor:pointer;font-size:12px">
          ${ag.active?'停用':'启用'}
        </button>
      </td>
    </tr>`;
  }).join("");

  // 读取billing统计
  let totalCost = "$0.0000", totalSessions = 0;
  try {
    const lines = fs.existsSync(BILLING_LOG)
      ? fs.readFileSync(BILLING_LOG, "utf8").trim().split("\n").filter(Boolean) : [];
    const closes = lines.filter(l => l.includes("CLOSE"));
    let total = 0;
    closes.forEach(l => { const m = l.match(/\$(\d+\.\d+)/); if(m) total += parseFloat(m[1]); });
    totalCost = "$" + total.toFixed(4);
    totalSessions = closes.length;
  } catch(e) {}

  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>GloTalk 管理后台</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#0a0a0a;color:#f0f0f0;font-family:-apple-system,sans-serif;padding:20px}
  h1{color:#22c55e;font-size:24px;margin-bottom:20px}
  h2{color:#888;font-size:13px;margin:8px 0 8px}
  .card{background:#111;border:1px solid #222;border-radius:10px;padding:10px 14px;margin-bottom:10px}
  .stats{display:flex;gap:16px;flex-wrap:wrap}
  .stat{background:#1a1a1a;border-radius:8px;padding:12px 16px;flex:1;min-width:120px}
  .stat-val{font-size:22px;font-weight:800;color:#22c55e}
  .stat-label{font-size:11px;color:#555;margin-top:4px}
  input,select{background:#1a1a1a;border:1px solid #333;border-radius:8px;color:#f0f0f0;
    font:inherit;font-size:14px;padding:8px 12px;outline:none;width:100%}
  .row{display:flex;gap:8px;margin-bottom:8px}
  .row input,.row select{flex:1}
  button{background:#22c55e;color:#000;border:none;border-radius:8px;padding:10px 20px;
    font:inherit;font-size:14px;font-weight:700;cursor:pointer;width:100%}
  button.danger{background:#ef4444;color:#fff}
  button.small{width:auto;padding:4px 10px;font-size:12px;background:#333;color:#888}
  table{width:100%;border-collapse:collapse;font-size:13px}
  th{text-align:left;color:#555;padding:6px 8px;border-bottom:1px solid #222}
  td{padding:8px;border-bottom:1px solid #1a1a1a}
  .dim td{color:#444}
  #msg{padding:10px;border-radius:8px;background:#0d1a0f;color:#22c55e;display:none;margin-top:8px}
  #msg.err{background:#1a0f0f;color:#ef4444}
</style>
</head>
<body>
<h1>GloTalk 管理后台</h1>

<div class="card">
  <h2>📊 费用统计</h2>
  <div class="stats">
    <div class="stat"><div class="stat-val">${totalSessions}</div><div class="stat-label">累计通话次数</div></div>
    <div class="stat"><div class="stat-val">${totalCost}</div><div class="stat-label">累计费用</div></div>
    <div class="stat"><div class="stat-val">${dailySessionCount}</div><div class="stat-label">今日session数</div></div>
    <div class="stat"><div class="stat-val">${MAX_SESSIONS_PER_DAY - dailySessionCount}</div><div class="stat-label">今日剩余</div></div>
  </div>
</div>

<div class="card">
  <h2>👥 代理管理</h2>
  <div class="row">
    <input id="agentName" placeholder="代理姓名"/>
    <input id="agentBudget" placeholder="月度额度（人民币）" type="number" value="200"/>
  </div>
  <button onclick="createAgent()">创建代理账号</button>
  <div id="agentMsg" style="display:none;padding:8px;margin-top:8px;border-radius:6px;font-size:13px"></div>
  <br/>
  <table>
    <tr><th>代理ID</th><th>姓名</th><th>状态</th><th>月额度</th><th>本月已用</th><th>剩余</th><th>创建日期</th><th>操作</th></tr>
    ${agentList || '<tr><td colspan="8" style="color:#333;text-align:center;padding:16px">暂无代理</td></tr>'}
  </table>
</div>

<div class="card">
  <h2>🎫 生成邀请码</h2>
  <div class="row">
    <input id="inviteName" placeholder="被邀请人姓名（备注）"/>
    <select id="inviteDuration">
      <option value="30">30分钟</option>
      <option value="60" selected>60分钟</option>
      <option value="120">2小时</option>
      <option value="480">8小时</option>
      <option value="1440">24小时</option>
    </select>
  </div>
  <button id="createInviteBtn" onclick="createInvite()">生成邀请码</button>
  <div id="msg"></div>
</div>

<div class="card">
  <h2>📋 邀请码列表</h2>
  <table>
    <tr><th>邀请码</th><th>备注</th><th>状态</th><th>剩余</th><th>使用时间</th><th>有效期</th><th>操作</th></tr>
    ${inviteList || '<tr><td colspan="7" style="color:#333;text-align:center;padding:20px">暂无邀请码</td></tr>'}
  </table>
</div>

<script>
const ADMIN = new URLSearchParams(location.search).get('admin') || '';
const BASE_URL = 'https://glotalk.tech/glotalk-fullduplex.html';
const LANGS = [
  {c:'zh',l:'中文'},{c:'en',l:'英文'},{c:'ja',l:'日文'},{c:'ko',l:'韩文'},
  {c:'es',l:'西文'},{c:'fr',l:'法文'},{c:'de',l:'德文'},{c:'ar',l:'阿文'}
];

function showMsg(text, isErr) {
  const m = document.getElementById('msg');
  m.textContent = text;
  m.style.display = 'block';
  m.className = isErr ? 'err' : '';
  setTimeout(function(){ m.style.display='none'; }, 5000);
}

function copyLang(lang) {
  const code = window._lastCode || '';
  const txt = '邀请码：' + code + ' | 链接：' + BASE_URL + '?lang=' + lang;
  navigator.clipboard.writeText(txt).then(function(){
    const btn = document.getElementById('lang_' + lang);
    if(btn){ btn.style.background='#22c55e'; btn.style.color='#000'; btn.textContent='✅'; }
  });
}

async function createInvite() {
  const btn = document.getElementById('createInviteBtn');
  if(btn.disabled) return;
  btn.disabled = true;
  btn.textContent = '生成中...';
  const name = document.getElementById('inviteName').value.trim() || '测试用户';
  const duration = parseInt(document.getElementById('inviteDuration').value);
  try {
    const r = await fetch('/admin/invite?admin=' + ADMIN, {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({name:name, duration:duration})
    });
    const d = await r.json();
    if(d.code) {
      window._lastCode = d.code;
      let btns = '';
      LANGS.forEach(function(lg){
        btns += '<button id="lang_' + lg.c + '" onclick="copyLang(' + "'" + lg.c + "'" + ')" ' +
          'style="background:#1a1a1a;border:1px solid #333;border-radius:8px;color:#888;' +
          'font-size:11px;padding:6px 8px;cursor:pointer;flex:1;min-width:55px;text-align:center">' +
          lg.l + '</button>';
      });
      const m = document.getElementById('msg');
      m.innerHTML = '<div style="color:#22c55e;font-weight:700;margin-bottom:6px">✅ ' + d.code + 
        ' <span style="color:#666;font-weight:400;font-size:12px">有效期' + duration + '分钟</span></div>' +
        '<div style="color:#888;font-size:12px;margin-bottom:6px">点语言按钮复制链接+邀请码发给对方：</div>' +
        '<div style="display:flex;flex-wrap:wrap;gap:6px">' + btns + '</div>';
      m.style.display = 'block';
      m.className = '';
      btn.textContent = '再生成一个';
      btn.disabled = false;
      setTimeout(function(){ location.reload(); }, 120000);
    } else {
      showMsg('❌ ' + (d.error || '生成失败'), true);
      btn.textContent = '生成邀请码';
      btn.disabled = false;
    }
  } catch(e) {
    showMsg('❌ 网络错误', true);
    btn.textContent = '生成邀请码';
    btn.disabled = false;
  }
}

async function createAgent() {
  const name = document.getElementById('agentName').value.trim();
  const budget = parseFloat(document.getElementById('agentBudget').value) || 200;
  if(!name){ alert('请输入代理姓名'); return; }
  const r = await fetch('/admin/agent/create?admin=' + ADMIN, {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({name:name, monthlyBudgetRMB:budget})
  });
  const d = await r.json();
  const msg = document.getElementById('agentMsg');
  if(d.agentId){
    const agentLink = 'https://glotalk.tech/agent.html?id=' + d.agentId;
    msg.style.background='#0d1a0f'; msg.style.color='#22c55e';
    msg.innerHTML = 
      '<div style="font-weight:700;margin-bottom:8px">✅ 代理已创建：' + d.agentId + ' (' + name + ') 月额度¥' + budget + '</div>' +
      '<div style="color:#888;font-size:12px;margin-bottom:6px">发给代理的链接（点复制）：</div>' +
      '<div style="display:flex;align-items:center;gap:8px">' +
        '<div style="flex:1;background:#111;border:1px solid #222;border-radius:6px;padding:6px 8px;font-size:12px;color:#22c55e;word-break:break-all">' + agentLink + '</div>' +
        '<button id="copyAgentLink" style="background:#22c55e;color:#000;border:none;border-radius:6px;padding:6px 12px;font-size:12px;font-weight:700;cursor:pointer;white-space:nowrap">📋 复制</button>' +
      '</div>';
    msg.style.display = 'block';
    document.getElementById('copyAgentLink').onclick = function(){
      navigator.clipboard.writeText(agentLink).then(function(){
        document.getElementById('copyAgentLink').textContent='✅ 已复制';
      }).catch(function(){
        var el=document.createElement('textarea');
        el.value=agentLink;el.style.position='fixed';el.style.opacity='0';
        document.body.appendChild(el);el.select();document.execCommand('copy');
        document.body.removeChild(el);
        document.getElementById('copyAgentLink').textContent='✅ 已复制';
      });
    };
    setTimeout(function(){ location.reload(); }, 30000);
  } else {
    msg.style.background='#1a0f0f'; msg.style.color='#ef4444';
    msg.textContent = '❌ ' + (d.error || '创建失败');
    msg.style.display = 'block';
  }
}

async function toggleAgent(agentId, action) {
  const r = await fetch('/admin/agent/toggle?admin=' + ADMIN, {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({agentId:agentId, action:action})
  });
  const d = await r.json();
  if(d.ok) location.reload();
  else alert('操作失败: ' + d.error);
}

async function revoke(code) {
  if(!confirm('确定吊销 ' + code + '？')) return;
  const r = await fetch('/admin/invite/revoke?admin=' + ADMIN, {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({code:code})
  });
  const d = await r.json();
  if(d.ok){ showMsg('✅ 已吊销 ' + code); setTimeout(function(){ location.reload(); }, 1000); }
  else showMsg('❌ ' + d.error, true);
}
</script>
</body>
</html>`;
}

// ═══ alibaba-v1 Admin HTML ═══


// ═══ HTTP服务 ═══
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Content-Type, Authorization, X-GloTalk-Token",
      "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    });
    res.end(); return;
  }

  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-GloTalk-Token");

  // ── 健康检查 ──────────────────────────────────────────
  if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
    jsonResp(res, { status:"ok", service:"GloTalk Server v3",
      daily_sessions:dailySessionCount, daily_limit:MAX_SESSIONS_PER_DAY,
      active_sessions:activeSessions.size });
    return;
  }

  // ── 管理员界面 ────────────────────────────────────────
  if (req.method === "GET" && url.pathname === "/admin") {
    if (!verifyAdmin(req)) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    htmlResp(res, adminHTML()); return;
  }
  if (req.method === "GET" && url.pathname.startsWith("/g/")) {
    const code = url.pathname.slice(3).toUpperCase();
    const lang = url.searchParams.get("lang") || "";
    const langParam = lang ? "&lang=" + lang : "";
    res.writeHead(302, {"Location": "https://glotalk.tech/glotalk-al.html?code=" + code + langParam, "Access-Control-Allow-Origin": "*"});
    res.end(); return;
  }

  if (req.method === "GET" && url.pathname === "/admin-al") {
    const q = url.searchParams.get("admin") || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    const alHtml = fs.readFileSync('/var/www/glotalk/admin-al.html', 'utf8');
    htmlResp(res, alHtml); return;
  }

  // ── alibaba-v1 独立接口 ──────────────────────────
  if (req.method === "POST" && url.pathname === "/invite-al/verify") {
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { code } = JSON.parse(body || "{}");
        const inv = invitesAL[code];
        if (!inv) { jsonResp(res, {ok:false, error:"邀请码不存在"}); return; }
        if (Date.now() > inv.expiresAt) { jsonResp(res, {ok:false, error:"邀请码已过期"}); return; }
        // 不标记已使用，允许多次使用
        const roomId = inv.roomId || code;
        jsonResp(res, {ok:true, roomId, name:inv.name, duration:inv.duration});
      } catch(e) { jsonResp(res, {ok:false, error:e.message}); }
    }); return;
  }

  if (req.method === "GET" && url.pathname === "/admin-al/data") {
    const q = url.searchParams.get("admin") || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    jsonResp(res, { invites: invitesAL, agents: agentsAL }); return;
  }
  if (req.method === "POST" && url.pathname === "/admin-al/invite") {
    const q = url.searchParams.get("admin") || req.headers["x-admin-pass"] || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { name = "\u6d4b\u8bd5\u7528\u6237", duration = 60 } = JSON.parse(body || "{}");
        const code = generateInviteCodeAL();
        const roomId = generateRoomNumber();
        const expiresAt = Date.now() + duration * 60 * 1000;
        invitesAL[code] = { name, duration, expiresAt, used: false, createdAt: Date.now(), usedAt: null, roomId };
        saveInvitesAL(invitesAL);
        log("[AL] \u9080\u8bf7\u7801\u751f\u6210: " + code);
        jsonResp(res, { code, expiresAt, duration, roomId });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  if (req.method === "POST" && url.pathname === "/admin-al/invite/revoke") {
    const q = url.searchParams.get("admin") || req.headers["x-admin-pass"] || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { code } = JSON.parse(body || "{}");
        if (!invitesAL[code]) { jsonResp(res, {error:"\u9080\u8bf7\u7801\u4e0d\u5b58\u5728"}, 404); return; }
        delete invitesAL[code]; saveInvitesAL(invitesAL);
        jsonResp(res, { ok: true });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  if (req.method === "POST" && url.pathname === "/admin-al/agent/create") {
    const q = url.searchParams.get("admin") || req.headers["x-admin-pass"] || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { name, monthlyBudgetRMB = 200 } = JSON.parse(body || "{}");
        if (!name) { jsonResp(res, {error:"\u8bf7\u8f93\u5165\u4ee3\u7406\u59d3\u540d"}, 400); return; }
        const agentId = generateAgentId();
        const monthlyBudgetUSD = parseFloat((monthlyBudgetRMB / 7).toFixed(2));
        agentsAL[agentId] = { name, monthlyBudgetRMB, monthlyBudgetUSD, active: true, createdAt: Date.now(), inviteCount: 0 };
        saveAgentsAL(agentsAL);
        jsonResp(res, { agentId, name, monthlyBudgetRMB, monthlyBudgetUSD });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  if (req.method === "POST" && url.pathname === "/admin-al/agent/toggle") {
    const q = url.searchParams.get("admin") || req.headers["x-admin-pass"] || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { agentId, action } = JSON.parse(body || "{}");
        if (!agentsAL[agentId]) { jsonResp(res, {error:"\u4ee3\u7406\u4e0d\u5b58\u5728"}, 404); return; }
        agentsAL[agentId].active = (action === "enable");
        saveAgentsAL(agentsAL);
        jsonResp(res, { ok: true });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  // ── alibaba-v1 独立接口 ──────────────────────────
  if (req.method === "POST" && url.pathname === "/invite-al/verify") {
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { code } = JSON.parse(body || "{}");
        const inv = invitesAL[code];
        if (!inv) { jsonResp(res, {ok:false, error:"邀请码不存在"}); return; }
        if (Date.now() > inv.expiresAt) { jsonResp(res, {ok:false, error:"邀请码已过期"}); return; }
        // 不标记已使用，允许多次使用
        const roomId = inv.roomId || code;
        jsonResp(res, {ok:true, roomId, name:inv.name, duration:inv.duration});
      } catch(e) { jsonResp(res, {ok:false, error:e.message}); }
    }); return;
  }

  if (req.method === "GET" && url.pathname === "/admin-al/data") {
    const q = url.searchParams.get("admin") || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    jsonResp(res, { invites: invitesAL, agents: agentsAL }); return;
  }
  if (req.method === "POST" && url.pathname === "/admin-al/invite") {
    const q = url.searchParams.get("admin") || req.headers["x-admin-pass"] || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { name = "\u6d4b\u8bd5\u7528\u6237", duration = 60 } = JSON.parse(body || "{}");
        const code = generateInviteCodeAL();
        const roomId = generateRoomNumber();
        const expiresAt = Date.now() + duration * 60 * 1000;
        invitesAL[code] = { name, duration, expiresAt, used: false, createdAt: Date.now(), usedAt: null, roomId };
        saveInvitesAL(invitesAL);
        log("[AL] \u9080\u8bf7\u7801\u751f\u6210: " + code);
        jsonResp(res, { code, expiresAt, duration, roomId });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  if (req.method === "POST" && url.pathname === "/admin-al/invite/revoke") {
    const q = url.searchParams.get("admin") || req.headers["x-admin-pass"] || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { code } = JSON.parse(body || "{}");
        if (!invitesAL[code]) { jsonResp(res, {error:"\u9080\u8bf7\u7801\u4e0d\u5b58\u5728"}, 404); return; }
        delete invitesAL[code]; saveInvitesAL(invitesAL);
        jsonResp(res, { ok: true });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  if (req.method === "POST" && url.pathname === "/admin-al/agent/create") {
    const q = url.searchParams.get("admin") || req.headers["x-admin-pass"] || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { name, monthlyBudgetRMB = 200 } = JSON.parse(body || "{}");
        if (!name) { jsonResp(res, {error:"\u8bf7\u8f93\u5165\u4ee3\u7406\u59d3\u540d"}, 400); return; }
        const agentId = generateAgentId();
        const monthlyBudgetUSD = parseFloat((monthlyBudgetRMB / 7).toFixed(2));
        agentsAL[agentId] = { name, monthlyBudgetRMB, monthlyBudgetUSD, active: true, createdAt: Date.now(), inviteCount: 0 };
        saveAgentsAL(agentsAL);
        jsonResp(res, { agentId, name, monthlyBudgetRMB, monthlyBudgetUSD });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  if (req.method === "POST" && url.pathname === "/admin-al/agent/toggle") {
    const q = url.searchParams.get("admin") || req.headers["x-admin-pass"] || "";
    if (q !== ADMIN_AL_PASS) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { agentId, action } = JSON.parse(body || "{}");
        if (!agentsAL[agentId]) { jsonResp(res, {error:"\u4ee3\u7406\u4e0d\u5b58\u5728"}, 404); return; }
        agentsAL[agentId].active = (action === "enable");
        saveAgentsAL(agentsAL);
        jsonResp(res, { ok: true });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }
  // ── 生成邀请码 ────────────────────────────────────────
  if (req.method === "POST" && url.pathname === "/admin/invite") {
    if (!verifyAdmin(req)) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { name = "测试用户", duration = 60 } = JSON.parse(body || "{}");
        const code = generateInviteCode();
        const roomId = generateRoomNumber(); // 2位数房间号
        const expiresAt = Date.now() + duration * 60 * 1000;
        invites[code] = { name, duration, expiresAt, used: false, createdAt: Date.now(), usedAt: null, roomId };
        saveInvites(invites);
        log(`🎫 邀请码生成: ${code} 给${name} 有效${duration}分钟`);
        jsonResp(res, { code, expiresAt, duration, roomId });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  // ── 吊销邀请码 ────────────────────────────────────────
  if (req.method === "POST" && url.pathname === "/admin/invite/revoke") {
    if (!verifyAdmin(req)) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { code } = JSON.parse(body || "{}");
        if (!invites[code]) { jsonResp(res, {error:"邀请码不存在"}, 404); return; }
        delete invites[code]; saveInvites(invites);
        log(`🚫 邀请码已吊销: ${code}`);
        jsonResp(res, { ok: true });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  // ── 创建代理 ──────────────────────────────────────────
  if (req.method === "POST" && url.pathname === "/admin/agent/create") {
    if (!verifyAdmin(req)) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { name, monthlyBudgetRMB = 200 } = JSON.parse(body || "{}");
        if (!name) { jsonResp(res, {error:"请输入代理姓名"}, 400); return; }
        const agentId = generateAgentId();
        const monthlyBudgetUSD = parseFloat((monthlyBudgetRMB / 7).toFixed(2));
        agents[agentId] = {
          name, monthlyBudgetRMB, monthlyBudgetUSD,
          active: true, createdAt: Date.now(), inviteCount: 0
        };
        saveAgents(agents);
        log(`👤 代理创建: ${agentId} ${name} 月额度¥${monthlyBudgetRMB}($${monthlyBudgetUSD})`);
        jsonResp(res, { agentId, name, monthlyBudgetRMB, monthlyBudgetUSD });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  // ── 停用/启用代理 ─────────────────────────────────────
  if (req.method === "POST" && url.pathname === "/admin/agent/toggle") {
    if (!verifyAdmin(req)) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { agentId, action } = JSON.parse(body || "{}");
        if (!agents[agentId]) { jsonResp(res, {error:"代理不存在"}, 404); return; }
        agents[agentId].active = (action === "enable");
        saveAgents(agents);
        log(`👤 代理${action}: ${agentId}`);
        jsonResp(res, { ok: true });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  // ── 代理生成邀请码（消耗代理额度） ────────────────────
  // ── alibaba-v1 代理接口 ──────────────────────────────
  if (req.method === "GET" && url.pathname === "/agent-al/status") {
    const agentId = url.searchParams.get("id");
    const ag = agentsAL[agentId];
    if (!ag) { jsonResp(res, {error:"代理ID无效"}, 403); return; }
    const myInvites = Object.entries(invitesAL)
      .filter(([, inv]) => inv.agentId === agentId)
      .map(([code, inv]) => ({
        code, name: inv.name,
        status: Date.now() > inv.expiresAt ? "已过期" : "可用",
        duration: inv.duration
      }));
    jsonResp(res, {
      agentId, name: ag.name, active: ag.active,
      monthlyBudgetRMB: ag.monthlyBudgetRMB,
      monthlyBudgetUSD: ag.monthlyBudgetUSD,
      usedUSD: "0.0000",
      remainingUSD: ag.monthlyBudgetUSD.toFixed(4),
      remainingMinutes: Math.floor(ag.monthlyBudgetUSD / 0.046 * 60),
      invites: myInvites
    });
    return;
  }

  if (req.method === "POST" && url.pathname === "/agent-al/invite/create") {
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { agentId, guestName = "客户", duration = 1440 } = JSON.parse(body || "{}");
        const ag = agentsAL[agentId];
        if (!ag) { jsonResp(res, {error:"代理ID无效"}, 403); return; }
        if (!ag.active) { jsonResp(res, {error:"代理账号已停用"}, 403); return; }
        const code = generateInviteCodeAL();
        const roomId = code;
        const expiresAt = Date.now() + duration * 60 * 1000;
        invitesAL[code] = {
          name: guestName, duration, expiresAt,
          used: false, createdAt: Date.now(), usedAt: null,
          roomId, agentId, agentName: ag.name
        };
        ag.inviteCount = (ag.inviteCount || 0) + 1;
        saveInvitesAL(invitesAL);
        saveAgentsAL(agentsAL);
        log("[AL] 代理" + agentId + "生成邀请码: " + code);
        jsonResp(res, { ok: true, code, roomId, expiresAt, duration });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  if (req.method === "POST" && url.pathname === "/agent/invite/create") {
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { agentId, guestName = "客户", duration = 60 } = JSON.parse(body || "{}");
        const ag = agents[agentId];
        if (!ag) { jsonResp(res, {error:"代理ID无效"}, 403); return; }
        if (!ag.active) { jsonResp(res, {error:"代理账号已停用"}, 403); return; }
        // 检查本月额度
        const used = getAgentMonthlyUsed(agentId);
        const remaining = ag.monthlyBudgetUSD - used;
        const estimatedCost = duration * 0.068 / 60 * 10; // 估算10分钟成本
        if (remaining < 0.068) {
          jsonResp(res, {error:`本月额度已用完（已用$${used.toFixed(2)}/$${ag.monthlyBudgetUSD}）`}, 429);
          return;
        }
        const code = generateInviteCode();
        const roomId = generateRoomNumber(); // 2位数房间号
        const expiresAt = Date.now() + duration * 60 * 1000;
        invites[code] = {
          name: guestName, duration, expiresAt,
          used: false, createdAt: Date.now(), usedAt: null,
          roomId, agentId, agentName: ag.name
        };
        ag.inviteCount = (ag.inviteCount || 0) + 1;
        saveInvites(invites);
        saveAgents(agents);
        log(`🎫 代理${agentId}(${ag.name})生成邀请码: ${code} 给${guestName} 剩余额度$${remaining.toFixed(2)}`);
        jsonResp(res, {
          ok: true, code, roomId, expiresAt, duration,
          remaining: remaining.toFixed(2),
          budgetUSD: ag.monthlyBudgetUSD
        });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  // ── 代理查看自己的状态 ─────────────────────────────────
  if (req.method === "GET" && url.pathname === "/agent/status") {
    const agentId = url.searchParams.get("id");
    const ag = agents[agentId];
    if (!ag) { jsonResp(res, {error:"代理ID无效"}, 403); return; }
    const used = getAgentMonthlyUsed(agentId);
    const remaining = Math.max(0, ag.monthlyBudgetUSD - used);
    const myInvites = Object.entries(invites)
      .filter(([, inv]) => inv.agentId === agentId)
      .map(([code, inv]) => ({
        code, name: inv.name,
        status: inv.used ? "已使用" : Date.now() > inv.expiresAt ? "已过期" : "可用",
        usedAt: inv.usedAt ? new Date(inv.usedAt).toLocaleString() : "-",
        duration: inv.duration
      }));
    jsonResp(res, {
      agentId, name: ag.name, active: ag.active,
      monthlyBudgetRMB: ag.monthlyBudgetRMB,
      monthlyBudgetUSD: ag.monthlyBudgetUSD,
      usedUSD: used.toFixed(4),
      remainingUSD: remaining.toFixed(4),
      remainingMinutes: Math.floor(remaining / 0.068),
      invites: myInvites
    });
    return;
  }

  // ── 验证邀请码（通话开始时调用） ──────────────────────
  if (req.method === "POST" && url.pathname === "/invite/verify") {
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { code } = JSON.parse(body || "{}");
        if (!code) { jsonResp(res, {error:"请输入邀请码"}, 400); return; }
        const inv = invites[code.toUpperCase()];
        if (!inv) { jsonResp(res, {error:"邀请码无效"}, 403); return; }
        if (inv.used) { jsonResp(res, {error:"邀请码已使用"}, 403); return; }
        if (Date.now() > inv.expiresAt) { jsonResp(res, {error:"邀请码已过期"}, 403); return; }
        log(`✅ 邀请码验证通过: ${code} (${inv.name}) 房间:${inv.roomId}`);
        jsonResp(res, { ok: true, name: inv.name, duration: inv.duration, roomId: inv.roomId });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  // ── 标记邀请码已使用 ──────────────────────────────────
  if (req.method === "POST" && url.pathname === "/invite/use") {
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { code } = JSON.parse(body || "{}");
        const inv = invites[code?.toUpperCase()];
        if (inv && !inv.used && Date.now() <= inv.expiresAt) {
          inv.used = true; inv.usedAt = Date.now();
          saveInvites(invites);
          log(`📞 邀请码已使用: ${code} (${inv.name})`);
        }
        jsonResp(res, { ok: true });
      } catch(e) { jsonResp(res, {error: e.message}, 500); }
    }); return;
  }

  // ── billing统计 ───────────────────────────────────────
  if (req.method === "GET" && url.pathname === "/billing") {
    const tok = url.searchParams.get("token") || (req.headers["authorization"]||"").replace(/^Bearer /i,"").trim();
    if (tok !== ACCESS_TOKEN && !verifyAdmin(req)) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    try {
      const lines = fs.existsSync(BILLING_LOG)
        ? fs.readFileSync(BILLING_LOG,"utf8").trim().split("\n").filter(Boolean) : [];
      const closes = lines.filter(l => l.includes("CLOSE"));
      let total = 0;
      closes.forEach(l => { const m = l.match(/\$(\d+\.\d+)/); if(m) total += parseFloat(m[1]); });
      const today = new Date().toISOString().slice(0,10);
      const todayCloses = closes.filter(l => l.startsWith(today));
      let todayTotal = 0;
      todayCloses.forEach(l => { const m = l.match(/\$(\d+\.\d+)/); if(m) todayTotal += parseFloat(m[1]); });
      jsonResp(res, { today_cost:"$"+todayTotal.toFixed(4), today_sessions:todayCloses.length,
        total_cost:"$"+total.toFixed(4), total_sessions:closes.length, last_20:closes.slice(-20) });
    } catch(e) { jsonResp(res, {error: e.message}, 500); }
    return;
  }

  // ── 以下需要ACCESS_TOKEN ──────────────────────────────
  // 放行路线A和路线B的API接口（不需要用户token）
  if (url.pathname === "/api/translation-token" || url.pathname.startsWith("/api/gemini/") || url.pathname === "/alibaba-token" || url.pathname === "/alibaba-ws" || url.pathname === "/livekit-token" || url.pathname === "/start-bot" || url.pathname === "/stop-bot" || url.pathname.startsWith("/al-web/") || url.pathname.startsWith("/al-app/") || url.pathname.startsWith("/agent-al/") || url.pathname.startsWith("/invite-al/") || url.pathname.startsWith("/admin-al") || url.pathname.startsWith("/g/")) {
    // 继续往下走，不验证
  } else if (!verifyToken(req)) {
    log(`⚠️ 未授权: ${getIP(req)} ${url.pathname}`);
    jsonResp(res, {error:"Unauthorized"}, 403); return;
  }

  // ── /session：生成client_secret ───────────────────────
// [旧残留已禁用]   if (req.method === "POST" && url.pathname === "/session") {
// [旧残留已禁用]     checkDailyReset();
// [旧残留已禁用]     const ip = getIP(req);
// [旧残留已禁用]     if (dailySessionCount >= MAX_SESSIONS_PER_DAY) {
// [旧残留已禁用]       jsonResp(res, {error:"Daily session limit reached"}, 429); return;
// [旧残留已禁用]     }
// [旧残留已禁用]     if (!checkIPLimit(ip)) {
// [旧残留已禁用]       jsonResp(res, {error:"Too many requests from your IP"}, 429); return;
// [旧残留已禁用]     }
// [旧残留已禁用]     let body = ""; req.on("data", c => body += c);
// [旧残留已禁用]     req.on("end", async () => {
// [旧残留已禁用]       try {
// [旧残留已禁用]         const { outputLanguage = "en" } = JSON.parse(body || "{}");
// [旧残留已禁用]         if (!OPENAI_KEY) { jsonResp(res, {error:"OPENAI_API_KEY not configured"}, 500); return; }
// [旧残留已禁用]         const { status, data } = await fetchOpenAISession(outputLanguage);
// [旧残留已禁用]         if (status !== 200) {
// [旧残留已禁用]           log(`❌ OpenAI失败: ${status}`);
// [旧残留已禁用]           jsonResp(res, {error: data?.error?.message || "OpenAI request failed"}, status); return;
// [旧残留已禁用]         }
// [旧残留已禁用]         const clientSecret = data?.value ?? data?.client_secret?.value;
// [旧残留已禁用]         const expiresAt    = data?.expires_at ?? data?.client_secret?.expires_at;
// [旧残留已禁用]         if (!clientSecret) { jsonResp(res, {error:"No client_secret"}, 502); return; }
// [旧残留已禁用]         const sessionId = `sess_${Date.now()}_${Math.random().toString(36).slice(2,6)}`;
// [旧残留已禁用]         activeSessions.set(sessionId, { createdAt:Date.now(), ip, outputLang:outputLanguage });
// [旧残留已禁用]         dailySessionCount++;
// [旧残留已禁用]         writeBillingLog({sessionId, outputLang:outputLanguage, ip, minutes:0, event:"OPEN"});
// [旧残留已禁用]         log(`✅ Session: ${sessionId} →${outputLanguage} IP:${ip} 今日第${dailySessionCount}个`);
// [旧残留已禁用]         jsonResp(res, { client_secret:clientSecret, expires_at:expiresAt||null,
// [旧残留已禁用]           session_id:sessionId, max_minutes:SESSION_MAX_MINUTES });
// [旧残留已禁用]       } catch(e) { log(`❌ /session: ${e.message}`); jsonResp(res, {error:e.message}, 500); }
// [旧残留已禁用]     }); return;
// [旧残留已禁用]   }
// [旧残留已禁用] 
  // ── /sdp：转发SDP握手 ─────────────────────────────────
// [旧残留已禁用]   if (req.method === "POST" && url.pathname.startsWith("/sdp")) {
// [旧残留已禁用]     const model = url.searchParams.get("model") || "gpt-realtime-translate";
// [旧残留已禁用]     const token = (req.headers["authorization"] || "").replace(/^Bearer\s+/i, "").trim();
// [旧残留已禁用]     if (!token) { jsonResp(res, {error:"Missing client_secret"}, 401); return; }
// [旧残留已禁用]     let body = ""; req.on("data", c => body += c);
// [旧残留已禁用]     req.on("end", () => {
// [旧残留已禁用]       const options = {
// [旧残留已禁用]         hostname:"api.openai.com", path:`/v1/realtime/translations?model=${model}`,
// [旧残留已禁用]         method:"POST",
// [旧残留已禁用]         headers:{ "Authorization":`Bearer ${token}`, "Content-Type":"application/sdp",
// [旧残留已禁用]           "Content-Length":Buffer.byteLength(body) },
// [旧残留已禁用]       };
// [旧残留已禁用]       const proxyReq = https.request(options, proxyRes => {
// [旧残留已禁用]         let data = "";
// [旧残留已禁用]         proxyRes.on("data", c => data += c);
// [旧残留已禁用]         proxyRes.on("end", () => {
// [旧残留已禁用]           res.writeHead(proxyRes.statusCode, {"Content-Type":"application/sdp","Access-Control-Allow-Origin":"*"});
// [旧残留已禁用]           res.end(data);
// [旧残留已禁用]           if (proxyRes.statusCode === 200) log(`✅ SDP握手成功`);
// [旧残留已禁用]           else log(`❌ SDP失败: ${proxyRes.statusCode}`);
// [旧残留已禁用]         });
// [旧残留已禁用]       });
// [旧残留已禁用]       proxyReq.on("error", e => { res.writeHead(500,{"Access-Control-Allow-Origin":"*"}); res.end(e.message); });
// [旧残留已禁用]       proxyReq.write(body); proxyReq.end();
// [旧残留已禁用]     }); return;
// [旧残留已禁用]   }
// [旧残留已禁用] 
  // ── /session/close ────────────────────────────────────
// [旧残留已禁用]   if (req.method === "POST" && url.pathname === "/session/close") {
// [旧残留已禁用]     let body = ""; req.on("data", c => body += c);
// [旧残留已禁用]     req.on("end", () => {
// [旧残留已禁用]       try {
// [旧残留已禁用]         const { session_id } = JSON.parse(body || "{}");
// [旧残留已禁用]         if (session_id && activeSessions.has(session_id)) {
// [旧残留已禁用]           const sess = activeSessions.get(session_id);
// [旧残留已禁用]           const minutes = ((Date.now() - sess.createdAt) / 60000).toFixed(1);
// [旧残留已禁用]           writeBillingLog({sessionId:session_id, outputLang:sess.outputLang, ip:sess.ip,
// [旧残留已禁用]             minutes:parseFloat(minutes), event:"CLOSE"});
// [旧残留已禁用]           log(`📵 Session关闭: ${session_id} ${minutes}分钟`);
// [旧残留已禁用]           activeSessions.delete(session_id);
// [旧残留已禁用]         }
// [旧残留已禁用]       } catch(e) {}
// [旧残留已禁用]       jsonResp(res, {ok:true});
// [旧残留已禁用]     }); return;
// [旧残留已禁用]   }
// [旧残留已禁用] 
  // ── /stats ────────────────────────────────────────────
// [旧残留已禁用] 
  // ═══ LiveKit Token ═══
  if (req.method === "GET" && url.pathname === "/livekit-token") {
    const h = req.headers["x-glotalk-token"] || "";
    if (h !== ACCESS_TOKEN) { jsonResp(res, {error:"Unauthorized"}, 401); return; }
    const q        = url.searchParams;
    const room     = q.get("room")     || "glotalk-room";
    const identity = q.get("identity") || ("user-" + Date.now());
    const lang     = q.get("lang")     || "zh";
    const { AccessToken } = require("livekit-server-sdk");
    const LK_KEY    = process.env.LIVEKIT_API_KEY    || "";
    const LK_SECRET = process.env.LIVEKIT_API_SECRET || "";
    const LK_URL    = process.env.LIVEKIT_URL        || "wss://glotalk-nppyx7kk.livekit.cloud";
    if (!LK_KEY || !LK_SECRET) { jsonResp(res, {error:"LiveKit not configured"}, 500); return; }
    // [旧残留已禁用] AgentDispatchClient 已移除
    const at = new AccessToken(LK_KEY, LK_SECRET, { identity: identity, ttl: 7200, attributes: { lang: lang } });
    at.addGrant({
      roomJoin: true, room: room, canPublish: true, canSubscribe: true,
      roomCreate: true,
    });

    // [路线A不需要Agent dispatch，已禁用]

    const token = await at.toJwt();
// [旧残留已禁用]     if (!global._bridgeStarted) global._bridgeStarted = new Set();
// [已禁用旧Gemini Bridge]     if (!global._bridgeStarted.has(room)) { global._bridgeStarted.add(room); startTranslationBridge(room, LK_URL, LK_KEY, LK_SECRET, process.env.GEMINI_API_KEY).catch(e => log("Bridge: " + e.message)); }
    jsonResp(res, { token, url: LK_URL, room, identity, lang });
    log("LiveKit token: " + identity + " room:" + room + " lang:" + lang);
    return;
  }

  if (req.method === "GET" && url.pathname === "/stats") {
    jsonResp(res, { daily_sessions:dailySessionCount, daily_limit:MAX_SESSIONS_PER_DAY,
      active_sessions:Array.from(activeSessions.entries()).map(([id,s])=>({
        id, outputLang:s.outputLang, minutes:((Date.now()-s.createdAt)/60000).toFixed(1), ip:s.ip
      })) });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/translation-token") { await _tlHandleTranslationToken(req, res); return; }
  if (await handleGeminiRoutes(req, res, url)) return;
  // ===== alibaba-v1: 临时Token接口 =====
  if (req.method === "GET" && url.pathname === "/alibaba-token") {
    const apiKey = process.env.DASHSCOPE_API_KEY;
    if (!apiKey) { res.writeHead(500); res.end("DASHSCOPE_API_KEY not set"); return; }
    res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
    res.end(JSON.stringify({ token: apiKey }));
    return;
  }


  // ══════════════════════════════════════════════════════════
  // AL-WEB：alibaba 网页版专用接口
  // ══════════════════════════════════════════════════════════

  if (req.method === "POST" && url.pathname === "/al-web/invite/verify") {
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { code } = JSON.parse(body || "{}");
        const inv = invitesAL[code];
        if (!inv) { jsonResp(res, {ok:false, error:"邀请码不存在"}); return; }
        if (Date.now() > inv.expiresAt) { jsonResp(res, {ok:false, error:"邀请码已过期"}); return; }
        const roomId = inv.roomId || code;
        jsonResp(res, {ok:true, roomId, name:inv.name, duration:inv.duration});
      } catch(e) { jsonResp(res, {ok:false, error:e.message}); }
    }); return;
  }

  if (req.method === "GET" && url.pathname === "/al-web/token") {
    const q = url.searchParams;
    const room = q.get("room") || "glotalk-room";
    const identity = q.get("identity") || ("用户-" + Math.random().toString(36).slice(2,10));
    const lang = q.get("lang") || "zh";
    const { AccessToken } = require("livekit-server-sdk");
    const LK_KEY = process.env.LIVEKIT_API_KEY || "";
    const LK_SECRET = process.env.LIVEKIT_API_SECRET || "";
    const LK_URL = process.env.LIVEKIT_URL || "wss://glotalk-nppyx7kk.livekit.cloud";
    if (!LK_KEY || !LK_SECRET) { jsonResp(res, {error:"LiveKit not configured"}, 500); return; }
    const at = new AccessToken(LK_KEY, LK_SECRET, { identity, ttl: 7200, attributes: { lang } });
    at.addGrant({ roomJoin: true, room, canPublish: true, canSubscribe: true, roomCreate: true });
    const token = await at.toJwt();
    jsonResp(res, { token, url: LK_URL, room, identity, lang });
    log("LiveKit token: " + identity + " room:" + room + " lang:" + lang);
    return;
  }

  if (req.method === "GET" && url.pathname === "/al-web/start-bot") {
    const { room, identity, source, target } = url.searchParams ? Object.fromEntries(url.searchParams) : {};
    if (!room || !identity || !source || !target) {
      jsonResp(res, { ok: false, error: 'missing params' }, 400); return;
    }
    const botKey = `${room}:${source}`;
    if (!global._activeBotsWeb) global._activeBotsWeb = new Map();
    if (global._activeBotsWeb.has(botKey)) {
      const oldBot = global._activeBotsWeb.get(botKey);
      try { process.kill(oldBot.pid, 'SIGTERM'); } catch(e) {}
      global._activeBotsWeb.delete(botKey);
      log(`[al-web] 终止旧Bot: ${botKey}`);
    }
    const { spawn } = require('child_process');
    const bot = spawn('python3', [
      '/var/www/glotalk/translation_bot.py',
      room, source, target, identity
    ], { env: { ...process.env }, detached: true, stdio: 'ignore' });
    bot.on('exit', () => {
      if (global._activeBotsWeb.get(botKey) === bot) {
        global._activeBotsWeb.delete(botKey);
      }
      log(`[al-web] Bot退出: ${botKey}`);
      // 连带停止同房间另一个Bot
      const otherKey = `${room}:${target}`;
      if (global._activeBotsWeb && global._activeBotsWeb.has(otherKey)) {
        const otherBot = global._activeBotsWeb.get(otherKey);
        try { process.kill(otherBot.pid, 'SIGTERM'); } catch(e) {}
        global._activeBotsWeb.delete(otherKey);
        log(`[al-web] 连带停止Bot: ${otherKey}`);
      }
    });
    global._activeBotsWeb.set(botKey, bot);
    bot.unref();
    log(`[al-web] 启动Bot: room=${room} ${source}→${target} for ${identity}`);
    jsonResp(res, { ok: true });
    return;
  }
    if (req.method === "GET" && url.pathname === "/al-web/stop-bot") {
    const { room, source } = url.searchParams ? Object.fromEntries(url.searchParams) : {};
    if (!room || !source) { jsonResp(res, { ok: false, error: "missing params" }, 400); return; }
    const botKey = `${room}:${source}`;
    if (global._activeBotsWeb && global._activeBotsWeb.has(botKey)) {
      const bot = global._activeBotsWeb.get(botKey);
      try { process.kill(bot.pid, "SIGTERM"); } catch(e) {}
      global._activeBotsWeb.delete(botKey);
      log(`[al-web] 终止Bot: ${botKey}`);
    }
    jsonResp(res, { ok: true });
    return;
  }

  // ══════════════════════════════════════════════════════════
  // AL-APP：alibaba App版专用接口
  // ══════════════════════════════════════════════════════════

  if (req.method === "POST" && url.pathname === "/al-app/invite/verify") {
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { code } = JSON.parse(body || "{}");
        const inv = invitesAL[code];
        if (!inv) { jsonResp(res, {ok:false, error:"邀请码不存在"}); return; }
        if (Date.now() > inv.expiresAt) { jsonResp(res, {ok:false, error:"邀请码已过期"}); return; }
        const roomId = inv.roomId || code;
        jsonResp(res, {ok:true, roomId, name:inv.name, duration:inv.duration});
      } catch(e) { jsonResp(res, {ok:false, error:e.message}); }
    }); return;
  }

  if (req.method === "GET" && url.pathname === "/al-app/token") {
    const h = req.headers["x-glotalk-token"] || "";
    if (h !== ACCESS_TOKEN) { jsonResp(res, {error:"Unauthorized"}, 401); return; }
    const q = url.searchParams;
    const room = q.get("room") || "glotalk-room";
    const identity = q.get("identity") || ("user-" + Date.now());
    const lang = q.get("lang") || "zh";
    const { AccessToken } = require("livekit-server-sdk");
    const LK_KEY = process.env.LIVEKIT_API_KEY || "";
    const LK_SECRET = process.env.LIVEKIT_API_SECRET || "";
    const LK_URL = process.env.LIVEKIT_URL || "wss://glotalk-nppyx7kk.livekit.cloud";
    if (!LK_KEY || !LK_SECRET) { jsonResp(res, {error:"LiveKit not configured"}, 500); return; }
    const at = new AccessToken(LK_KEY, LK_SECRET, { identity, ttl: 7200, attributes: { lang } });
    at.addGrant({ roomJoin: true, room, canPublish: true, canSubscribe: true, roomCreate: true });
    const token = await at.toJwt();
    jsonResp(res, { token, url: LK_URL, room, identity, lang });
    log("LiveKit token: " + identity + " room:" + room + " lang:" + lang);
    return;
  }

  if (req.method === "GET" && url.pathname === "/al-app/start-bot") {
    const { room, identity, source, target } = url.searchParams ? Object.fromEntries(url.searchParams) : {};
    if (!room || !identity || !source || !target) {
      jsonResp(res, { ok: false, error: 'missing params' }, 400); return;
    }
    // 房间锁：同一房间1秒内只处理一次
    if (!global._roomLocksApp) global._roomLocksApp = new Map();
    const lockKey = `lock:${room}`;
    if (global._roomLocksApp.has(lockKey)) {
      log(`[al-app] 房间锁忽略重复请求: ${room}`);
      jsonResp(res, { ok: true, waiting: true });
      return;
    }
    global._roomLocksApp.set(lockKey, true);
    setTimeout(() => global._roomLocksApp.delete(lockKey), 1000);

    try {
      const { RoomServiceClient } = require('livekit-server-sdk');
      const LK_KEY = process.env.LIVEKIT_API_KEY || "";
      const LK_SECRET = process.env.LIVEKIT_API_SECRET || "";
      const LK_HOST = (process.env.LIVEKIT_URL || "wss://glotalk-nppyx7kk.livekit.cloud").replace('wss://', 'https://');
      const svc = new RoomServiceClient(LK_HOST, LK_KEY, LK_SECRET);
      const participants = await svc.listParticipants(room);
      const realUsers = participants.filter(p => !p.identity.startsWith('bot-'));

      if (realUsers.length > 2) {
        jsonResp(res, { ok: false, error: '房间已满，最多2人通话' }, 400); return;
      }
      if (realUsers.length <= 1) {
        log(`[al-app] 等待第二人加入: room=${room}`);
        jsonResp(res, { ok: true, waiting: true }); return;
      }

      const user1 = realUsers[0];
      const user2 = realUsers[1];
      const lang1 = (user1.attributes && user1.attributes.lang) || source;
      const lang2 = (user2.attributes && user2.attributes.lang) || target;

      if (lang1 === lang2) {
        log(`[al-app] 两端语言相同(${lang1})，不启动Bot`);
        jsonResp(res, { ok: false, error: '两端语言相同，无需翻译' }, 400); return;
      }

      if (!global._activeBotsApp) global._activeBotsApp = new Map();
      const { spawn } = require('child_process');

      function spawnBotApp(srcLang, tgtLang, userIdentity) {
        const botKey = `${room}:${srcLang}`;
        if (global._activeBotsApp.has(botKey)) {
          const oldBot = global._activeBotsApp.get(botKey);
          try { process.kill(oldBot.pid, 'SIGTERM'); } catch(e) {}
          global._activeBotsApp.delete(botKey);
          log(`[al-app] 终止旧Bot: ${botKey}`);
        }
        const bot = spawn('python3', [
          '/var/www/glotalk/translation_bot.py',
          room, srcLang, tgtLang, userIdentity
        ], { env: { ...process.env }, detached: true, stdio: 'ignore' });
        bot.on('exit', () => {
          if (global._activeBotsApp.get(botKey) === bot) {
            global._activeBotsApp.delete(botKey);
          }
          log(`[al-app] Bot退出: ${botKey}`);
          const otherKey = `${room}:${tgtLang}`;
          if (global._activeBotsApp && global._activeBotsApp.has(otherKey)) {
            const otherBot = global._activeBotsApp.get(otherKey);
            try { process.kill(otherBot.pid, 'SIGTERM'); } catch(e) {}
            global._activeBotsApp.delete(otherKey);
            log(`[al-app] 连带停止Bot: ${otherKey}`);
          }
        });
        global._activeBotsApp.set(botKey, bot);
        bot.unref();
        log(`[al-app] 启动Bot: room=${room} ${srcLang}→${tgtLang} for ${userIdentity}`);
      }

      spawnBotApp(lang1, lang2, user1.identity);
      spawnBotApp(lang2, lang1, user2.identity);
      jsonResp(res, { ok: true, waiting: false });
    } catch(e) {
      log(`[al-app] 错误: ${e.message}`);
      jsonResp(res, { ok: false, error: e.message }, 500);
    }
    return;
  }

  if (req.method === "GET" && url.pathname === "/al-app/stop-bot") {
    const { room, source } = url.searchParams ? Object.fromEntries(url.searchParams) : {};
    if (!room || !source) { jsonResp(res, { ok: false, error: "missing params" }, 400); return; }
    const botKey = `${room}:${source}`;
    if (global._activeBotsApp && global._activeBotsApp.has(botKey)) {
      const bot = global._activeBotsApp.get(botKey);
      try { process.kill(bot.pid, "SIGTERM"); } catch(e) {}
      global._activeBotsApp.delete(botKey);
      log(`[al-app] 终止Bot: ${botKey}`);
    }
    jsonResp(res, { ok: true });
    return;
  }

  if (req.method === "GET" && url.pathname === "/start-bot") {
    const { room, identity, source, target } = url.searchParams ? Object.fromEntries(url.searchParams) : {};
    if (!room || !identity || !source || !target) {
      res.writeHead(400, {"Content-Type":"application/json","Access-Control-Allow-Origin":"*"});
      res.end(JSON.stringify({ ok: false, error: 'missing params' }));
      return;
    }
    // botKey = room:source，同一房间同一说话语言只允许一个Bot
    const botKey = `${room}:${source}`;
    if (!global._activeBots) global._activeBots = new Map();
    if (global._activeBots.has(botKey)) {
      // 已有同source语言的Bot，kill旧的再启动新的
      const oldBot = global._activeBots.get(botKey);
      try { process.kill(oldBot.pid, 'SIGTERM'); } catch(e) {}
      global._activeBots.delete(botKey);
      log(`[start-bot] 终止旧Bot(同语言重复): ${botKey}`);
    }
    const { spawn } = require('child_process');
    const env = { ...process.env };
    const bot = spawn('python3', [
      '/var/www/glotalk/translation_bot.py',
      room, source, target, identity
    ], { env, detached: true, stdio: 'ignore' });
    bot.on('exit', () => {
      if (global._activeBots.get(botKey) === bot) {
        global._activeBots.delete(botKey);
      }
      log(`[start-bot] Bot退出: ${botKey}`);
    });
    global._activeBots.set(botKey, bot);
    bot.unref();
    log(`[start-bot] 启动 Bot: room=${room} ${source}→${target} for ${identity}`);
    res.writeHead(200, {"Content-Type":"application/json","Access-Control-Allow-Origin":"*"});
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  if (req.method === "GET" && url.pathname === "/stop-bot") {
    const { room, source } = url.searchParams ? Object.fromEntries(url.searchParams) : {};
    if (!room || !source) {
      res.writeHead(400, {"Content-Type":"application/json","Access-Control-Allow-Origin":"*"});
      res.end(JSON.stringify({ ok: false, error: "missing params" }));
      return;
    }
    const botKey = `${room}:${source}`;
    if (global._activeBots && global._activeBots.has(botKey)) {
      const bot = global._activeBots.get(botKey);
      try { process.kill(bot.pid, "SIGTERM"); } catch(e) {}
      global._activeBots.delete(botKey);
      log(`[stop-bot] 终止Bot: ${botKey}`);
    }
    res.writeHead(200, {"Content-Type":"application/json","Access-Control-Allow-Origin":"*"});
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  res.writeHead(404, {"Access-Control-Allow-Origin":"*"}); res.end("Not found");
});

// Session超时清理
setInterval(() => {
  const now = Date.now();
  for (const [id, sess] of activeSessions.entries()) {
    if ((now - sess.createdAt) / 60000 >= SESSION_MAX_MINUTES) {
      log(`⏰ Session超时清理: ${id}`);
      activeSessions.delete(id);
    }
  }
  // 清理过期邀请码（保留7天记录）
  const sevenDays = 7 * 24 * 60 * 60 * 1000;
  for (const [code, inv] of Object.entries(invites)) {
    if (inv.used && inv.usedAt && (now - inv.usedAt) > sevenDays) {
      delete invites[code];
    }
  }
  saveInvites(invites);
}, 60 * 1000);

// ═══ Gemini WebSocket 代理 ═══
const { WebSocket: WS, WebSocketServer } = require("ws");
// [已禁用旧Gemini Bridge] const { startTranslationBridge } = require("./translation-bridge.js");
const wss = new WebSocketServer({ noServer: true });

// [旧残留已禁用] WebSocket upgrade handler 已移除（路线A不需要 WebSocket）


// ============================================================
// GloTalk 路线A — /api/translation-token 接口
// 参考：OpenAI Cookbook livekit-translation-demo route.ts
// 适配本服务器原生 http 格式
// ============================================================
const _tlSupportedLangs = new Set(["es","pt","fr","ja","ru","zh","de","ko","hi","id","vi","it","en"]);
const _tlLangPattern = /^[a-z]{2,3}(?:-[a-z0-9]{2,8}){0,2}$/;

function _tlNormalizeLang(lang) {
  if (typeof lang !== "string" || !lang.trim()) throw new Error("A translation language is required");
  const n = lang.trim().toLowerCase();
  if (!_tlLangPattern.test(n)) throw new Error("Invalid translation language");
  if (!_tlSupportedLangs.has(n)) throw new Error("Unsupported translation language");
  return n;
}

async function _tlHandleTranslationToken(req, res) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) { res.writeHead(500); res.end("Missing OPENAI_API_KEY"); return; }
  let body = "";
  req.on("data", d => { body += d; });
  req.on("end", async () => {
    try {
      const payload = JSON.parse(body || "{}");
      const language = _tlNormalizeLang(payload.language || "en");
      const inputTranscriptionEnabled = !!payload.inputTranscriptionEnabled;
      const noiseReductionEnabled = !!payload.noiseReductionEnabled;
      const sessionConfig = {
        model: process.env.OPENAI_TRANSLATION_MODEL || "gpt-realtime-translate",
        audio: {
          input: {
            ...(inputTranscriptionEnabled ? { transcription: { model: "gpt-realtime-whisper" } } : {}),
            noise_reduction: noiseReductionEnabled ? { type: "near_field" } : null,
          },
          output: { language },
        },
      };
      const response = await fetch("https://api.openai.com/v1/realtime/translations/client_secrets", {
        method: "POST",
        headers: { Authorization: "Bearer " + apiKey, "Content-Type": "application/json" },
        body: JSON.stringify({ session: sessionConfig }),
      });
      const text = await response.text();
      if (!response.ok) { res.writeHead(response.status); res.end(text); return; }
      const data = JSON.parse(text);
      const clientSecret = data.value ?? data.client_secret?.value;
      const expiresAt = data.expires_at ?? data.client_secret?.expires_at ?? null;
      if (!clientSecret) { res.writeHead(502); res.end("Missing client secret"); return; }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ clientSecret, expiresAt }));
    } catch (err) {
      res.writeHead(400); res.end(err.message || "Error");
    }
  });

}

// ===== alibaba-v1: WebSocket 中转代理 =====
const ALIBABA_WS_URL = 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3.5-livetranslate-flash-realtime';

wss.on('connection', (clientWs, req) => {
  const pathname = new URL(req.url, 'http://localhost').pathname;
  if (pathname !== '/alibaba-ws') return;

  const apiKey = process.env.DASHSCOPE_API_KEY;
  if (!apiKey) { clientWs.close(1008, 'No API key'); return; }

  const { WebSocket: WS } = require('ws');
  const aliWs = new WS(ALIBABA_WS_URL, {
    headers: { Authorization: 'Bearer ' + apiKey },
    agent: new (require('https').Agent)({ keepAlive: false }),
    handshakeTimeout: 10000
  });

  aliWs.on('open', () => { log('[alibaba-ws] 已连接阿里云，apiKey前10: ' + apiKey.substring(0,10)); });
  aliWs.on('message', (data) => { 
    log('[alibaba-ws] 阿里云消息: ' + data.toString().substring(0,100));
    if (clientWs.readyState === 1) clientWs.send(data); 
  });

  aliWs.on('close', (code, reason) => { log('[alibaba-ws] 阿里云断开: ' + code + ' reason: ' + reason.toString()); clientWs.close(code, reason); });
  aliWs.on('error', (e) => { log('[alibaba-ws] 阿里云错误: ' + e.message); clientWs.close(1011, e.message); });

  clientWs.on('message', (data) => { if (aliWs.readyState === 1) aliWs.send(data.toString()); });
  clientWs.on('close', () => { aliWs.close(); });
  clientWs.on('error', (e) => { log('[alibaba-ws] 浏览器错误: ' + e.message); });
});


// ===== WebSocket Upgrade 处理 =====
server.on('upgrade', (req, socket, head) => {
  const pathname = new URL(req.url, 'http://localhost').pathname;
  if (pathname === '/alibaba-ws') {
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit('connection', ws, req);
    });
  } else {
    socket.destroy();
  }
});


server.listen(PORT, () => {
  log(`GloTalk Server v3 启动，端口${PORT}`);
  log(`ACCESS_TOKEN: ${ACCESS_TOKEN ? "已配置" : "⚠️未配置"}`);
  log(`ADMIN_PASS: ${ADMIN_PASS ? "已配置" : "⚠️未配置"}`);
  log(`OPENAI_API_KEY: ${OPENAI_KEY ? "已配置" : "⚠️未配置"}`);
  log(`每日session上限: ${MAX_SESSIONS_PER_DAY}`);
});
