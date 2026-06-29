// OpusMTInference.kt
// GloTalk-V3 | 节点 3：神经机器翻译（NMT）
// 模型：opus-mt-zh-en-encoder.onnx + opus-mt-zh-en-decoder.onnx（约 300MB 各）
// 来源：https://huggingface.co/onnx-community/opus-mt-zh-en
// OnnxRuntime Java API：https://onnxruntime.ai/docs/get-started/with-java.html
// MarianMT 架构：https://huggingface.co/docs/transformers/model_doc/marian
// 查证报告：A-004 第四部分 OPUS-1 ~ OPUS-7

package tech.glotalk.glotalk_v3

import ai.onnxruntime.OnnxTensor      // https://onnxruntime.ai/docs/get-started/with-java.html
import ai.onnxruntime.OrtEnvironment   // https://onnxruntime.ai/docs/get-started/with-java.html
import ai.onnxruntime.OrtSession       // https://onnxruntime.ai/docs/get-started/with-java.html
import android.content.Context
import java.nio.FloatBuffer            // A-004-补丁：OnnxTensor.createTensor(env, FloatBuffer, shape)
import java.nio.LongBuffer             // A-004-补丁：OnnxTensor.createTensor(env, LongBuffer, shape)
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

/**
 * Opus-MT ONNX 翻译推理封装（encoder + decoder 分体）
 *
 * 架构说明（来源：A-004 OPUS-1，HuggingFace onnx-community/opus-mt-zh-en）：
 *   encoder_model.onnx  — 对源语言编码
 *   decoder_model.onnx  — 自回归生成目标语言 token
 *
 * Encoder 输入规格（来源：A-004 OPUS-2，GitHub Issue #26523）：
 *   "input_ids"      int64  [1, src_len]
 *   "attention_mask" int64  [1, src_len]
 *
 * Encoder 输出规格（来源：A-004 OPUS-2）：
 *   "last_hidden_state" float32 [1, src_len, d_model]
 *
 * Decoder 输入规格（来源：A-004 OPUS-3，GitHub Issue #26523）：
 *   "input_ids"               int64   [1, tgt_len]
 *   "encoder_hidden_states"   float32 [1, src_len, d_model]
 *   "encoder_attention_mask"  int64   [1, src_len]
 *
 * Decoder 输出规格（来源：A-004 OPUS-3）：
 *   "logits" float32 [1, tgt_len, vocab_size]
 *
 * Token 规格（来源：A-004 OPUS-4，HuggingFace MarianMT 文档，onnx-community/opus-mt-zh-en config.json）：
 *   pad_token_id = 58100  （= vocab_size - 1 = decoder_start_token_id）
 *   eos_token_id = 0      （</s>，解码终止）
 *
 * ⚠️ 大模型内存策略（来源：A-004 C-1，N-4）：
 *   encoder 和 decoder 各约 300MB，必须先复制到 filesDir 再用路径加载，
 *   禁止用 readBytes() 加载到 JVM heap（来源：A-004 C-1 方式 B，GitHub Issue #19599）
 */
class OpusMTInference(private val context: Context) {

    companion object {
        // 模型 asset 路径（来源：工作手册 8.3）
        private const val ENCODER_ASSET = "models/opus-mt-zh-en-encoder.onnx"
        private const val DECODER_ASSET = "models/opus-mt-zh-en-decoder.onnx"
        // vocab.json asset 路径（SentencePiece 词表，来源：A-004 OPUS-5）
        private const val VOCAB_ASSET = "models/opus-mt-zh-en-vocab.json"

        // filesDir 中的缓存路径（来源：A-004 C-1 方式 B）
        private const val ENCODER_CACHE_NAME = "opus-mt-zh-en-encoder.onnx"
        private const val DECODER_CACHE_NAME = "opus-mt-zh-en-decoder.onnx"

        // Token 规格（来源：A-004 OPUS-4，onnx-community/opus-mt-zh-en config.json）
        // pad_token_id = vocab_size - 1 = 58100
        // 参考：https://huggingface.co/onnx-community/opus-mt-zh-en/blob/main/config.json
        private const val PAD_TOKEN_ID = 58100L       // = decoder_start_token_id
        private const val EOS_TOKEN_ID = 0L           // </s>

        // Greedy decode 最大生成 token 数（来源：B-004 任务规格）
        private const val MAX_GENERATE_TOKENS = 128
    }

    // OrtEnvironment 全局单例（来源：https://onnxruntime.ai/docs/get-started/with-java.html）
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var encoderSession: OrtSession? = null
    private var decoderSession: OrtSession? = null

    // vocab：id → token 字符串（来源：A-004 OPUS-5）
    private val idToToken = mutableMapOf<Int, String>()
    // token → id 映射（用于 tokenize，来源：A-004 OPUS-5）
    private val tokenToId = mutableMapOf<String, Int>()

    /**
     * 将 assets 中的大模型文件复制到 filesDir（避免 JVM heap OOM）
     * 来源：A-004 C-1 方式 B，GitHub Issue #19599
     * 参考：https://onnxruntime.ai/docs/get-started/with-java.html
     *
     * @param assetPath assets 中的路径
     * @param fileName  filesDir 中的文件名
     * @return 复制后的 File 对象
     */
    private fun copyAssetToFilesDir(assetPath: String, fileName: String): File {
        val outFile = File(context.filesDir, fileName)
        // 若已存在则跳过（仅首次复制）
        if (!outFile.exists()) {
            context.assets.open(assetPath).use { input ->
                FileOutputStream(outFile).use { output ->
                    val buf = ByteArray(4 * 1024 * 1024)  // 4MB 缓冲
                    var read: Int
                    while (input.read(buf).also { read = it } != -1) {
                        output.write(buf, 0, read)
                    }
                }
            }
        }
        return outFile
    }

    /**
     * 加载模型
     * 大模型（各约 300MB）必须先复制到 filesDir，再用路径加载（来源：A-004 C-1 方式 B，N-4）
     * 在子线程中调用，避免阻塞主线程
     * 来源：https://onnxruntime.ai/docs/get-started/with-java.html
     */
    fun loadModel() {
        // Step 1：复制 encoder 到 filesDir（来源：A-004 C-1 方式 B）
        val encoderFile = copyAssetToFilesDir(ENCODER_ASSET, ENCODER_CACHE_NAME)

        // Step 2：复制 decoder 到 filesDir（来源：A-004 C-1 方式 B）
        val decoderFile = copyAssetToFilesDir(DECODER_ASSET, DECODER_CACHE_NAME)

        // Step 3：用文件路径创建 OrtSession（来源：A-004 C-1 方式 B，C-2）
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2)
        }
        encoderSession = env.createSession(encoderFile.absolutePath, options)
        decoderSession = env.createSession(decoderFile.absolutePath, options)

        // Step 4：加载 vocab.json（来源：A-004 OPUS-5）
        loadVocab()
    }

    /**
     * 加载 vocab.json，构建 token↔id 双向映射
     * 来源：A-004 OPUS-5，HuggingFace MarianTokenizer 文档
     * 参考：https://huggingface.co/onnx-community/opus-mt-zh-en
     */
    private fun loadVocab() {
        try {
            val vocabJson = context.assets.open(VOCAB_ASSET).bufferedReader().readText()
            val jsonObj = JSONObject(vocabJson)
            val keys = jsonObj.keys()
            while (keys.hasNext()) {
                val token = keys.next()
                val id = jsonObj.getInt(token)
                tokenToId[token] = id
                idToToken[id] = token
            }
        } catch (e: Exception) {
            // vocab.json 未找到时记录警告，不崩溃
            // 来源：A-004 OPUS-5（vocab.json 与模型同目录打包）
            android.util.Log.w("OpusMTInference", "vocab.json 未找到，decode 将返回 token id: ${e.message}")
        }
    }

    /**
     * 翻译主函数：中文文字 → 英文文字
     *
     * @param sourceText 源语言文本（UTF-8）
     * @return 目标语言译文
     *
     * 调用顺序（来源：A-004 OPUS-6）：
     *   分词 → Encoder → Decoder 循环（greedy）→ 解码
     * 资源管理：所有 OnnxTensor 和 OrtSession.Result 必须在 finally 中 close
     * 来源：A-004 C-3，OPUS-7
     */
    fun translate(sourceText: String): String {
        checkNotNull(encoderSession) { "OpusMTInference: 请先调用 loadModel()" }
        checkNotNull(decoderSession) { "OpusMTInference: 请先调用 loadModel()" }

        // Step 1：分词（来源：A-004 OPUS-5，OPUS-6）
        // 注意：完整实现需接入 libsentencepiece.so JNI（来源：A-004 OPUS-5）
        // 此处提供基于 vocab.json 的字符级回退实现，供集成测试
        val (inputIds, attentionMask) = tokenize(sourceText)

        if (inputIds.isEmpty()) return ""

        val srcLen = inputIds.size.toLong()

        // Step 2：Encoder 推理（来源：A-004 OPUS-2，OPUS-6）
        // A-004-补丁：LongBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
        val encoderInputTensor = OnnxTensor.createTensor(
            env, LongBuffer.wrap(inputIds), longArrayOf(1, srcLen)
        )
        // A-004-补丁：LongBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
        val encoderMaskTensor = OnnxTensor.createTensor(
            env, LongBuffer.wrap(attentionMask), longArrayOf(1, srcLen)
        )

        val encoderHiddenState: FloatArray
        val hiddenStateShape: LongArray
        try {
            val encoderInputs = mapOf(
                "input_ids"      to encoderInputTensor,
                "attention_mask" to encoderMaskTensor
            )
            val encoderResults = encoderSession!!.run(encoderInputs)
            encoderResults.use {
                // 输出："last_hidden_state" float32 [1, src_len, d_model]（来源：A-004 OPUS-2）
                val rawHidden = encoderResults[0].value as Array<Array<FloatArray>>
                val batchSize = rawHidden.size
                val seqLen = rawHidden[0].size
                val dModel = rawHidden[0][0].size
                hiddenStateShape = longArrayOf(batchSize.toLong(), seqLen.toLong(), dModel.toLong())
                encoderHiddenState = FloatArray(batchSize * seqLen * dModel)
                var idx = 0
                for (b in 0 until batchSize)
                    for (s in 0 until seqLen)
                        for (d in 0 until dModel)
                            encoderHiddenState[idx++] = rawHidden[b][s][d]
            }
        } finally {
            encoderInputTensor.close()  // 必须 close（来源：A-004 OPUS-7）
            encoderMaskTensor.close()   // 必须 close（来源：A-004 OPUS-7）
        }

        // Step 3：Decoder 初始化（来源：A-004 OPUS-4，OPUS-6）
        // MarianMT 以 pad_token_id 开始解码（与 BART/T5 不同）
        // 参考：https://huggingface.co/docs/transformers/model_doc/marian
        val decoderInputIds = mutableListOf(PAD_TOKEN_ID)
        val generatedIds = mutableListOf<Long>()

        // Step 4：Greedy Decode 循环（来源：A-004 OPUS-6）
        for (step in 0 until MAX_GENERATE_TOKENS) {
            val currentIds = decoderInputIds.toLongArray()
            val tgtLen = currentIds.size.toLong()

            // 创建 decoder 输入张量（来源：A-004 OPUS-3）
            // A-004-补丁：LongBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
            val decoderInputTensor = OnnxTensor.createTensor(
                env, LongBuffer.wrap(currentIds), longArrayOf(1, tgtLen)
            )
            // encoder_hidden_states 张量（来源：A-004 OPUS-3）
            // A-004-补丁：FloatBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
            val hiddenTensor = OnnxTensor.createTensor(
                env, FloatBuffer.wrap(encoderHiddenState), hiddenStateShape
            )
            // encoder_attention_mask 张量（来源：A-004 OPUS-3）
            // A-004-补丁：LongBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
            val encoderMaskForDecoder = OnnxTensor.createTensor(
                env, LongBuffer.wrap(attentionMask), longArrayOf(1, srcLen)
            )

            var nextToken: Long
            try {
                val decoderInputs = mapOf(
                    "input_ids"              to decoderInputTensor,
                    "encoder_hidden_states"  to hiddenTensor,
                    "encoder_attention_mask" to encoderMaskForDecoder
                )
                val decoderResults = decoderSession!!.run(decoderInputs)
                decoderResults.use {
                    // logits [1, tgt_len, vocab_size]（来源：A-004 OPUS-3）
                    val logits = decoderResults[0].value as Array<Array<FloatArray>>
                    // Greedy：取最后一个位置 argmax（来源：A-004 OPUS-6）
                    val lastLogits = logits[0][logits[0].size - 1]
                    nextToken = argmax(lastLogits)
                }
            } finally {
                // 每步循环后必须 close 所有张量（来源：A-004 OPUS-7）
                decoderInputTensor.close()   // close decoderInputTensor
                hiddenTensor.close()          // close hiddenTensor
                encoderMaskForDecoder.close() // close encoderMaskForDecoder
            }

            // EOS 检测（来源：A-004 OPUS-4，OPUS-6，eos_token_id = 0）
            if (nextToken == EOS_TOKEN_ID) break

            generatedIds.add(nextToken)
            decoderInputIds.add(nextToken)
        }

        // Step 5：解码目标 token ID → 文字（来源：A-004 OPUS-5，OPUS-6）
        return decodeIds(generatedIds)
    }

    /**
     * 源语言文本分词
     * 来源：A-004 OPUS-5，HuggingFace MarianTokenizer
     * 参考：https://huggingface.co/onnx-community/opus-mt-zh-en
     *
     * 完整方案需接入 libsentencepiece.so JNI（来源：A-004 OPUS-5）
     * 当前实现：字符级回退 + vocab.json 查表（可供集成测试）
     *
     * @return Pair<LongArray, LongArray> = (input_ids, attention_mask)
     */
    private fun tokenize(text: String): Pair<LongArray, LongArray> {
        if (tokenToId.isEmpty()) {
            // vocab 未加载，返回空（来源：A-004 OPUS-5 警告说明）
            android.util.Log.w("OpusMTInference", "vocab 未加载，分词跳过")
            return Pair(LongArray(0), LongArray(0))
        }

        // SentencePiece 字符级回退：
        // 完整实现应调用 libsentencepiece.so JNI
        // 来源：A-004 OPUS-5，推荐方案：预编译 sentencepiece .so 放入 jniLibs/arm64-v8a/
        // 此处使用字符级 unigram 回退，将每个字符查 vocab，未知字符用 <unk>
        val unkId = tokenToId["<unk>"] ?: 3
        val ids = mutableListOf<Long>()

        for (char in text) {
            val charStr = char.toString()
            // 先尝试直接查 vocab（SentencePiece 风格加前缀▁）
            val id = tokenToId["▁$charStr"] ?: tokenToId[charStr] ?: unkId
            ids.add(id.toLong())
        }

        // 末尾加 EOS（来源：A-004 OPUS-4，MarianMT tokenizer 末尾加 </s>）
        // 参考：https://huggingface.co/docs/transformers/model_doc/marian
        ids.add(EOS_TOKEN_ID)

        val inputIds = ids.toLongArray()
        // attention_mask 全 1（无 padding，来源：A-004 OPUS-2）
        val attentionMask = LongArray(inputIds.size) { 1L }

        return Pair(inputIds, attentionMask)
    }

    /**
     * 目标 token ID 序列 → 文字
     * 来源：A-004 OPUS-5，OPUS-6
     * 参考：https://huggingface.co/docs/transformers/model_doc/marian
     *
     * 过滤特殊 token（PAD=58100，EOS=0）
     * SentencePiece ▁ 前缀替换为空格
     */
    private fun decodeIds(ids: List<Long>): String {
        if (idToToken.isEmpty()) {
            return "[ids:${ids.joinToString(",")}]"
        }
        return ids
            .filter { it != PAD_TOKEN_ID && it != EOS_TOKEN_ID }
            .mapNotNull { idToToken[it.toInt()] }
            .joinToString("")
            .replace("▁", " ")  // SentencePiece 空格还原（来源：A-004 OPUS-5）
            .trim()
    }

    /**
     * FloatArray argmax（Greedy decode 用）
     * 来源：A-004 OPUS-6
     */
    private fun argmax(logits: FloatArray): Long {
        var maxIdx = 0
        var maxVal = logits[0]
        for (i in 1 until logits.size) {
            if (logits[i] > maxVal) {
                maxVal = logits[i]
                maxIdx = i
            }
        }
        return maxIdx.toLong()
    }

    /**
     * 释放所有资源
     * 来源：A-004 C-3，OPUS-7
     * 来源：https://onnxruntime.ai/docs/get-started/with-java.html
     */
    fun close() {
        encoderSession?.close()  // close encoderSession（来源：A-004 OPUS-7）
        decoderSession?.close()  // close decoderSession（来源：A-004 OPUS-7）
        encoderSession = null
        decoderSession = null
        idToToken.clear()
        tokenToId.clear()
    }
}
