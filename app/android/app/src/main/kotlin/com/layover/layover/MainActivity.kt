package com.layover.layover

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.ComponentName
import android.content.Intent
import android.provider.Settings
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val prefs = getSharedPreferences(PaymentNotificationListener.PREFS, MODE_PRIVATE)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "layover/payment_capture")
        PaymentNotificationListener.onAvailable = { runOnUiThread { channel.invokeMethod("paymentsAvailable", null) } }
        channel.setMethodCallHandler { call, result ->
            try {
                synchronized(PaymentNotificationListener.lock) {
                    val account = call.argument<String>("account").orEmpty()
                    if (call.method !in listOf("bindAccount", "openSettings") &&
                        (account.isEmpty() || account != prefs.getString("account", ""))) {
                        result.error("account", "Sign in again before capturing payments", null)
                        return@setMethodCallHandler
                    }
                    when (call.method) {
                        "bindAccount" -> {
                            if (account != prefs.getString("account", "")) prefs.edit().clear().putString("account", account).commit()
                            result.success(null)
                        }
                        "configure" -> {
                            val start = call.argument<Number>("start")!!.toLong()
                            val end = call.argument<Number>("end")!!.toLong()
                            val sources = call.argument<List<String>>("sources")!!.toSet()
                            require(start < end && end > System.currentTimeMillis() && sources.isNotEmpty())
                            prefs.edit().putBoolean("enabled", true).putString("trip_id", call.argument<String>("trip_id"))
                                .putLong("start", start).putLong("end", end).putLong("enabled_at", System.currentTimeMillis())
                                .putStringSet("sources", sources).commit()
                            result.success(null)
                        }
                        "stop" -> { prefs.edit().putBoolean("enabled", false).commit(); result.success(null) }
                        "openSettings" -> { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)); result.success(null) }
                        "read" -> {
                            val component = ComponentName(this, PaymentNotificationListener::class.java)
                            val permission = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
                                ?.split(':')?.any { ComponentName.unflattenFromString(it) == component } == true
                            val queue = JSONArray(prefs.getString("queue", "[]"))
                            val items = (0 until queue.length()).map { i ->
                                val item = queue.getJSONObject(i)
                                item.keys().asSequence().associateWith { item.get(it) }
                            }
                            result.success(mapOf("items" to items, "status" to mapOf(
                                "permission" to permission, "enabled" to (prefs.getBoolean("enabled", false) && System.currentTimeMillis() < prefs.getLong("end", 0)),
                                "trip_id" to prefs.getString("trip_id", null), "sources" to prefs.getStringSet("sources", emptySet())!!.toList()
                            )))
                        }
                        "acknowledge" -> {
                            val ids = call.argument<List<String>>("ids")!!.toSet()
                            val queue = JSONArray(prefs.getString("queue", "[]"))
                            val remaining = JSONArray()
                            for (i in 0 until queue.length()) if (queue.getJSONObject(i).getString("id") !in ids) remaining.put(queue.getJSONObject(i))
                            prefs.edit().putString("queue", remaining.toString()).commit()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            } catch (e: Exception) { result.error("capture", "Could not update payment capture", null) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        PaymentNotificationListener.onAvailable = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
