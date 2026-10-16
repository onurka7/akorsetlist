package com.gitar.akorlist

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "akor_setlist/audio_decoder")
            .setMethodCallHandler { call, result ->
                val path = call.argument<String>("path")
                val rate = call.argument<Int>("sampleRate")
                if (call.method != "decodeToPcm" || path == null || rate == null) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val main = Handler(Looper.getMainLooper())
                thread(name = "AudioDecoder") {
                    try {
                        val out = AudioDecoder.decode(path, rate, cacheDir)
                        main.post { result.success(out.absolutePath) }
                    } catch (e: Exception) {
                        main.post { result.error("decode_failed", e.message, null) }
                    }
                }
            }
    }
}

/**
 * Decodes compressed audio (MP3, M4A, AAC, ...) with MediaCodec, mixes to mono
 * and resamples linearly to [targetRate]; writes little-endian float32 to a
 * cache file for the on-device chord analyzer.
 */
object AudioDecoder {
    private const val TIMEOUT_US = 10_000L

    fun decode(path: String, targetRate: Int, cacheDir: File): File {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        val trackIndex = (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: throw IllegalArgumentException("Dosyada ses kanalı yok.")
        extractor.selectTrack(trackIndex)
        val format = extractor.getTrackFormat(trackIndex)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()

        val outFile = File(cacheDir, "${UUID.randomUUID()}.f32")
        val stream = BufferedOutputStream(FileOutputStream(outFile), 1 shl 16)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var sourceRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var pcmFloat = false
        // Linear resampler state carried across decoder buffers.
        var position = 0.0
        var previous = 0f
        var hasPrevious = false
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        val scratch = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)

        try {
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        sourceRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        pcmFloat = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                            f.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
                    }
                    outIndex >= 0 -> {
                        val buffer = codec.getOutputBuffer(outIndex)!!.order(ByteOrder.LITTLE_ENDIAN)
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val step = sourceRate.toDouble() / targetRate
                        while (buffer.remaining() >= channels * (if (pcmFloat) 4 else 2)) {
                            var sum = 0f
                            for (c in 0 until channels) {
                                sum += if (pcmFloat) buffer.float else buffer.short / 32768f
                            }
                            val sample = sum / channels
                            if (!hasPrevious) {
                                previous = sample
                                hasPrevious = true
                                continue
                            }
                            // Emit output samples falling between previous and current input samples.
                            while (position <= 1.0) {
                                val value = previous + (sample - previous) * position.toFloat()
                                scratch.clear()
                                scratch.putFloat(value)
                                stream.write(scratch.array(), 0, 4)
                                position += step
                            }
                            position -= 1.0
                            previous = sample
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                }
            }
        } finally {
            stream.close()
            codec.stop()
            codec.release()
            extractor.release()
        }
        return outFile
    }
}
