# GloTalk 模式3：V2 Seamless 积木模式（待建）

## 状态：⏳ 规划中

## 技术栈（四块积木）
1. Gemini Live Translate — 高质量翻译引擎
2. Meta SeamlessStreaming — 预测性翻译（句子没说完就开始）
3. Fish Audio S2 — 声音克隆（Apache 2.0，跨语言最强）
4. Meta SeamlessExpressive — 情感/语速/停顿保留

## License 说明
- Gemini：商业可用，$0.023/分钟
- SeamlessStreaming/Expressive：CC BY-NC（非商业），Demo阶段可用，商业化需申请
- Fish Audio S2：Apache 2.0，完全商业免费

## 商业化路径
- Demo验证阶段：GitHub开源版，完全合法
- 产品收费后：用新加坡公司身份向 Meta 申请商业许可

## 目标
- 接近 EzDubs 质量的 90%
- 保留说话者声音 + 情感 + 预测性翻译
- 成本比 OpenAI 方案低 60%+

## 待完成
- [ ] 集成 SeamlessStreaming
- [ ] 集成 Fish Audio S2
- [ ] 集成 SeamlessExpressive vocoder
- [ ] 延迟优化（目标 <500ms）
- [ ] Android App 集成测试
