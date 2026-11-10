package com.awa.aichat.ui;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ListView;
import android.widget.Toast;

import com.awa.aichat.R;
import com.awa.aichat.adapter.ChatAdapter;
import com.awa.aichat.model.Message;
import com.awa.aichat.network.NetworkService;
import com.awa.aichat.util.ThemeManager;

import java.util.ArrayList;
import java.util.List;

/**
 * Main chat screen — ListView of messages + input field + send button.
 * Streams AI responses via SSE.
 *
 * v0.2 changes:
 *  - Applies ThemeManager theme in onCreate (light/dark/auto).
 *  - Renders thinking text in the AI bubble (was ignored in v0.1).
 *  - Clear-conversation button (with confirm dialog).
 *  - Settings + Clear buttons moved to a top bar.
 *  - Reads temperature / max_tokens / stream flag from prefs.
 *  - onStopStreaming: sendButton label reverts to "发送" even on cancel.
 *  - onChunk: no longer wraps an empty runOnUiThread around the update
 *    (NetworkService already posts to the main looper).
 */
public class ChatActivity extends Activity implements NetworkService.Listener {

    private static final String PREFS = "aichat_prefs";
    private static final String KEY_API_KEY = "api_key";
    private static final String KEY_BASE_URL = "base_url";
    private static final String KEY_MODEL = "model";
    private static final String KEY_SYSTEM_PROMPT = "system_prompt";
    private static final String KEY_TEMPERATURE = "temperature";
    private static final String KEY_MAX_TOKENS = "max_tokens";
    private static final String KEY_STREAM = "stream";

    private ListView listView;
    private EditText inputField;
    private Button sendButton;
    private ChatAdapter adapter;
    private NetworkService networkService;
    private boolean isStreaming = false;

    private SharedPreferences prefs;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        ThemeManager.applyTheme(this);
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_chat);

        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        // Sync the last-applied theme tracker so onResume doesn't see a
        // "change" that didn't happen (and thus loop recreating).
        lastAppliedThemeMode = ThemeManager.getThemeMode(this);

        listView = (ListView) findViewById(R.id.listView);
        inputField = (EditText) findViewById(R.id.inputField);
        sendButton = (Button) findViewById(R.id.sendButton);

        adapter = new ChatAdapter(this);
        listView.setAdapter(adapter);

        // Restore conversation across recreate (theme switch / orientation).
        if (savedInstanceState != null) {
            try {
                String[] roles = savedInstanceState.getStringArray("roles");
                String[] contents = savedInstanceState.getStringArray("contents");
                String[] thinkings = savedInstanceState.getStringArray("thinkings");
                boolean[] errors = savedInstanceState.getBooleanArray("errors");
                if (roles != null && contents != null && roles.length == contents.length) {
                    for (int i = 0; i < roles.length; i++) {
                        int r = Integer.parseInt(roles[i]);
                        Message m = new Message(r, contents[i]);
                        if (thinkings != null && i < thinkings.length) m.thinking = thinkings[i];
                        if (errors != null && i < errors.length) m.error = errors[i];
                        adapter.add(m);
                    }
                }
            } catch (Exception e) {
                // v0.3: 防御性 — 恢复失败不崩（NumberFormatException / IndexOutOfBounds
                // 在某些 OEM 2.3 build 上偶发，老设备闪退高发路径之一）
                android.util.Log.w("ChatActivity", "state restore failed: " + e.getMessage());
            }
        }

        networkService = new NetworkService();
        networkService.setListener(this);

        // Check if API key is set
        String apiKey = prefs.getString(KEY_API_KEY, "");
        if (apiKey == null || apiKey.length() == 0) {
            // First launch — open settings
            startActivity(new Intent(this, SettingsActivity.class));
            Toast.makeText(this, "请先设置 API Key", Toast.LENGTH_LONG).show();
        }

        sendButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (isStreaming) {
                    // Stop — cancel silently (no error toast).
                    networkService.cancel();
                    isStreaming = false;
                    sendButton.setText("发送");
                    // If the AI bubble still shows "…" or partial text,
                    // leave it as-is (the user can see what was generated).
                    return;
                }
                sendMessage();
            }
        });

        // Settings button
        Button settingsButton = (Button) findViewById(R.id.settingsButton);
        settingsButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startActivity(new Intent(ChatActivity.this, SettingsActivity.class));
            }
        });

        // Clear button
        Button clearButton = (Button) findViewById(R.id.clearButton);
        clearButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (isStreaming) {
                    Toast.makeText(ChatActivity.this, "请先停止生成", Toast.LENGTH_SHORT).show();
                    return;
                }
                if (adapter.getCount() == 0) return;
                new AlertDialog.Builder(ChatActivity.this)
                    .setTitle("清空对话")
                    .setMessage("确定要清空当前对话吗？")
                    .setPositiveButton("清空", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface d, int w) {
                            adapter.clear();
                            Toast.makeText(ChatActivity.this, "已清空", Toast.LENGTH_SHORT).show();
                        }
                    })
                    .setNegativeButton("取消", null)
                    .show();
            }
        });

        // Enable send button only when input has text
        inputField.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {}
            @Override
            public void afterTextChanged(Editable s) {
                sendButton.setEnabled(s != null && s.length() > 0);
            }
        });
        sendButton.setEnabled(false);
    }

    private void sendMessage() {
        String text = inputField.getText().toString().trim();
        if (text.length() == 0) return;

        // Add user message
        Message userMsg = new Message(Message.ROLE_USER, text);
        adapter.add(userMsg);

        // Clear input
        inputField.setText("");

        // Add placeholder AI message
        Message aiMsg = new Message(Message.ROLE_ASSISTANT, "…");
        adapter.add(aiMsg);

        // Scroll to bottom
        listView.setSelection(adapter.getCount() - 1);

        // Start streaming
        isStreaming = true;
        sendButton.setText("停止");

        String apiKey = prefs.getString(KEY_API_KEY, "");
        String baseURL = prefs.getString(KEY_BASE_URL, "https://api.openai.com/v1");
        String model = prefs.getString(KEY_MODEL, "gpt-3.5-turbo");
        String systemPrompt = prefs.getString(KEY_SYSTEM_PROMPT, "You are a helpful assistant.");
        float temperature = prefs.getFloat(KEY_TEMPERATURE, 0.7f);
        int maxTokens = prefs.getInt(KEY_MAX_TOKENS, 0);
        boolean stream = prefs.getBoolean(KEY_STREAM, true);

        // Build message list (exclude the placeholder "…" AI message)
        List<Message> apiMessages = new ArrayList<Message>();
        apiMessages.addAll(adapter.getMessages());
        // Remove the last (placeholder) message
        if (!apiMessages.isEmpty()) {
            apiMessages.remove(apiMessages.size() - 1);
        }

        networkService.streamChat(baseURL, apiKey, model, apiMessages,
                                  systemPrompt, temperature, maxTokens, stream);
    }

    @Override
    public void onChunk(String fullText) {
        // Already on main thread (NetworkService posts via mainHandler).
        adapter.updateLast(fullText);
        listView.setSelection(adapter.getCount() - 1);
    }

    @Override
    public void onThinking(String thinkingText) {
        // Show thinking text in the AI bubble (above content).
        adapter.updateLastThinking(thinkingText);
        listView.setSelection(adapter.getCount() - 1);
    }

    @Override
    public void onFinish(String fullText, String thinking) {
        isStreaming = false;
        sendButton.setText("发送");
        if (fullText == null || fullText.length() == 0) {
            adapter.updateLast("⚠️ 空回复");
        }
        listView.setSelection(adapter.getCount() - 1);
    }

    @Override
    public void onError(String message) {
        isStreaming = false;
        sendButton.setText("发送");
        String shown = message == null ? "未知错误" : message;
        adapter.markLastError("⚠️ " + shown);
        listView.setSelection(adapter.getCount() - 1);
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        // Persist the conversation across recreate (theme switch / orientation).
        List<Message> msgs = adapter.getMessages();
        String[] roles = new String[msgs.size()];
        String[] contents = new String[msgs.size()];
        String[] thinkings = new String[msgs.size()];
        boolean[] errors = new boolean[msgs.size()];
        for (int i = 0; i < msgs.size(); i++) {
            Message m = msgs.get(i);
            roles[i] = String.valueOf(m.role);
            contents[i] = m.content == null ? "" : m.content;
            thinkings[i] = m.thinking == null ? "" : m.thinking;
            errors[i] = m.error;
        }
        outState.putStringArray("roles", roles);
        outState.putStringArray("contents", contents);
        outState.putStringArray("thinkings", thinkings);
        outState.putBooleanArray("errors", errors);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        networkService.setListener(null);  // v261103-35 fix #12: 释放 Activity 引用
        networkService.cancel();
    }

    @Override
    protected void onResume() {
        super.onResume();
        // If the user changed the theme in settings, recreate this Activity
        // so the new theme applies. We detect a change by comparing the
        // last-applied mode to the current mode.
        int currentMode = ThemeManager.getThemeMode(this);
        if (currentMode != lastAppliedThemeMode) {
            lastAppliedThemeMode = currentMode;
            // recreate() requires API 11; on API 9-10 we just finish+restart.
            recreateCompat();
        }
    }

    private int lastAppliedThemeMode = ThemeManager.THEME_AUTO;

    private void recreateCompat() {
        // recreate() requires API 11 (Honeycomb). Our minSdk is 9, so on
        // Gingerbread we fall back to finish() + startActivity().
        if (android.os.Build.VERSION.SDK_INT >= 11) {
            recreate();
        } else {
            finish();
            startActivity(getIntent());
        }
    }
}
