package tech.khalidrafi.emacshell.elwidget;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.Build;
import android.text.Html;
import android.util.TypedValue;
import android.view.Gravity;
import android.widget.RemoteViews;

import com.termux.R;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Map;

/**
 * Draws one elwidget spec (the JSON the Elisp side wrote) as Android
 * RemoteViews.
 *
 * API 31+ builds a real view tree with RemoteViews.addView and gives
 * every check/button its own tap PendingIntent.  API 24-30 (addView
 * does not exist there) falls back to a Canvas-rendered bitmap of the
 * whole tree with a single tap target (open Emacs); the display is
 * identical, only per-node taps are lost.  See the elwidget README,
 * "Why not arbitrary layouts".
 */
final class ElwidgetRenderer {

    private static final String[] CHECK_GLYPHS =
            {"\u2713", "", "\u2192", "?"};   // on, off, skip, unknown

    private final Context context;
    private final String pkg;
    private final int widgetId;
    private final String specName;
    private final Map<String, Object> state;
    private int fg;
    private int bg;

    ElwidgetRenderer(Context context, int widgetId, String specName,
                     Map<String, Object> state) {
        this.context = context;
        this.pkg = context.getPackageName();
        this.widgetId = widgetId;
        this.specName = specName;
        this.state = state;
    }

    /** Render one spec document into RemoteViews (never null). */
    RemoteViews render(JSONObject spec) {
        fg = parseColor(spec.optString("fg", "#cdd6f4"), 0xffcdd6f4);
        bg = parseColor(spec.optString("bg", "#1e1e2e"), 0xff1e1e2e);
        if (Build.VERSION.SDK_INT >= 31)
            return renderTree(spec);
        return renderBitmapFallback(spec);
    }

    /* ---------------- API 31+: the RemoteViews tree ---------------- */

    private RemoteViews renderTree(JSONObject spec) {
        RemoteViews root = new RemoteViews(pkg, R.layout.elwidget_widget);
        root.setInt(R.id.elwidget_root, "setBackgroundColor", bg);
        JSONArray children = spec.optJSONArray("children");
        if (children != null)
            for (int i = 0; i < children.length(); i++) {
                JSONObject node = children.optJSONObject(i);
                if (node != null)
                    root.addView(R.id.elwidget_column, buildNode(node, true));
            }
        return root;
    }

    private RemoteViews buildNode(JSONObject node, boolean inColumn) {
        String type = node.optString("type", "");
        switch (type) {
            case "text":
                return textNode(node, inColumn);
            case "row":
                return containerNode(node, R.layout.elwidget_node_row,
                        R.id.elwidget_row, false);
            case "column":
                return containerNode(node, R.layout.elwidget_node_column,
                        R.id.elwidget_column_inner, true);
            case "check":
                return checkNode(node);
            case "button":
                return buttonNode(node);
            case "progress":
                return progressNode(node);
            case "bar":
                return barNode(node);
            case "gap":
                return new RemoteViews(pkg, R.layout.elwidget_node_gap);
            default:
                RemoteViews unknown = textNode(new JSONObject(), true);
                try {
                    unknown.setTextViewText(R.id.elwidget_text,
                            "<?" + type + ">");
                } catch (Exception ignored) {
                }
                return unknown;
        }
    }

    private RemoteViews textNode(JSONObject node, boolean inColumn) {
        String align = node.optString("align", "left");
        boolean wide = inColumn && !"left".equals(align);
        RemoteViews rv = new RemoteViews(pkg, wide
                ? R.layout.elwidget_node_text_wide
                : R.layout.elwidget_node_text);
        String text = node.optString("text", "");
        try {
            if (node.optBoolean("bold", false))
                rv.setTextViewText(R.id.elwidget_text,
                        Html.fromHtml("<b>" + htmlEscape(text) + "</b>",
                                Html.FROM_HTML_MODE_LEGACY));
            else
                rv.setTextViewText(R.id.elwidget_text, text);
        } catch (Exception e) {
            rv.setTextViewText(R.id.elwidget_text, text);
        }
        rv.setTextColor(R.id.elwidget_text,
                parseColor(node.optString("color", ""), fg));
        double size = node.optDouble("size", 13);
        rv.setTextViewTextSize(R.id.elwidget_text,
                TypedValue.COMPLEX_UNIT_SP, (float) size);
        int gravity = Gravity.LEFT | Gravity.CENTER_VERTICAL;
        if ("center".equals(align))
            gravity = Gravity.CENTER_HORIZONTAL | Gravity.CENTER_VERTICAL;
        else if ("right".equals(align))
            gravity = Gravity.RIGHT | Gravity.CENTER_VERTICAL;
        rv.setInt(R.id.elwidget_text, "setGravity", gravity);
        return rv;
    }

    private RemoteViews containerNode(JSONObject node, int layout,
                                      int containerId, boolean childrenInColumn) {
        RemoteViews rv = new RemoteViews(pkg, layout);
        JSONArray children = node.optJSONArray("children");
        if (children != null)
            for (int i = 0; i < children.length(); i++) {
                JSONObject child = children.optJSONObject(i);
                if (child != null)
                    rv.addView(containerId, buildNode(child, childrenInColumn));
            }
        return rv;
    }

    private RemoteViews checkNode(JSONObject node) {
        RemoteViews rv = new RemoteViews(pkg, R.layout.elwidget_node_check);
        String stateKey = shadowState(node);
        int glyph = glyphFor(stateKey != null ? stateKey
                : node.optString("state", "off"));
        int color = parseColor(node.optString("color", ""), fg);
        String label = node.optString("label", "");
        String shown = glyph >= 0 ? CHECK_GLYPHS[glyph] : label;
        try {
            rv.setTextViewText(R.id.elwidget_check, shown);
        } catch (Exception ignored) {
        }
        rv.setTextColor(R.id.elwidget_check,
                glyph == 0 ? color : dim(color));
        rv.setOnClickPendingIntent(R.id.elwidget_check,
                tapPI(node.optString("action", "toggle"),
                        node.optString("arg", "")));
        return rv;
    }

    private RemoteViews buttonNode(JSONObject node) {
        RemoteViews rv = new RemoteViews(pkg, R.layout.elwidget_node_button);
        try {
            rv.setTextViewText(R.id.elwidget_button, node.optString("label", ""));
        } catch (Exception ignored) {
        }
        rv.setTextColor(R.id.elwidget_button,
                parseColor(node.optString("color", ""), fg));
        rv.setOnClickPendingIntent(R.id.elwidget_button,
                tapPI(node.optString("action", "open"),
                        node.optString("arg", "")));
        return rv;
    }

    private RemoteViews progressNode(JSONObject node) {
        RemoteViews rv = new RemoteViews(pkg, R.layout.elwidget_node_progress);
        int max = Math.max(1, node.optInt("max", 1));
        int value = node.optInt("value", 0);
        rv.setProgressBar(R.id.elwidget_progress, max, value, false);
        String label = node.optString("label", "");
        try {
            rv.setTextViewText(R.id.elwidget_label, label);
        } catch (Exception ignored) {
        }
        rv.setTextColor(R.id.elwidget_label,
                parseColor(node.optString("color", ""), fg));
        rv.setInt(R.id.elwidget_label, "setVisibility",
                label.isEmpty() ? android.view.View.GONE
                        : android.view.View.VISIBLE);
        return rv;
    }

    private RemoteViews barNode(JSONObject node) {
        RemoteViews rv = new RemoteViews(pkg, R.layout.elwidget_node_bar);
        rv.setInt(R.id.elwidget_bar, "setBackgroundColor",
                parseColor(node.optString("color", ""), fg));
        return rv;
    }

    private PendingIntent tapPI(String action, String arg) {
        Intent intent = new Intent(context, ElwidgetProvider.class);
        intent.setAction(ElwidgetProvider.ACTION_TAP);
        intent.putExtra(ElwidgetProvider.EXTRA_APPWIDGET_ID, widgetId);
        intent.putExtra(ElwidgetProvider.EXTRA_SPEC, specName);
        intent.putExtra(ElwidgetProvider.EXTRA_ACTION, action);
        intent.putExtra(ElwidgetProvider.EXTRA_ARG, arg);
        int requestCode = (specName + "\u0000" + action + "\u0000" + arg
                + "\u0000" + widgetId).hashCode();
        return PendingIntent.getBroadcast(context, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    /**
     * The shadow state overrides the spec for toggle taps: state.json
     * is flipped the moment the user taps, before Emacs re-renders.
     */
    private String shadowState(JSONObject node) {
        if (!"toggle".equals(node.optString("action", "")))
            return null;
        Object value = state.get(node.optString("arg", ""));
        if (value == null)
            return null;
        if (Integer.valueOf(1).equals(value) || "1".equals(value))
            return "on";
        if (Integer.valueOf(0).equals(value) || "0".equals(value))
            return "off";
        return null;
    }

    private static int glyphFor(String state) {
        switch (state) {
            case "on": return 0;
            case "off": return 1;
            case "skip": return 2;
            case "unknown": return 3;
            default: return -1;
        }
    }

    /* ------------- API 24-30: the bitmap fallback ------------------ */

    private RemoteViews renderBitmapFallback(JSONObject spec) {
        RemoteViews rv = new RemoteViews(pkg, R.layout.elwidget_fallback);
        try {
            rv.setTextViewText(R.id.elwidget_fallback_title,
                    spec.optString("title", specName));
        } catch (Exception ignored) {
        }
        rv.setTextColor(R.id.elwidget_fallback_title, fg);
        rv.setInt(R.id.elwidget_fallback_root, "setBackgroundColor", bg);
        rv.setImageViewBitmap(R.id.elwidget_fallback_image, drawBitmap(spec));
        rv.setOnClickPendingIntent(R.id.elwidget_fallback_image, openPI());
        return rv;
    }

    private PendingIntent openPI() {
        Intent launch = context.getPackageManager()
                .getLaunchIntentForPackage(pkg);
        if (launch == null)
            return null;
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return PendingIntent.getActivity(context, specName.hashCode(), launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    /** Simple vertical canvas layout of the node tree. */
    private Bitmap drawBitmap(JSONObject spec) {
        int width = Math.max(320, dp(280));
        Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        JSONArray children = spec.optJSONArray("children");
        int count = children == null ? 0 : children.length();

        // Pass 1: measure.
        float x = dp(8), y = dp(8);
        float[][] boxes = new float[count][4];   // x, y, w, h
        for (int i = 0; i < count; i++) {
            JSONObject node = children.optJSONObject(i);
            if (node == null)
                continue;
            paint.setTextSize(textSizePx(node.optDouble("size", 13)));
            String text = nodeText(node);
            float w = paint.measureText(text == null ? "" : text);
            float h = "check".equals(node.optString("type", ""))
                    ? dp(30) : textSizePx(node.optDouble("size", 13)) * 1.4f;
            boxes[i][0] = x;
            boxes[i][1] = y;
            boxes[i][2] = Math.max(w, dp(12));
            boxes[i][3] = h;
            y += h + dp(3);
        }
        int height = Math.max(dp(40), (int) (y + dp(6)));

        // Pass 2: draw.
        Bitmap bitmap = Bitmap.createBitmap(width, height,
                Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        canvas.drawColor(bg);
        for (int i = 0; i < count; i++) {
            JSONObject node = children.optJSONObject(i);
            if (node == null)
                continue;
            String type = node.optString("type", "");
            String text = nodeText(node);
            if (text == null)
                continue;
            int color = parseColor(node.optString("color", ""), fg);
            paint.setColor(color);
            paint.setTextSize(textSizePx(node.optDouble("size", 13)));
            paint.setFakeBoldText(node.optBoolean("bold", false));
            if ("check".equals(type)) {
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(dp(1.5f));
                RectF box = new RectF(boxes[i][0], boxes[i][1],
                        boxes[i][0] + dp(24), boxes[i][1] + dp(24));
                canvas.drawRoundRect(box, dp(5), dp(5), paint);
                paint.setStyle(Paint.Style.FILL);
                if ("on".equals(node.optString("state", "")))
                    canvas.drawText("\u2713", boxes[i][0] + dp(6),
                            boxes[i][1] + dp(18), paint);
            } else {
                canvas.drawText(text, boxes[i][0],
                        boxes[i][1] + textSizePx(node.optDouble("size", 13)),
                        paint);
            }
        }
        paint.setFakeBoldText(false);
        return bitmap;
    }

    /** Display text for a node in the fallback bitmap. */
    private static String nodeText(JSONObject node) {
        switch (node.optString("type", "")) {
            case "text": return node.optString("text", "");
            case "button": return "[" + node.optString("label", "") + "]";
            case "check": return "  " + node.optString("label", "");
            case "progress":
                return node.optString("label",
                        node.optInt("value", 0) + "/" + node.optInt("max", 0));
            case "bar": return "";
            case "gap": return null;
            default: return "";
        }
    }

    private float textSizePx(double sp) {
        return (float) (sp * context.getResources().getDisplayMetrics().scaledDensity);
    }

    private int dp(int value) {
        return Math.round(value * context.getResources().getDisplayMetrics().density);
    }

    private float dp(float value) {
        return value * context.getResources().getDisplayMetrics().density;
    }

    /* ---------------- shared helpers ---------------- */

    private static int parseColor(String color, int fallback) {
        if (color == null || color.isEmpty())
            return fallback;
        try {
            return Color.parseColor(color);
        } catch (Exception e) {
            return fallback;
        }
    }

    private static int dim(int color) {
        int r = (color >> 16) & 0xff, g = (color >> 8) & 0xff, b = color & 0xff;
        return 0xff000000 | ((r / 2) << 16) | ((g / 2) << 8) | (b / 2);
    }

    private static String htmlEscape(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;");
    }
}
