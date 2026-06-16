# GloTalk 模式1：OpenAI gpt-realtime-translate

## 状态：已归档（2026-06-13 停用）

## 停用原因
- API Key 被 ACCIO Work（阿里外贸AI）盗刷，损失 $11.57
- 费用比 Gemini 贵 32%（$0.034/分钟 vs $0.023/分钟）

## 技术特点
- gpt-realtime-translate 模型
- WebRTC P2P 直连
- ScriptProcessor 音频处理（已知有 Safari 兼容性问题）

## 切换回此模式
1. 补充新的 OpenAI API Key 到 .env
2. 前端 URL 加 ?provider=openai 参数
3. server.js 已保留 /session 接口，随时可用

## 相关费用
- gpt-realtime-translate: $0.034/分钟
- 双向通话两个 session: $0.068/分钟
