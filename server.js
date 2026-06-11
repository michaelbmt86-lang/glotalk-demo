/**
 * GloTalk Server v3
 * 新增：一次性邀请码系统
 * 参考：Zoom会议室邀请码 + Discord服务器邀请链接设计
 */

const https  = require("https");
const http   = require("http");
const fs     = require("fs");
const crypto = require("crypto");

// ═══ 配置 ═══
const PORT          = 3000;
const ACCESS_TOKEN  = process.env.ACCESS_TOKEN  || "glotalk2026";
const ADMIN_PASS    = process.env.ADMIN_PASS    || "gloAdmin2026";
const OPENAI_KEY    = process.env.OPENAI_API_KEY;

const MAX_SESSIONS_PER_DAY = 50;
const MAX_SESSIONS_PER_IP  = 10;
const SESSION_MAX_MINUTES  = 30;
const BILLING_LOG = "/var/www/glotalk/billing.log";
const INVITE_FILE = "/var/www/glotalk/invites.json";
const AGENT_FILE  = "/var/www/glotalk/agents.json";

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
function generateInviteCode() {
  return "GT-" + crypto.randomBytes(3).toString("hex").toUpperCase();
}

// ═══ OpenAI session ═══
function fetchOpenAISession(outputLanguage) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify({
      session: {
        model: "gpt-realtime-translate",
        audio: { input: { noise_reduction: null }, output: { language: outputLanguage } }
      }
    });
    const options = {
      hostname: "api.openai.com",
      path: "/v1/realtime/translations/client_secrets",
      method: "POST",
      headers: {
        "Authorization": `Bearer ${OPENAI_KEY}`,
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(payload),
      },
    };
    const req = https.request(options, res => {
      let data = "";
      res.on("data", chunk => data += chunk);
      res.on("end", () => {
        try { resolve({ status: res.statusCode, data: JSON.parse(data) }); }
        catch(e) { reject(new Error("解析失败: " + data)); }
      });
    });
    req.on("error", reject);
    req.write(payload); req.end();
  });
}

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
  h2{color:#888;font-size:14px;margin:20px 0 10px}
  .card{background:#111;border:1px solid #222;border-radius:12px;padding:16px;margin-bottom:16px}
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
  <button onclick="createInvite()">生成邀请码</button>
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
const ADMIN = '${ADMIN_PASS}';
function showMsg(text, err) {
  const m = document.getElementById('msg');
  m.textContent = text; m.style.display = 'block';
  m.className = err ? 'err' : '';
  setTimeout(() => m.style.display = 'none', 5000);
}
async function createAgent() {
  const name = document.getElementById('agentName').value.trim();
  const budget = parseFloat(document.getElementById('agentBudget').value) || 200;
  if (!name) { alert('请输入代理姓名'); return; }
  const r = await fetch('/admin/agent/create?admin=' + ADMIN, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({name, monthlyBudgetRMB: budget})
  });
  const d = await r.json();
  const msg = document.getElementById('agentMsg');
  if (d.agentId) {
    msg.style.background = '#0d1a0f'; msg.style.color = '#22c55e';
    msg.textContent = '✅ 代理已创建：' + d.agentId + ' (' + name + ') 月额度¥' + budget;
    msg.style.display = 'block';
    setTimeout(() => location.reload(), 2000);
  } else {
    msg.style.background = '#1a0f0f'; msg.style.color = '#ef4444';
    msg.textContent = '❌ ' + (d.error || '创建失败');
    msg.style.display = 'block';
  }
}
async function toggleAgent(agentId, action) {
  const r = await fetch('/admin/agent/toggle?admin=' + ADMIN, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({agentId, action})
  });
  const d = await r.json();
  if (d.ok) location.reload();
  else alert('操作失败: ' + d.error);
}
async function createInvite() {
  const name = document.getElementById('inviteName').value.trim() || '测试用户';
  const duration = document.getElementById('inviteDuration').value;
  const r = await fetch('/admin/invite?admin=' + ADMIN, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({name, duration: parseInt(duration)})
  });
  const d = await r.json();
  if (d.code) {
    showMsg('✅ 邀请码：' + d.code + '（有效期' + duration + '分钟）');
    setTimeout(() => location.reload(), 2000);
  } else {
    showMsg('❌ ' + (d.error || '生成失败'), true);
  }
}
async function revoke(code) {
  if (!confirm('确定吊销 ' + code + '？')) return;
  const r = await fetch('/admin/invite/revoke?admin=' + ADMIN, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({code})
  });
  const d = await r.json();
  if (d.ok) { showMsg('✅ 已吊销 ' + code); setTimeout(() => location.reload(), 1000); }
  else showMsg('❌ ' + d.error, true);
}
</script>
</body>
</html>`;
}

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

  // ── 生成邀请码 ────────────────────────────────────────
  if (req.method === "POST" && url.pathname === "/admin/invite") {
    if (!verifyAdmin(req)) { jsonResp(res, {error:"Unauthorized"}, 403); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { name = "测试用户", duration = 60 } = JSON.parse(body || "{}");
        const code = generateInviteCode();
        const roomId = code.replace("GT-", "").slice(0, 6); // 房间号取邀请码后6位
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
        const roomId = code.replace("GT-", "").slice(0, 6);
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
      remainingMinutes: Math.floor(remaining / 0.068 * 60),
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
  if (!verifyToken(req)) {
    log(`⚠️ 未授权: ${getIP(req)} ${url.pathname}`);
    jsonResp(res, {error:"Unauthorized"}, 403); return;
  }

  // ── /session：生成client_secret ───────────────────────
  if (req.method === "POST" && url.pathname === "/session") {
    checkDailyReset();
    const ip = getIP(req);
    if (dailySessionCount >= MAX_SESSIONS_PER_DAY) {
      jsonResp(res, {error:"Daily session limit reached"}, 429); return;
    }
    if (!checkIPLimit(ip)) {
      jsonResp(res, {error:"Too many requests from your IP"}, 429); return;
    }
    let body = ""; req.on("data", c => body += c);
    req.on("end", async () => {
      try {
        const { outputLanguage = "en" } = JSON.parse(body || "{}");
        if (!OPENAI_KEY) { jsonResp(res, {error:"OPENAI_API_KEY not configured"}, 500); return; }
        const { status, data } = await fetchOpenAISession(outputLanguage);
        if (status !== 200) {
          log(`❌ OpenAI失败: ${status}`);
          jsonResp(res, {error: data?.error?.message || "OpenAI request failed"}, status); return;
        }
        const clientSecret = data?.value ?? data?.client_secret?.value;
        const expiresAt    = data?.expires_at ?? data?.client_secret?.expires_at;
        if (!clientSecret) { jsonResp(res, {error:"No client_secret"}, 502); return; }
        const sessionId = `sess_${Date.now()}_${Math.random().toString(36).slice(2,6)}`;
        activeSessions.set(sessionId, { createdAt:Date.now(), ip, outputLang:outputLanguage });
        dailySessionCount++;
        writeBillingLog({sessionId, outputLang:outputLanguage, ip, minutes:0, event:"OPEN"});
        log(`✅ Session: ${sessionId} →${outputLanguage} IP:${ip} 今日第${dailySessionCount}个`);
        jsonResp(res, { client_secret:clientSecret, expires_at:expiresAt||null,
          session_id:sessionId, max_minutes:SESSION_MAX_MINUTES });
      } catch(e) { log(`❌ /session: ${e.message}`); jsonResp(res, {error:e.message}, 500); }
    }); return;
  }

  // ── /sdp：转发SDP握手 ─────────────────────────────────
  if (req.method === "POST" && url.pathname.startsWith("/sdp")) {
    const model = url.searchParams.get("model") || "gpt-realtime-translate";
    const token = (req.headers["authorization"] || "").replace(/^Bearer\s+/i, "").trim();
    if (!token) { jsonResp(res, {error:"Missing client_secret"}, 401); return; }
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      const options = {
        hostname:"api.openai.com", path:`/v1/realtime/translations?model=${model}`,
        method:"POST",
        headers:{ "Authorization":`Bearer ${token}`, "Content-Type":"application/sdp",
          "Content-Length":Buffer.byteLength(body) },
      };
      const proxyReq = https.request(options, proxyRes => {
        let data = "";
        proxyRes.on("data", c => data += c);
        proxyRes.on("end", () => {
          res.writeHead(proxyRes.statusCode, {"Content-Type":"application/sdp","Access-Control-Allow-Origin":"*"});
          res.end(data);
          if (proxyRes.statusCode === 200) log(`✅ SDP握手成功`);
          else log(`❌ SDP失败: ${proxyRes.statusCode}`);
        });
      });
      proxyReq.on("error", e => { res.writeHead(500,{"Access-Control-Allow-Origin":"*"}); res.end(e.message); });
      proxyReq.write(body); proxyReq.end();
    }); return;
  }

  // ── /session/close ────────────────────────────────────
  if (req.method === "POST" && url.pathname === "/session/close") {
    let body = ""; req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { session_id } = JSON.parse(body || "{}");
        if (session_id && activeSessions.has(session_id)) {
          const sess = activeSessions.get(session_id);
          const minutes = ((Date.now() - sess.createdAt) / 60000).toFixed(1);
          writeBillingLog({sessionId:session_id, outputLang:sess.outputLang, ip:sess.ip,
            minutes:parseFloat(minutes), event:"CLOSE"});
          log(`📵 Session关闭: ${session_id} ${minutes}分钟`);
          activeSessions.delete(session_id);
        }
      } catch(e) {}
      jsonResp(res, {ok:true});
    }); return;
  }

  // ── /stats ────────────────────────────────────────────
  if (req.method === "GET" && url.pathname === "/stats") {
    jsonResp(res, { daily_sessions:dailySessionCount, daily_limit:MAX_SESSIONS_PER_DAY,
      active_sessions:Array.from(activeSessions.entries()).map(([id,s])=>({
        id, outputLang:s.outputLang, minutes:((Date.now()-s.createdAt)/60000).toFixed(1), ip:s.ip
      })) });
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

server.listen(PORT, () => {
  log(`GloTalk Server v3 启动，端口${PORT}`);
  log(`ACCESS_TOKEN: ${ACCESS_TOKEN ? "已配置" : "⚠️未配置"}`);
  log(`ADMIN_PASS: ${ADMIN_PASS ? "已配置" : "⚠️未配置"}`);
  log(`OPENAI_API_KEY: ${OPENAI_KEY ? "已配置" : "⚠️未配置"}`);
  log(`每日session上限: ${MAX_SESSIONS_PER_DAY}`);
});
