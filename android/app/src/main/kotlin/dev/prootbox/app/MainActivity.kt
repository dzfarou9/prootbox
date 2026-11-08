package dev.prootbox.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var ptyManager: PtyManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val manager = PtyManager()
        ptyManager = manager

        // Interactive PTY sessions.
        MethodChannel(messenger, "prootbox/pty").setMethodCallHandler(manager)
        EventChannel(messenger, "prootbox/pty/events").setStreamHandler(manager)

        // Device info, exec checks and chmod.
        MethodChannel(messenger, "prootbox/native")
            .setMethodCallHandler(NativeSupport(applicationContext))
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Never leave a guest process group running behind a dead UI.
        ptyManager?.dispose()
        ptyManager = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
