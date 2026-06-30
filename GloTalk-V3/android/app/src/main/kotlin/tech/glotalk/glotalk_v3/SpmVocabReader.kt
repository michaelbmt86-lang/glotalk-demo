// SpmVocabReader.kt
// GloTalk-V3 — SentencePiece .spm 词表读取工具类
// 职责：从 source.spm / target.spm 提取词表，填充 tokenToId / idToToken
// 来源：google/sentencepiece sentencepiece_model.proto
//       https://github.com/google/sentencepiece/blob/master/src/sentencepiece_model.proto
// 查证报告：A-008b，A-010
// 路径：GloTalk-V3/android/app/src/main/kotlin/tech/glotalk/glotalk_v3/SpmVocabReader.kt

package tech.glotalk.glotalk_v3

import android.util.Log
import java.io.File
import java.io.InputStream

/**
 * SentencePiece .spm 词表读取工具（纯 Kotlin，零 JNI，零外部依赖）
 *
 * .spm 文件结构（来源：sentencepiece_model.proto，proto2 LITE_RUNTIME）：
 *   message ModelProto {
 *     repeated SentencePiece pieces = 1;   ← field 1，重复消息
 *     ...
 *   }
 *   message SentencePiece {
 *     optional string piece = 1;           ← field 1，token 文字
 *     optional float  score = 2;           ← field 2，log 概率（不需要）
 *     optional Type   type  = 3;           ← field 3，token 类型（不需要）
 *   }
 *
 * proto2 wire 格式（来源：protobuf encoding 官方文档）：
 *   tag = (field_number << 3) | wire_type
 *   wire_type 0 = varint，wire_type 2 = length-delimited（string/bytes/message）
 *
 *   ModelProto.pieces  : tag = (1 << 3) | 2 = 0x0A
 *   SentencePiece.piece: tag = (1 << 3) | 2 = 0x0A
 *   SentencePiece.score: tag = (2 << 3) | 5 = 0x15（32-bit，跳过）
 *   SentencePiece.type : tag = (3 << 3) | 0 = 0x18（varint，跳过）
 *
 * piece 的顺序索引即为 token ID（来源：A-008b 查证）
 */
object SpmVocabReader {

    private const val TAG = "SpmVocabReader"

    // proto tag 常量（来源：sentencepiece_model.proto + proto2 encoding 规则）
    private const val TAG_PIECES        = 0x0A  // ModelProto.pieces (field 1, wire 2)
    private const val TAG_PIECE_STRING  = 0x0A  // SentencePiece.piece (field 1, wire 2)
    private const val TAG_PIECE_SCORE   = 0x15  // SentencePiece.score (field 2, wire 5 = 32bit)
    private const val TAG_PIECE_TYPE    = 0x18  // SentencePiece.type  (field 3, wire 0 = varint)

    /**
     * 读取 source.spm，填充 tokenToId（用于 encode，字符 → ID）和 idToToken（用于 decode，ID → 字符）
     *
     * @param sourceFile source.spm 文件（源语言，中文）
     * @param targetFile target.spm 文件（目标语言，英文）
     * @param tokenToId  由调用方传入，本方法负责填充（源语言词表）
     * @param idToToken  由调用方传入，本方法负责填充（目标语言词表）
     *
     * 来源：A-008b — decode 用 target.spm，encode 用 source.spm
     * 注意：OpusMTInference 的 tokenize() 用 source.spm（中文→ID），
     *       decodeIds() 用 target.spm（ID→英文）
     */
    fun read(
        sourceFile: File,
        targetFile: File,
        tokenToId: MutableMap<String, Int>,
        idToToken: MutableMap<Int, String>
    ) {
        // 读取源语言词表（tokenToId：token → ID，用于 tokenize）
        if (sourceFile.exists()) {
            try {
                val pieces = extractPieces(sourceFile.inputStream())
                pieces.forEachIndexed { idx, piece ->
                    tokenToId[piece] = idx
                }
                Log.d(TAG, "source.spm 加载完成，词表大小：${pieces.size}")
            } catch (e: Exception) {
                Log.e(TAG, "source.spm 读取失败：${e.message}", e)
            }
        } else {
            Log.w(TAG, "source.spm 未找到：${sourceFile.absolutePath}")
        }

        // 读取目标语言词表（idToToken：ID → token，用于 decodeIds）
        if (targetFile.exists()) {
            try {
                val pieces = extractPieces(targetFile.inputStream())
                pieces.forEachIndexed { idx, piece ->
                    idToToken[idx] = piece
                }
                Log.d(TAG, "target.spm 加载完成，词表大小：${pieces.size}")
            } catch (e: Exception) {
                Log.e(TAG, "target.spm 读取失败：${e.message}", e)
            }
        } else {
            Log.w(TAG, "target.spm 未找到：${targetFile.absolutePath}")
        }
    }

    /**
     * 从 .spm 文件字节流提取所有 piece 字符串列表
     * 返回列表的索引即为 token ID
     *
     * 来源：sentencepiece_model.proto proto2 编码规则
     * 来源：https://protobuf.dev/programming-guides/encoding/
     */
    private fun extractPieces(input: InputStream): List<String> {
        val bytes = input.use { it.readBytes() }
        val pieces = mutableListOf<String>()
        var pos = 0

        // 解析 ModelProto 顶层字段
        while (pos < bytes.size) {
            val tagResult = readVarint(bytes, pos)
            pos = tagResult.second
            if (pos > bytes.size) break
            val tag = tagResult.first.toInt()

            when (tag) {
                TAG_PIECES -> {
                    // field 1, wire 2：length-delimited，内容是 SentencePiece 消息
                    val lenResult = readVarint(bytes, pos)
                    pos = lenResult.second
                    val len = lenResult.first.toInt()
                    if (len <= 0 || pos + len > bytes.size) { pos += maxOf(0, len); continue }

                    // 解析 SentencePiece 子消息
                    val piece = parseSentencePiece(bytes, pos, pos + len)
                    if (piece != null) pieces.add(piece)
                    pos += len
                }
                else -> {
                    // 跳过不需要的字段
                    pos = skipField(bytes, pos, tag)
                }
            }
        }
        return pieces
    }

    /**
     * 解析一个 SentencePiece 消息，提取 piece 字符串（field 1）
     * 跳过 score（field 2）和 type（field 3）
     *
     * 来源：sentencepiece_model.proto SentencePiece message 结构
     */
    private fun parseSentencePiece(bytes: ByteArray, start: Int, end: Int): String? {
        var pos = start
        var piece: String? = null

        while (pos < end) {
            val tagResult = readVarint(bytes, pos)
            pos = tagResult.second
            if (pos > end) break
            val tag = tagResult.first.toInt()

            when (tag) {
                TAG_PIECE_STRING -> {
                    // field 1, wire 2：piece 字符串
                    val lenResult = readVarint(bytes, pos)
                    pos = lenResult.second
                    val len = lenResult.first.toInt()
                    if (len > 0 && pos + len <= end) {
                        piece = String(bytes, pos, len, Charsets.UTF_8)
                    }
                    pos += maxOf(0, len)
                }
                TAG_PIECE_SCORE -> {
                    // field 2, wire 5：32-bit float，固定 4 字节，跳过
                    pos += 4
                }
                TAG_PIECE_TYPE -> {
                    // field 3, wire 0：varint，跳过
                    val skipResult = readVarint(bytes, pos)
                    pos = skipResult.second
                }
                else -> {
                    pos = skipField(bytes, pos, tag)
                }
            }
        }
        return piece
    }

    /**
     * 读取 protobuf varint（LEB128 编码）
     * 来源：https://protobuf.dev/programming-guides/encoding/#varints
     *
     * @return Pair(值, 读取后的新位置)
     */
    private fun readVarint(bytes: ByteArray, start: Int): Pair<Long, Int> {
        var result = 0L
        var shift = 0
        var pos = start
        while (pos < bytes.size) {
            val b = bytes[pos++].toInt() and 0xFF
            result = result or ((b and 0x7F).toLong() shl shift)
            if (b and 0x80 == 0) break
            shift += 7
            if (shift >= 64) break  // 防止溢出
        }
        return Pair(result, pos)
    }

    /**
     * 跳过未知字段（根据 wire type 跳过对应字节数）
     * 来源：https://protobuf.dev/programming-guides/encoding/#structure
     */
    private fun skipField(bytes: ByteArray, pos: Int, tag: Int): Int {
        return when (tag and 0x07) {
            0 -> readVarint(bytes, pos).second              // varint
            1 -> minOf(pos + 8, bytes.size)                // 64-bit
            2 -> {                                          // length-delimited
                val lenResult = readVarint(bytes, pos)
                minOf(lenResult.second + lenResult.first.toInt(), bytes.size)
            }
            5 -> minOf(pos + 4, bytes.size)                // 32-bit
            else -> bytes.size                             // 未知，停止解析
        }
    }
}
