// WhisperTokenizer.kt
// GloTalk-V3 — Whisper tiktoken BPE decode 工具类
// 职责：读取 multilingual.tiktoken，将 token ID 序列还原为 UTF-8 文字
// 来源：openai/whisper tokenizer.py 官方读取逻辑
//       https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
// 查证报告：A-008b
// 路径：GloTalk-V3/android/app/src/main/kotlin/tech/glotalk/glotalk_v3/WhisperTokenizer.kt

package tech.glotalk.glotalk_v3

import android.content.Context
import android.util.Base64    // Android API 1+，minSdk 24 完全支持
import android.util.Log
import java.io.File

/**
 * Whisper tiktoken BPE decode 工具类（Kotlin object 单例，懒加载）
 *
 * 文件格式（来源：openai/whisper tokenizer.py 官方源码）：
 *   multilingual.tiktoken 是纯文本，每行两列，空格分隔：
 *     <base64编码的token字节>  <整数rank>
 *   rank 即为 token ID，base64 解码后得到该 token 对应的 UTF-8 字节。
 *
 * decode 路径（来源：A-008b 查证报告）：
 *   token ID → 查 Map<Int,ByteArray> → 拼接 ByteArray → String(UTF-8)
 *   无需 BPE merge 算法（merge 只在 encode 时需要），纯查表，零 JNI，零依赖。
 *
 * 特殊 token 范围（来源：WhisperInference.kt A-004 WHISPER-6）：
 *   ID >= 50257 均为特殊 token，decode 前已由调用方过滤。
 */
object WhisperTokenizer {

    private const val TAG = "WhisperTokenizer"

    // token ID → UTF-8 字节（来源：multilingual.tiktoken rank → base64 bytes）
    private val idToBytes = HashMap<Int, ByteArray>(65536)

    @Volatile private var loaded = false

    /**
     * 懒加载：首次调用时从 filesDir 读取 multilingual.tiktoken
     * 来源：A-008b — 文件在 filesDir，不在 assets
     * 来源：https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
     *
     * 线程安全：@Volatile + synchronized 双重检查，推理线程首次触发时只加载一次
     */
    fun load(context: Context) {
        if (loaded) return
        synchronized(this) {
            if (loaded) return

            val file = File(context.filesDir, "multilingual.tiktoken")
            if (!file.exists()) {
                Log.w(TAG, "multilingual.tiktoken 未找到，decode 将返回 token ID 序列")
                return
            }

            try {
                // 来源：openai/whisper tokenizer.py 官方读取逻辑
                // with open(vocab_path, 'r', encoding='utf-8') as file:
                //     ranks = {
                //         base64.b64decode(token): int(rank)
                //         for token, rank in (line.split() for line in file if line)
                //     }
                file.bufferedReader(Charsets.UTF_8).useLines { lines ->
                    for (line in lines) {
                        if (line.isBlank()) continue
                        val parts = line.split(" ")
                        if (parts.size != 2) continue
                        val bytes = Base64.decode(parts[0], Base64.DEFAULT)
                        val rank  = parts[1].toIntOrNull() ?: continue
                        idToBytes[rank] = bytes
                    }
                }
                loaded = true
                Log.d(TAG, "multilingual.tiktoken 加载完成，词表大小：${idToBytes.size}")
            } catch (e: Exception) {
                Log.e(TAG, "multilingual.tiktoken 读取失败：${e.message}", e)
            }
        }
    }

    /**
     * token ID 列表 → UTF-8 字符串
     *
     * @param tokenIds 已过滤特殊 token 的 ID 列表（调用方保证 ID < 50257）
     * @param context  用于懒加载（首次调用时触发 load）
     * @return 识别文字，加载失败时返回 "[tokens:id,id,...]" 供调试
     *
     * decode 路径（来源：A-008b）：
     *   ids → 各自查 idToBytes → 拼接所有 ByteArray → String(UTF-8)
     */
    fun decode(tokenIds: List<Long>, context: Context): String {
        // 懒加载：推理线程首次调用时触发
        load(context)

        if (!loaded || idToBytes.isEmpty()) {
            // 回退：未加载时返回 token ID 序列（与原 decodeTokens TODO 行为一致）
            return "[tokens:${tokenIds.joinToString(",")}]"
        }

        // 拼接所有 token 对应的字节，统一 UTF-8 decode
        // 来源：A-008b — token bytes 拼接后整体 decode，而非逐 token decode
        // 原因：单个 token 可能只是一个 UTF-8 字符的部分字节（多字节字符跨 token）
        val byteList = ArrayList<Byte>(tokenIds.size * 3)
        for (id in tokenIds) {
            val bytes = idToBytes[id.toInt()]
            if (bytes != null) {
                for (b in bytes) byteList.add(b)
            }
            // 查不到的 ID 静默跳过（特殊 token 理论上已被调用方过滤）
        }

        return String(byteList.toByteArray(), Charsets.UTF_8)
    }
}
