package com.awa.aichat.ui;

import android.app.Activity;
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

import java.util.ArrayList;
import java.util.List;

/**
 * Main chat screen — ListView of messages + input field + send button.
 * Streams AI responses via SSE.
 */
public class ChatActivity extends Activity implements NetworkService.Listener {

    private static final String PREFS = "aichat_prefs";
    private static final String KEY_API_KEY = "api_key";
    private static final String KEY_BASE_URL = "base_url";
    private static final String KEY_MODEL = "model";
    private static final String KEY_SYSTEM_PROMPT = "system_prompt";

    private ListView listView;
    private EditText inputField;
    private Button sendButton;
    private ChatAdapter adapter;
    private NetworkService networkService;
    private boolean isStreaming = false;
    private SharedPreferences prefs;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_chat);

        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        listView = (ListView) findViewById(R.id.listView);
        inputField = (EditText) findViewById(R.id.inputField);
        sendButton = (Button) findViewById(R.id.sendButton);

        adapter = new ChatAdapter(this);
        listView.setAdapter(adapter);

        networkService = new NetworkService();
        networkService.setListener(this);

        // Settings button (in top bar now)
        Button settingsButton = (Button) findViewById(R.id.settingsButton);
        settingsButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startActivity(new Intent(ChatActivity.this, SettingsActivity.class));
            }
        });

        // Check if API key is set
        String apiKey = prefs.getString(KEY_API_KEY, "");
        if (apiKey.isEmpty()) {
            startActivity(new Intent(this, SettingsActivity.class));
            Toast.makeText(this, "请先设置 API Key", Toast.LENGTH_LONG).show();
        }

        sendButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (isStreaming) {
                    networkService.cancel();
                    isStreaming = false;
                    sendButton.setText("发送");
                    return;
                }
                sendMessage();
            }
        });

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
        String text = inputField.getText() != null ? inputField.getText().toString().trim() : "";
        if (text.isEmpty()) return;

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

        // Build message list (exclude the placeholder "…" AI message)
        List<Message> apiMessages = new ArrayList<Message>();
        List<Message> allMsgs = adapter.getMessages();
        for (int i = 0; i < allMsgs.size() - 1; i++) {
            apiMessages.add(allMsgs.get(i));
        }

        try {
            networkService.streamChat(baseURL, apiKey, model, apiMessages, systemPrompt, 0.7f);
        } catch (Exception e) {
            isStreaming = false;
            sendButton.setText("发送");
            adapter.updateLast("⚠️ " + e.getMessage());
        }
    }

    // --- NetworkService.Listener ---

    @Override
    public void onChunk(String fullText) {
        // Already on main thread (NetworkService uses Handler.post)
        if (isFinishing()) return;
        adapter.updateLast(fullText);
        listView.setSelection(adapter.getCount() - 1);
    }

    @Override
    public void onThinking(String thinkingText) {
        // TODO: show thinking in a collapsible block
    }

    @Override
    public void onFinish(String fullText, String thinking) {
        if (isFinishing()) return;
        isStreaming = false;
        sendButton.setText("发送");
        if (fullText == null || fullText.isEmpty()) {
            adapter.updateLast("⚠️ 空回复");
        }
        listView.setSelection(adapter.getCount() - 1);
    }

    @Override
    public void onError(String message) {
        if (isFinishing()) return;
        isStreaming = false;
        sendButton.setText("发送");
        adapter.updateLast("⚠️ " + (message != null ? message : "未知错误"));
        listView.setSelection(adapter.getCount() - 1);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (networkService != null) {
            networkService.cancel();
        }
    }
}
