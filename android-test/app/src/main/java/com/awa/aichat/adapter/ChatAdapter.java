package com.awa.aichat.adapter;

import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.text.SpannableStringBuilder;
import android.text.method.LinkMovementMethod;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AbsListView;
import android.widget.BaseAdapter;
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

    public ChatAdapter(Context ctx) {
        this.context = ctx;
        float density = ctx.getResources().getDisplayMetrics().density;
        this.padH = (int) (24 * density + 0.5f);
        this.padV = (int) (14 * density + 0.5f);
        this.cornerRadius = (int) (8 * density + 0.5f);
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
        return new ArrayList<Message>(messages);
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

            bubble.addView(thinking);
            bubble.addView(content);
            root.addView(spacer);
            root.addView(bubble);
            h.root = root;
            h.spacer = spacer;
            h.bubble = bubble;
            h.thinking = thinking;
            h.content = content;
            convertView = root;
            convertView.setTag(h);
        } else {
            h = (Holder) convertView.getTag();
        }

        boolean dark = ThemeManager.isDark(context);

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

        // Rounded bubble background.
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(bgColor);
        bg.setCornerRadius(cornerRadius);
        h.bubble.setBackgroundDrawable(bg);
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

        // Thinking text.
        String thinking = msg.thinking == null ? "" : msg.thinking;
        if (thinking.length() > 0) {
            h.thinking.setVisibility(View.VISIBLE);
            // v0.3: 不用 💭 emoji（Android 2.3 无 emoji 字体显示成方块），改纯文本
            h.thinking.setText("[思考] " + thinking);
        } else {
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

        return convertView;
    }

    private static class Holder {
        LinearLayout root;
        View spacer;
        LinearLayout bubble;
        TextView thinking;
        TextView content;
    }
}
