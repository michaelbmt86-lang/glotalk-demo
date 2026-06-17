// ============================================================
// GloTalk 路线A — 新增接口片段
// 参考来源：OpenAI Cookbook livekit-translation-demo
//   app/api/realtime/translation-token/route.ts
//   lib/realtime-translation-config.js
// 这段代码插入到现有 server.js 末尾（在 app.listen 之前）
// ============================================================

// ---- 官方常量（来自 realtime-translation-config.js）----
const OPENAI_TRANSLATION_CLIENT_SECRET_URL =
  "https://api.openai.com/v1/realtime/translations/client_secrets";

const TRANSLATION_MODEL =
  process.env.OPENAI_TRANSLATION_MODEL || "gpt-realtime-translate";

const SUPPORTED_LANGUAGES = new Set([
  "es", "pt", "fr", "ja", "ru", "zh", "de", "ko",
  "hi", "id", "vi", "it", "en",
]);

const LANGUAGE_PATTERN = /^[a-z]{2,3}(?:-[a-z0-9]{2,8}){0,2}$/;

// ---- 官方 normalizeTranslationLanguage（来自 config.js）----
function normalizeTranslationLanguage(language) {
  if (typeof language !== "string" || !language.trim()) {
    throw new Error("A translation language is required");
  }
  const normalized = language.trim().toLowerCase();
  if (!LANGUAGE_PATTERN.test(normalized)) {
    throw new Error("Invalid translation language");
  }
  if (!SUPPORTED_LANGUAGES.has(normalized)) {
    throw new Error("Unsupported translation language");
  }
  return normalized;
}

// ---- 官方 buildTranslationSessionConfig（来自 config.js）----
function buildTranslationSessionConfig({
  language,
  inputTranscriptionEnabled,
  noiseReductionEnabled,
}) {
  return {
    model: TRANSLATION_MODEL,
    audio: {
      input: {
        ...(inputTranscriptionEnabled
          ? { transcription: { model: "gpt-realtime-whisper" } }
          : {}),
        noise_reduction: noiseReductionEnabled
          ? { type: "near_field" }
          : null,
      },
      output: {
        language: normalizeTranslationLanguage(language),
      },
    },
  };
}

// ---- 官方 translation-token 接口（来自 route.ts）----
// POST /api/translation-token
// Body: { language, inputTranscriptionEnabled, noiseReductionEnabled }
// 返回: { clientSecret, expiresAt }
app.post("/api/translation-token", async (req, res) => {
  const apiKey = process.env.OPENAI_API_KEY;

  if (!apiKey) {
    return res.status(500).send("Missing OPENAI_API_KEY");
  }

  const {
    language,
    inputTranscriptionEnabled = false,
    noiseReductionEnabled = false,
  } = req.body || {};

  let normalizedLanguage;
  try {
    normalizedLanguage = normalizeTranslationLanguage(language || "en");
  } catch (error) {
    return res
      .status(400)
      .send(error instanceof Error ? error.message : "Unsupported translation language");
  }

  const sessionConfig = buildTranslationSessionConfig({
    language: normalizedLanguage,
    inputTranscriptionEnabled: !!inputTranscriptionEnabled,
    noiseReductionEnabled: !!noiseReductionEnabled,
  });

  try {
    const response = await fetch(OPENAI_TRANSLATION_CLIENT_SECRET_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ session: sessionConfig }),
    });

    if (!response.ok) {
      const text = await response.text();
      return res.status(response.status).send(text);
    }

    const data = await response.json();

    // 官方 response 结构兼容两种格式
    const clientSecret = data.value ?? data.client_secret?.value;
    const expiresAt = data.expires_at ?? data.client_secret?.expires_at ?? null;

    if (!clientSecret) {
      return res
        .status(502)
        .send("Realtime translation client secret response was missing value");
    }

    return res.json({ clientSecret, expiresAt });
  } catch (err) {
    console.error("[translation-token] error:", err);
    return res.status(500).send("Failed to create translation token");
  }
});
