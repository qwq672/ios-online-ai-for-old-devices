package com.awa.aichat.model;

/**
 * A single chat message — role (user/assistant/system) + content.
 * Used by ChatAdapter and NetworkService.
 */
public class Message {
    public static final int ROLE_USER = 0;
    public static final int ROLE_ASSISTANT = 1;
    public static final int ROLE_SYSTEM = 2;

    public int role;
    public String content;
    public String thinking;
    public long timestamp;

    public Message(int role, String content) {
        this.role = role;
        this.content = content;
        this.timestamp = System.currentTimeMillis();
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
