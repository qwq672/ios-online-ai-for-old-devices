package com.awa.aichat.ui;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import com.awa.aichat.R;
import com.awa.aichat.util.ThemeManager;

/**
 * Settings screen — API Key, Base URL, Model, System Prompt, plus
 * v0.2 additions:
 *  - Theme mode (Auto / Light / Dark)
 *  - Temperature slider
 *  - Max tokens
 *  - Stream toggle
 *  - Reset-to-defaults button
 *
 * Stored in SharedPreferences ("aichat_prefs"), shared with ChatActivity.
 */
public class SettingsActivity extends Activity {

    private static final String PREFS = "aichat_prefs";
    private static final String KEY_API_KEY = "api_key";
    private static final String KEY_BASE_URL = "base_url";
    private static final String KEY_MODEL = "model";
    private static final String KEY_SYSTEM_PROMPT = "system_prompt";
    private static final String KEY_TEMPERATURE = "temperature";
    private static final String KEY_MAX_TOKENS = "max_tokens";
    private static final String KEY_STREAM = "stream";
    private static final String KEY_STREAMING_INTERVAL = "streamingInterval";  // v0.6: 流式刷新频率
    private static final String KEY_DEEP_THINKING = "deep_thinking";  // v0.6: 深度思考
    private static final String KEY_WEB_SEARCH = "web_search";  // v0.6: 联网搜索

    private EditText apiKeyField, baseURLField, modelField, promptField, maxTokensField;
    private SeekBar temperatureSeek, intervalSeek;  // v0.6: intervalSeek
    private TextView temperatureLabel, intervalLabel;  // v0.6: intervalLabel
    private CheckBox streamCheckBox, deepThinkingCheckBox, webSearchCheckBox;  // v0.6
    private CheckBox _mbedtlsCheckBox;  // v261116-7: nullable (仅当 native 支持)
    private String _useMbedTlsKey;
    private Spinner themeSpinner;
    private Button saveButton, resetButton, exportButton, importButton;  // v0.6: 导出/导入

    private SharedPreferences prefs;
    private int pendingThemeMode; // user's selection in the spinner (saved on Save)

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        ThemeManager.applyTheme(this);
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_settings);

        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        apiKeyField = (EditText) findViewById(R.id.apiKeyField);
        baseURLField = (EditText) findViewById(R.id.baseURLField);
        modelField = (EditText) findViewById(R.id.modelField);
        promptField = (EditText) findViewById(R.id.promptField);
        maxTokensField = (EditText) findViewById(R.id.maxTokensField);
        temperatureSeek = (SeekBar) findViewById(R.id.temperatureSeek);
        temperatureLabel = (TextView) findViewById(R.id.temperatureLabel);
        streamCheckBox = (CheckBox) findViewById(R.id.streamCheckBox);
        themeSpinner = (Spinner) findViewById(R.id.themeSpinner);
        saveButton = (Button) findViewById(R.id.saveButton);
        resetButton = (Button) findViewById(R.id.clearChatButton);

        // v0.6: 新增控件（动态创建，不改 XML）
        // 流式刷新频率
        intervalSeek = new SeekBar(this);
        intervalLabel = new TextView(this);
        intervalSeek.setMax(840);  // 160-1000ms，范围 840
        int intervalMs = prefs.getInt(KEY_STREAMING_INTERVAL, 300);
        intervalSeek.setProgress(intervalMs - 160);
        updateIntervalLabel(intervalMs);

        // 深度思考 + 联网搜索
        deepThinkingCheckBox = new CheckBox(this);
        deepThinkingCheckBox.setText("深度思考");
        deepThinkingCheckBox.setChecked(prefs.getBoolean(KEY_DEEP_THINKING, false));

        webSearchCheckBox = new CheckBox(this);
        webSearchCheckBox.setText("联网搜索");
        webSearchCheckBox.setChecked(prefs.getBoolean(KEY_WEB_SEARCH, false));

        // 导出/导入对话
        exportButton = new Button(this);
        exportButton.setText("导出对话");
        importButton = new Button(this);
        importButton.setText("导入对话（从剪贴板）");

        // 把新控件加到布局里（动态加到 saveButton 前面）
        LinearLayout mainLayout = (LinearLayout) saveButton.getParent();
        int saveIdx = mainLayout.indexOfChild(saveButton);

        // 流式频率
        LinearLayout intervalLayout = new LinearLayout(this);
        intervalLayout.setOrientation(LinearLayout.HORIZONTAL);
        intervalLabel.setPadding(8, 0, 8, 0);
        intervalLabel.setGravity(android.view.Gravity.CENTER_VERTICAL);
        intervalLayout.addView(intervalLabel, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 0.3f));
        intervalLayout.addView(intervalSeek, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 0.7f));
        mainLayout.addView(intervalLayout, saveIdx);

        // 深度思考 + 联网搜索（水平排列）
        LinearLayout toggleLayout = new LinearLayout(this);
        toggleLayout.setOrientation(LinearLayout.HORIZONTAL);
        toggleLayout.addView(deepThinkingCheckBox, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        toggleLayout.addView(webSearchCheckBox, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        mainLayout.addView(toggleLayout, saveIdx + 1);

        // v261116-7: mbedTLS 切换（仅当 native 库支持时显示）
        // v261116-8: 修复 saveIdx 计数 — 用 insertIdx 变量动态计算
        int insertIdx = saveIdx + 2;
        if (com.awa.aichat.network.MbedTLSClient.hasMbedTLS()) {
            CheckBox mbedtlsCheckBox = new CheckBox(this);
            mbedtlsCheckBox.setText("使用 mbedTLS (Android 2.3 TLS 1.2)");
            mbedtlsCheckBox.setChecked(prefs.getBoolean("use_mbedtls", false));
            mainLayout.addView(mbedtlsCheckBox, insertIdx);
            _mbedtlsCheckBox = mbedtlsCheckBox;
            _useMbedTlsKey = "use_mbedtls";
            insertIdx++;
        }

        // 导出/导入（水平排列）
        LinearLayout ioLayout = new LinearLayout(this);
        ioLayout.setOrientation(LinearLayout.HORIZONTAL);
        ioLayout.addView(exportButton, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        ioLayout.addView(importButton, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        mainLayout.addView(ioLayout, insertIdx);

        // intervalSeek 回调
        intervalSeek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onStartTrackingTouch(SeekBar sb) {}
            @Override public void onStopTrackingTouch(SeekBar sb) {}
            @Override
            public void onProgressChanged(SeekBar sb, int progress, boolean fromUser) {
                updateIntervalLabel(progress + 160);
            }
        });

        // 导出按钮
        exportButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                exportConversations();
            }
        });

        // 导入按钮
        importButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                importConversations();
            }
        });

        // Load existing values
        apiKeyField.setText(prefs.getString(KEY_API_KEY, ""));
        baseURLField.setText(prefs.getString(KEY_BASE_URL, "https://api.openai.com/v1"));
        modelField.setText(prefs.getString(KEY_MODEL, "gpt-3.5-turbo"));
        promptField.setText(prefs.getString(KEY_SYSTEM_PROMPT, "You are a helpful assistant."));
        int maxTok = prefs.getInt(KEY_MAX_TOKENS, 0);
        maxTokensField.setText(String.valueOf(maxTok));
        streamCheckBox.setChecked(prefs.getBoolean(KEY_STREAM, true));

        // Temperature: stored as float (0.0 - 2.0), seek bar is 0..20 (step 0.1).
        float temp = prefs.getFloat(KEY_TEMPERATURE, 0.7f);
        int seekProgress = Math.round(temp * 10f);
        if (seekProgress < 0) seekProgress = 0;
        if (seekProgress > 20) seekProgress = 20;
        temperatureSeek.setMax(20);
        temperatureSeek.setProgress(seekProgress);
        updateTemperatureLabel(seekProgress);

        temperatureSeek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onStartTrackingTouch(SeekBar sb) {}
            @Override public void onStopTrackingTouch(SeekBar sb) {}
            @Override
            public void onProgressChanged(SeekBar sb, int progress, boolean fromUser) {
                updateTemperatureLabel(progress);
            }
        });

        // Theme spinner
        final String[] themeLabels = new String[] {
            ThemeManager.modeLabel(ThemeManager.THEME_AUTO),
            ThemeManager.modeLabel(ThemeManager.THEME_LIGHT),
            ThemeManager.modeLabel(ThemeManager.THEME_DARK)
        };
        ArrayAdapter<String> themeAdapter = new ArrayAdapter<String>(this,
            android.R.layout.simple_spinner_item, themeLabels);
        themeAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        themeSpinner.setAdapter(themeAdapter);
        pendingThemeMode = ThemeManager.getThemeMode(this);
        themeSpinner.setSelection(pendingThemeMode);
        themeSpinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override public void onNothingSelected(AdapterView<?> parent) {}
            @Override
            public void onItemSelected(AdapterView<?> parent, View view, int pos, long id) {
                pendingThemeMode = pos; // matches the THEME_* constants
            }
        });

        // v0.6.5: 主题色选择（6 预设色）
        // v261116-8: 修复 Java 1.7 编译错误 — 内部类访问局部变量必须 final
        final Button colorPickerBtn = new Button(this);
        colorPickerBtn.setText("主题色: " + ThemeManager.getColorName(ThemeManager.getAccentColorIndex(this)));
        colorPickerBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                final String[] names = ThemeManager.getColorNames();
                int current = ThemeManager.getAccentColorIndex(SettingsActivity.this);
                new AlertDialog.Builder(SettingsActivity.this)
                    .setTitle("选择主题色")
                    .setSingleChoiceItems(names, current, new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface d, int which) {
                            ThemeManager.setAccentColorIndex(SettingsActivity.this, which);
                            colorPickerBtn.setText("主题色: " + names[which]);
                            Toast.makeText(SettingsActivity.this, "主题色已切换，返回后生效", Toast.LENGTH_SHORT).show();
                            d.dismiss();
                        }
                    })
                    .setNegativeButton("取消", null)
                    .show();
            }
        });
        // 加到主题下方（找 themeSpinner 父布局）
        try {
            if (themeSpinner.getParent() instanceof android.view.ViewGroup) {
                ((android.view.ViewGroup) themeSpinner.getParent()).addView(colorPickerBtn);
            }
        } catch (Exception e) {
            android.util.Log.w("Settings", "color picker add failed: " + e.getMessage());
        }

        saveButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                saveAll();
                Toast.makeText(SettingsActivity.this, "已保存", Toast.LENGTH_SHORT).show();
                finish();
            }
        });

        resetButton.setText("重置设置");
        resetButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                new AlertDialog.Builder(SettingsActivity.this)
                    .setTitle("重置设置")
                    .setMessage("将清空 API Key 等所有设置，确定继续吗？")
                    .setPositiveButton("重置", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface d, int w) {
                            SharedPreferences.Editor ed = prefs.edit();
                            ed.clear();
                            ed.commit();
                            Toast.makeText(SettingsActivity.this, "已重置", Toast.LENGTH_SHORT).show();
                            // Reload UI fields with defaults
                            apiKeyField.setText("");
                            baseURLField.setText("https://api.openai.com/v1");
                            modelField.setText("gpt-3.5-turbo");
                            promptField.setText("You are a helpful assistant.");
                            maxTokensField.setText("0");
                            streamCheckBox.setChecked(true);
                            temperatureSeek.setProgress(7);
                            updateTemperatureLabel(7);
                            themeSpinner.setSelection(ThemeManager.THEME_AUTO);
                            pendingThemeMode = ThemeManager.THEME_AUTO;
                        }
                    })
                    .setNegativeButton("取消", null)
                    .show();
            }
        });
    }

    private void updateTemperatureLabel(int progress) {
        float t = progress / 10f;
        temperatureLabel.setText(String.format(java.util.Locale.US, "%.1f", t));
    }

    // v0.6: 流式频率标签
    private void updateIntervalLabel(int ms) {
        if (ms < 160) ms = 160;
        if (ms > 1000) ms = 1000;
        intervalLabel.setText(ms + "ms");
    }

    // v0.6: 导出对话（剪贴板）
    private void exportConversations() {
        String savedJson = prefs.getString("saved_messages", "");
        String json = "{\"version\":1,\"conversations\":[{\"id\":\"android\",\"title\":\"\u5bfc\u51fa\u5bf9\u8bdd\",\"messages\":" + (savedJson.length() > 0 ? savedJson : "[]") + "}]}";
        android.content.ClipboardManager clip = (android.content.ClipboardManager) getSystemService(android.content.Context.CLIPBOARD_SERVICE);
        clip.setText(json);
        Toast.makeText(this, "\u5bf9\u8bdd\u5df2\u5bfc\u51fa\u5230\u526a\u8d34\u677f\uff08" + json.length() + " \u5b57\u7b26\uff09", Toast.LENGTH_LONG).show();
    }

    // v0.6: 导入对话（从剪贴板）
    private void importConversations() {
        android.content.ClipboardManager clip = (android.content.ClipboardManager) getSystemService(android.content.Context.CLIPBOARD_SERVICE);
        CharSequence text = clip.getText();
        if (text == null || text.length() == 0) {
            Toast.makeText(this, "\u526a\u8d34\u677f\u4e3a\u7a7a", Toast.LENGTH_SHORT).show();
            return;
        }
        String json = text.toString();
        if (!json.startsWith("{") || !json.contains("\"messages\"")) {
            Toast.makeText(this, "\u526a\u8d34\u677f\u5185\u5bb9\u4e0d\u662f\u6709\u6548\u7684\u5bf9\u8bdd JSON", Toast.LENGTH_SHORT).show();
            return;
        }
        String messagesJson = extractMessagesArray(json);
        if (messagesJson == null) {
            Toast.makeText(this, "\u65e0\u6cd5\u89e3\u6790 messages \u5b57\u6bb5", Toast.LENGTH_SHORT).show();
            return;
        }
        SharedPreferences.Editor ed = prefs.edit();
        ed.putString("saved_messages", messagesJson);
        ed.apply();
        Toast.makeText(this, "\u5bf9\u8bdd\u5df2\u5bfc\u5165\uff08\u91cd\u542f app \u540e\u751f\u6548\uff09", Toast.LENGTH_LONG).show();
    }

    // v0.6.4: 从外层 JSON 提取 messages 数组字符串
    private String extractMessagesArray(String json) {
        try {
            org.json.JSONObject root = new org.json.JSONObject(json);
            if (root.has("conversations")) {
                org.json.JSONArray convs = root.getJSONArray("conversations");
                if (convs.length() > 0) {
                    org.json.JSONObject first = convs.getJSONObject(0);
                    if (first.has("messages")) {
                        return first.getJSONArray("messages").toString();
                    }
                }
            }
            if (root.has("messages")) {
                return root.getJSONArray("messages").toString();
            }
            return null;
        } catch (Exception e) {
            return null;
        }
    }

    private void saveAll() {
        SharedPreferences.Editor ed = prefs.edit();
        ed.putString(KEY_API_KEY, apiKeyField.getText().toString().trim());
        ed.putString(KEY_BASE_URL, baseURLField.getText().toString().trim());
        ed.putString(KEY_MODEL, modelField.getText().toString().trim());
        ed.putString(KEY_SYSTEM_PROMPT, promptField.getText().toString().trim());
        ed.putBoolean(KEY_STREAM, streamCheckBox.isChecked());
        ed.putInt(KEY_MAX_TOKENS, parseIntSafe(maxTokensField.getText().toString().trim(), 0));
        float temp = temperatureSeek.getProgress() / 10f;
        ed.putFloat(KEY_TEMPERATURE, temp);
        ed.putInt("theme_mode", pendingThemeMode);
        // v0.6: 新增设置
        ed.putInt(KEY_STREAMING_INTERVAL, intervalSeek.getProgress() + 160);
        ed.putBoolean(KEY_DEEP_THINKING, deepThinkingCheckBox.isChecked());
        ed.putBoolean(KEY_WEB_SEARCH, webSearchCheckBox.isChecked());
        if (_mbedtlsCheckBox != null && _useMbedTlsKey != null) {
            ed.putBoolean(_useMbedTlsKey, _mbedtlsCheckBox.isChecked());
        }
        ed.commit();
    }

    private static int parseIntSafe(String s, int def) {
        if (s == null || s.length() == 0) return def;
        try {
            return Integer.parseInt(s);
        } catch (NumberFormatException e) {
            return def;
        }
    }
}
