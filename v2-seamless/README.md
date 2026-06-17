# GloTalk V2-Seamless

## 状态：📋 规划中（等 openai-v2-fish 稳定后启动）

## 定位
完全独立的第三条技术路线，与 OpenAI 和 Gemini 无关。
目标：接近 EzDubs 90% 的翻译质量，成本最低。

## 四块积木

| 积木 | 功能 | 协议 | 状态 |
|---|---|---|---|
| LiveKit | 音频传输 | Apache 2.0 | ✅ 已有 |
| Meta SeamlessStreaming | 预测性翻译（EMMA机制） | CC BY-NC | 📋 待集成 |
| Qwen3-TTS | 声音克隆（说话者声音） | Apache 2.0 | 📋 待集成 |
| Meta SeamlessExpressive | 情感/语速/停顿保留 | CC BY-NC | 📋 待集成 |

## 架构

```
说话者A说中文
    ↓ LiveKit WebRTC
SeamlessStreaming（EMMA预测性翻译，延迟<2秒）
    ↓ 翻译文字
Qwen3-TTS（用A的克隆声音读翻译，首包97ms）
    + SeamlessExpressive（保留A的情感语速）
    ↓
说话者B听到：用A的声音说的英文，带情感
```

## 与其他路线对比

| 路线 | 翻译质量 | 声音 | 成本/分钟 |
|---|---|---|---|
| openai-v1 | 80% | 机器声 | $0.068 |
| openai-v2-fish | 80% | 克隆声音 | $0.068+极低 |
| gemini-v2 | 70% | 声音保留 | $0.046 |
| **v2-seamless** | **90%** | **完美克隆** | **极低** |

## License

- Meta SeamlessStreaming/Expressive：CC BY-NC，Demo 合法，商业需向 Meta 申请
- Qwen3-TTS：Apache 2.0，完全商业免费
- LiveKit：Apache 2.0，完全免费

## 需要

- GPU 服务器（最低 8GB VRAM）
- 阿里云百炼 API Key（已有）✅
- Meta 商业许可（产品收费后申请）

## 开发计划

等 openai-v2-fish 验证完成后启动。
