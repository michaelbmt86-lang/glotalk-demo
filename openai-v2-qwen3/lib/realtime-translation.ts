"use client"

import * as React from "react"

import {
  REALTIME_TRANSLATION_CALL_URL,
  TRANSLATION_LANGUAGES,
  buildSessionUpdate,
} from "@/lib/realtime-translation-config"

import {
  isQwen3Supported,
  recordReferenceAudio,
  cloneVoice,
  synthesizeWithClonedVoice,
  isSentenceComplete,
} from "@/lib/qwen3-tts-client"

// 本地存储 key（App 注册制：voice_id 永久保存，二次通话直接用）
const VOICE_ID_STORAGE_KEY = "glotalk_qwen3_voice_id"

export type TranslationLanguage = {
  value: string
  label: string
}

export { TRANSLATION_LANGUAGES }

export type TranslationStatus = "idle" | "connecting" | "connected" | "error"

type TranslationTokenResponse = {
  clientSecret: string
  expiresAt: number | null
}

type UseRemoteTranslationOptions = {
  enabled: boolean
  sourceTrack: MediaStreamTrack | null
  language: string
  sourceTranscriptionEnabled: boolean
  noiseReductionEnabled: boolean
  translatedVolume: number
}

export type UseRemoteTranslationResult = {
  status: TranslationStatus
  error: string | null
  sourceTranscript: string
  translatedTranscript: string
  sourceSubtitle: string
  translatedSubtitle: string
  hasOutputAudio: boolean
}

type TranslationSessionConfig = {
  language: string
  sourceTranscriptionEnabled: boolean
  noiseReductionEnabled: boolean
}

type RealtimeEvent = {
  type?: unknown
  delta?: unknown
  error?: unknown
}

export function useRemoteTranslation({
  enabled,
  sourceTrack,
  language,
  sourceTranscriptionEnabled,
  noiseReductionEnabled,
  translatedVolume,
}: UseRemoteTranslationOptions): UseRemoteTranslationResult {
  const [status, setStatus] = React.useState<TranslationStatus>("idle")
  const [error, setError] = React.useState<string | null>(null)
  const [sourceTranscript, setSourceTranscript] = React.useState("")
  const [translatedTranscript, setTranslatedTranscript] = React.useState("")
  const [hasOutputAudio, setHasOutputAudio] = React.useState(false)
  const peerConnectionRef = React.useRef<RTCPeerConnection | null>(null)
  const dataChannelRef = React.useRef<RTCDataChannel | null>(null)
  const translatedAudioRef = React.useRef<HTMLAudioElement | null>(null)
  const translatedVolumeRef = React.useRef(translatedVolume)
  const sessionConfigRef = React.useRef<TranslationSessionConfig>({
    language,
    sourceTranscriptionEnabled,
    noiseReductionEnabled,
  })
  const active = enabled && !!sourceTrack

  // ── Qwen3-TTS 声音克隆状态 ──────────────────────────────────────
  // voice_id 优先从 localStorage 读取（App 注册制：一次克隆永久复用）
  const [voiceId, setVoiceId] = React.useState<string | null>(() => {
    if (typeof window !== "undefined") {
      return localStorage.getItem(VOICE_ID_STORAGE_KEY)
    }
    return null
  })
  const [voiceCloneReady, setVoiceCloneReady] = React.useState<boolean>(() => {
    if (typeof window !== "undefined") {
      return !!localStorage.getItem(VOICE_ID_STORAGE_KEY)
    }
    return false
  })
  // 累积翻译字幕，等句子完成后送给 Qwen3-TTS
  const pendingTranslationRef = React.useRef<string>("")
  // 标记是否已经开始录音（避免重复录）
  const recordingStartedRef = React.useRef<boolean>(false)

  React.useEffect(() => {
    translatedVolumeRef.current = translatedVolume
    if (translatedAudioRef.current) {
      translatedAudioRef.current.volume = translatedVolume
    }
  }, [translatedVolume])

  // ── 自动录音 + 声音克隆（通话开始10秒后执行）──────────────────────
  // 设计逻辑（来自产品需求）：
  // 1. 用户进入房间开始通话，前10秒自动静默录制参考音频（用户无感知）
  // 2. 10秒后自动上传到阿里云 Qwen3-TTS，创建克隆音色
  // 3. 克隆成功后，翻译声音从 OpenAI 机器声切换为克隆声音
  // 4. voice_id 保存到 localStorage，下次通话直接跳过录音步骤
  // 5. 仅对 Qwen3-TTS 支持的语言执行（其他语言将来用 Fish Audio S2）
  React.useEffect(() => {
    if (!active || !sourceTrack) return
    if (voiceCloneReady) return  // 已有 voice_id，跳过录音
    if (recordingStartedRef.current) return  // 已经在录了
    if (!isQwen3Supported(language)) return  // 不支持的语言跳过

    recordingStartedRef.current = true
    let timer: ReturnType<typeof setTimeout>

    // 10秒后开始录制10秒参考音频
    timer = setTimeout(async () => {
      console.log("[Qwen3-TTS] 开始录制参考音频（10秒）...")
      try {
        const { audioBase64, mimeType } = await recordReferenceAudio(sourceTrack, 10000)
        console.log("[Qwen3-TTS] 录音完成，上传克隆中...")

        const newVoiceId = await cloneVoice(audioBase64, mimeType, "glotalk-user")
        console.log("[Qwen3-TTS] 声音克隆成功！voice_id:", newVoiceId)

        // 保存到 localStorage（永久复用）
        localStorage.setItem(VOICE_ID_STORAGE_KEY, newVoiceId)
        setVoiceId(newVoiceId)
        setVoiceCloneReady(true)
      } catch (err) {
        console.error("[Qwen3-TTS] 声音克隆失败（不影响翻译）:", err)
        // 克隆失败不影响翻译，只是继续用 OpenAI 机器声
      }
    }, 10000)  // 10秒后开始

    return () => clearTimeout(timer)
  }, [active, sourceTrack, language, voiceCloneReady])

  React.useEffect(() => {
    const nextConfig = {
      language,
      sourceTranscriptionEnabled,
      noiseReductionEnabled,
    }
    sessionConfigRef.current = nextConfig

    const dataChannel = dataChannelRef.current
    if (!active || !dataChannel || dataChannel.readyState !== "open") {
      return
    }

    dataChannel.send(JSON.stringify(buildTranslationSessionUpdate(nextConfig)))
  }, [active, language, noiseReductionEnabled, sourceTranscriptionEnabled])

  React.useEffect(() => {
    if (!active || !sourceTrack) {
      return
    }

    const activeSourceTrack = sourceTrack
    let cancelled = false
    let peerConnection: RTCPeerConnection | null = null
    let dataChannel: RTCDataChannel | null = null
    let translatedAudio: HTMLAudioElement | null = null

    async function connect() {
      const initialSessionConfig = sessionConfigRef.current
      setStatus("connecting")
      setError(null)
      setSourceTranscript("")
      setTranslatedTranscript("")
      setHasOutputAudio(false)

      try {
        const tokenResponse = await fetch("/api/realtime/translation-token", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            language: initialSessionConfig.language,
            inputTranscriptionEnabled:
              initialSessionConfig.sourceTranscriptionEnabled,
            noiseReductionEnabled: initialSessionConfig.noiseReductionEnabled,
          }),
        })

        if (!tokenResponse.ok) {
          throw new Error(await tokenResponse.text())
        }

        const token = (await tokenResponse.json()) as TranslationTokenResponse

        if (cancelled) {
          return
        }

        peerConnection = new RTCPeerConnection()
        dataChannel = peerConnection.createDataChannel("oai-events")
        translatedAudio = new Audio()
        translatedAudio.autoplay = true
        translatedAudio.setAttribute("playsinline", "")
        translatedAudio.volume = translatedVolumeRef.current

        peerConnectionRef.current = peerConnection
        dataChannelRef.current = dataChannel
        translatedAudioRef.current = translatedAudio

        peerConnection.ontrack = ({ streams, track }) => {
          if (!translatedAudio) {
            return
          }

          translatedAudio.srcObject = streams[0] ?? new MediaStream([track])
          setHasOutputAudio(true)
          void translatedAudio.play().catch((audioError) => {
            setError(getErrorMessage(audioError))
          })
        }

        peerConnection.onconnectionstatechange = () => {
          if (!peerConnection || cancelled) {
            return
          }

          if (peerConnection.connectionState === "failed") {
            setError("Translation WebRTC connection failed")
            setStatus("error")
          }

          if (peerConnection.connectionState === "connected") {
            setStatus("connected")
          }
        }

        dataChannel.onopen = () => {
          if (!dataChannel || cancelled) {
            return
          }

          dataChannel.send(
            JSON.stringify(
              buildTranslationSessionUpdate(sessionConfigRef.current)
            )
          )
        }
        dataChannel.onmessage = (event) => {
          if (!cancelled) {
            void handleRealtimeEvent(event.data, {
              onSessionReady: () => setStatus("connected"),
              onInputTranscript: (delta) => {
                setSourceTranscript((current) =>
                  appendTranscriptDelta(current, delta)
                )
              },
              onOutputAudio: () => setHasOutputAudio(true),
              onOutputTranscript: (delta) => {
                // 更新字幕显示（官方逻辑，不动）
                setTranslatedTranscript((current) =>
                  appendTranscriptDelta(current, delta)
                )

                // ── Qwen3-TTS 克隆声音播放 ──────────────────────────
                // 克隆就绪后：累积翻译字幕，句子完成时用克隆声音朗读
                // 克隆未就绪时：继续用 OpenAI 翻译音频（peerConnection.ontrack）
                const currentVoiceId = voiceId
                if (currentVoiceId && voiceCloneReady && isQwen3Supported(language)) {
                  pendingTranslationRef.current += delta

                  // 检测句子是否完成（遇到标点符号）
                  if (isSentenceComplete(pendingTranslationRef.current)) {
                    const sentence = pendingTranslationRef.current.trim()
                    pendingTranslationRef.current = ""

                    // 静音 OpenAI 翻译音频，切换到克隆声音
                    if (translatedAudio) {
                      translatedAudio.volume = 0
                    }

                    void synthesizeWithClonedVoice(sentence, currentVoiceId, language).catch(
                      (err) => {
                        console.warn("[Qwen3-TTS] 合成失败，回退到 OpenAI 音频:", err)
                        // 合成失败时恢复 OpenAI 音频
                        if (translatedAudio) {
                          translatedAudio.volume = translatedVolumeRef.current
                        }
                      }
                    )
                  }
                }
              },
              onError: (message) => {
                setError(message)
                setStatus("error")
              },
            })
          }
        }
        dataChannel.onerror = () => {
          if (!cancelled) {
            setError("Translation data channel failed")
            setStatus("error")
          }
        }

        peerConnection.addTrack(
          activeSourceTrack,
          new MediaStream([activeSourceTrack])
        )

        const offer = await peerConnection.createOffer()
        await peerConnection.setLocalDescription(offer)

        const sdpResponse = await fetch(REALTIME_TRANSLATION_CALL_URL, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token.clientSecret}`,
            "Content-Type": "application/sdp",
          },
          body: offer.sdp,
        })

        const answerSdp = await sdpResponse.text()
        if (!sdpResponse.ok) {
          throw new Error(answerSdp)
        }

        await peerConnection.setRemoteDescription({
          type: "answer",
          sdp: answerSdp,
        })

        if (!cancelled) {
          setStatus("connected")
        }
      } catch (connectError) {
        if (!cancelled) {
          setError(getErrorMessage(connectError))
          setStatus("error")
        }
      }
    }

    void connect()

    return () => {
      cancelled = true
      dataChannel?.close()
      peerConnection?.close()

      if (translatedAudio) {
        translatedAudio.pause()
        translatedAudio.srcObject = null
      }

      if (dataChannelRef.current === dataChannel) {
        dataChannelRef.current = null
      }
      if (peerConnectionRef.current === peerConnection) {
        peerConnectionRef.current = null
      }
      if (translatedAudioRef.current === translatedAudio) {
        translatedAudioRef.current = null
      }
    }
  }, [active, sourceTrack])

  return {
    status: active ? status : "idle",
    error: active ? error : null,
    sourceTranscript,
    translatedTranscript,
    sourceSubtitle: getSubtitle(sourceTranscript),
    translatedSubtitle: getSubtitle(translatedTranscript),
    hasOutputAudio: active ? hasOutputAudio : false,
  }
}

async function handleRealtimeEvent(
  payload: unknown,
  handlers: {
    onSessionReady: () => void
    onInputTranscript: (delta: string) => void
    onOutputAudio: () => void
    onOutputTranscript: (delta: string) => void
    onError: (message: string) => void
  }
) {
  const text =
    typeof payload === "string"
      ? payload
      : payload instanceof Blob
        ? await payload.text()
        : null

  if (!text) {
    return
  }

  let event: RealtimeEvent
  try {
    event = JSON.parse(text) as RealtimeEvent
  } catch {
    return
  }

  if (event.type === "session.updated") {
    handlers.onSessionReady()
    return
  }

  if (event.type === "session.input_transcript.delta") {
    if (typeof event.delta === "string") {
      handlers.onInputTranscript(event.delta)
    }
    return
  }

  if (event.type === "session.output_audio.delta") {
    handlers.onOutputAudio()
    return
  }

  if (event.type === "session.output_transcript.delta") {
    if (typeof event.delta === "string") {
      handlers.onOutputTranscript(event.delta)
    }
    return
  }

  if (event.type === "error") {
    const error = event.error
    if (error && typeof error === "object" && !Array.isArray(error)) {
      const message = (error as Record<string, unknown>).message
      handlers.onError(
        typeof message === "string" ? message : "Translation error"
      )
      return
    }

    handlers.onError("Translation error")
  }
}

function appendTranscriptDelta(current: string, delta: string) {
  if (!delta) {
    return current
  }

  if (!current) {
    return delta.replace(/^\s+/, "")
  }

  if (
    /\s$/.test(current) ||
    /^\s/.test(delta) ||
    /^[,.;:!?%)}\]]/.test(delta)
  ) {
    return `${current}${delta}`
  }

  return `${current} ${delta}`
}

function buildTranslationSessionUpdate(config: TranslationSessionConfig) {
  return buildSessionUpdate({
    language: config.language,
    inputTranscriptionEnabled: config.sourceTranscriptionEnabled,
    noiseReductionEnabled: config.noiseReductionEnabled,
  })
}

function getSubtitle(transcript: string) {
  const normalized = transcript.replace(/\s+/g, " ").trim()

  if (!normalized) {
    return ""
  }

  const sentenceStart = Math.max(
    normalized.lastIndexOf(". "),
    normalized.lastIndexOf("? "),
    normalized.lastIndexOf("! ")
  )
  const latest =
    sentenceStart >= 0 ? normalized.slice(sentenceStart + 2) : normalized

  return latest.length > 180 ? latest.slice(latest.length - 180) : latest
}

function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Translation failed"
}
