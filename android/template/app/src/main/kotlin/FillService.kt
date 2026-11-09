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

// The system's autofill. The vault is sealed while the service runs, so a fill
// answers with one locked entry; choosing it opens FillActivity, which unlocks
// and asks the program's handler which logins fill.
class FillService : AutofillService() {
    override fun onFillRequest(request: FillRequest, cancellation: CancellationSignal, callback: FillCallback) {
        val structure = request.fillContexts.last().structure
        val read = Request.read(structure)
        if (read.probe == null || read.ids.isEmpty() || read.packageName == packageName || Program(this).autofill == null) {
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

    // Saving a typed login is not offered: the vault is written on its own screen.
    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) = callback.onSuccess()
}
