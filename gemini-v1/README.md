# GloTalk 模式2：Gemini Live Translate（当前运行）

## 状态：✅ 运行中（2026-06-15）

## 两个子模式
- (a) 网页模式：glotalk-fullduplex.html，浏览器直接使用
- (b) App模式：flutter_app/，Android APK，回声问题彻底解决

## 服务器
- 地址：47.84.206.142（新加坡）
- 域名：glotalk.tech
- PM2进程：glotalk-server（25MB内存）

## 核心文件
- server.js：主服务器（邀请码+计费+LiveKit Token+Gemini代理）
- translation-bridge.js：Node.js翻译桥接（LiveKit↔Gemini）
- ecosystem.config.js：PM2启动配置

## 启动命令
```bash
pm2 stop glotalk-server && pm2 start /var/www/glotalk/ecosystem.config.js
```

## 费用
- Gemini Live Translate: $0.023/分钟
- 双向通话: $0.046/分钟
