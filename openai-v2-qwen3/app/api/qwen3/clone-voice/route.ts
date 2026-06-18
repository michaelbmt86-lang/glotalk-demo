/**
 * Qwen3-TTS 声音克隆接口
 * 官方文档：https://help.aliyun.com/zh/model-studio/qwen-tts-voice-cloning
 *
 * 接收前端上传的参考音频（base64），调用阿里云 API 创建克隆音色，返回 voice_id
 * voice_id 缓存在前端，后续 TTS 合成时传入
 */

import { NextRequest, NextResponse } from "next/server"

// 新加坡节点（GloTalk 服务器在新加坡）
const DASHSCOPE_CLONE_URL =
  "https://dashscope-intl.aliyuncs.com/api/v1/services/audio/tts/customization"

// 声音克隆使用的模型（固定，不要改）
const CLONE_MODEL = "qwen-voice-enrollment"

// 对应的实时合成模型（两者必须匹配）
const TARGET_MODEL = "qwen3-tts-vc-realtime-2026-01-15"

export async function POST(req: NextRequest) {
  const apiKey = process.env.DASHSCOPE_API_KEY
  if (!apiKey) {
    return NextResponse.json({ error: "DASHSCOPE_API_KEY not configured" }, { status: 500 })
  }

  try {
    const body = await req.json()
    const { audioBase64, mimeType = "audio/webm", preferredName = "glotalk-user" } = body

    if (!audioBase64) {
      return NextResponse.json({ error: "audioBase64 is required" }, { status: 400 })
    }

    const dataUri = `data:${mimeType};base64,${audioBase64}`

    const response = await fetch(DASHSCOPE_CLONE_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: CLONE_MODEL,
        input: {
          action: "create",
          target_model: TARGET_MODEL,
          preferred_name: preferredName,
          audio: { data: dataUri },
        },
      }),
    })

    if (!response.ok) {
      const errorText = await response.text()
      console.error("[Qwen3-TTS Clone] Error:", response.status, errorText)
      return NextResponse.json(
        { error: `Qwen3-TTS clone failed: ${response.status}` },
        { status: response.status }
      )
    }

    const data = await response.json()
    const voiceId = data?.output?.voice

    if (!voiceId) {
      return NextResponse.json({ error: "No voice ID returned" }, { status: 502 })
    }

    console.log("[Qwen3-TTS Clone] Created voice:", voiceId)
    return NextResponse.json({ voiceId, targetModel: TARGET_MODEL })
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error"
    console.error("[Qwen3-TTS Clone] Exception:", message)
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
