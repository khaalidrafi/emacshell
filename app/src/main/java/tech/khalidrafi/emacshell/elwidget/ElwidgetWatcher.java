package tech.khalidrafi.emacshell.elwidget;

import android.appwidget.AppWidgetManager;
import android.content.Context;
import android.os.FileObserver;
import android.os.Handler;
import android.os.Looper;

import java.io.File;

/**
 * Watches the elwidget tree so widgets re-draw within a second of an
 * Emacs re-render while the app process (which also hosts Emacs) is
 * alive.  One debounced handler for the specs directory and the
 * root-level bindings/state files; Android itself refreshes widgets
 * at most every 30 minutes otherwise.
 */
public final class ElwidgetWatcher {

    private static FileObserver sSpecsObserver;
    private static FileObserver sRootObserver;
    private static final Handler sHandler =
            new Handler(Looper.getMainLooper());
    private static Runnable sPending;

    private ElwidgetWatcher() {
    }

    /**
     * Start watching (once) if the elwidget tree exists.  Called from
     * EmacshellApplication.onCreate and from the widget provider; on a
     * fresh install there is nothing to watch yet, so this is a no-op
     * until Emacs first runs.
     */
    public static synchronized void ensure(Context context) {
        final Context app = context.getApplicationContext();
        ElwidgetFiles files = new ElwidgetFiles(app);
        if (!files.specsDir().isDirectory())
            return;
        if (sSpecsObserver != null)
            return;

        sSpecsObserver = new FileObserver(files.specsDir().getAbsolutePath(),
                FileObserver.CREATE | FileObserver.CLOSE_WRITE
                        | FileObserver.MOVED_TO | FileObserver.DELETE) {
            @Override
            public void onEvent(int event, String path) {
                schedule(app);
            }
        };
        sSpecsObserver.startWatching();

        sRootObserver = new FileObserver(files.root().getAbsolutePath(),
                FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO
                        | FileObserver.DELETE) {
            @Override
            public void onEvent(int event, String path) {
                if ("bindings.json".equals(path)
                        || "state.json".equals(path))
                    schedule(app);
            }
        };
        sRootObserver.startWatching();
    }

    /** Debounced re-render of every bound widget. */
    private static void schedule(Context app) {
        if (sPending != null)
            sHandler.removeCallbacks(sPending);
        sPending = new Runnable() {
            @Override
            public void run() {
                sPending = null;
                try {
                    ElwidgetProvider.renderAll(app,
                            AppWidgetManager.getInstance(app));
                } catch (Exception ignored) {
                }
            }
        };
        sHandler.postDelayed(sPending, 400);
    }
}
