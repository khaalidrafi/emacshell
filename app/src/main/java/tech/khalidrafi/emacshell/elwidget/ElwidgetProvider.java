package tech.khalidrafi.emacshell.elwidget;

import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.util.Log;
import android.widget.RemoteViews;

import com.termux.R;

import org.json.JSONObject;

import java.util.Map;

/**
 * The AppWidget host for Emacs-defined widgets (the elwidget package).
 *
 * Three provider declarations (4x1, 4x2, 4x3) share this behaviour
 * through the thin ElwidgetProvider4x{1,2,3} subclasses -- the manifest
 * merger rejects one receiver class declared three times.  Each bound
 * Android widget renders the spec Emacs wrote for it and sends taps
 * back down the file contract (events.jsonl) where Emacs drains them.
 * "open" taps foreground Emacs first, as the elwidget README documents.
 */
public class ElwidgetProvider extends AppWidgetProvider {

    /** The declared receiver classes, smallest first. */
    static final Class<?>[] PROVIDER_CLASSES = {
            ElwidgetProvider4x1.class,
            ElwidgetProvider4x2.class,
            ElwidgetProvider4x3.class,
    };

    public static final String ACTION_TAP =
            "tech.khalidrafi.emacshell.elwidget.ACTION_TAP";
    public static final String ACTION_REFRESH =
            "tech.khalidrafi.emacshell.elwidget.ACTION_REFRESH";

    public static final String EXTRA_APPWIDGET_ID = "appWidgetId";
    public static final String EXTRA_SPEC = "spec";
    public static final String EXTRA_ACTION = "action";
    public static final String EXTRA_ARG = "arg";

    private static final String TAG = "ElwidgetProvider";

    @Override
    public void onUpdate(Context context, AppWidgetManager manager,
                         int[] appWidgetIds) {
        ElwidgetWatcher.ensure(context);
        renderAll(context, manager);
    }

    @Override
    public void onDeleted(Context context, int[] appWidgetIds) {
        ElwidgetFiles files = new ElwidgetFiles(context);
        Map<Integer, String> bindings = files.readBindings();
        boolean changed = false;
        for (int id : appWidgetIds)
            changed |= bindings.remove(id) != null;
        if (changed)
            files.writeBindings(bindings);
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        super.onReceive(context, intent);
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_TAP.equals(action))
            handleTap(context, intent);
        else if (ACTION_REFRESH.equals(action))
            renderAll(context, AppWidgetManager.getInstance(context));
    }

    private void handleTap(Context context, Intent intent) {
        int widgetId = intent.getIntExtra(EXTRA_APPWIDGET_ID, -1);
        String spec = intent.getStringExtra(EXTRA_SPEC);
        String action = intent.getStringExtra(EXTRA_ACTION);
        String arg = intent.getStringExtra(EXTRA_ARG);
        Log.d(TAG, "tap " + widgetId + " " + spec + " " + action + " " + arg);

        if ("open".equals(action)) {
            // The elwidget contract: an "open" tap foregrounds Emacs;
            // the queued event then tells the handler what to open.
            Intent launch = context.getPackageManager()
                    .getLaunchIntentForPackage(context.getPackageName());
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                try {
                    context.startActivity(launch);
                } catch (Exception e) {
                    Log.w(TAG, "launch Emacs: " + e.getMessage());
                }
            }
        }

        if (spec == null || action == null)
            return;
        ElwidgetFiles files = new ElwidgetFiles(context);
        files.appendEvent(spec, action, arg);
        if (arg == null || arg.isEmpty())
            return;
        // Instant feedback while Emacs is frozen in the background:
        // toggles flip the check 0<->1, stepper taps bump the numeric
        // state by one (floored at zero).  The queued event makes the
        // Emacs side authoritative on the next sync.
        if ("toggle".equals(action))
            files.flipState(arg);
        else if ("inc".equals(action))
            files.bumpState(arg, 1);
        else if ("dec".equals(action))
            files.bumpState(arg, -1);
        renderAll(context, AppWidgetManager.getInstance(context));
    }

    /** Re-render every widget that has a binding to an existing spec. */
    public static void renderAll(Context context, AppWidgetManager manager) {
        if (manager == null)
            return;
        ElwidgetFiles files = new ElwidgetFiles(context);
        Map<Integer, String> bindings = files.readBindings();
        if (bindings.isEmpty())
            return;
        Map<String, JSONObject> specs = files.readSpecs();
        Map<String, Object> state = files.readState();
        // Collect widget ids across ALL declared size subclasses; the
        // base class itself is not a manifest component.
        java.util.List<Integer> bound = new java.util.ArrayList<>();
        for (Class<?> provider : PROVIDER_CLASSES)
            for (int id : manager.getAppWidgetIds(
                    new ComponentName(context, provider)))
                bound.add(id);
        for (int id : bound) {
            String name = bindings.get(id);
            if (name == null)
                continue;
            RemoteViews views;
            JSONObject spec = specs.get(name);
            if (spec != null)
                views = new ElwidgetRenderer(context, id, name, state)
                        .render(spec);
            else
                views = missingSpecViews(context, name);
            if (views != null)
                manager.updateAppWidget(id, views);
        }
    }

    /** Placeholder for a binding whose spec Emacs has not written. */
    private static RemoteViews missingSpecViews(Context context, String name) {
        RemoteViews rv = new RemoteViews(context.getPackageName(),
                R.layout.elwidget_fallback);
        try {
            rv.setTextViewText(R.id.elwidget_fallback_title, name);
        } catch (Exception ignored) {
        }
        rv.setTextColor(R.id.elwidget_fallback_title, 0xffa6adc8);
        rv.setInt(R.id.elwidget_fallback_root, "setBackgroundColor",
                0xff1e1e2e);
        rv.setTextViewText(R.id.elwidget_fallback_hint,
                "Open Emacs and run M-x elwidget-refresh");
        rv.setTextColor(R.id.elwidget_fallback_hint, 0xffa6adc8);
        return rv;
    }
}
