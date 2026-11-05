package com.awa.aichat.adapter;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.TextView;

import com.awa.aichat.markdown.MarkdownParser;
import com.awa.aichat.model.Message;
import com.awa.aichat.util.ThemeManager;

import java.util.ArrayList;
import java.util.List;

/**
 * ListView adapter for chat messages with theme support.
 * Uses ViewHolder + convertView recycling (fixes OOM crash on Android 2.3).
 */
public class ChatAdapter extends BaseAdapter {

    private final Context context;
    private final List<Message> messages = new ArrayList<Message>();

    private static class ViewHolder {
        TextView tv;
    }

    public ChatAdapter(Context ctx) {
        this.context = ctx;
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

    public void clear() {
        messages.clear();
        notifyDataSetChanged();
    }

    public List<Message> getMessages() {
        return new ArrayList<Message>(messages);
    }

    @Override
    public int getCount() { return messages.size(); }

    @Override
    public Object getItem(int position) { return messages.get(position); }

    @Override
    public long getItemId(int position) { return position; }

    @Override
    public int getItemViewTypeCount() { return 2; }

    @Override
    public int getItemViewType(int position) {
        return messages.get(position).isUser() ? 0 : 1;
    }

    @Override
    public View getView(int position, View convertView, ViewGroup parent) {
        Message msg = messages.get(position);
        ViewHolder holder;

        if (convertView == null) {
            TextView tv = new TextView(context);
            tv.setPadding(24, 16, 24, 16);
            holder = new ViewHolder();
            holder.tv = tv;
            tv.setTag(holder);
            convertView = tv;
        } else {
            holder = (ViewHolder) convertView.getTag();
        }

        TextView tv = holder.tv;
        tv.setTextSize(ThemeManager.baseFontSize());

        if (msg.isUser()) {
            tv.setBackgroundColor(ThemeManager.userBubbleColor());
            tv.setTextColor(ThemeManager.userBubbleTextColor());
            tv.setText(msg.content);
        } else {
            tv.setBackgroundColor(ThemeManager.aiBubbleColor());
            tv.setTextColor(ThemeManager.textColor());
            if (msg.content != null && !msg.content.equals("…") && msg.content.length() > 0) {
                try {
                    tv.setText(MarkdownParser.parse(msg.content));
                } catch (Exception e) {
                    tv.setText(msg.content);
                }
            } else {
                tv.setText(msg.content);
            }
        }

        return convertView;
    }
}
