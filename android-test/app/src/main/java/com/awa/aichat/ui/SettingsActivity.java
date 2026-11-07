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

    private EditText apiKeyField, baseURLField, modelField, promptField, maxTokensField;
    private SeekBar temperatureSeek;
    private TextView temperatureLabel;
    private CheckBox streamCheckBox;
    private Spinner themeSpinner;
    private Button saveButton, resetButton;

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
        // Use Locale.US so the decimal separator is always "." and the
        // digits are always 0-9 (some default locales produce Arabic
        // numerals which look weird in a tiny label).
        temperatureLabel.setText(String.format(java.util.Locale.US, "%.1f", t));
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
        // putFloat takes a float; cast to (float) for Java 7 compat.
        ed.putFloat(KEY_TEMPERATURE, temp);
        ed.putInt("theme_mode", pendingThemeMode);
        ed.commit();
        // Also write through ThemeManager so it takes effect immediately
        // (the same SharedPreferences key — ThemeManager reads it).
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
