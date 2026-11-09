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
 */
public final class ThemeManager {

    public static final int THEME_AUTO  = 0;
    public static final int THEME_LIGHT = 1;
    public static final int THEME_DARK  = 2;

    private static final String PREFS = "aichat_prefs";
    private static final String KEY_THEME = "theme_mode";

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
