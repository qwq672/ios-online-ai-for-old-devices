package com.awa.aichat.ui;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.Toast;

import com.awa.aichat.R;

/**
 * Settings screen — API Key, Base URL, Model, System Prompt.
 * Stored in SharedPreferences.
 */
public class SettingsActivity extends Activity {

    private static final String PREFS = "aichat_prefs";
    private static final String KEY_API_KEY = "api_key";
    private static final String KEY_BASE_URL = "base_url";
    private static final String KEY_MODEL = "model";
    private static final String KEY_SYSTEM_PROMPT = "system_prompt";

    private EditText apiKeyField, baseURLField, modelField, promptField;
    private Button saveButton;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_settings);

        final SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        apiKeyField = (EditText) findViewById(R.id.apiKeyField);
        baseURLField = (EditText) findViewById(R.id.baseURLField);
        modelField = (EditText) findViewById(R.id.modelField);
        promptField = (EditText) findViewById(R.id.promptField);
        saveButton = (Button) findViewById(R.id.saveButton);

        // Load existing values
        apiKeyField.setText(prefs.getString(KEY_API_KEY, ""));
        baseURLField.setText(prefs.getString(KEY_BASE_URL, "https://api.openai.com/v1"));
        modelField.setText(prefs.getString(KEY_MODEL, "gpt-3.5-turbo"));
        promptField.setText(prefs.getString(KEY_SYSTEM_PROMPT, "You are a helpful assistant."));

        saveButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                SharedPreferences.Editor ed = prefs.edit();
                ed.putString(KEY_API_KEY, apiKeyField.getText().toString().trim());
                ed.putString(KEY_BASE_URL, baseURLField.getText().toString().trim());
                ed.putString(KEY_MODEL, modelField.getText().toString().trim());
                ed.putString(KEY_SYSTEM_PROMPT, promptField.getText().toString().trim());
                ed.commit();
                Toast.makeText(SettingsActivity.this, "已保存", Toast.LENGTH_SHORT).show();
                finish();
            }
        });
    }
}
