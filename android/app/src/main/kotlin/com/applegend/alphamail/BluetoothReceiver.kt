package com.applegend.alphamail

import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONObject
import java.io.File
import java.util.Calendar

// 자동 실행 while the app is closed or in the background: opens it when the
// chosen device connects, unless it already asked today. Home then checks
// the connection and asks, as when it was open. Android only lets it open
// itself with 다른 앱 위에 표시 allowed.
class BluetoothReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        } ?: return
        // AppSettings in lib/screens/settings.dart; its folder is
        // getApplicationSupportDirectory().
        val settings = try {
            JSONObject(File(context.filesDir, "settings.json").readText())
        } catch (_: Exception) {
            return
        }
        // Same format as AppSettings.dayKey: 2026-11-5.
        val now = Calendar.getInstance()
        val today = "${now.get(Calendar.YEAR)}-${now.get(Calendar.MONTH) + 1}-${now.get(Calendar.DAY_OF_MONTH)}"
        if (!settings.optBoolean("autoRun") ||
            settings.optString("autoDevice") != device.address ||
            settings.optString("autoRanOn") == today
        ) return
        context.startActivity(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(AUTO_RUN, true),
        )
    }

    companion object {
        const val AUTO_RUN = "autoRun"
    }
}
