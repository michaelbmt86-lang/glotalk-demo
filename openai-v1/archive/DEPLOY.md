# GloTalk 路线A 部署说明
# 参考：OpenAI Cookbook livekit-translation-demo（2026-05-07）
# 操作日期：2026-06-16

## 文件说明

glotalk-openai.html  → 前端页面，上传到 /var/www/glotalk/public/
server-addon.js      → 新增接口代码，手动插入到 server.js

---

## 第一步：上传前端页面

# SSH 进服务器
ssh admin@47.84.206.142

# 上传 HTML（在本地运行，或直接复制粘贴到服务器）
cp glotalk-openai.html /var/www/glotalk/public/glotalk-openai.html

---

## 第二步：修改 server.js（加入新接口）

# 打开 server.js
nano /var/www/glotalk/server.js

# 找到这一行（大约在文件末尾）：
#   app.listen(PORT, ...)
# 在这一行 【之前】 插入 server-addon.js 的全部内容

---

## 第三步：填入 OpenAI API Key

# 编辑 .env 文件
nano /var/www/glotalk/.env

# 找到这一行，填入你的新 OpenAI Key：
OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxx

# 可选：指定翻译模型（默认已是正确值，可不加）
OPENAI_TRANSLATION_MODEL=gpt-realtime-translate

---

## 第四步：重启服务

pm2 stop glotalk-server
pm2 start /var/www/glotalk/ecosystem.config.js

# 检查是否正常启动
pm2 status
tail -f /home/admin/.pm2/logs/glotalk-server-out.log

---

## 第五步：测试

# 浏览器打开：
https://glotalk.tech/glotalk-openai.html

# 两台设备（或两个浏览器窗口）进同一房间
# 开启 Translation，选好语言，开始说话

---

## 验证接口是否正常（拿到 Key 后）

curl -X POST https://glotalk.tech/api/translation-token \
  -H "Content-Type: application/json" \
  -d '{"language":"en","inputTranscriptionEnabled":true}'

# 正常返回：
# {"clientSecret":"ek_xxxx...","expiresAt":1234567890}

---

## 注意事项

1. 这个文件（glotalk-openai.html）和路线B（Gemini）完全独立，不影响任何现有功能
2. server.js 只是新增一个 /api/translation-token 接口，现有接口不改动
3. OpenAI Key 填入 .env 后，路线B（Gemini）不受影响，因为它用 GEMINI_API_KEY
4. 测试前必须确认 OPENAI_API_KEY 已填入，否则接口返回 500
