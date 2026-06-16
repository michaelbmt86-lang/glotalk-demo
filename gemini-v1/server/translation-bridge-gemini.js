/**
 * GloTalk 路线B升级版 — TranslationBridge + TranslationSessionManager
 * 参考来源：google-gemini/gemini-live-api-examples
 *   src/lib/translation-bridge.ts
 *   src/lib/translation-session-manager.ts
 * 适配：Node.js（原生 http，非 Next.js），使用 @livekit/rtc-node
 * 与路线A完全隔离，所有接口加 /api/gemini/ 前缀
 */

const { AccessToken } = require("livekit-server-sdk");
const {
  Room,
  RoomEvent,
  LocalAudioTrack,
  AudioSource,
  AudioFrame,
  TrackPublishOptions,
  TrackSource,
  TrackKind,
  AudioStream,
} = require("@livekit/rtc-node");
const WebSocket = require("ws");

// ============================================================
// TranslationBridge（来自官方 translation-bridge.ts）
// 每个语言一个实例，以 Bot 身份加入 LiveKit 房间
// ============================================================
class TranslationBridge {
  constructor(sessionId, targetLanguage, organizerIdentity, config) {
    this.sessionId = sessionId;
    this.targetLanguage = targetLanguage;
    this.organizerIdentity = organizerIdentity;
    this.identity = `translator-${targetLanguage}`;
    this.geminiApiKey = config.geminiApiKey;
    this.livekitUrl = config.livekitUrl;
    this.livekitApiKey = config.livekitApiKey;
    this.livekitApiSecret = config.livekitApiSecret;

    // 官方配置（来自 translation-bridge.ts）
    this.geminiModel = "gemini-3.5-live-translate-preview";
    this.sampleRate = 24000;       // Gemini 输出 24kHz
    this.inputSampleRate = 48000;  // LiveKit 默认 48kHz
    this.channels = 1;

    this.room = null;
    this.geminiWs = null;
    this.audioSource = null;
    this.localTrack = null;
    this.publishedTrackSid = "";
    this.transcriptionSegmentId = 0;
    this.framesSentToGemini = 0;
    this.framesReceivedFromGemini = 0;
    this.geminiSetupComplete = false;
    this.lastAudioFrameTime = 0;
    this.captureChain = Promise.resolve();

    this.status = "starting";
    this.subscriberCount = 0;
  }

  async start() {
    console.log(`[Bridge:${this.targetLanguage}] Starting for session ${this.sessionId}`);
    try {
      await this._joinLiveKitRoom();
      await this._connectGemini();
      await this._subscribeToOrganizer();
      this.status = "active";
      console.log(`[Bridge:${this.targetLanguage}] Active`);
    } catch (err) {
      console.error(`[Bridge:${this.targetLanguage}] Failed:`, err);
      this.status = "error";
      throw err;
    }
  }

  async stop() {
    console.log(`[Bridge:${this.targetLanguage}] Stopping`);
    this.status = "closed";
    if (this.geminiWs) { this.geminiWs.close(); this.geminiWs = null; }
    if (this.room) { await this.room.disconnect(); this.room = null; }
    this.audioSource = null;
    this.localTrack = null;
    this.geminiSetupComplete = false;
  }

  // ── 1. 加入 LiveKit 房间（来自官方 joinLiveKitRoom）──
  async _joinLiveKitRoom() {
    const at = new AccessToken(this.livekitApiKey, this.livekitApiSecret, {
      identity: this.identity,
      name: `Translator (${this.targetLanguage.toUpperCase()})`,
    });
    at.addGrant({ roomJoin: true, room: this.sessionId, canPublish: true, canSubscribe: true });
    const token = await at.toJwt();

    this.room = new Room();
    this.room.on(RoomEvent.Disconnected, () => {
      console.log(`[Bridge:${this.targetLanguage}] Disconnected from room`);
      this.status = "closed";
    });

    await this.room.connect(this.livekitUrl, token, { autoSubscribe: false, dynacast: false });
    console.log(`[Bridge:${this.targetLanguage}] Joined room as ${this.identity}`);

    // 创建翻译音轨发布源（Gemini 输出 24kHz mono PCM）
    this.audioSource = new AudioSource(this.sampleRate, this.channels);
    this.localTrack = LocalAudioTrack.createAudioTrack(
      `translated-audio-${this.targetLanguage}`,
      this.audioSource
    );

    const publishOptions = new TrackPublishOptions();
    publishOptions.source = TrackSource.SOURCE_MICROPHONE;
    await this.room.localParticipant.publishTrack(this.localTrack, publishOptions);

    // 保存已发布 track 的 SID
    for (const [, pub] of this.room.localParticipant.trackPublications) {
      if (pub.track === this.localTrack) {
        this.publishedTrackSid = pub.sid || "";
        break;
      }
    }
    console.log(`[Bridge:${this.targetLanguage}] Published translated audio track`);
  }

  // ── 2. 连接 Gemini Live API WebSocket（来自官方 connectGemini）──
  async _connectGemini() {
    const wsUrl = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${this.geminiApiKey}`;

    return new Promise((resolve, reject) => {
      this.geminiWs = new WebSocket(wsUrl);

      this.geminiWs.on("open", () => {
        console.log(`[Bridge:${this.targetLanguage}] Gemini WebSocket connected`);
        this._sendGeminiSetup();
      });

      this.geminiWs.on("message", (data) => {
        this._handleGeminiMessage(data);
      });

      this.geminiWs.on("error", (err) => {
        console.error(`[Bridge:${this.targetLanguage}] Gemini WS error:`, err);
        if (!this.geminiSetupComplete) reject(err);
      });

      this.geminiWs.on("close", (code, reason) => {
        const reasonStr = reason.toString();
        console.log(`[Bridge:${this.targetLanguage}] Gemini WS closed`, { code, reason: reasonStr });
        if (!this.geminiSetupComplete) {
          reject(new Error(`Gemini WS closed before setup: code=${code}`));
        } else if (this.status === "active") {
          // 自动重连（来自官方 reconnectGemini）
          console.log(`[Bridge:${this.targetLanguage}] Reconnecting...`);
          this.geminiSetupComplete = false;
          this._reconnectGemini();
        }
      });

      // 等待 setupComplete（来自官方 checkSetup 逻辑）
      const checkSetup = setInterval(() => {
        if (this.geminiSetupComplete) { clearInterval(checkSetup); resolve(); }
      }, 100);

      setTimeout(() => {
        if (!this.geminiSetupComplete) { clearInterval(checkSetup); reject(new Error("Gemini setup timeout")); }
      }, 15000);
    });
  }

  // 自动重连（来自官方 reconnectGemini）
  async _reconnectGemini() {
    try {
      const wsUrl = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${this.geminiApiKey}`;
      this.geminiWs = new WebSocket(wsUrl);

      this.geminiWs.on("open", () => { this._sendGeminiSetup(); });
      this.geminiWs.on("message", (data) => { this._handleGeminiMessage(data); });
      this.geminiWs.on("error", (err) => { console.error(`[Bridge:${this.targetLanguage}] Reconnect error:`, err); });
      this.geminiWs.on("close", (code) => {
        if (this.status === "active") {
          setTimeout(() => { this.geminiSetupComplete = false; this._reconnectGemini(); }, 1000);
        }
      });
    } catch (err) {
      console.error(`[Bridge:${this.targetLanguage}] Reconnect failed:`, err);
      this.status = "error";
    }
  }

  // ── 3. 发送 Gemini Setup 消息（来自官方 sendGeminiSetup）──
  _sendGeminiSetup() {
    const setupMessage = {
      setup: {
        model: `models/${this.geminiModel}`,
        outputAudioTranscription: {},
        generationConfig: {
          responseModalities: ["AUDIO"],
          translationConfig: {
            targetLanguageCode: this.targetLanguage,
            echoTargetLanguage: true,
          },
        },
        realtimeInputConfig: {
          automaticActivityDetection: { disabled: false },
        },
      },
    };
    console.log(`[Bridge:${this.targetLanguage}] Sending Gemini setup`);
    this.geminiWs.send(JSON.stringify(setupMessage));
  }

  // ── 4. 处理 Gemini 返回消息（来自官方 handleGeminiMessage）──
  _handleGeminiMessage(data) {
    try {
      const message = JSON.parse(data.toString());

      if (message.setupComplete) {
        console.log(`[Bridge:${this.targetLanguage}] Gemini setup complete`);
        this.geminiSetupComplete = true;
        return;
      }

      // 处理翻译音频帧
      const parts = message?.serverContent?.modelTurn?.parts;
      if (parts?.length) {
        for (const part of parts) {
          if (part.inlineData?.data) {
            this.framesReceivedFromGemini++;
            this._queueAudioFrame(part.inlineData.data);
          }
        }
      }

      // 处理字幕（来自官方 outputTranscription）
      const outputTranscription = message?.serverContent?.outputTranscription;
      if (outputTranscription?.text) {
        this._publishTranscriptionText(
          outputTranscription.text,
          !message.serverContent.turnComplete
        );
      }

      if (message?.serverContent?.turnComplete) {
        this.transcriptionSegmentId++;
      }
    } catch (err) {
      console.error(`[Bridge:${this.targetLanguage}] Error parsing Gemini message:`, err);
    }
  }

  // ── 5. 串行发布翻译音频帧（来自官方 queueAudioFrame）──
  _queueAudioFrame(base64Audio) {
    this.captureChain = this.captureChain.then(() =>
      this._publishTranslatedAudio(base64Audio)
    );
  }

  async _publishTranslatedAudio(base64Audio) {
    if (!this.audioSource || this.status === "closed") return;
    try {
      const pcmBuffer = Buffer.from(base64Audio, "base64");
      const int16 = new Int16Array(pcmBuffer.buffer, pcmBuffer.byteOffset, pcmBuffer.byteLength / 2);
      const frame = new AudioFrame(int16, this.sampleRate, this.channels, int16.length);
      await this.audioSource.captureFrame(frame);
      this.lastAudioFrameTime = Date.now();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (msg.includes("InvalidState") || msg.includes("closed")) {
        console.warn(`[Bridge:${this.targetLanguage}] AudioSource closed`);
        this.audioSource = null;
      } else {
        console.error(`[Bridge:${this.targetLanguage}] Error capturing audio:`, err);
      }
    }
  }

  // ── 6. 订阅主讲人音频（来自官方 subscribeToOrganizer）──
  async _subscribeToOrganizer() {
    if (!this.room) return;

    for (const [, participant] of this.room.remoteParticipants) {
      if (participant.identity === this.organizerIdentity) {
        this._subscribeToParticipantAudio(participant);
        return;
      }
    }

    console.log(`[Bridge:${this.targetLanguage}] Waiting for organizer ${this.organizerIdentity}...`);

    this.room.on(RoomEvent.TrackPublished, (publication, participant) => {
      if (participant.identity === this.organizerIdentity && publication.kind === TrackKind.KIND_AUDIO) {
        publication.setSubscribed(true);
      }
    });

    this.room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
      if (participant.identity === this.organizerIdentity && publication.kind === TrackKind.KIND_AUDIO) {
        this._pipeTrackToGemini(track);
      }
    });
  }

  _subscribeToParticipantAudio(participant) {
    for (const [, publication] of participant.trackPublications) {
      if (publication.kind === TrackKind.KIND_AUDIO) {
        publication.setSubscribed(true);
      }
    }

    this.room.on(RoomEvent.TrackSubscribed, (track, pub, p) => {
      if (p.identity === this.organizerIdentity && pub.kind === TrackKind.KIND_AUDIO) {
        this._pipeTrackToGemini(track);
      }
    });
  }

  // ── 7. 把音频流管道接入 Gemini（来自官方 pipeTrackToGemini）──
  _pipeTrackToGemini(track) {
    console.log(`[Bridge:${this.targetLanguage}] Piping organizer audio to Gemini`);

    const audioStream = new AudioStream(track, {
      sampleRate: this.inputSampleRate,
      numChannels: this.channels,
      frameSizeMs: 100,
    });

    const reader = audioStream.getReader();
    const readLoop = async () => {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        this._sendAudioToGemini(value);
      }
    };

    readLoop().catch((err) => {
      console.error(`[Bridge:${this.targetLanguage}] Audio stream error:`, err);
    });
  }

  // ── 8. 把音频帧发给 Gemini（来自官方 sendAudioToGemini）──
  _sendAudioToGemini(frame) {
    if (!this.geminiWs || this.geminiWs.readyState !== WebSocket.OPEN || !this.geminiSetupComplete) return;

    try {
      const int16Data = frame.data;
      const buffer = Buffer.from(int16Data.buffer, int16Data.byteOffset, int16Data.byteLength);
      const base64 = buffer.toString("base64");

      this.framesSentToGemini++;

      this.geminiWs.send(JSON.stringify({
        realtimeInput: {
          audio: {
            mimeType: `audio/pcm;rate=${this.inputSampleRate}`,
            data: base64,
          },
        },
      }));
    } catch (err) {
      console.error(`[Bridge:${this.targetLanguage}] Error sending audio:`, err);
    }
  }

  // ── 9. 发布字幕数据（来自官方 publishTranscriptionText）──
  async _publishTranscriptionText(text, interim) {
    if (!this.room?.localParticipant) return;
    try {
      const payload = JSON.stringify({
        type: "transcription",
        language: this.targetLanguage,
        segmentId: `${this.targetLanguage}-${this.transcriptionSegmentId}`,
        text,
        final: !interim,
        timestamp: Date.now(),
      });
      await this.room.localParticipant.publishData(
        new TextEncoder().encode(payload),
        { reliable: true, topic: "transcription" }
      );
    } catch (err) {
      console.error(`[Bridge:${this.targetLanguage}] Error publishing transcription:`, err);
    }
  }
}

// ============================================================
// TranslationSessionManager（来自官方 translation-session-manager.ts）
// 单例，每个房间每种语言最多一个 Bridge 实例
// ============================================================
class TranslationSessionManager {
  constructor() {
    this.translations = new Map(); // Map<sessionId, Map<language, TranslationBridge>>
    this.sessions = new Map();     // Map<sessionId, SessionInfo>
  }

  static getInstance() {
    if (!TranslationSessionManager._instance) {
      TranslationSessionManager._instance = new TranslationSessionManager();
    }
    return TranslationSessionManager._instance;
  }

  createSession(sessionId, organizerIdentity) {
    const info = { sessionId, organizerIdentity, createdAt: new Date() };
    this.sessions.set(sessionId, info);
    console.log(`[SessionManager] Created session ${sessionId} for organizer ${organizerIdentity}`);
    return info;
  }

  getSession(sessionId) {
    return this.sessions.get(sessionId);
  }

  getAllSessions() {
    return Array.from(this.sessions.values());
  }

  async getOrCreate(sessionId, targetLanguage, organizerIdentity) {
    let languageMap = this.translations.get(sessionId);

    if (languageMap) {
      const existing = languageMap.get(targetLanguage);
      if (existing && existing.status === "active") {
        console.log(`[SessionManager] Reusing bridge for ${targetLanguage} in ${sessionId}`);
        existing.subscriberCount++;
        return existing;
      }
      if (existing && (existing.status === "error" || existing.status === "closed")) {
        await existing.stop();
        languageMap.delete(targetLanguage);
      }
    }

    console.log(`[SessionManager] Creating bridge for ${targetLanguage} in ${sessionId}`);

    const config = {
      geminiApiKey: process.env.GEMINI_API_KEY,
      livekitUrl: process.env.LIVEKIT_URL,
      livekitApiKey: process.env.LIVEKIT_API_KEY,
      livekitApiSecret: process.env.LIVEKIT_API_SECRET,
    };

    const bridge = new TranslationBridge(sessionId, targetLanguage, organizerIdentity, config);

    if (!languageMap) {
      languageMap = new Map();
      this.translations.set(sessionId, languageMap);
    }
    languageMap.set(targetLanguage, bridge);

    try {
      await bridge.start();
      bridge.subscriberCount = 1;
      return bridge;
    } catch (err) {
      languageMap.delete(targetLanguage);
      throw err;
    }
  }

  getActiveTranslations(sessionId) {
    const languageMap = this.translations.get(sessionId);
    if (!languageMap) return [];
    const result = [];
    for (const [language, bridge] of languageMap) {
      result.push({
        language,
        translatorIdentity: bridge.identity,
        status: bridge.status,
        subscriberCount: bridge.subscriberCount,
      });
    }
    return result;
  }

  async unsubscribe(sessionId, targetLanguage) {
    const languageMap = this.translations.get(sessionId);
    if (!languageMap) return;
    const bridge = languageMap.get(targetLanguage);
    if (!bridge) return;

    bridge.subscriberCount = Math.max(0, bridge.subscriberCount - 1);
    console.log(`[SessionManager] Unsubscribed from ${targetLanguage} in ${sessionId} (${bridge.subscriberCount} remaining)`);

    if (bridge.subscriberCount === 0) {
      console.log(`[SessionManager] No more subscribers, tearing down ${targetLanguage} bridge`);
      await bridge.stop();
      languageMap.delete(targetLanguage);
      if (languageMap.size === 0) this.translations.delete(sessionId);
    }
  }

  async removeAllTranslations(sessionId) {
    const languageMap = this.translations.get(sessionId);
    if (!languageMap) return;
    for (const [, bridge] of languageMap) await bridge.stop();
    languageMap.clear();
    this.translations.delete(sessionId);
    this.sessions.delete(sessionId);
    console.log(`[SessionManager] Removed all bridges for session ${sessionId}`);
  }
}

module.exports = { TranslationBridge, TranslationSessionManager };
