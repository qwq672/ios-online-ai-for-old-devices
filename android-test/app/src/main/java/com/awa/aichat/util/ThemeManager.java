package com.awa.aichat.util;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * Theme manager — handles dark mode toggle + color access.
 * Mirrors the iOS app's iOS6Theme approach.
 */
public class ThemeManager {

    private static final String PREFS = "aichat_prefs";
    private static final String KEY_DARK_MODE = "dark_mode";
    private static final String KEY_FONT_SIZE = "font_size"; // 0=S, 1=M, 2=L, 3=XL

    private static boolean darkMode = false;
    private static int fontSize = 1; // default M
    private static boolean initialized = false;

    public static void init(Context ctx) {
        if (initialized) return;
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        darkMode = prefs.getBoolean(KEY_DARK_MODE, false);
        fontSize = prefs.getInt(KEY_FONT_SIZE, 1);
        initialized = true;
    }

    public static boolean isDarkMode() { return darkMode; }

    public static void setDarkMode(boolean on, Context ctx) {
        darkMode = on;
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        prefs.edit().putBoolean(KEY_DARK_MODE, on).commit();
    }

    public static int getFontSize() { return fontSize; }

    public static void setFontSize(int size, Context ctx) {
        fontSize = size;
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        prefs.edit().putInt(KEY_FONT_SIZE, size).commit();
    }

    public static float baseFontSize() {
        switch (fontSize) {
            case 0: return 13f; case 1: return 15f;
            case 2: return 17f; case 3: return 19f;
            default: return 15f;
        }
    }

    public static int backgroundColor() { return darkMode ? 0xFF070707 : 0xFFEDEDED; }
    public static int topBarColor() { return darkMode ? 0xFF111111 : 0xFFF5F5F5; }
    public static int inputBarColor() { return darkMode ? 0xFF151515 : 0xFFFFFFFF; }
    public static int textColor() { return darkMode ? 0xFFD8D8E0 : 0xFF1A1A1A; }
    public static int secondaryTextColor() { return darkMode ? 0xFF7A8298 : 0xFF666666; }
    public static int userBubbleColor() { return darkMode ? 0xFF151515 : 0xFFDCF8C6; }
    public static int userBubbleTextColor() { return darkMode ? 0xFFD8D8E0 : 0xFF000000; }
    public static int aiBubbleColor() { return darkMode ? 0xFF0F0F0F : 0xFFFFFFFF; }
    public static int tintColor() { return 0xFF1E3A8A; }
    public static int codeBgColor() { return darkMode ? 0xFF111111 : 0xFFF5F5F5; }
    public static int toolTextColor() { return darkMode ? 0xFF7A8298 : 0xFF666666; }
    public static int toolBgColor() { return darkMode ? 0xFF111111 : 0xFFF5F5F5; }
}
