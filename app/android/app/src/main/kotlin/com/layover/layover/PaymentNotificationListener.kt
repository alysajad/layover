package com.layover.layover

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

class PaymentNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("enabled", false)) return
        val now = System.currentTimeMillis()
        if (now < prefs.getLong("start", Long.MAX_VALUE) || now >= prefs.getLong("end", 0)) return
        if (sbn.postTime < prefs.getLong("enabled_at", now) || sbn.postTime < prefs.getLong("start", now)) return
        if (!prefs.getStringSet("sources", emptySet())!!.contains(sbn.packageName)) return
        if (sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val body = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        val text = "$title $body".trim().take(4000)
        if (!Regex("(?:INR|Rs\\.?|₹)\\s*\\d", RegexOption.IGNORE_CASE).containsMatchIn(text)) return
        if (!Regex("\\b(paid|debited|spent|sent|payment successful|payment of|transferred|purchase of)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text)) return
        if (Regex("\\b(otp|verification|failed|declined|pending|refund|cashback|credited|received|request|mandate|autopay|reminder|due)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text)) return
        val hash = MessageDigest.getInstance("SHA-256").digest("${sbn.key}|$text|${sbn.postTime}".toByteArray())
            .joinToString("") { "%02x".format(it) }
        synchronized(lock) {
            val queue = JSONArray(prefs.getString("queue", "[]"))
            for (i in 0 until queue.length()) if (queue.getJSONObject(i).getString("id") == hash) return
            // Keep at most 200 undelivered candidates; only parsed details leave this queue.
            while (queue.length() >= 200) queue.remove(0)
            queue.put(JSONObject().put("id", hash).put("text", text).put("source", sbn.packageName)
                .put("trip_id", prefs.getString("trip_id", "")).put("posted_at", sbn.postTime))
            prefs.edit().putString("queue", queue.toString()).apply()
        }
        onAvailable?.invoke()
    }

    companion object {
        const val PREFS = "layover_payment_capture"
        val lock = Any()
        var onAvailable: (() -> Unit)? = null
    }
}
