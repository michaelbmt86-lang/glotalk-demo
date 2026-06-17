# GloTalk openai-v2-fish

## 状态：🔧 开发中

## 基础
- 基于 openai-v1（OpenAI 官方 livekit-translation-demo）
- 在官方代码基础上集成 Fish Audio S2-Pro 声音克隆

## 新增功能
- 用说话者自己的声音读翻译（Fish Audio S2-Pro）
- 进入房间自动采集3-5秒参考音频
- 翻译字幕 → Fish Audio TTS → 克隆声音播放

## 技术栈
- Next.js 16 + React（官方不动）
- LiveKit（官方不动）
- gpt-realtime-translate（官方不动）
- Fish Audio S2-Pro API（新增）

## 与 openai-v1 的区别
| 功能 | openai-v1 | openai-v2-fish |
|---|---|---|
| 翻译引擎 | gpt-realtime-translate | gpt-realtime-translate |
| 翻译声音 | OpenAI 机器声 | 说话者克隆声音 |
| 声音克隆 | ❌ | ✅ Fish Audio S2-Pro |

## Fish Audio S2-Pro
- Apache 2.0 开源，完全商业免费
- 10秒参考音频即可克隆
- 首包延迟 <300ms
- 支持 80+ 语言跨语言克隆
