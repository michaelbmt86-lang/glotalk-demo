/**
 * GloTalk Translation Bridge
 * 参考：google-gemini/gemini-live-api-examples/gemini-live-translate-livekit
 * 参考：官方文档 https://ai.google.dev/gemini-api/docs/live-api/live-translate
 *
 * 架构：
 *   LiveKit Room ─→ Bridge Bot 订阅音频 ─→ Gemini Live Translate WebSocket
 *   Gemini 返回翻译音频 ─→ Bridge Bot 发布翻译轨道 ─→ 听众
 *
 * 每个 (说话者, 目标语言) 对 = 1个 Bridge 实例
 * 同语言直接听原声，不消耗 Gemini
 */

const { Room, RoomEvent, AudioStream, LocalAudioTrack, AudioSource, TrackPublishOptions, TrackSource, AudioFrame } = require("@livekit/rtc-node");
const { WebSocket } = require("ws");

const GEMINI_MODEL = "gemini-3.5-live-translate-preview";
const GEMINI_WS_URL = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`;
const ATTR_LANG = "lang";
const RECONCILE_DEBOUNCE_MS = 300;
const FRAME_SIZE_MS = 100; // 官方推荐100ms chunks

// 支持的语言（BCP-47短码）
const SUPPORTED_LANGS = new Set([
  "zh","en","ja","ko","es","fr","de","pt","ar","hi","th","vi","id","ms","ru","it"
]);

// ─── GeminiTranslationBridge ───────────────────────────────────────────────
// 一个说话者 → 一个目标语言 = 一个 Bridge
class GeminiTranslationBridge {
  constructor(speakerIdentity, targetLang, room, geminiApiKey) {
    this.speakerIdentity = speakerIdentity;
    this.targetLang = targetLang;
    this.room = room;
    this.geminiApiKey = geminiApiKey;
    this.trackName = `tx:${speakerIdentity}:${targetLang}`;
    this.closed = false;
    this.geminiWs = null;
    this.audioSource = null;
    this.localTrack = null;
    this.audioStream = null;
  }

  async start(remoteAudioTrack) {
    // 1. 创建输出音源（24kHz，Gemini输出格式）
    this.audioSource = new AudioSource(24000, 1);
    this.localTrack = LocalAudioTrack.createAudioTrack(this.trackName, this.audioSource);
    const publishOptions = new TrackPublishOptions();
    publishOptions.source = TrackSource.SOURCE_MICROPHONE;
    await this.room.localParticipant.publishTrack(this.localTrack, publishOptions);
    log(`[Bridge] 翻译轨道已发布: ${this.trackName}`);

    // 2. 连接 Gemini Live Translate WebSocket
    await this._connectGemini();

    // 3. 订阅说话者音频流，转发给 Gemini
    this.audioStream = new AudioStream(remoteAudioTrack, 16000, 1, FRAME_SIZE_MS);
    this._pipeAudioToGemini();
  }

  async _connectGemini() {
    return new Promise((resolve, reject) => {
      const wsUrl = `${GEMINI_WS_URL}?key=${this.geminiApiKey}`;
      this.geminiWs = new WebSocket(wsUrl);

      this.geminiWs.on("open", () => {
        // 发送初始化配置（官方格式）
        const setupMsg = {
          setup: {
            model: `models/${GEMINI_MODEL}`,
            generationConfig: {
              responseModalities: ["AUDIO"],
              translationConfig: {
                targetLanguageCode: this.targetLang,
              }
            }
          }
        };
        this.geminiWs.send(JSON.stringify(setupMsg));
        log(`[Bridge] Gemini 连接成功: ${this.trackName} → ${this.targetLang}`);
        resolve();
      });

      this.geminiWs.on("message", async (data) => {
        try {
          const msg = JSON.parse(data.toString());
          if (msg.serverContent?.modelTurn?.parts) {
            for (const part of msg.serverContent.modelTurn.parts) {
              if (part.inlineData?.data) {
                // 收到翻译音频（24kHz PCM base64）
                const pcmBuffer = Buffer.from(part.inlineData.data, "base64");
                await this._playTranslatedAudio(pcmBuffer);
              }
            }
          }
        } catch (e) {
          // 忽略解析错误
        }
      });

      this.geminiWs.on("error", (e) => {
        log(`[Bridge] Gemini WS错误: ${this.trackName}: ${e.message}`);
        reject(e);
      });

      this.geminiWs.on("close", (code, reason) => {
        log(`[Bridge] Gemini WS关闭: ${this.trackName} code:${code}`);
      });
    });
  }

  async _pipeAudioToGemini() {
    try {
      for await (const frame of this.audioStream) {
        if (this.closed) break;
        if (this.geminiWs?.readyState !== WebSocket.OPEN) continue;

        // 把 AudioFrame 数据转成 base64 发给 Gemini
        const pcmData = Buffer.from(frame.data.buffer);
        const b64 = pcmData.toString("base64");

        const realtimeInput = {
          realtimeInput: {
            mediaChunks: [{
              mimeType: "audio/pcm;rate=16000",
              data: b64
            }]
          }
        };
        this.geminiWs.send(JSON.stringify(realtimeInput));
      }
    } catch (e) {
      if (!this.closed) {
        log(`[Bridge] 音频管道错误: ${this.trackName}: ${e.message}`);
      }
    }
  }

  async _playTranslatedAudio(pcmBuffer) {
    if (this.closed || !this.audioSource) return;
    try {
      // 24kHz 16bit mono PCM → LiveKit AudioFrame
      const numSamples = pcmBuffer.length / 2;
      const int16Data = new Int16Array(pcmBuffer.buffer, pcmBuffer.byteOffset, numSamples);
      const frame = new AudioFrame(int16Data, 24000, 1, numSamples);
      await this.audioSource.captureFrame(frame);
    } catch (e) {
      // 忽略帧播放错误
    }
  }

  async close() {
    this.closed = true;
    if (this.geminiWs) {
      try { this.geminiWs.close(); } catch(e) {}
      this.geminiWs = null;
    }
    if (this.localTrack) {
      try {
        await this.room.localParticipant.unpublishTrack(this.localTrack.sid);
      } catch(e) {}
      this.localTrack = null;
    }
    log(`[Bridge] 已关闭: ${this.trackName}`);
  }
}

// ─── TranslationRouter ─────────────────────────────────────────────────────
// 管理房间内所有翻译 Bridge，监听参与者变化
class TranslationRouter {
  constructor(room, geminiApiKey) {
    this.room = room;
    this.geminiApiKey = geminiApiKey;
    this.bridges = new Map(); // key: "speakerId:targetLang"
    this.debounceTimer = null;
    this.cachedTracks = new Map(); // speakerId → AudioTrack
  }

  scheduleReconcile() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => this.reconcile(), RECONCILE_DEBOUNCE_MS);
  }

  async reconcile() {
    // 收集当前参与者语言
    const participants = new Map();
    for (const [id, p] of this.room.remoteParticipants) {
      const lang = p.attributes?.[ATTR_LANG];
      if (lang && SUPPORTED_LANGS.has(lang)) {
        participants.set(id, lang);
      }
    }

    log(`[Router] 参与者: ${JSON.stringify(Object.fromEntries(participants))}`);

    // 计算需要的翻译对
    const needed = new Set();
    for (const [speakerId, speakerLang] of participants) {
      for (const [listenerId, listenerLang] of participants) {
        if (speakerId !== listenerId && speakerLang !== listenerLang) {
          needed.add(`${speakerId}:${listenerLang}`);
        }
      }
    }

    // 关闭不再需要的 Bridge
    for (const [key, bridge] of this.bridges) {
      if (!needed.has(key)) {
        await bridge.close();
        this.bridges.delete(key);
      }
    }

    // 创建新需要的 Bridge
    for (const key of needed) {
      if (this.bridges.has(key)) continue;
      const [speakerId, targetLang] = key.split(":");
      const audioTrack = this.cachedTracks.get(speakerId);
      if (!audioTrack) {
        log(`[Router] 等待 ${speakerId} 的音频轨道`);
        continue;
      }
      const bridge = new GeminiTranslationBridge(speakerId, targetLang, this.room, this.geminiApiKey);
      this.bridges.set(key, bridge);
      bridge.start(audioTrack).catch(e => {
        log(`[Router] Bridge启动失败: ${key}: ${e.message}`);
        this.bridges.delete(key);
      });
    }
  }

  onTrackSubscribed(track, publication, participant) {
    if (track.kind === "audio") {
      this.cachedTracks.set(participant.identity, track);
      log(`[Router] 订阅到音频: ${participant.identity}`);
      this.scheduleReconcile();
    }
  }

  async closeAll() {
    for (const bridge of this.bridges.values()) {
      await bridge.close();
    }
    this.bridges.clear();
  }
}

// ─── 活跃的翻译房间 ─────────────────────────────────────────────────────────
const activeTranslationRooms = new Map(); // roomName → { room, router }

// ─── 启动翻译 Bridge（由 /livekit-token 接口调用）────────────────────────
async function startTranslationBridge(roomName, lkUrl, lkKey, lkSecret, geminiApiKey) {
  if (activeTranslationRooms.has(roomName)) {
    log(`[Bridge] 房间已有翻译: ${roomName}`);
    return;
  }

  try {
    const { AccessToken } = require("livekit-server-sdk");
    const botIdentity = `translator-${Date.now()}`;
    const at = new AccessToken(lkKey, lkSecret, { identity: botIdentity, ttl: 7200 });
    at.addGrant({ roomJoin: true, room: roomName, canPublish: true, canSubscribe: true });
    const token = await at.toJwt();

    const room = new Room();
    const router = new TranslationRouter(room, geminiApiKey);

    room.on(RoomEvent.ParticipantConnected, () => router.scheduleReconcile());
    room.on(RoomEvent.ParticipantDisconnected, (p) => {
      router.cachedTracks.delete(p.identity);
      router.scheduleReconcile();
    });
    room.on(RoomEvent.TrackSubscribed, (track, pub, participant) => {
      router.onTrackSubscribed(track, pub, participant);
    });
    room.on(RoomEvent.ParticipantAttributesChanged, () => router.scheduleReconcile());
    room.on(RoomEvent.Disconnected, async () => {
      log(`[Bridge] 房间断开: ${roomName}`);
      await router.closeAll();
      activeTranslationRooms.delete(roomName);
    });

    await room.connect(lkUrl, token);
    activeTranslationRooms.set(roomName, { room, router });
    log(`[Bridge] ✅ 翻译Bridge已启动: ${roomName}`);

    // 立刻reconcile（处理已在房间的参与者）
    await router.reconcile();

  } catch(e) {
    log(`[Bridge] ❌ 启动失败: ${roomName}: ${e.message}`);
    activeTranslationRooms.delete(roomName);
  }
}

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

module.exports = { startTranslationBridge, activeTranslationRooms };
