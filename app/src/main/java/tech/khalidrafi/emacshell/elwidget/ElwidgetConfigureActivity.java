package tech.khalidrafi.emacshell.elwidget;

import android.app.Activity;
import android.appwidget.AppWidgetManager;
import android.content.Intent;
import android.os.Bundle;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.ListView;

import com.termux.R;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * The widget configuration screen: lists every spec Emacs has written
 * under ~/.emacs.d/elwidget/specs/ and binds the new Android widget to
 * the picked one (bindings.json, the same table the Elisp side
 * maintains).
 */
public class ElwidgetConfigureActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setResult(RESULT_CANCELED);

        Bundle extras = getIntent().getExtras();
        int widgetId = extras != null
                ? extras.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID,
                        AppWidgetManager.INVALID_APPWIDGET_ID)
                : AppWidgetManager.INVALID_APPWIDGET_ID;
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish();
            return;
        }

        setContentView(R.layout.elwidget_configure);
        ListView list = findViewById(R.id.elwidget_list);
        View empty = findViewById(R.id.elwidget_empty);

        ElwidgetFiles files = new ElwidgetFiles(this);
        Map<String, JSONObject> specs = files.readSpecs();
        List<String> names = new ArrayList<>(specs.keySet());
        Collections.sort(names);

        if (names.isEmpty()) {
            list.setVisibility(View.GONE);
            empty.setVisibility(View.VISIBLE);
            return;
        }

        List<String> rows = new ArrayList<>();
        for (String name : names) {
            JSONObject spec = specs.get(name);
            String title = spec != null ? spec.optString("title", name) : name;
            JSONArray size = spec != null ? spec.optJSONArray("size") : null;
            String suffix = size != null && size.length() == 2
                    ? "  " + size.optInt(0) + "x" + size.optInt(1)
                    : "";
            rows.add(title + suffix);
        }

        list.setAdapter(new ArrayAdapter<>(this,
                android.R.layout.simple_list_item_1, rows));
        list.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override
            public void onItemClick(AdapterView<?> parent, View view,
                                    int position, long id) {
                Map<Integer, String> bindings = files.readBindings();
                bindings.put(widgetId, names.get(position));
                files.writeBindings(bindings);
                ElwidgetWatcher.ensure(ElwidgetConfigureActivity.this);

                Intent result = new Intent();
                result.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId);
                setResult(RESULT_OK, result);
                finish();
            }
        });
    }
}
