# GloTalk — 实时语音翻译 SaaS

> Your World, Translated

## 项目架构（三个模式）

| 模式 | 文件夹 | 状态 | 说明 |
|------|--------|------|------|
| 模式1 | archive/openai-v1/ | 已归档 | OpenAI gpt-realtime-translate |
| 模式2(a) | current/web/ | ✅运行中 | Gemini网页版 |
| 模式2(b) | current/flutter_app/ | ✅已编译 | Gemini Android App |
| 模式3 | v2-seamless/ | ⏳待建 | Seamless+Fish Audio声音克隆版 |

## 服务器
- 新加坡阿里云：47.84.206.142
- 域名：glotalk.tech
- 管理后台：https://glotalk.tech/admin?admin=gloAdmin2026

## 技术栈
- 通话：LiveKit Cloud（WebRTC）
- 翻译：Gemini 3.5 Live Translate
- 后端：Node.js（server.js + translation-bridge.js）
- App：Flutter（iOS + Android）

## 快速切换模式
- 切回模式1（OpenAI）：见 archive/openai-v1/README.md
- 当前模式2：见 current/README.md
- V2规划：见 v2-seamless/README.md
