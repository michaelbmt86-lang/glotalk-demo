// ============================================================
// GloTalk 路线B升级版 — Gemini Live Translate 接口
// 参考来源：google-gemini/gemini-live-api-examples
//   src/app/api/sessions/route.ts
//   src/app/api/translate/route.ts
//   src/app/api/translate/status/route.ts
//   src/app/api/translate/unsubscribe/route.ts
// 适配：Node.js 原生 http（与 server.js 路由格式一致）
// 所有路径加 /api/gemini/ 前缀，与路线A完全隔离
// 插入位置：server.js 里 404 handler 之前（和路线A一样）
// ============================================================

const {
  TranslationSessionManager,
} = require("./translation-bridge-gemini");

// ── 工具函数：读取 POST body ──
function _readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (d) => { body += d; });
    req.on("end", () => {
      try { resolve(JSON.parse(body || "{}")); }
      catch { resolve({}); }
    });
    req.on("error", reject);
  });
}

// ── 路由注册函数（在 server.js 的路由区域调用）──
async function handleGeminiRoutes(req, res, url) {
  const pathname = url.pathname;
  const method = req.method;
  const manager = TranslationSessionManager.getInstance();

  // ── POST /api/gemini/sessions — 创建会话（来自官方 POST /api/sessions）──
  if (method === "POST" && pathname === "/api/gemini/sessions") {
    try {
      const body = await _readBody(req);
      const organizerName = body.organizerName || "organizer";
      const sessionId = Math.random().toString(36).slice(2, 10);
      const organizerIdentity = `organizer-${organizerName}`;

      manager.createSession(sessionId, organizerIdentity);

      const protocol = req.headers["x-forwarded-proto"] || "https";
      const host = req.headers.host || "glotalk.tech";

      res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({
        sessionId,
        organizerIdentity,
        joinUrl: `${protocol}://${host}/glotalk-gemini.html?session=${sessionId}&role=attendee`,
        broadcastUrl: `${protocol}://${host}/glotalk-gemini.html?session=${sessionId}&role=organizer`,
      }));
      return true;
    } catch (err) {
      res.writeHead(500); res.end(err.message);
      return true;
    }
  }

  // ── GET /api/gemini/sessions — 查询所有会话（来自官方 GET /api/sessions）──
  if (method === "GET" && pathname === "/api/gemini/sessions") {
    const sessions = manager.getAllSessions();
    res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
    res.end(JSON.stringify({ sessions }));
    return true;
  }

  // ── GET /api/gemini/sessions/:id — 查询单个会话（来自官方 GET /api/sessions/:sessionId）──
  const sessionMatch = pathname.match(/^\/api\/gemini\/sessions\/([^/]+)$/);
  if (method === "GET" && sessionMatch) {
    const sessionId = sessionMatch[1];
    const session = manager.getSession(sessionId);
    if (!session) {
      res.writeHead(404); res.end("Session not found");
      return true;
    }
    const translations = manager.getActiveTranslations(sessionId);
    res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
    res.end(JSON.stringify({ ...session, translations }));
    return true;
  }

  // ── DELETE /api/gemini/sessions/:id — 结束会话（来自官方 DELETE /api/sessions/:sessionId）──
  if (method === "DELETE" && sessionMatch) {
    const sessionId = sessionMatch[1];
    await manager.removeAllTranslations(sessionId);
    res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
    res.end(JSON.stringify({ success: true }));
    return true;
  }

  // ── POST /api/gemini/translate — 启动翻译 Bot（来自官方 POST /api/translate）──
  if (method === "POST" && pathname === "/api/gemini/translate") {
    try {
      const body = await _readBody(req);
      const { sessionId, targetLanguage, previousLanguage } = body;

      if (!sessionId || !targetLanguage) {
        res.writeHead(400); res.end("Missing sessionId or targetLanguage");
        return true;
      }

      const session = manager.getSession(sessionId);
      if (!session) {
        res.writeHead(404); res.end("Session not found");
        return true;
      }

      // 取消上一个语言订阅（语言切换时）
      if (previousLanguage && previousLanguage !== "original") {
        await manager.unsubscribe(sessionId, previousLanguage);
      }

      // 原声不需要 Bot
      if (targetLanguage === "original") {
        res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
        res.end(JSON.stringify({ translatorIdentity: null, status: "original" }));
        return true;
      }

      // 启动或复用 Bridge Bot
      const bridge = await manager.getOrCreate(sessionId, targetLanguage, session.organizerIdentity);

      res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({
        translatorIdentity: bridge.identity,
        status: bridge.status,
        targetLanguage: bridge.targetLanguage,
      }));
      return true;
    } catch (err) {
      res.writeHead(500); res.end("Failed to start translation: " + err.message);
      return true;
    }
  }

  // ── DELETE /api/gemini/translate — 停止翻译（来自官方 DELETE /api/translate）──
  if (method === "DELETE" && pathname === "/api/gemini/translate") {
    try {
      const body = await _readBody(req);
      const { sessionId, targetLanguage } = body;
      if (!sessionId || !targetLanguage) {
        res.writeHead(400); res.end("Missing sessionId or targetLanguage");
        return true;
      }
      await manager.unsubscribe(sessionId, targetLanguage);
      res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({ success: true }));
      return true;
    } catch (err) {
      res.writeHead(500); res.end(err.message);
      return true;
    }
  }

  // ── GET /api/gemini/translate/status — 查询 Bot 状态（来自官方 GET /api/translate/status）──
  if (method === "GET" && pathname === "/api/gemini/translate/status") {
    const sessionId = url.searchParams.get("sessionId");
    if (!sessionId) {
      res.writeHead(400); res.end("Missing sessionId");
      return true;
    }
    const translations = manager.getActiveTranslations(sessionId);
    res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
    res.end(JSON.stringify({ translations }));
    return true;
  }

  // ── POST /api/gemini/translate/unsubscribe — 用户离开时减订阅数（来自官方同名路由）──
  if (method === "POST" && pathname === "/api/gemini/translate/unsubscribe") {
    try {
      const body = await _readBody(req);
      const { sessionId, targetLanguage } = body;
      if (!sessionId || !targetLanguage) {
        res.writeHead(400); res.end("Missing params");
        return true;
      }
      await manager.unsubscribe(sessionId, targetLanguage);
      res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({ success: true }));
      return true;
    } catch (err) {
      res.writeHead(500); res.end(err.message);
      return true;
    }
  }

  return false; // 不是 Gemini 路由，继续走原来的路由
}

module.exports = { handleGeminiRoutes };
