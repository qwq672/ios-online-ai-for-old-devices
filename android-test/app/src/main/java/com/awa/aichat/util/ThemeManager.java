package com.awa.aichat.util;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.os.Build;

/**
 * ThemeManager — manual light/dark theme switching for Android 2.3+.
 *
 * WHY: Android 2.3-5.x has NO system-wide dark mode API. The framework's
 * `android:configChanges="uiMode"` and `values-night/` resource qualifier
 * only kick in on Android 6+ (API 23) when the user enables dark mode in
 * system settings. On our target devices (Android 2.3 Gingerbread,
 * Android 4.x Ice Cream Sandwich / Jelly Bean), `values-night/` is
 * IGNORED — the app would always render in the light theme regardless of
 * the user's preference.
 *
 * Solution: store the user's theme choice in SharedPreferences and apply
 * it programmatically in each Activity's onCreate BEFORE setContentView.
 * ChatAdapter and MarkdownParser read the same flag to pick colors.
 *
 * Three modes:
 *   THEME_AUTO  — follow system (resolves to LIGHT on < API 23,
 *                 follows uiMode on >= API 23)
 *   THEME_LIGHT — always light
 *   THEME_DARK  — always dark
 *
 * v0.6.5: 6 preset accent colors (blue/green/orange/pink/purple/teal).
 */
public final class ThemeManager {

    public static final int THEME_AUTO  = 0;
    public static final int THEME_LIGHT = 1;
    public static final int THEME_DARK  = 2;

    // v0.6.5: 6 预设主题色
    public static final int COLOR_BLUE   = 0;  // 默认蓝 #3B82F6
    public static final int COLOR_GREEN  = 1;  // 森林绿 #10B981
    public static final int COLOR_ORANGE = 2;  // 暖橙 #F97316
    public static final int COLOR_PINK   = 3;  // 樱花粉 #EC4899
    public static final int COLOR_PURPLE = 4;  // 优雅紫 #8B5CF6
    public static final int COLOR_TEAL   = 5;  // 青绿 #14B8A6

    private static final String PREFS = "aichat_prefs";
    private static final String KEY_THEME = "theme_mode";
    private static final String KEY_ACCENT_COLOR = "accent_color";

    // 亮色主题下的 accent 颜色
    private static final int[] ACCENT_LIGHT = new int[] {
        0xFF3B82F6,  // blue
        0xFF10B981,  // green
        0xFFF97316,  // orange
        0xFFEC4899,  // pink
        0xFF8B5CF6,  // purple
        0xFF14B8A6   // teal
    };
    // 暗色主题下提亮的 accent 颜色（避免对比度不足）
    private static final int[] ACCENT_DARK = new int[] {
        0xFF5B9BFF,  // blue
        0xFF34D399,  // green
        0xFFFB923C,  // orange
        0xFFF472B6,  // pink
        0xFFA78BFA,  // purple
        0xFF2DD4BF   // teal
    };

    private static final String[] COLOR_NAMES = new String[] {
        "蓝色", "绿色", "橙色", "粉色", "紫色", "青色"
    };

    private ThemeManager() {} // no instances

    public static int getThemeMode(Context ctx) {
        if (ctx == null) return THEME_AUTO;
        SharedPreferences p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        return p.getInt(KEY_THEME, THEME_AUTO);
    }

    public static void setThemeMode(Context ctx, int mode) {
        if (ctx == null) return;
        SharedPreferences.Editor ed = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit();
        ed.putInt(KEY_THEME, mode);
        ed.commit();
    }

    // v0.6.5: 获取/设置 accent 颜色索引
    public static int getAccentColorIndex(Context ctx) {
        if (ctx == null) return COLOR_BLUE;
        SharedPreferences p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        return p.getInt(KEY_ACCENT_COLOR, COLOR_BLUE);
    }

    public static void setAccentColorIndex(Context ctx, int idx) {
        if (ctx == null) return;
        if (idx < 0 || idx >= ACCENT_LIGHT.length) idx = COLOR_BLUE;
        SharedPreferences.Editor ed = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit();
        ed.putInt(KEY_ACCENT_COLOR, idx);
        ed.commit();
    }

    /** v0.6.5: 获取当前 accent 颜色（ARGB int） */
    public static int getAccentColor(Context ctx) {
        int idx = getAccentColorIndex(ctx);
        return isDark(ctx) ? ACCENT_DARK[idx] : ACCENT_LIGHT[idx];
    }

    public static String[] getColorNames() { return COLOR_NAMES; }
    public static int getColorCount() { return ACCENT_LIGHT.length; }
    public static String getColorName(int idx) {
        if (idx < 0 || idx >= COLOR_NAMES.length) return "蓝色";
        return COLOR_NAMES[idx];
    }
    public static int getAccentLight(int idx) {
        if (idx < 0 || idx >= ACCENT_LIGHT.length) return ACCENT_LIGHT[0];
        return ACCENT_LIGHT[idx];
    }
    public static int getAccentDark(int idx) {
        if (idx < 0 || idx >= ACCENT_DARK.length) return ACCENT_DARK[0];
        return ACCENT_DARK[idx];
    }

    /** True if the effective theme (after resolving AUTO) is dark. */
    public static boolean isDark(Context ctx) {
        int mode = getThemeMode(ctx);
        if (mode == THEME_DARK) return true;
        if (mode == THEME_LIGHT) return false;
        // THEME_AUTO: follow system on API 8+, default to light below.
        // Configuration.UI_MODE_NIGHT_* bits were added in API 8 (Froyo);
        // our minSdk is 9 (Gingerbread), so this is always safe.
        int nightMode = ctx.getResources().getConfiguration().uiMode
                        & Configuration.UI_MODE_NIGHT_MASK;
        return nightMode == Configuration.UI_MODE_NIGHT_YES;
    }

    /**
     * Apply the theme to an Activity. Call this in onCreate BEFORE
     * setContentView. Chooses between AppThemeLight and AppThemeDark.
     * THEME_AUTO delegates to the system on API 23+ (where values-night
     * works) and otherwise resolves to LIGHT.
     */
    public static void applyTheme(Context ctx) {
        int mode = getThemeMode(ctx);
        if (mode == THEME_DARK) {
            ctx.setTheme(com.awa.aichat.R.style.AppThemeDark);
        } else if (mode == THEME_LIGHT) {
            ctx.setTheme(com.awa.aichat.R.style.AppThemeLight);
        } else {
            // AUTO — let the system decide (on API 23+ this honors
            // values-night; on older devices it falls back to light).
            if (isDark(ctx)) {
                ctx.setTheme(com.awa.aichat.R.style.AppThemeDark);
            } else {
                ctx.setTheme(com.awa.aichat.R.style.AppThemeLight);
            }
        }
    }

    public static String modeLabel(int mode) {
        switch (mode) {
            case THEME_DARK:  return "深色";
            case THEME_LIGHT: return "浅色";
            default:          return "跟随系统";
        }
    }
}
