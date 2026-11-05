package __APPLICATION_ID__

import android.view.View

// A release build answers no driver: scenarios run on debug builds alone.
object Driver {
    fun attach(activity: MainActivity, engine: TerminalEngine, root: View) {}
    fun detach() {}
}
