package com.awa.aichat.model;

/**
 * A single chat message — role (user/assistant/system) + content + thinking.
 * Used by ChatAdapter and NetworkService.
 *
 * v0.2: added `error` flag (so the adapter can render error bubbles with a
 * distinct color) and made `thinking` mutable so streaming updates work.
 */
public class Message {
    public static final int ROLE_USER = 0;
    public static final int ROLE_ASSISTANT = 1;
    public static final int ROLE_SYSTEM = 2;

    public int role;
    public String content;
    public String thinking;
    public boolean error;
    public long timestamp;

    public Message(int role, String content) {
        this.role = role;
        this.content = content;
        this.thinking = "";
        this.error = false;
        this.timestamp = System.currentTimeMillis();
    }

    public Message(int role, String content, boolean error) {
        this(role, content);
        this.error = error;
    }

    public boolean isUser() { return role == ROLE_USER; }
    public boolean isAssistant() { return role == ROLE_ASSISTANT; }

    public String roleName() {
        switch (role) {
            case ROLE_USER: return "user";
            case ROLE_ASSISTANT: return "assistant";
            case ROLE_SYSTEM: return "system";
            default: return "user";
        }
    }
}
