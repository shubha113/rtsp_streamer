package com.example.rtsp_streamer

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.camera2.*
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Base64
import android.util.Log
import android.view.Surface
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.rtspstreamer/rtsp"
    private val REQUEST_CODE = 100
    private val TAG = "RTSPPublisher"

    private val isRunning = AtomicBoolean(false)

    // Camera / Encoder
    private var mediaCodec: MediaCodec? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var encoderInputSurface: Surface? = null
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

    @Volatile private var spsBytes: ByteArray? = null
    @Volatile private var ppsBytes: ByteArray? = null
    private var spsPpsLatch = CountDownLatch(1)

    // RTSP publish socket
    private var rtspSocket: Socket? = null
    private var rtspOutputStream: OutputStream? = null
    private var rtspInputStream: InputStream? = null
    private var rtspCSeq = 1
    private var rtpSeq = 0
    private var ssrc: Int = (Math.random() * 0x7FFFFFFF).toInt()

    private var pendingPermResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startServer" -> {
                        val mediamtxIp = call.argument<String>("mediamtxIp") ?: run { result.success(false); return@setMethodCallHandler }
                        val streamId   = call.argument<String>("streamId")   ?: run { result.success(false); return@setMethodCallHandler }
                        val port       = call.argument<Int>("port") ?: 8554
                        if (!hasPermissions()) { result.success(false); return@setMethodCallHandler }
                        thread {
                            val ok = startPublishing(mediamtxIp, port, streamId)
                            runOnUiThread { result.success(ok) }
                        }
                    }
                    "stopServer"          -> { stopPublishing(); result.success(true) }
                    "isStreaming"         -> result.success(isRunning.get())
                    "getDeviceIp"         -> result.success(getWifiIp())
                    "checkPermissions"    -> result.success(hasPermissions())
                    "requestPermissions"  -> {
                        if (hasPermissions()) result.success(true)
                        else {
                            pendingPermResult = result
                            ActivityCompat.requestPermissions(this,
                                arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO), REQUEST_CODE)
                        }
                    }
                    "switchCamera" -> result.success(null)
                    "toggleTorch"  -> result.success(null)
                    else           -> result.notImplemented()
                }
            }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  START PUBLISHING
    // ════════════════════════════════════════════════════════════════════════

    private fun startPublishing(mediamtxIp: String, port: Int, streamId: String): Boolean {
        if (isRunning.get()) return true
        spsPpsLatch = CountDownLatch(1)

        return try {
            cameraThread = HandlerThread("CameraThread").also { it.start() }
            cameraHandler = Handler(cameraThread!!.looper)
            initEncoder()
            openCamera()

            if (!spsPpsLatch.await(8, TimeUnit.SECONDS)) {
                Log.e(TAG, "Timeout waiting for SPS/PPS")
                stopPublishing(); return false
            }

            // Connect TCP socket to MediaMTX
            val sock = Socket()
            sock.connect(java.net.InetSocketAddress(mediamtxIp, port), 5000)
            sock.soTimeout = 10000   // 10s read timeout during handshake
            rtspSocket = sock
            rtspOutputStream = sock.getOutputStream()
            rtspInputStream  = sock.getInputStream()

            Log.i(TAG, "TCP connected to $mediamtxIp:$port")

            if (!doHandshake(mediamtxIp, port, streamId)) {
                Log.e(TAG, "RTSP handshake failed")
                stopPublishing(); return false
            }

            // After RECORD, remove read timeout — we own the socket for streaming
            sock.soTimeout = 0
            isRunning.set(true)
            Log.i(TAG, "✅ Publishing to rtsp://$mediamtxIp:$port/$streamId")
            true
        } catch (e: Exception) {
            Log.e(TAG, "startPublishing error: $e", e)
            stopPublishing(); false
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  RTSP HANDSHAKE: OPTIONS → ANNOUNCE → SETUP → RECORD
    //  We send OPTIONS first so MediaMTX knows we're a valid RTSP client.
    // ════════════════════════════════════════════════════════════════════════

    private fun doHandshake(host: String, port: Int, streamId: String): Boolean {
        val url = "rtsp://$host:$port/$streamId"

        // ── OPTIONS ──────────────────────────────────────────────────────────
        sendRequest("OPTIONS $url RTSP/1.0\r\nCSeq: ${rtspCSeq++}\r\nUser-Agent: AndroidRtspPublisher/1.0\r\n\r\n")
        val optionsResp = readResponse()
        Log.d(TAG, "OPTIONS response: ${optionsResp.statusLine}")
        // OPTIONS 200 is nice but not mandatory — continue regardless

        // ── ANNOUNCE ─────────────────────────────────────────────────────────
        val sdp = buildSdp(host)
        val sdpBytes = sdp.toByteArray(Charsets.UTF_8)
        sendRequest(
            "ANNOUNCE $url RTSP/1.0\r\n" +
                    "CSeq: ${rtspCSeq++}\r\n" +
                    "User-Agent: AndroidRtspPublisher/1.0\r\n" +
                    "Content-Type: application/sdp\r\n" +
                    "Content-Length: ${sdpBytes.size}\r\n" +
                    "\r\n",
            sdpBytes
        )
        val announceResp = readResponse()
        Log.d(TAG, "ANNOUNCE response: ${announceResp.statusLine}")
        if (announceResp.statusCode != 200) {
            Log.e(TAG, "ANNOUNCE failed: ${announceResp.statusLine}")
            return false
        }

        // ── SETUP ─────────────────────────────────────────────────────────────
        sendRequest(
            "SETUP $url/trackID=0 RTSP/1.0\r\n" +
                    "CSeq: ${rtspCSeq++}\r\n" +
                    "User-Agent: AndroidRtspPublisher/1.0\r\n" +
                    "Transport: RTP/AVP/TCP;unicast;mode=record;interleaved=0-1\r\n" +
                    "\r\n"
        )
        val setupResp = readResponse()
        Log.d(TAG, "SETUP response: ${setupResp.statusLine}")
        if (setupResp.statusCode != 200) {
            Log.e(TAG, "SETUP failed: ${setupResp.statusLine}")
            return false
        }

        // Grab session ID from SETUP response
        val sessionId = setupResp.headers["session"]?.substringBefore(';') ?: "88776655"
        Log.d(TAG, "Session ID: $sessionId")

        // ── RECORD ────────────────────────────────────────────────────────────
        sendRequest(
            "RECORD $url RTSP/1.0\r\n" +
                    "CSeq: ${rtspCSeq++}\r\n" +
                    "User-Agent: AndroidRtspPublisher/1.0\r\n" +
                    "Session: $sessionId\r\n" +
                    "Range: npt=0.000-\r\n" +
                    "\r\n"
        )
        val recordResp = readResponse()
        Log.d(TAG, "RECORD response: ${recordResp.statusLine}")
        if (recordResp.statusCode != 200) {
            Log.e(TAG, "RECORD failed: ${recordResp.statusLine}")
            return false
        }

        Log.i(TAG, "✅ RTSP handshake complete — streaming!")
        return true
    }

    // ════════════════════════════════════════════════════════════════════════
    //  LOW-LEVEL RTSP I/O
    // ════════════════════════════════════════════════════════════════════════

    private fun sendRequest(header: String, body: ByteArray = ByteArray(0)) {
        val out = rtspOutputStream ?: return
        Log.v(TAG, "→ ${header.lines().first()}")
        out.write(header.toByteArray(Charsets.US_ASCII))
        if (body.isNotEmpty()) out.write(body)
        out.flush()
    }

    /** Read a full RTSP response (status line + headers + optional body) */
    private fun readResponse(): RtspResponse {
        val inp = rtspInputStream ?: return RtspResponse(0, "", emptyMap())
        val sb = StringBuilder()

        // Read byte-by-byte until we hit \r\n\r\n (end of headers)
        val buf = ByteArray(1)
        while (true) {
            val n = inp.read(buf)
            if (n < 0) break
            sb.append(buf[0].toInt().toChar())
            if (sb.length >= 4 && sb.substring(sb.length - 4) == "\r\n\r\n") break
        }

        val raw = sb.toString()
        Log.v(TAG, "← $raw")

        val lines = raw.split("\r\n")
        val statusLine = lines.firstOrNull() ?: ""
        val statusCode = statusLine.split(" ").getOrNull(1)?.toIntOrNull() ?: 0

        val headers = mutableMapOf<String, String>()
        for (line in lines.drop(1)) {
            val ci = line.indexOf(':')
            if (ci > 0) {
                headers[line.substring(0, ci).trim().lowercase()] = line.substring(ci + 1).trim()
            }
        }

        // Read body if Content-Length is present
        val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
        if (contentLength > 0) {
            val bodyBuf = ByteArray(contentLength)
            var read = 0
            while (read < contentLength) {
                val n = inp.read(bodyBuf, read, contentLength - read)
                if (n < 0) break
                read += n
            }
        }

        return RtspResponse(statusCode, statusLine, headers)
    }

    data class RtspResponse(
        val statusCode: Int,
        val statusLine: String,
        val headers: Map<String, String>
    )

    // ════════════════════════════════════════════════════════════════════════
    //  ENCODER
    // ════════════════════════════════════════════════════════════════════════

    private fun initEncoder() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1280, 720).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 2_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoderInputSurface = codec.createInputSurface()
        codec.start()
        mediaCodec = codec
        thread(name = "Encoder-Output") { drainEncoder() }
    }

    private fun drainEncoder() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val codec = mediaCodec ?: break
            val idx = try { codec.dequeueOutputBuffer(info, 10_000L) } catch (e: Exception) { break }
            if (idx == MediaCodec.INFO_TRY_AGAIN_LATER) continue
            if (idx < 0) continue

            val buf = codec.getOutputBuffer(idx) ?: run { codec.releaseOutputBuffer(idx, false); continue }
            buf.position(info.offset); buf.limit(info.offset + info.size)
            val data = ByteArray(info.size); buf.get(data)
            codec.releaseOutputBuffer(idx, false)

            when {
                info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 -> parseAndStoreSpsPps(data)
                data.isNotEmpty() && isRunning.get() -> {
                    val rtpTs = (info.presentationTimeUs * 90L / 1000L).toInt()
                    val isKey = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                    sendFrameViaRtp(data, rtpTs, isKey)
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  CAMERA2
    // ════════════════════════════════════════════════════════════════════════

    private fun openCamera() {
        val mgr = getSystemService(CAMERA_SERVICE) as CameraManager
        val camId = mgr.cameraIdList.firstOrNull { id ->
            mgr.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: mgr.cameraIdList.first()

        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return

        mgr.openCamera(camId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) { cameraDevice = camera; startCaptureSession(camera) }
            override fun onDisconnected(camera: CameraDevice) { camera.close() }
            override fun onError(camera: CameraDevice, error: Int) { Log.e(TAG, "Camera error $error"); camera.close() }
        }, cameraHandler)
    }

    private fun startCaptureSession(camera: CameraDevice) {
        val surface = encoderInputSurface ?: return
        @Suppress("DEPRECATION")
        camera.createCaptureSession(listOf(surface), object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                captureSession = session
                val req = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                    addTarget(surface)
                    set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                    set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, android.util.Range(30, 30))
                }
                session.setRepeatingRequest(req.build(), null, cameraHandler)
            }
            override fun onConfigureFailed(session: CameraCaptureSession) { Log.e(TAG, "Camera config failed") }
        }, cameraHandler)
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SPS/PPS EXTRACTION
    // ════════════════════════════════════════════════════════════════════════

    private fun parseAndStoreSpsPps(data: ByteArray) {
        val positions = mutableListOf<Int>()
        var i = 0
        while (i <= data.size - 4) {
            if (data[i] == 0x00.toByte() && data[i+1] == 0x00.toByte() &&
                data[i+2] == 0x00.toByte() && data[i+3] == 0x01.toByte()) {
                positions.add(i + 4); i += 4
            } else i++
        }
        if (positions.size >= 2) {
            spsBytes = data.copyOfRange(positions[0], positions[1] - 4)
            ppsBytes = data.copyOfRange(positions[1], data.size)
            Log.i(TAG, "SPS+PPS extracted")
            spsPpsLatch.countDown()
        } else if (positions.size == 1) {
            val naluType = data[positions[0]].toInt() and 0x1F
            if (naluType == 7) spsBytes = data.copyOfRange(positions[0], data.size)
            if (naluType == 8) { ppsBytes = data.copyOfRange(positions[0], data.size); if (spsBytes != null) spsPpsLatch.countDown() }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  RTP SEND
    // ════════════════════════════════════════════════════════════════════════

    private fun sendFrameViaRtp(annexBData: ByteArray, rtpTimestamp: Int, isKey: Boolean) {
        if (rtspSocket?.isConnected != true) return
        if (isKey) {
            spsBytes?.let { sendNaluRtp(it, rtpTimestamp, false) }
            ppsBytes?.let { sendNaluRtp(it, rtpTimestamp, false) }
        }
        val nalus = splitAnnexB(annexBData)
        for ((i, nalu) in nalus.withIndex()) {
            if (nalu.isNotEmpty()) sendNaluRtp(nalu, rtpTimestamp, i == nalus.size - 1)
        }
    }

    private val MAX_RTP = 1400

    private fun sendNaluRtp(nalu: ByteArray, ts: Int, marker: Boolean) {
        if (nalu.size <= MAX_RTP) {
            sendInterleaved(buildRtp(nalu, ts, marker))
        } else {
            val naluType = nalu[0].toInt() and 0x1F
            val hdr = nalu[0].toInt() and 0xE0
            var offset = 1
            while (offset < nalu.size) {
                val end = minOf(offset + MAX_RTP - 2, nalu.size)
                val isFirst = offset == 1; val isLast = end == nalu.size
                val fu = ByteArray(2 + end - offset)
                fu[0] = (hdr or 28).toByte()
                fu[1] = ((if (isFirst) 0x80 else 0) or (if (isLast) 0x40 else 0) or naluType).toByte()
                System.arraycopy(nalu, offset, fu, 2, end - offset)
                sendInterleaved(buildRtp(fu, ts, isLast && marker))
                offset = end
            }
        }
    }

    private fun buildRtp(payload: ByteArray, ts: Int, marker: Boolean): ByteArray {
        val p = ByteArray(12 + payload.size)
        p[0] = 0x80.toByte()
        p[1] = ((if (marker) 0x80 else 0) or 96).toByte()
        val seq = rtpSeq++ and 0xFFFF
        p[2] = (seq shr 8).toByte(); p[3] = (seq and 0xFF).toByte()
        p[4] = (ts shr 24).toByte(); p[5] = (ts shr 16 and 0xFF).toByte()
        p[6] = (ts shr 8 and 0xFF).toByte(); p[7] = (ts and 0xFF).toByte()
        p[8] = (ssrc shr 24).toByte(); p[9] = (ssrc shr 16 and 0xFF).toByte()
        p[10] = (ssrc shr 8 and 0xFF).toByte(); p[11] = (ssrc and 0xFF).toByte()
        System.arraycopy(payload, 0, p, 12, payload.size)
        return p
    }

    private fun sendInterleaved(rtp: ByteArray) {
        try {
            val o = rtspOutputStream ?: return
            synchronized(this) {
                o.write(byteArrayOf(0x24, 0x00, (rtp.size shr 8 and 0xFF).toByte(), (rtp.size and 0xFF).toByte()))
                o.write(rtp); o.flush()
            }
        } catch (e: Exception) {
            Log.e(TAG, "RTP send error: $e")
            if (isRunning.get()) stopPublishing()
        }
    }

    private fun splitAnnexB(data: ByteArray): List<ByteArray> {
        val result = mutableListOf<ByteArray>()
        var start = 0; var i = 0
        fun startCodeLen(at: Int): Int {
            if (at + 3 < data.size && data[at] == 0.toByte() && data[at+1] == 0.toByte() && data[at+2] == 0.toByte() && data[at+3] == 1.toByte()) return 4
            if (at + 2 < data.size && data[at] == 0.toByte() && data[at+1] == 0.toByte() && data[at+2] == 1.toByte()) return 3
            return 0
        }
        val sc = startCodeLen(0); start = sc; i = sc
        while (i < data.size) {
            val scl = startCodeLen(i)
            if (scl > 0) {
                var end = i; while (end > start && data[end-1] == 0.toByte()) end--
                if (end > start) result.add(data.copyOfRange(start, end))
                start = i + scl; i = start
            } else i++
        }
        if (start < data.size) result.add(data.copyOfRange(start, data.size))
        return result
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SDP
    // ════════════════════════════════════════════════════════════════════════

    private fun buildSdp(host: String): String {
        val spsB64 = Base64.encodeToString(spsBytes!!, Base64.NO_WRAP)
        val ppsB64 = Base64.encodeToString(ppsBytes!!, Base64.NO_WRAP)
        return "v=0\r\n" +
                "o=- 0 0 IN IP4 $host\r\n" +
                "s=Live\r\n" +
                "c=IN IP4 $host\r\n" +
                "t=0 0\r\n" +
                "a=control:*\r\n" +
                "m=video 0 RTP/AVP 96\r\n" +
                "a=rtpmap:96 H264/90000\r\n" +
                "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=$spsB64,$ppsB64\r\n" +
                "a=control:trackID=0\r\n"
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STOP / HELPERS
    // ════════════════════════════════════════════════════════════════════════

    private fun stopPublishing() {
        isRunning.set(false)
        runCatching { captureSession?.close() }; captureSession = null
        runCatching { cameraDevice?.close() }; cameraDevice = null
        runCatching { mediaCodec?.stop(); mediaCodec?.release() }; mediaCodec = null
        runCatching { encoderInputSurface?.release() }; encoderInputSurface = null
        cameraThread?.quitSafely(); cameraThread = null
        runCatching { rtspOutputStream?.close() }
        runCatching { rtspSocket?.close() }
        rtspOutputStream = null; rtspInputStream = null; rtspSocket = null
        spsBytes = null; ppsBytes = null
        Log.i(TAG, "Stopped")
    }

    private fun hasPermissions() = listOf(
        Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO
    ).all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }

    private fun getWifiIp(): String? = try {
        @Suppress("DEPRECATION")
        val ip = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager).connectionInfo.ipAddress
        if (ip == 0) null else "%d.%d.%d.%d".format(ip and 0xFF, ip shr 8 and 0xFF, ip shr 16 and 0xFF, ip shr 24 and 0xFF)
    } catch (e: Exception) { null }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE) {
            pendingPermResult?.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
            pendingPermResult = null
        }
    }

    override fun onDestroy() { super.onDestroy(); stopPublishing() }
}