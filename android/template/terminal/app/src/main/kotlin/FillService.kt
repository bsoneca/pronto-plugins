package __APPLICATION_ID__

import android.app.PendingIntent
import android.content.Intent
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.widget.RemoteViews
import org.json.JSONObject

// The system's autofill, for an app that asks for it (android.json's "autofill", which needs its
// "unlock": "biometric"). Its storage is sealed while the service runs, so a fill answers with one
// locked entry; choosing it opens FillActivity, which unlocks, boots the terminal headless and asks
// the app's handler which logins fill.
class FillService : AutofillService() {
    override fun onFillRequest(request: FillRequest, cancellation: CancellationSignal, callback: FillCallback) {
        val structure = request.fillContexts.last().structure
        val read = Request.read(structure)
        if (read.probe == null || read.ids.isEmpty() || read.packageName == packageName || contract(this) == null) {
            callback.onSuccess(null)
            return
        }
        val intent = Intent(this, FillActivity::class.java)
        val sender = PendingIntent.getActivity(
            this, read.packageName.hashCode(), intent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
        ).intentSender
        val label = applicationInfo.loadLabel(packageManager)
        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
            setTextViewText(android.R.id.text1, "Unlock $label")
        }
        @Suppress("DEPRECATION")
        callback.onSuccess(FillResponse.Builder().setAuthentication(read.ids.toTypedArray(), sender, presentation).build())
    }

    // Saving a typed login is not offered: logins are written on the app's own screens.
    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) = callback.onSuccess()

    companion object {
        // autofill.json: which handler answers a fill, the tables it reads, and the columns a dataset
        // takes. Only under an unlock: a fill hands out secrets, so a key no person opens never does.
        fun contract(context: android.content.Context): Autofill? =
            if (context.getString(R.string.pronto_unlock) != "biometric") null
            else context.assets.list("").orEmpty().takeIf { "autofill.json" in it }
                ?.let { Autofill(JSONObject(context.assets.open("autofill.json").bufferedReader().use { r -> r.readText() })) }
    }
}
