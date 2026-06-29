// =============================================================================
// 文件路径：GloTalk-V3/android/app/src/main/kotlin/tech/glotalk/glotalk_v3/AudioService.kt
// package：tech.glotalk.glotalk_v3
// 任务编号：B-001 | 依据：智能体 A 查证报告 A-001 | 日期：2026-06-29
// =============================================================================

package tech.glotalk.glotalk_v3

// 来源：https://developer.android.com/reference/android/media/AudioFormat
import android.media.AudioFormat
// 来源：https://developer.android.com/reference/android/media/AudioRecord
import android.media.AudioRecord
// 来源：https://developer.android.com/reference/android/media/MediaRecorder
import android.media.MediaRecorder
// 来源：https://developer.android.com/reference/android/os/Handler
import android.os.Handler
// 来源：https://developer.android.com/reference/android/os/Looper
import android.os.Looper
// 来源：https://api.flutter.dev/javadoc/io/flutter/plugin/common/EventChannel.EventSink.html
import io.flutter.plugin.common.EventChannel

/**
 * AudioService — Android 麦克风采集服务
 *
 * 职责：
 *   1. 使用 AudioRecord 以 16kHz / 单声道 / PCM_16BIT 采集麦克风数据
 *   2. 将 PCM 数据转换为 ByteArray 推送至 Flutter EventChannel
 *
 * 设计要点（来自查证报告 A-001）：
 *   - D1 修正：初始化前检查 getMinBufferSize() 返回值是否为负数
 *   - D2 修正：startRecording() 前检查 STATE_INITIALIZED
 *   - D3 修正：ShortArray → ByteArray 转换后再推送（Platform Channel 原生支持）
 *   - D4 修正：EventSink.success() 必须通过 mainHandler 在主线程调用
 *   - D5 修正：mainHandler 在类初始化时创建，不在每次回调中新建
 */
class AudioService {

    // =========================================================================
    // 常量（来源：https://developer.android.com/reference/android/media/AudioRecord）
    // Whisper 模型要求输入音频为 16kHz 单声道 16-bit PCM
    // =========================================================================
    companion object {
        const val SAMPLE_RATE    = 16000                          // 16kHz，Whisper 要求
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO   // 单声道
        const val AUDIO_FORMAT   = AudioFormat.ENCODING_PCM_16BIT // 16-bit PCM
    }

    // =========================================================================
    // 成员变量
    // =========================================================================

    private var audioRecord: AudioRecord? = null
    private var isRecording  = false
    private var recordThread: Thread? = null

    // D5 修正：Handler 在类初始化时创建并复用，不在每次回调中新建
    // 来源：https://github.com/flutter/flutter/issues/34993
    // 来源：https://developer.android.com/reference/android/os/Handler
    private val mainHandler = Handler(Looper.getMainLooper())

    // EventSink 引用，由 MainActivity 注入（在 onListen / onCancel 中管理）
    var eventSink: EventChannel.EventSink? = null

    // =========================================================================
    // 公开方法：startRecording
    // 来源：https://developer.android.com/reference/android/media/AudioRecord
    // =========================================================================

    /**
     * 初始化并启动麦克风录音。
     * 采集到的 PCM 数据将通过 EventSink 推送至 Flutter。
     *
     * @return true = 启动成功；false = 初始化失败（参见 logcat 错误日志）
     */
    fun startRecording(): Boolean {

        // --- D1 修正 -----------------------------------------------------------
        // 来源：https://developer.android.com/reference/android/media/AudioRecord
        // getMinBufferSize() 若参数无效或硬件不支持，返回 ERROR_BAD_VALUE 或 ERROR（均为负数）
        // 必须检查返回值 > 0，否则直接传入构造函数会导致初始化失败
        val minBufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT
        )
        if (minBufferSize <= 0) {
            // 硬件不支持该参数组合，或参数本身无效
            android.util.Log.e(
                "AudioService",
                "getMinBufferSize() 返回无效值：$minBufferSize。" +
                "ERROR=${AudioRecord.ERROR}，ERROR_BAD_VALUE=${AudioRecord.ERROR_BAD_VALUE}"
            )
            return false
        }

        // 实际 buffer 大小：使用 minBufferSize 的 2 倍以提供缓冲余量
        // 来源：https://developer.android.com/reference/android/media/AudioRecord
        // "buffer size expressed in bytes. It is recommended to use a buffer larger
        //  than the minimum buffer size"
        val bufferSize = minBufferSize * 2

        // 初始化 AudioRecord
        // 来源：https://developer.android.com/reference/android/media/AudioRecord
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC, // audioSource
            SAMPLE_RATE,                   // sampleRateInHz：16000
            CHANNEL_CONFIG,                // channelConfig：CHANNEL_IN_MONO
            AUDIO_FORMAT,                  // audioFormat：ENCODING_PCM_16BIT
            bufferSize                     // bufferSizeInBytes：≥ minBufferSize
        )

        // --- D2 修正 -----------------------------------------------------------
        // 来源：https://developer.android.com/reference/android/media/AudioRecord
        // getState() 返回 STATE_INITIALIZED（1）表示硬件资源获取成功
        // 若未能获取硬件资源，state 为 STATE_UNINITIALIZED（0）
        // 必须在 startRecording() 前检查，否则调用 startRecording() 会抛出 IllegalStateException
        if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
            android.util.Log.e(
                "AudioService",
                "AudioRecord 初始化失败，state=${audioRecord?.state}。" +
                "期望 STATE_INITIALIZED=${AudioRecord.STATE_INITIALIZED}"
            )
            audioRecord?.release()
            audioRecord = null
            return false
        }

        // 开始录音
        // 来源：https://developer.android.com/reference/android/media/AudioRecord
        audioRecord?.startRecording()
        isRecording = true

        // 在后台线程循环读取 PCM 数据
        // 来源：https://developer.android.com/reference/android/media/AudioRecord
        // read() 会阻塞至数据可用，必须在独立线程调用，不得在主线程调用
        recordThread = Thread {
            // read() 以 short 为单位；bufferSize 是字节数，故 short 数量 = bufferSize / 2
            val shortBuffer = ShortArray(bufferSize / 2)

            while (isRecording) {
                val readCount = audioRecord?.read(shortBuffer, 0, shortBuffer.size) ?: 0

                // 来源：https://developer.android.com/reference/android/media/AudioRecord
                // read() 返回实际读取的 short 数量；负值表示错误，0 表示无数据，均不处理
                if (readCount > 0) {

                    // --- D3 修正 -----------------------------------------------
                    // 来源：A-001 查证报告 D3
                    // Platform Channel 的 StandardMessageCodec 原生支持 ByteArray
                    // ShortArray 不是原生支持类型，需先转换为 ByteArray（Little-Endian）
                    // 每个 short（2 字节）转为低字节在前、高字节在后的 2 个 byte
                    val byteBuffer = shortArrayToByteArray(shortBuffer, readCount)

                    // --- D4 修正 -----------------------------------------------
                    // 来源：https://github.com/flutter/flutter/issues/34993
                    // EventSink.success() 必须在主线程调用，否则抛出 IllegalStateException
                    // 使用 mainHandler（D5 修正：类初始化时创建，此处直接复用）在主线程 post
                    mainHandler.post {
                        eventSink?.success(byteBuffer)
                    }
                }
            }
        }.also { it.start() }

        android.util.Log.i("AudioService", "录音已启动：${SAMPLE_RATE}Hz / 单声道 / PCM_16BIT")
        return true
    }

    // =========================================================================
    // 公开方法：stopRecording
    // 来源：https://developer.android.com/reference/android/media/AudioRecord
    // =========================================================================

    /**
     * 停止录音并释放全部 native 资源。
     *
     * 停止顺序（来源：A-001 查证报告 查证项 4）：
     *   ① isRecording = false  → 让采集线程退出循环
     *   ② audioRecord.stop()   → 停止录音
     *   ③ audioRecord.release() → 释放 native 资源
     *   ④ audioRecord = null   → 置空引用（防止悬空指针）
     *
     * 顺序不可颠倒：必须先 stop() 再 release()，否则可能抛出 IllegalStateException
     * 来源：https://developer.android.com/reference/android/media/AudioRecord
     */
    fun stopRecording() {
        // ① 先让采集线程退出循环
        isRecording = false

        // 等待采集线程结束（最多等待 1 秒，避免阻塞调用方）
        recordThread?.join(1000)
        recordThread = null

        // ② stop()：停止录音
        // 来源：https://developer.android.com/reference/android/media/AudioRecord
        audioRecord?.stop()

        // ③ release()：释放 native 硬件资源
        // 来源：https://developer.android.com/reference/android/media/AudioRecord
        // "Releases the native AudioRecord resources. The object can no longer be used
        //  after this call."
        audioRecord?.release()

        // ④ 置空引用
        // 来源：https://developer.android.com/reference/android/media/AudioRecord
        // "The reference should be set to null after a release() call."
        audioRecord = null

        android.util.Log.i("AudioService", "录音已停止，native 资源已释放")
    }

    // =========================================================================
    // 私有工具方法：ShortArray → ByteArray（Little-Endian PCM）
    // D3 修正：Platform Channel 不原生支持 ShortArray，转为 ByteArray 传递
    // 来源：A-001 查证报告 D3
    // =========================================================================

    /**
     * 将 ShortArray（PCM_16BIT）转换为 ByteArray（Little-Endian）。
     *
     * Android PCM_16BIT 采用 Little-Endian 字节序（低字节在前）：
     *   short value = 0x1234 → byte[0] = 0x34（低字节），byte[1] = 0x12（高字节）
     *
     * Flutter 侧使用 ByteData.getInt16(offset, Endian.little) 解析
     *
     * @param shorts    PCM 数据（ShortArray）
     * @param count     实际有效的 short 数量（= AudioRecord.read() 的返回值）
     * @return          ByteArray，长度 = count * 2
     */
    private fun shortArrayToByteArray(shorts: ShortArray, count: Int): ByteArray {
        val bytes = ByteArray(count * 2)
        for (i in 0 until count) {
            val s = shorts[i]
            bytes[i * 2]     = (s.toInt() and 0xFF).toByte()        // 低字节
            bytes[i * 2 + 1] = (s.toInt() shr 8 and 0xFF).toByte() // 高字节
        }
        return bytes
    }
}
