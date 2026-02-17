package com.example.rtsp_streamer

// ══════════════════════════════════════════════════════════════════════════════
//  COMPLETE RTSP SERVER — Zero external dependencies
//  Uses only standard Android APIs:
//    - Camera2 API         → capture video frames
//    - MediaCodec          → encode to H264
//    - ServerSocket        → RTSP/TCP server
//    - RTP over TCP        → stream to VLC
//
//  VLC connects to:  rtsp://PHONE_IP:8554/live
// ══════════════════════════════════════════════════════════════════════════════

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
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.rtspstreamer/rtsp"
    private val REQUEST_CODE = 100
    private val TAG = "RTSPStreamer"

    // ─── State ───────────────────────────────────────────────────────────────
    private val isRunning = AtomicBoolean(false)

    // Camera / Encoder
    private var mediaCodec: MediaCodec? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var encoderInputSurface: Surface? = null
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

    // SPS/PPS (extracted from first codec config output — needed for SDP)
    @Volatile private var spsBytes: ByteArray? = null
    @Volatile private var ppsBytes: ByteArray? = null
    private var spsPpsLatch = CountDownLatch(1)

    // RTSP / RTP
    private var serverSocket: ServerSocket? = null
    private val clients = mutableListOf<RtspClientSession>()
    private val clientsLock = Any()
    private var rtpSeq: Int = 0
    private var ssrc: Int = (Math.random() * 0x7FFFFFFF).toInt()

    // Flutter permissions callback
    private var pendingPermResult: MethodChannel.Result? = null

    // ─── Flutter MethodChannel ────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "startServer" -> {
                        val port = call.argument<Int>("port") ?: 8554
                        if (!hasPermissions()) { result.success(false); return@setMethodCallHandler }
                        thread {
                            val ok = startRtspServer(port)
                            runOnUiThread { result.success(ok) }
                        }
                    }

                    "stopServer" -> {
                        stopRtspServer()
                        result.success(true)
                    }

                    "isStreaming" -> result.success(isRunning.get())

                    "getDeviceIp" -> result.success(getWifiIp())

                    "checkPermissions" -> result.success(hasPermissions())

                    "requestPermissions" -> {
                        if (hasPermissions()) {
                            result.success(true)
                        } else {
                            pendingPermResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO),
                                REQUEST_CODE
                            )
                        }
                    }

                    "switchCamera" -> result.success(null)  // TODO: implement if needed
                    "toggleTorch"  -> result.success(null)
                    else           -> result.notImplemented()
                }
            }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SERVER START / STOP
    // ════════════════════════════════════════════════════════════════════════

    private fun startRtspServer(port: Int): Boolean {
        if (isRunning.get()) return true
        spsPpsLatch = CountDownLatch(1)     // reset for fresh start

        return try {
            // 1. Start camera thread
            cameraThread = HandlerThread("CameraThread").also { it.start() }
            cameraHandler = Handler(cameraThread!!.looper)

            // 2. Init H264 encoder (creates encoderInputSurface)
            initEncoder()

            // 3. Open camera → feeds frames into encoder via surface
            openCamera()

            // 4. Wait for SPS+PPS (max 6 seconds) before we can serve DESCRIBE
            if (!spsPpsLatch.await(6, TimeUnit.SECONDS)) {
                Log.e(TAG, "Timed out waiting for SPS/PPS from encoder")
                stopRtspServer()
                return false
            }

            // 5. Open RTSP server socket
            serverSocket = ServerSocket(port)
            isRunning.set(true)
            Log.i(TAG, "✅ RTSP server ready → rtsp://${getWifiIp()}:$port/live")

            // 6. Accept client connections in background
            thread(name = "RTSP-Accept") {
                while (isRunning.get()) {
                    try {
                        val sock = serverSocket?.accept() ?: break
                        Log.i(TAG, "New client: ${sock.remoteSocketAddress}")
                        val session = RtspClientSession(sock)
                        synchronized(clientsLock) { clients.add(session) }
                        session.start()
                    } catch (e: Exception) {
                        if (isRunning.get()) Log.e(TAG, "Accept error: $e")
                    }
                }
            }

            true
        } catch (e: Exception) {
            Log.e(TAG, "startRtspServer failed: $e", e)
            stopRtspServer()
            false
        }
    }

    private fun stopRtspServer() {
        isRunning.set(false)

        synchronized(clientsLock) {
            clients.forEach { it.close() }
            clients.clear()
        }
        runCatching { serverSocket?.close() }
        serverSocket = null
        runCatching { captureSession?.close() }
        captureSession = null
        runCatching { cameraDevice?.close() }
        cameraDevice = null
        runCatching { mediaCodec?.stop(); mediaCodec?.release() }
        mediaCodec = null
        runCatching { encoderInputSurface?.release() }
        encoderInputSurface = null
        cameraThread?.quitSafely()
        cameraThread = null
        spsBytes = null
        ppsBytes = null
        Log.i(TAG, "RTSP server stopped")
    }

    // ════════════════════════════════════════════════════════════════════════
    //  MEDIACODEC H264 ENCODER
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

        // Drain encoder output in a background thread
        thread(name = "Encoder-Output") { drainEncoder() }
    }

    private fun drainEncoder() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val codec = mediaCodec ?: break
            val idx = try {
                codec.dequeueOutputBuffer(info, 10_000L)
            } catch (e: Exception) {
                break
            }

            if (idx == MediaCodec.INFO_TRY_AGAIN_LATER) continue
            if (idx < 0) continue

            val buf = codec.getOutputBuffer(idx) ?: run {
                codec.releaseOutputBuffer(idx, false); continue
            }
            buf.position(info.offset)
            buf.limit(info.offset + info.size)

            val data = ByteArray(info.size)
            buf.get(data)
            codec.releaseOutputBuffer(idx, false)

            when {
                info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 -> {
                    // SPS + PPS packed together with Annex B start codes
                    parseAndStoreSpsPps(data)
                }
                data.isNotEmpty() -> {
                    // Encoded video frame — packetize and broadcast
                    val isKey = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                    val rtpTs = (info.presentationTimeUs * 90L / 1000L).toInt()
                    broadcastFrame(data, rtpTs, isKey)
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  CAMERA2
    // ════════════════════════════════════════════════════════════════════════

    private fun openCamera() {
        val mgr = getSystemService(CAMERA_SERVICE) as CameraManager
        // Pick back camera
        val camId = mgr.cameraIdList.firstOrNull { id ->
            mgr.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: mgr.cameraIdList.first()

        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) return

        mgr.openCamera(camId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                startCaptureSession(camera)
            }
            override fun onDisconnected(camera: CameraDevice) { camera.close() }
            override fun onError(camera: CameraDevice, error: Int) {
                Log.e(TAG, "Camera error $error")
                camera.close()
            }
        }, cameraHandler)
    }

    private fun startCaptureSession(camera: CameraDevice) {
        val surface = encoderInputSurface ?: return

        @Suppress("DEPRECATION")
        camera.createCaptureSession(listOf(surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    val req = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                        addTarget(surface)
                        set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                        set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, android.util.Range(30, 30))
                    }
                    session.setRepeatingRequest(req.build(), null, cameraHandler)
                    Log.i(TAG, "Camera capture session started")
                }
                override fun onConfigureFailed(session: CameraCaptureSession) {
                    Log.e(TAG, "Camera session configure failed")
                }
            }, cameraHandler)
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SPS / PPS EXTRACTION
    // ════════════════════════════════════════════════════════════════════════

    private fun parseAndStoreSpsPps(codecConfig: ByteArray) {
        // MediaCodec outputs: [00 00 00 01] SPS_NALU [00 00 00 01] PPS_NALU
        val positions = mutableListOf<Int>()
        var i = 0
        while (i <= codecConfig.size - 4) {
            if (codecConfig[i] == 0x00.toByte() && codecConfig[i+1] == 0x00.toByte() &&
                codecConfig[i+2] == 0x00.toByte() && codecConfig[i+3] == 0x01.toByte()) {
                positions.add(i + 4)  // start of NALU data (after start code)
                i += 4
            } else i++
        }

        if (positions.size >= 2) {
            val spsEnd = positions[1] - 4  // exclude next start code
            spsBytes = codecConfig.copyOfRange(positions[0], spsEnd)
            ppsBytes = codecConfig.copyOfRange(positions[1], codecConfig.size)
            Log.i(TAG, "SPS=${spsBytes!!.size}B PPS=${ppsBytes!!.size}B extracted")
            spsPpsLatch.countDown()
        } else if (positions.size == 1) {
            // Some devices put SPS and PPS in separate codec config outputs
            val naluType = codecConfig[positions[0]].toInt() and 0x1F
            if (naluType == 7) spsBytes = codecConfig.copyOfRange(positions[0], codecConfig.size)
            if (naluType == 8) {
                ppsBytes = codecConfig.copyOfRange(positions[0], codecConfig.size)
                if (spsBytes != null) spsPpsLatch.countDown()
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  RTP PACKETIZATION + BROADCAST
    // ════════════════════════════════════════════════════════════════════════

    private fun broadcastFrame(annexBData: ByteArray, rtpTimestamp: Int, isKeyFrame: Boolean) {
        if (spsBytes == null || ppsBytes == null) return

        val nalus = splitAnnexBToNalus(annexBData)

        for ((idx, nalu) in nalus.withIndex()) {
            if (nalu.isEmpty()) continue
            val marker = (idx == nalus.size - 1)  // marker on last packet of frame
            sendNaluAsRtp(nalu, rtpTimestamp, marker)
        }
    }

    /** Split Annex-B byte stream into individual NALU byte arrays (no start codes) */
    private fun splitAnnexBToNalus(data: ByteArray): List<ByteArray> {
        val result = mutableListOf<ByteArray>()
        var start = 0
        var i = 0
        // Skip leading start code
        if (data.size >= 4 && data[0] == 0x00.toByte() && data[1] == 0x00.toByte() &&
            data[2] == 0x00.toByte() && data[3] == 0x01.toByte()) { start = 4; i = 4 }
        else if (data.size >= 3 && data[0] == 0x00.toByte() && data[1] == 0x00.toByte() &&
            data[2] == 0x01.toByte()) { start = 3; i = 3 }

        while (i <= data.size - 3) {
            val sc4 = i + 3 < data.size &&
                    data[i] == 0.toByte() && data[i+1] == 0.toByte() &&
                    data[i+2] == 0.toByte() && data[i+3] == 1.toByte()
            val sc3 = data[i] == 0.toByte() && data[i+1] == 0.toByte() && data[i+2] == 1.toByte()

            if (sc4 || sc3) {
                // Collect NALU [start .. i), strip trailing zeros
                var end = i
                while (end > start && data[end - 1] == 0.toByte()) end--
                if (end > start) result.add(data.copyOfRange(start, end))
                start = i + (if (sc4) 4 else 3)
                i = start
            } else i++
        }
        if (start < data.size) result.add(data.copyOfRange(start, data.size))
        return result
    }

    private val MAX_RTP_PAYLOAD = 1400

    private fun sendNaluAsRtp(nalu: ByteArray, ts: Int, marker: Boolean) {
        if (nalu.size <= MAX_RTP_PAYLOAD) {
            // Single NAL unit packet (RFC 6184 §5.6)
            broadcast(buildRtpPacket(nalu, ts, marker))
        } else {
            // FU-A fragmentation (RFC 6184 §5.8)
            val naluType  = nalu[0].toInt() and 0x1F
            val naluHeader = nalu[0].toInt() and 0xE0   // forbidden + NRI bits
            var offset = 1
            while (offset < nalu.size) {
                val end = minOf(offset + MAX_RTP_PAYLOAD - 2, nalu.size)
                val isFirst = offset == 1
                val isLast  = end == nalu.size
                val fuPayload = ByteArray(2 + (end - offset))
                fuPayload[0] = (naluHeader or 28).toByte()          // FU indicator
                fuPayload[1] = (
                        (if (isFirst) 0x80 else 0) or
                                (if (isLast)  0x40 else 0) or
                                naluType
                        ).toByte()                                           // FU header
                System.arraycopy(nalu, offset, fuPayload, 2, end - offset)
                broadcast(buildRtpPacket(fuPayload, ts, isLast && marker))
                offset = end
            }
        }
    }

    /** Build 12-byte RTP header + payload */
    private fun buildRtpPacket(payload: ByteArray, timestamp: Int, marker: Boolean): ByteArray {
        val pkt = ByteArray(12 + payload.size)
        pkt[0] = 0x80.toByte()                                       // V=2, P=0, X=0, CC=0
        pkt[1] = ((if (marker) 0x80 else 0x00) or 96).toByte()      // M + PT=96 (H264)
        val seq = rtpSeq++ and 0xFFFF
        pkt[2] = (seq shr 8).toByte()
        pkt[3] = (seq and 0xFF).toByte()
        pkt[4] = (timestamp shr 24).toByte()
        pkt[5] = (timestamp shr 16 and 0xFF).toByte()
        pkt[6] = (timestamp shr 8  and 0xFF).toByte()
        pkt[7] = (timestamp        and 0xFF).toByte()
        pkt[8] = (ssrc shr 24).toByte()
        pkt[9] = (ssrc shr 16 and 0xFF).toByte()
        pkt[10]= (ssrc shr 8  and 0xFF).toByte()
        pkt[11]= (ssrc        and 0xFF).toByte()
        System.arraycopy(payload, 0, pkt, 12, payload.size)
        return pkt
    }

    private fun broadcast(rtpPacket: ByteArray) {
        synchronized(clientsLock) {
            val dead = mutableListOf<RtspClientSession>()
            for (c in clients) {
                if (!c.sendRtp(rtpPacket)) dead.add(c)
            }
            clients.removeAll(dead.toSet())
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  RTSP CLIENT SESSION  (one per connected VLC instance)
    // ════════════════════════════════════════════════════════════════════════

    inner class RtspClientSession(private val socket: Socket) {
        @Volatile private var playing = false
        @Volatile private var closed  = false
        private var out: OutputStream? = null

        fun start() = thread(name = "RTSP-Client") {
            try {
                out = socket.getOutputStream()
                val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
                serveRtsp(reader)
            } catch (e: Exception) {
                Log.d(TAG, "Client gone: ${e.message}")
            } finally { close() }
        }

        private fun serveRtsp(reader: BufferedReader) {
            while (!socket.isClosed && !closed) {
                val requestLine = reader.readLine() ?: break
                if (requestLine.isBlank()) continue
                Log.d(TAG, "← $requestLine")

                // Collect headers until blank line
                val headers = mutableMapOf<String, String>()
                var line = reader.readLine()
                while (!line.isNullOrBlank()) {
                    val ci = line.indexOf(':')
                    if (ci > 0) headers[line.substring(0, ci).trim().lowercase()] =
                        line.substring(ci + 1).trim()
                    line = reader.readLine()
                }

                val cseq   = headers["cseq"] ?: "0"
                val method = requestLine.substringBefore(' ').uppercase()

                when (method) {
                    "OPTIONS" -> reply(cseq, "200 OK",
                        "Public: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE\r\n")

                    "DESCRIBE" -> {
                        val sdp = buildSdp()
                        reply(cseq, "200 OK",
                            "Content-Type: application/sdp\r\nContent-Length: ${sdp.length}\r\n",
                            sdp)
                    }

                    "SETUP" -> {
                        // Always use TCP interleaved (channel 0=RTP, 1=RTCP)
                        reply(cseq, "200 OK",
                            "Session: 88776655;timeout=60\r\n" +
                                    "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n")
                    }

                    "PLAY" -> {
                        reply(cseq, "200 OK",
                            "Session: 88776655\r\n" +
                                    "RTP-Info: url=rtsp://0.0.0.0/live/trackID=0\r\n")
                        playing = true
                        Log.i(TAG, "▶ Client started playing")
                    }

                    "PAUSE" -> {
                        playing = false
                        reply(cseq, "200 OK", "Session: 88776655\r\n")
                    }

                    "TEARDOWN" -> {
                        playing = false
                        reply(cseq, "200 OK", "Session: 88776655\r\n")
                        break
                    }

                    else -> reply(cseq, "405 Method Not Allowed", "")
                }
            }
        }

        private fun reply(cseq: String, status: String, extra: String, body: String = "") {
            val msg = "RTSP/1.0 $status\r\nCSeq: $cseq\r\n$extra\r\n$body"
            try {
                out?.write(msg.toByteArray(Charsets.UTF_8))
                out?.flush()
                Log.d(TAG, "→ $status")
            } catch (e: Exception) { Log.e(TAG, "Reply error: $e") }
        }

        /** Called from encoder thread — sends RTP packet as RTSP interleaved frame */
        fun sendRtp(rtpData: ByteArray): Boolean {
            if (!playing || closed) return !closed
            return try {
                val o = out ?: return false
                // Interleaved binary data header: $ + channel(0) + length(2)
                val hdr = byteArrayOf(
                    0x24, 0x00,
                    (rtpData.size shr 8 and 0xFF).toByte(),
                    (rtpData.size       and 0xFF).toByte()
                )
                synchronized(this) {
                    o.write(hdr)
                    o.write(rtpData)
                    o.flush()
                }
                true
            } catch (e: Exception) { false }
        }

        fun close() {
            closed  = true
            playing = false
            runCatching { socket.close() }
        }

        private fun buildSdp(): String {
            val sps = spsBytes!!
            val pps = ppsBytes!!
            val spsB64 = Base64.encodeToString(sps, Base64.NO_WRAP)
            val ppsB64 = Base64.encodeToString(pps, Base64.NO_WRAP)
            val ip = getWifiIp() ?: "0.0.0.0"
            return "v=0\r\n" +
                    "o=- 0 0 IN IP4 $ip\r\n" +
                    "s=Android RTSP Stream\r\n" +
                    "c=IN IP4 $ip\r\n" +
                    "t=0 0\r\n" +
                    "a=control:*\r\n" +
                    "m=video 0 RTP/AVP 96\r\n" +
                    "a=rtpmap:96 H264/90000\r\n" +
                    "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=$spsB64,$ppsB64\r\n" +
                    "a=control:trackID=0\r\n"
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ════════════════════════════════════════════════════════════════════════

    private fun hasPermissions() = listOf(
        Manifest.permission.CAMERA,
        Manifest.permission.RECORD_AUDIO
    ).all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }

    private fun getWifiIp(): String? = try {
        val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val ip = wifi.connectionInfo.ipAddress
        if (ip == 0) null
        else "%d.%d.%d.%d".format(ip and 0xFF, ip shr 8 and 0xFF, ip shr 16 and 0xFF, ip shr 24 and 0xFF)
    } catch (e: Exception) { null }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE) {
            val ok = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pendingPermResult?.success(ok)
            pendingPermResult = null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRtspServer()
    }
}