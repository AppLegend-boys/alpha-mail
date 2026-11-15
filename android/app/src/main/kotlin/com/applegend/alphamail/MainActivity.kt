package com.applegend.alphamail

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // A device list waiting on the Bluetooth permission prompt.
    private var devicesResult: MethodChannel.Result? = null
    private var bluetoothReceiver: BroadcastReceiver? = null

    // 자동 실행 (lib/bluetooth.dart): paired devices, which are connected,
    // and a ping when a headset or car audio connects or disconnects.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "alphamail/bluetooth").setMethodCallHandler { call, result ->
            when (call.method) {
                "devices" -> if (canConnect()) {
                    result.success(paired())
                } else {
                    devicesResult?.success(emptyList<Any>())
                    devicesResult = result
                    requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), BLUETOOTH_REQUEST)
                }
                "connected" -> connected(result)
                "launchAllowed" -> result.success(Settings.canDrawOverlays(this))
                "allowLaunch" -> {
                    startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "alphamail/bluetooth/changes").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    bluetoothReceiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent) = events.success(true)
                    }
                    // Profile changes, not ACL ones: a device is only listed as
                    // connected by connected() once its audio profile is up.
                    registerReceiver(bluetoothReceiver, IntentFilter().apply {
                        addAction(BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED)
                        addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
                    })
                }

                override fun onCancel(arguments: Any?) {
                    bluetoothReceiver?.let { unregisterReceiver(it) }
                    bluetoothReceiver = null
                }
            },
        )
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != BLUETOOTH_REQUEST) return
        devicesResult?.success(if (canConnect()) paired() else emptyList())
        devicesResult = null
    }

    private fun canConnect() = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
        checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    private val adapter get() = getSystemService(BluetoothManager::class.java)?.adapter

    @SuppressLint("MissingPermission")
    private fun device(d: BluetoothDevice) = mapOf("id" to d.address, "name" to (d.name ?: d.address))

    @SuppressLint("MissingPermission")
    private fun paired(): List<Map<String, String>> = adapter?.bondedDevices?.map(::device) ?: emptyList()

    // Devices with a headset (calls) or A2DP (media) connection now.
    @SuppressLint("MissingPermission")
    private fun connected(result: MethodChannel.Result) {
        val adapter = adapter
        if (adapter == null || !adapter.isEnabled || !canConnect()) return result.success(emptyList<Any>())
        val found = mutableMapOf<String, Map<String, String>>()
        val profiles = listOf(BluetoothProfile.HEADSET, BluetoothProfile.A2DP)
        var left = profiles.size
        fun done() {
            if (--left == 0) result.success(found.values.toList())
        }
        for (profile in profiles) {
            val asked = adapter.getProfileProxy(this, object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                    for (d in proxy.connectedDevices) found[d.address] = device(d)
                    adapter.closeProfileProxy(profile, proxy)
                    done()
                }

                override fun onServiceDisconnected(profile: Int) {}
            }, profile)
            if (!asked) done()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hideNavigationBar()
        showOverLockScreen(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        showOverLockScreen(intent)
    }

    // Opened by 자동 실행 (BluetoothReceiver): over the lock screen, so it can
    // ask without an unlock, until the app is left or the screen goes off.
    private fun showOverLockScreen(intent: Intent?) {
        if (intent?.getBooleanExtra(BluetoothReceiver.AUTO_RUN, false) != true) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }

    override fun onStop() {
        super.onStop()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) setShowWhenLocked(false)
    }

    // Dialogs, the keyboard and coming back from another app show it again.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideNavigationBar()
    }

    // Hidden from launch rather than once Flutter starts (lib/main.dart does
    // the same); a swipe up shows it for a moment.
    private fun hideNavigationBar() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.apply {
                hide(WindowInsets.Type.navigationBars())
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        }
    }

    companion object {
        private const val BLUETOOTH_REQUEST = 7
    }
}
