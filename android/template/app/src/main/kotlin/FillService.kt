package __APPLICATION_ID__

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.view.View
import android.view.autofill.AutofillId
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

// One request's facts, read off the asking screen's view tree.
class Request(val packageName: String, val probe: Probe?, val username: AutofillId?, val password: AutofillId?) {
    val ids get() = listOfNotNull(username, password)

    companion object {
        fun read(structure: AssistStructure): Request {
            val fields = mutableListOf<Field<AutofillId>>()
            // A node's page is the nearest one declared at or above it: a frame
            // inside a page declares its own.
            fun walk(node: AssistStructure.ViewNode, outer: String?, outerScheme: String?) {
                val domain = node.webDomain ?: outer
                val scheme = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && node.webDomain != null) node.webScheme else null) ?: outerScheme
                val id = node.autofillId
                if (id != null && node.autofillType == View.AUTOFILL_TYPE_TEXT) {
                    val attrs = node.htmlInfo?.attributes.orEmpty().associate { it.first to it.second }
                    fields += Field(id, domain, scheme, node.autofillHints.orEmpty().toList(), node.inputType, attrs["type"], attrs["name"], node.idEntry)
                }
                for (i in 0 until node.childCount) walk(node.getChildAt(i), domain, scheme)
            }
            for (i in 0 until structure.windowNodeCount) walk(structure.getWindowNodeAt(i).rootViewNode, null, null)
            val pkg = structure.activityComponent.packageName
            val targets = Fill.targets(fields)
            val asking = fields.firstOrNull { it.id == targets.password } ?: fields.firstOrNull { it.id == targets.username }
            return Request(pkg, Fill.probe(pkg, asking), targets.username, targets.password)
        }
    }
}
