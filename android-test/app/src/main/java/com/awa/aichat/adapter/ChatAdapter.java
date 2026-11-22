package com.awa.aichat.adapter;

import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.text.SpannableStringBuilder;
import android.text.method.LinkMovementMethod;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AbsListView;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.awa.aichat.R;
import com.awa.aichat.markdown.MarkdownParser;
import com.awa.aichat.model.Message;
import com.awa.aichat.util.ThemeManager;

import java.util.ArrayList;
import java.util.List;

/**
 * ListView adapter for chat messages.
 *
 * v0.2 fixes:
 *  - ViewHolder view recycling (the v0.1 adapter created a new TextView
 *    on every getView call — long conversations OOM-crashed).
 *  - Markdown rendering is cached per message-content-hash; the v0.1
 *    adapter re-parsed Markdown on every chunk, which made streaming
 *    on long responses janky.
 *  - Colors come from ThemeManager, so dark mode actually works
 *    (the v0.1 adapter hard-coded #DCF8C6/#FFFFFF, making the dark
 *    theme visually broken).
 *  - Error messages get a distinct red-tinted bubble.
 *  - Thinking text is rendered above the main content in a muted color.
 */
public class ChatAdapter extends BaseAdapter {

    private final Context context;
    private final List<Message> messages = new ArrayList<Message>();
    private final int padH, padV, cornerRadius;
    // v0.6.4: 缓存 dark theme — 避免 getView 每次读 SharedPreferences
    private boolean cachedDark;
    private long cachedDarkAt;

    public ChatAdapter(Context ctx) {
        this.context = ctx;
        float density = ctx.getResources().getDisplayMetrics().density;
        this.padH = (int) (24 * density + 0.5f);
        this.padV = (int) (14 * density + 0.5f);
        this.cornerRadius = (int) (14 * density + 0.5f);  // v261116-14: 14dp 配合拟物化气泡
        // v0.6.5: 注入 accent 颜色到 MarkdownParser
        int idx = ThemeManager.getAccentColorIndex(ctx);
        MarkdownParser.setAccentColors(ThemeManager.getAccentLight(idx), ThemeManager.getAccentDark(idx));
    }

    // v0.6.4: 缓存 dark theme 5 秒，避免 ListView 滚动时每行都读 SharedPreferences
    private boolean isDarkCached() {
        long now = System.currentTimeMillis();
        if (now - cachedDarkAt > 5000) {
            cachedDark = ThemeManager.isDark(context);
            cachedDarkAt = now;
        }
        return cachedDark;
    }

    public void add(Message msg) {
        messages.add(msg);
        notifyDataSetChanged();
    }

    public void updateLast(String content) {
        if (messages.isEmpty()) return;
        Message last = messages.get(messages.size() - 1);
        last.content = content;
        notifyDataSetChanged();
    }

    public void updateLastThinking(String thinking) {
        if (messages.isEmpty()) return;
        Message last = messages.get(messages.size() - 1);
        last.thinking = thinking;
        notifyDataSetChanged();
    }

    public void markLastError(String msg) {
        if (messages.isEmpty()) return;
        Message last = messages.get(messages.size() - 1);
        last.error = true;
        last.content = msg;
        notifyDataSetChanged();
    }

    public void clear() {
        messages.clear();
        notifyDataSetChanged();
    }

    public List<Message> getMessages() {
        // v0.6.6: 不把错误气泡([错误]...)作为历史发给 API —— 旧实现把错误文案
        // 写进 content，下条消息构造请求时会污染上下文。error 消息仅用于 UI 展示。
        List<Message> out = new ArrayList<Message>();
        for (Message m : messages) {
            if (m.error) continue;
            out.add(m);
        }
        return out;
    }

    public Message getLast() {
        return messages.isEmpty() ? null : messages.get(messages.size() - 1);
    }

    @Override
    public int getCount() { return messages.size(); }

    @Override
    public Object getItem(int position) { return messages.get(position); }

    @Override
    public long getItemId(int position) { return position; }

    @Override
    public View getView(int position, View convertView, ViewGroup parent) {
        Message msg = messages.get(position);
        Holder h;
        if (convertView == null) {
            h = new Holder();
            // Root: a horizontal LinearLayout with a spacer + bubble.
            // The spacer's weight controls alignment (weight 0 = left,
            // weight 0.18 = right with ~82% bubble width).
            LinearLayout root = new LinearLayout(context);
            root.setOrientation(LinearLayout.HORIZONTAL);
            AbsListView.LayoutParams rootLp = new AbsListView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
            root.setLayoutParams(rootLp);
            root.setPadding(0, 4, 0, 4);

            View spacer = new View(context);
            LinearLayout.LayoutParams spacerLp = new LinearLayout.LayoutParams(
                0, 0, 0f);
            spacer.setLayoutParams(spacerLp);

            // Inner bubble container: vertical LinearLayout holding the
            // thinking + content TextViews.
            LinearLayout bubble = new LinearLayout(context);
            bubble.setOrientation(LinearLayout.VERTICAL);
            LinearLayout.LayoutParams bubbleLp = new LinearLayout.LayoutParams(
                0, // width controlled by weight
                ViewGroup.LayoutParams.WRAP_CONTENT,
                1f);
            bubble.setLayoutParams(bubbleLp);
            bubble.setPadding(padH, padV, padH, padV);

            // v0.6: 思考折叠 — toggle 按钮 + 可展开 thinking 文字
            Button thinkingToggle = new Button(context);
            thinkingToggle.setTextSize(12);
            thinkingToggle.setPadding(8, 2, 8, 2);
            thinkingToggle.setVisibility(View.GONE);

            TextView thinking = new TextView(context);
            thinking.setTextSize(13);
            LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
            thinking.setLayoutParams(tLp);

            TextView content = new TextView(context);
            content.setTextSize(15);
            content.setLineSpacing(0, 1.1f);
            content.setMovementMethod(LinkMovementMethod.getInstance());
            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
            content.setLayoutParams(cLp);

            bubble.addView(thinkingToggle);
            bubble.addView(thinking);
            bubble.addView(content);
            root.addView(spacer);
            root.addView(bubble);
            h.root = root;
            h.spacer = spacer;
            h.bubble = bubble;
            h.thinkingToggle = thinkingToggle;
            h.thinking = thinking;
            h.content = content;
            convertView = root;
            convertView.setTag(h);
        } else {
            h = (Holder) convertView.getTag();
        }

        boolean dark = isDarkCached();

        // Pick colors.
        int bgColorRes, fgColorRes, thinkColorRes;
        if (msg.error) {
            bgColorRes = dark ? R.color.bg_bubble_error_dark : R.color.bg_bubble_error_light;
            fgColorRes = dark ? R.color.text_error_dark : R.color.text_error_light;
            thinkColorRes = fgColorRes;
        } else if (msg.isUser()) {
            bgColorRes = dark ? R.color.bg_bubble_user_dark : R.color.bg_bubble_user_light;
            fgColorRes = dark ? R.color.text_user_dark : R.color.text_user_light;
            thinkColorRes = fgColorRes;
        } else {
            bgColorRes = dark ? R.color.bg_bubble_ai_dark : R.color.bg_bubble_ai_light;
            fgColorRes = dark ? R.color.text_ai_dark : R.color.text_ai_light;
            thinkColorRes = dark ? R.color.text_thinking_dark : R.color.text_thinking_light;
        }

        int bgColor = context.getResources().getColor(bgColorRes);
        int fgColor = context.getResources().getColor(fgColorRes);
        int thinkColor = context.getResources().getColor(thinkColorRes);

        // v261116-14: 拟物化气泡背景 — 用 drawable 资源（iOS 6 风格渐变 + 高光 + 边框）
        // 按消息类型 + 主题选择对应 drawable
        if (msg.error) {
            // 错误：纯色（红色淡背景）
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(bgColor);
            bg.setCornerRadius(cornerRadius);
            bg.setStroke(1, dark ? 0xFF3A1515 : 0xFFE8C0C0);
            h.bubble.setBackgroundDrawable(bg);
        } else if (msg.isUser()) {
            // 用户气泡：绿色拟物化
            int resId = dark ? R.drawable.bubble_user_skeuomorphic_dark : R.drawable.bubble_user_skeuomorphic;
            h.bubble.setBackgroundDrawable(context.getResources().getDrawable(resId));
        } else {
            // AI 气泡：白色拟物化
            int resId = dark ? R.drawable.bubble_ai_skeuomorphic_dark : R.drawable.bubble_ai_skeuomorphic;
            h.bubble.setBackgroundDrawable(context.getResources().getDrawable(resId));
        }
        h.content.setTextColor(fgColor);
        h.thinking.setTextColor(thinkColor);

        // Alignment: user right (spacer weight 0.18), AI/error left (spacer weight 0).
        LinearLayout.LayoutParams spacerLp = (LinearLayout.LayoutParams) h.spacer.getLayoutParams();
        LinearLayout.LayoutParams bubbleLp = (LinearLayout.LayoutParams) h.bubble.getLayoutParams();
        if (msg.isUser()) {
            spacerLp.weight = 0.18f;
            bubbleLp.weight = 0.82f;
        } else {
            spacerLp.weight = 0f;
            bubbleLp.weight = 1f;
        }
        h.spacer.setLayoutParams(spacerLp);
        h.bubble.setLayoutParams(bubbleLp);

        // Thinking text — v0.6.4: 状态存到 Message，避免 ViewHolder 复用陷阱
        String thinking = msg.thinking == null ? "" : msg.thinking;
        if (thinking.length() > 0) {
            h.thinkingToggle.setVisibility(View.VISIBLE);
            h.thinking.setVisibility(msg.thinkingExpanded ? View.VISIBLE : View.GONE);
            h.thinkingToggle.setText(msg.thinkingExpanded ? "思考 · 点击收起" : "思考 · 点击展开");
            h.thinking.setText("[思考] " + thinking);
            // v0.6.4: 不再用 final 局部变量捕获，直接操作 Message
            final Message boundMsg = msg;
            h.thinkingToggle.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    boundMsg.thinkingExpanded = !boundMsg.thinkingExpanded;
                    notifyDataSetChanged();
                }
            });
        } else {
            h.thinkingToggle.setVisibility(View.GONE);
            h.thinking.setVisibility(View.GONE);
        }

        // Content — Markdown for AI, plain for user/error.
        String content = msg.content == null ? "" : msg.content;
        if (msg.isUser() || msg.error) {
            h.content.setText(content);
        } else {
            SpannableStringBuilder rendered = MarkdownParser.parseCached(content, dark);
            h.content.setText(rendered);
        }

        // v261116-11: 长按菜单（Android 标准上下文菜单）
        // 弹出 AlertDialog 显示：复制 / 重新生成 / 删除
        // 通过 setOnLongClickListener 监听整个 bubble
        final Message boundMsg = msg;
        final int boundPosition = position;
        h.bubble.setOnLongClickListener(new View.OnLongClickListener() {
            @Override
            public boolean onLongClick(View v) {
                showItemMenu(boundMsg, boundPosition);
                return true;
            }
        });

        return convertView;
    }

    // v261116-11: 显示消息项菜单（复制/重新生成/删除）
    private void showItemMenu(final Message msg, final int position) {
        if (context instanceof android.app.Activity) {
            final android.app.Activity activity = (android.app.Activity) context;
            final CharSequence[] items;
            // 用户消息: 复制 + 删除
            // AI 消息: 复制 + 重新生成 + 删除
            if (msg.isUser()) {
                items = new CharSequence[]{"复制", "删除"};
            } else {
                items = new CharSequence[]{"复制", "重新生成", "删除"};
            }
            new android.app.AlertDialog.Builder(activity)
                .setItems(items, new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface d, int which) {
                        String action = items[which].toString();
                        if ("复制".equals(action)) {
                            copyMessage(msg);
                        } else if ("重新生成".equals(action)) {
                            regenerateMessage(msg, position, activity);
                        } else if ("删除".equals(action)) {
                            messages.remove(msg);
                            notifyDataSetChanged();
                            android.widget.Toast.makeText(activity, "已删除", android.widget.Toast.LENGTH_SHORT).show();
                        }
                    }
                })
                .show();
        }
    }

    // v261116-11: 复制消息到剪贴板
    // v0.6.6: minSdk=9 (Android 2.3) 没有 ClipData/ClipboardManager(新)，
    // API 11+ 才有。直接引用会在 2.3 触发 NoClassDefFoundError，而
    // catch(Exception) 抓不到 Error → 崩溃。按 SDK_INT 分支：
    private void copyMessage(Message msg) {
        String text = msg.content == null ? "" : msg.content;
        try {
            if (android.os.Build.VERSION.SDK_INT >= 11) {
                android.content.ClipboardManager clip = (android.content.ClipboardManager)
                    context.getSystemService(android.content.Context.CLIPBOARD_SERVICE);
                android.content.ClipData clipData = android.content.ClipData.newPlainText("AIAnyWhere", text);
                clip.setPrimaryClip(clipData);
            } else {
                // Android 2.3 — 旧 ClipboardManager (android.text.ClipboardManager)
                android.text.ClipboardManager oldClip = (android.text.ClipboardManager)
                    context.getSystemService(android.content.Context.CLIPBOARD_SERVICE);
                oldClip.setText(text);
            }
            android.widget.Toast.makeText(context, "已复制到剪贴板", android.widget.Toast.LENGTH_SHORT).show();
        } catch (Throwable e) {
            // 用 Throwable 兜底，连 NoClassDefFoundError/VerifyError 也不崩
            android.util.Log.w("ChatAdapter", "copy failed: " + e.getMessage());
        }
    }

    // v261116-11: 重新生成 — 删除当前 AI 消息及之后，找上一条 user 消息重发
    private void regenerateMessage(Message msg, int position, android.app.Activity activity) {
        // 删除从 position 开始的所有消息
        while (messages.size() > position) {
            messages.remove(messages.size() - 1);
        }
        notifyDataSetChanged();
        // 找上一条 user 消息
        String lastUserText = "";
        for (int i = messages.size() - 1; i >= 0; i--) {
            if (messages.get(i).isUser()) {
                lastUserText = messages.get(i).content;
                messages.remove(i);
                notifyDataSetChanged();
                break;
            }
        }
        if (lastUserText.length() == 0) {
            android.widget.Toast.makeText(activity, "找不到上一条用户消息", android.widget.Toast.LENGTH_SHORT).show();
            return;
        }
        // 触发 ChatActivity 重新发送
        if (activity instanceof ChatMessageListener) {
            ((ChatMessageListener) activity).onRegenerate(lastUserText);
        }
    }

    // v261116-11: 让 ChatActivity 监听菜单事件（重新生成）
    public interface ChatMessageListener {
        void onRegenerate(String userText);
    }

    private static class Holder {
        LinearLayout root;
        View spacer;
        LinearLayout bubble;
        Button thinkingToggle;  // v0.6
        TextView thinking;
        TextView content;
    }
}
