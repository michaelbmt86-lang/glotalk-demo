/**
 * Qwen3-TTS 实时语音合成接口
 * 官方文档：https://help.aliyun.com/zh/model-studio/qwen-tts-realtime
 *
 * 接收翻译文字 + voice_id，调用阿里云 WebSocket API，
 * 流式返回 PCM 音频数据给前端播放
 *
 * 支持的语言（Qwen3-TTS）：
 * zh, en, ja, ko, de, fr, ru, pt, es, it
 * 其他语言（如 ar, th, id）请使用 Fish Audio S2
 */

import { NextRequest } from "next/server"

// 新加坡节点 WebSocket（GloTalk 服务器在新加坡）
const DASHSCOPE_WS_URL = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime"

// 与 clone-voice 里的 TARGET_MODEL 必须一致
const TTS_MODEL = "qwen3-tts-vc-realtime-2026-01-15"

// Qwen3-TTS 支持的语言列表（其他语言用 Fish Audio S2）
const QWEN3_SUPPORTED_LANGUAGES = new Set([
  "zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it",
])

export async function POST(req: NextRequest) {
  const apiKey = process.env.DASHSCOPE_API_KEY
  if (!apiKey) {
    return new Response(JSON.stringify({ error: "DASHSCOPE_API_KEY not configured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  try {
    const body = await req.json()
    const { text, voiceId, language = "en" } = body

    if (!text || !voiceId) {
      return new Response(JSON.stringify({ error: "text and voiceId are required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      })
    }

    // 检查语言是否在 Qwen3-TTS 支持范围内
    if (!QWEN3_SUPPORTED_LANGUAGES.has(language)) {
      return new Response(
        JSON.stringify({
          error: `Language ${language} not supported by Qwen3-TTS. Use Fish Audio S2 instead.`,
          useAlternative: "fish-audio",
        }),
        { status: 422, headers: { "Content-Type": "application/json" } }
      )
    }

    // 通过 WebSocket 连接阿里云，获取 PCM 音频
    // 由于 Next.js API Route 不支持原生 WebSocket，这里用 HTTP 非实时接口作为降级方案
    // 实时 WebSocket 版本在前端直接连接（见 lib/qwen3-tts-client.ts）
    const nonRealtimeUrl = `https://dashscope-intl.aliyuncs.com/api/v1/services/audio/tts/synthesis`

    const response = await fetch(nonRealtimeUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "X-DashScope-OssResourceResolve": "enable",
      },
      body: JSON.stringify({
        model: "qwen3-tts-vc-2026-01-22",
        input: { text },
        parameters: {
          voice: voiceId,
          format: "mp3",
          sample_rate: 24000,
        },
      }),
    })

    if (!response.ok) {
      const errorText = await response.text()
      console.error("[Qwen3-TTS] Error:", response.status, errorText)
      return new Response(
        JSON.stringify({ error: `Qwen3-TTS failed: ${response.status}` }),
        { status: response.status, headers: { "Content-Type": "application/json" } }
      )
    }

    // 返回音频流给前端
    const audioBuffer = await response.arrayBuffer()
    return new Response(audioBuffer, {
      status: 200,
      headers: {
        "Content-Type": "audio/mpeg",
        "Content-Length": audioBuffer.byteLength.toString(),
      },
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error"
    console.error("[Qwen3-TTS] Exception:", message)
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }
}
