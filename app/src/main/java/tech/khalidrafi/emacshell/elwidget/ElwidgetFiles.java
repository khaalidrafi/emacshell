package tech.khalidrafi.emacshell.elwidget;

import android.content.Context;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * The elwidget file contract, shared with the Elisp side (see the
 * elwidget repository, README "Files (the Android contract)").
 *
 * Everything lives under HOME/.emacs.d/elwidget (HOME on the Android
 * port of Emacs is the app's files dir):
 *
 *   specs/NAME.json   written by Emacs; the rendered widget trees
 *   bindings.json     Android widget id -> spec name (both sides)
 *   state.json        instant-toggle shadow state (both sides)
 *   events.jsonl      tap queue, written here, drained by Emacs
 *   cursor.json       last event id Emacs drained
 *
 * All reads tolerate absent or malformed files: a fresh install (or
 * an Emacs that has not run yet) simply has no specs to show.
 */
public final class ElwidgetFiles {

    private static final String TAG = "ElwidgetFiles";

    /** Compact events.jsonl past this size (keeps id > cursor). */
    private static final long EVENT_FILE_SOFT_LIMIT = 256 * 1024;

    private final Context context;

    public ElwidgetFiles(Context context) {
        this.context = context.getApplicationContext();
    }

    public File root() {
        return new File(new File(context.getFilesDir(), ".emacs.d"), "elwidget");
    }

    public File specsDir() {
        return new File(root(), "specs");
    }

    public File bindingsFile() {
        return new File(root(), "bindings.json");
    }

    public File stateFile() {
        return new File(root(), "state.json");
    }

    public File eventsFile() {
        return new File(root(), "events.jsonl");
    }

    public File cursorFile() {
        return new File(root(), "cursor.json");
    }

    /** Spec name -> parsed spec JSON, for every specs/*.json on disk. */
    public Map<String, JSONObject> readSpecs() {
        Map<String, JSONObject> out = new TreeMap<>();
        File[] files = specsDir().listFiles();
        if (files == null)
            return out;
        for (File f : files) {
            String name = f.getName();
            if (!name.endsWith(".json"))
                continue;
            try {
                JSONObject spec = readJSONObject(f);
                if (spec != null)
                    out.put(name.substring(0, name.length() - 5), spec);
            } catch (Exception e) {
                Log.w(TAG, "Unreadable spec " + name + ": " + e.getMessage());
            }
        }
        return out;
    }

    /** Android widget id -> spec name, from bindings.json. */
    public Map<Integer, String> readBindings() {
        Map<Integer, String> out = new HashMap<>();
        JSONObject root = readJSONObject(bindingsFile());
        JSONArray bindings = root != null ? root.optJSONArray("bindings") : null;
        if (bindings == null)
            return out;
        for (int i = 0; i < bindings.length(); i++) {
            JSONArray pair = bindings.optJSONArray(i);
            if (pair != null && pair.length() >= 2)
                out.put(pair.optInt(0), pair.optString(1));
        }
        return out;
    }

    /** Persist bindings.json (widget id -> spec name). */
    public void writeBindings(Map<Integer, String> bindings) {
        JSONObject root = new JSONObject();
        JSONArray array = new JSONArray();
        for (Map.Entry<Integer, String> e : new TreeMap<>(bindings).entrySet())
            array.put(new JSONArray().put(e.getKey()).put(e.getValue()));
        try {
            root.put("bindings", array);
        } catch (Exception e) {
            Log.w(TAG, "writeBindings: " + e.getMessage());
            return;
        }
        writeJSONObject(root, bindingsFile());
    }

    /** The shadow state: arg string -> 0/1/other value. */
    public Map<String, Object> readState() {
        Map<String, Object> out = new HashMap<>();
        JSONObject root = readJSONObject(stateFile());
        if (root == null)
            return out;
        for (java.util.Iterator<String> it = root.keys(); it.hasNext(); ) {
            String key = it.next();
            out.put(key, root.opt(key));
        }
        return out;
    }

    /**
     * Flip the shadow value for ARG (0 <-> 1) so the check mark moves
     * the instant the user taps, while Emacs is still frozen in the
     * background.  The next Emacs sync is authoritative again.
     */
    public Object flipState(String arg) {
        JSONObject root = readJSONObject(stateFile());
        if (root == null)
            root = new JSONObject();
        Object current = root.opt(arg);
        Object next = Integer.valueOf(1).equals(current)
                || "1".equals(current) ? 0 : 1;
        try {
            root.put(arg, next);
        } catch (Exception e) {
            Log.w(TAG, "flipState: " + e.getMessage());
            return next;
        }
        writeJSONObject(root, stateFile());
        return next;
    }

    /**
     * Bump the numeric shadow value for ARG by DELTA (floored at
     * zero), the stepper counterpart of {@link #flipState(String)}:
     * "inc"/"dec" taps move the displayed number the instant the
     * user taps, while Emacs is still frozen in the background.  A
     * missing or non-numeric entry counts as zero; the next Emacs
     * sync writes the authoritative value again.
     */
    public Object bumpState(String arg, int delta) {
        JSONObject root = readJSONObject(stateFile());
        if (root == null)
            root = new JSONObject();
        double value = 0;
        Object current = root.opt(arg);
        if (current instanceof Number)
            value = ((Number) current).doubleValue();
        else if (current instanceof String)
            try {
                value = Double.parseDouble((String) current);
            } catch (NumberFormatException ignored) {
            }
        value = Math.max(0, value + delta);
        Object next = (value == Math.rint(value) && !Double.isInfinite(value))
                ? (Object) Long.valueOf((long) value)
                : (Object) Double.valueOf(value);
        try {
            root.put(arg, next);
        } catch (Exception e) {
            Log.w(TAG, "bumpState: " + e.getMessage());
            return next;
        }
        writeJSONObject(root, stateFile());
        return next;
    }

    /** Last event id Emacs drained (cursor.json), or 0. */
    public long readCursor() {
        JSONObject root = readJSONObject(cursorFile());
        return root != null ? root.optLong("id", 0) : 0;
    }

    /**
     * Append one tap event {"id":N,"spec":S,"action":A,"arg":G} to
     * events.jsonl with a monotonic id, and compact the file (keeping
     * everything Emacs has not drained yet) once it grows past
     * EVENT_FILE_SOFT_LIMIT.
     */
    public long appendEvent(String spec, String action, String arg) {
        File file = eventsFile();
        List<String> lines = readLines(file);
        long lastId = 0;
        for (String line : lines) {
            try {
                long id = new JSONObject(line).optLong("id", 0);
                if (id > lastId)
                    lastId = id;
            } catch (Exception ignored) {
            }
        }
        long id = lastId + 1;
        JSONObject event = new JSONObject();
        try {
            event.put("id", id);
            event.put("spec", spec);
            event.put("action", action);
            event.put("arg", arg == null ? "" : arg);
        } catch (Exception e) {
            Log.w(TAG, "appendEvent: " + e.getMessage());
            return id;
        }

        boolean oversized = file.isFile() && file.length() > EVENT_FILE_SOFT_LIMIT;
        long cursor = oversized ? readCursor() : Long.MIN_VALUE;

        File tmp = new File(file.getParentFile(), "events.jsonl.new");
        try (PrintWriter out = new PrintWriter(new FileWriter(tmp))) {
            if (oversized)
                for (String line : lines) {
                    try {
                        if (new JSONObject(line).optLong("id", 0) > cursor)
                            out.println(line);
                    } catch (Exception ignored) {
                    }
                }
            out.println(event.toString());
        } catch (IOException e) {
            Log.w(TAG, "appendEvent write: " + e.getMessage());
            tmp.delete();
            return id;
        }
        atomicRename(tmp, file);
        return id;
    }

    /** Read a whole file as one JSON object; null when absent/bad. */
    private JSONObject readJSONObject(File file) {
        if (!file.isFile())
            return null;
        try {
            return new JSONObject(readFile(file));
        } catch (Exception e) {
            return null;
        }
    }

    /** Write JSON atomically (tmp file + rename), like the Elisp side. */
    private void writeJSONObject(JSONObject object, File file) {
        File tmp = new File(file.getParentFile(), file.getName() + ".new");
        try (PrintWriter out = new PrintWriter(new FileWriter(tmp))) {
            out.println(object.toString());
        } catch (IOException e) {
            Log.w(TAG, "write " + file + ": " + e.getMessage());
            tmp.delete();
            return;
        }
        atomicRename(tmp, file);
    }

    private static String readFile(File file) throws IOException {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader in = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = in.readLine()) != null) {
                sb.append(line).append('\n');
            }
        }
        return sb.toString();
    }

    private static List<String> readLines(File file) {
        List<String> lines = new ArrayList<>();
        if (!file.isFile())
            return lines;
        try (BufferedReader in = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = in.readLine()) != null)
                lines.add(line);
        } catch (IOException e) {
            Log.w(TAG, "read " + file + ": " + e.getMessage());
        }
        return lines;
    }

    private static void atomicRename(File tmp, File dst) {
        if (!tmp.renameTo(dst)) {
            // Cross-filesystem or target-exists edge: last-resort copy.
            try (java.io.FileInputStream in = new java.io.FileInputStream(tmp);
                 java.io.FileOutputStream out = new java.io.FileOutputStream(dst)) {
                byte[] buffer = new byte[8192];
                int n;
                while ((n = in.read(buffer)) > 0)
                    out.write(buffer, 0, n);
            } catch (IOException e) {
                Log.w(TAG, "rename " + dst + ": " + e.getMessage());
            } finally {
                tmp.delete();
            }
        }
    }
}
