package com.awa.aichat.ui;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.Spinner;
import android.widget.Toast;

import com.awa.aichat.R;
import com.awa.aichat.util.ThemeManager;

/**
 * Settings screen — API Key, Base URL, Model, System Prompt,
 * dark mode, font size, streaming, deep thinking.
 */
public class SettingsActivity extends Activity {

    private static final String PREFS = "aichat_prefs";
    private static final String KEY_API_KEY = "api_key";
    private static final String KEY_BASE_URL = "base_url";
    private static final String KEY_MODEL = "model";
    private static final String KEY_SYSTEM_PROMPT = "system_prompt";
    private static final String KEY_STREAMING = "streaming";
    private static final String KEY_DEEP_THINKING = "deep_thinking";

    private EditText apiKeyField, baseURLField, modelField, promptField;
    private CheckBox darkModeSwitch, streamingSwitch, deepThinkingSwitch;
    private Spinner fontSizeSpinner;
    private Button saveButton;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        ThemeManager.init(this);
        setTheme(ThemeManager.isDarkMode() ? R.style.AppTheme_Dark : R.style.AppTheme);
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_settings);

        final SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        apiKeyField = (EditText) findViewById(R.id.apiKeyField);
        baseURLField = (EditText) findViewById(R.id.baseURLField);
        modelField = (EditText) findViewById(R.id.modelField);
        promptField = (EditText) findViewById(R.id.promptField);
        darkModeSwitch = (CheckBox) findViewById(R.id.darkModeSwitch);
        streamingSwitch = (CheckBox) findViewById(R.id.streamingSwitch);
        deepThinkingSwitch = (CheckBox) findViewById(R.id.deepThinkingSwitch);
        fontSizeSpinner = (Spinner) findViewById(R.id.fontSizeSpinner);
        saveButton = (Button) findViewById(R.id.saveButton);

        // Load existing values
        apiKeyField.setText(prefs.getString(KEY_API_KEY, ""));
        baseURLField.setText(prefs.getString(KEY_BASE_URL, "https://api.openai.com/v1"));
        modelField.setText(prefs.getString(KEY_MODEL, "gpt-3.5-turbo"));
        promptField.setText(prefs.getString(KEY_SYSTEM_PROMPT, "You are a helpful assistant."));
        darkModeSwitch.setChecked(prefs.getBoolean("dark_mode", false));
        streamingSwitch.setChecked(prefs.getBoolean(KEY_STREAMING, true));
        deepThinkingSwitch.setChecked(prefs.getBoolean(KEY_DEEP_THINKING, true));
        // Font size spinner
        ArrayAdapter<CharSequence> adapter = ArrayAdapter.createFromResource(this,
            R.array.font_sizes, android.R.layout.simple_spinner_item);
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        fontSizeSpinner.setAdapter(adapter);
        fontSizeSpinner.setSelection(ThemeManager.getFontSize());

        saveButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                SharedPreferences.Editor ed = prefs.edit();
                ed.putString(KEY_API_KEY, apiKeyField.getText().toString().trim());
                ed.putString(KEY_BASE_URL, baseURLField.getText().toString().trim());
                ed.putString(KEY_MODEL, modelField.getText().toString().trim());
                ed.putString(KEY_SYSTEM_PROMPT, promptField.getText().toString().trim());
                ed.putBoolean("dark_mode", darkModeSwitch.isChecked());
                ed.putBoolean(KEY_STREAMING, streamingSwitch.isChecked());
                ed.putBoolean(KEY_DEEP_THINKING, deepThinkingSwitch.isChecked());
                ed.putInt("font_size", fontSizeSpinner.getSelectedItemPosition());
                ed.commit();

                // Update ThemeManager
                ThemeManager.setDarkMode(darkModeSwitch.isChecked(), SettingsActivity.this);
                ThemeManager.setFontSize(fontSizeSpinner.getSelectedItemPosition(), SettingsActivity.this);

                Toast.makeText(SettingsActivity.this, "已保存", Toast.LENGTH_SHORT).show();
                // Recreate activity to apply theme
                SettingsActivity.this.recreate();
                finish();
            }
        });
    }
}
