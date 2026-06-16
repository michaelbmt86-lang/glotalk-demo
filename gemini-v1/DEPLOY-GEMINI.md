# GloTalk 路线B升级版 — 部署说明
# 参考：google-gemini/gemini-live-api-examples（2026-06-09）
# 操作日期：2026-06-16

## 文件清单

translation-bridge-gemini.js  → 服务器端 TranslationBridge + SessionManager
gemini-routes.js              → 服务器端路由接口（插入 server.js）
glotalk-gemini.html           → 前端验证页面
call_screen_gemini.dart       → Flutter App 通话界面（升级版）

---

## 第一步：安装依赖

服务器需要安装 @livekit/rtc-node（官方 Node.js SDK）：

cd /var/www/glotalk
npm install @livekit/rtc-node ws

---

## 第二步：上传文件到服务器

curl -o /var/www/glotalk/translation-bridge-gemini.js \
  https://raw.githubusercontent.com/michaelbmt86-lang/glotalk-demo/main/gemini-v1/server/translation-bridge-gemini.js

curl -o /var/www/glotalk/gemini-routes.js \
  https://raw.githubusercontent.com/michaelbmt86-lang/glotalk-demo/main/gemini-v1/server/gemini-routes.js

curl -o /var/www/glotalk/glotalk-gemini.html \
  https://raw.githubusercontent.com/michaelbmt86-lang/glotalk-demo/main/gemini-v1/web/glotalk-gemini.html

---

## 第三步：修改 server.js（加入 Gemini 路由）

在 server.js 顶部 require 区域加入：

  const { handleGeminiRoutes } = require("./gemini-routes");

在路由区域（404 handler 之前）加入：

  if (await handleGeminiRoutes(req, res, url)) return;

用 Python 插入（和路线A一样的方式）：

python3 << 'PYEOF'
with open("/var/www/glotalk/server.js", "r") as f:
    content = f.read()

# 加 require
require_marker = "const { handleGeminiRoutes } = require('./gemini-routes');\n"
if require_marker not in content:
    first_require = content.find("const ")
    content = content[:first_require] + require_marker + content[first_require:]

# 加路由调用
route_marker = '  res.writeHead(404, {"Access-Control-Allow-Origin":"*"}); res.end("Not found");'
route_addon = '  if (await handleGeminiRoutes(req, res, url)) return;\n'
content = content.replace(route_marker, route_addon + route_marker)

with open("/var/www/glotalk/server.js", "w") as f:
    f.write(content)
print("OK")
PYEOF

---

## 第四步：重启服务器

pm2 restart glotalk-server
pm2 logs glotalk-server --lines 20 --nostream

---

## 第五步：测试验证

浏览器打开：https://glotalk.tech/glotalk-gemini.html

测试流程（完全按官方 Demo）：
1. 一台设备选「主讲人」，记下会话 ID
2. 另一台设备选「听众」，输入会话 ID
3. 听众选择目标语言（如 English）
4. 主讲人说中文，听众应该听到英文翻译

验证接口：
curl -X POST https://glotalk.tech/api/gemini/sessions \
  -H "Content-Type: application/json" \
  -d '{"organizerName":"test"}'

---

## 第六步：Flutter App 升级

把 call_screen_gemini.dart 替换 flutter_app/lib/screens/call_screen.dart

需要在 language_screen.dart 里传入 sessionId 参数（主讲人先创建会话，听众输入 sessionId）

---

## 注意事项

1. 三个系统完全独立：
   - 路线A：/api/translation-token（不动）
   - 路线B：/api/gemini/sessions、/api/gemini/translate 等（新增）
   - 旧 Gemini 代码：已归档，不影响

2. GEMINI_API_KEY 已在 .env 里，不需要改

3. @livekit/rtc-node 是服务器端 SDK，和浏览器 SDK 完全不同
   这是路线B必须的，路线A不需要

4. 1GB 服务器完全够用，每个 Bridge Bot 约 20-30MB 内存
