/**
 * Qwen3-TTS 前端客户端
 * 官方文档：https://help.aliyun.com/zh/model-studio/qwen-tts-voice-cloning
 *
 * 功能：
 * 1. cloneVoice()   - 采集参考音频，上传到阿里云，得到 voice_id
 * 2. synthesize()   - 把翻译文字 + voice_id 送给 Qwen3-TTS，播放克隆声音
 * 3. isSupported()  - 判断语言是否在 Qwen3-TTS 支持范围内
 */

// Qwen3-TTS 支持的10种语言
const QWEN3_SUPPORTED_LANGUAGES = new Set([
  "zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it",
])

/**
 * 判断语言是否由 Qwen3-TTS 处理
 * 不在列表里的语言（如 ar, th, id）交给 Fish Audio S2
 */
export function isQwen3Supported(language: string): boolean {
  return QWEN3_SUPPORTED_LANGUAGES.has(language.toLowerCase())
}

/**
 * 从 MediaStreamTrack 录制参考音频（10秒）
 * 返回 base64 字符串
 */
export async function recordReferenceAudio(
  sourceTrack: MediaStreamTrack,
  durationMs: number = 10000
): Promise<{ audioBase64: string; mimeType: string }> {
  return new Promise((resolve, reject) => {
    const stream = new MediaStream([sourceTrack])
    const mimeType = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
      ? "audio/webm;codecs=opus"
      : "audio/webm"

    const recorder = new MediaRecorder(stream, { mimeType })
    const chunks: Blob[] = []

    recorder.ondataavailable = (e) => {
      if (e.data.size > 0) chunks.push(e.data)
    }

    recorder.onstop = async () => {
      const blob = new Blob(chunks, { type: mimeType })
      const arrayBuffer = await blob.arrayBuffer()
      const base64 = btoa(
        Array.from(new Uint8Array(arrayBuffer))
          .map((b) => String.fromCharCode(b))
          .join("")
      )
      resolve({ audioBase64: base64, mimeType })
    }

    recorder.onerror = (e) => reject(e)

    recorder.start()
    setTimeout(() => recorder.stop(), durationMs)
  })
}

/**
 * 上传参考音频，创建克隆音色
 * 返回 voice_id（缓存在调用方，避免重复创建）
 */
export async function cloneVoice(
  audioBase64: string,
  mimeType: string,
  preferredName: string = "glotalk-user"
): Promise<string> {
  const res = await fetch("/api/qwen3/clone-voice", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ audioBase64, mimeType, preferredName }),
  })

  if (!res.ok) {
    const err = await res.json()
    throw new Error(err.error ?? "Voice clone failed")
  }

  const data = await res.json()
  return data.voiceId as string
}

/**
 * 用克隆声音合成翻译文字
 * 返回并自动播放音频
 */
export async function synthesizeWithClonedVoice(
  text: string,
  voiceId: string,
  language: string
): Promise<void> {
  if (!text.trim()) return

  const res = await fetch("/api/qwen3/tts", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text, voiceId, language }),
  })

  if (!res.ok) {
    const err = await res.json()
    // 422 = 语言不支持，应该用 Fish Audio S2
    if (res.status === 422 && err.useAlternative === "fish-audio") {
      console.warn(`[Qwen3-TTS] Language ${language} not supported, fallback to Fish Audio S2`)
      return
    }
    throw new Error(err.error ?? "TTS synthesis failed")
  }

  // 播放返回的音频
  const audioBlob = await res.blob()
  const audioUrl = URL.createObjectURL(audioBlob)
  const audio = new Audio(audioUrl)
  audio.volume = 1.0

  await audio.play()

  // 播放完后释放 URL
  audio.onended = () => URL.revokeObjectURL(audioUrl)
}

/**
 * 判断翻译字幕是否构成一个完整句子（可以送给 TTS）
 * 遇到句号、问号、感叹号等标点就认为句子完成
 */
export function isSentenceComplete(text: string): boolean {
  return /[。！？.!?；;]$/.test(text.trim())
}
