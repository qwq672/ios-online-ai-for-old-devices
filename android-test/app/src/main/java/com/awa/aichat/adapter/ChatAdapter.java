package com.awa.aichat.adapter;

import android.content.Context;
import android.graphics.Color;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.awa.aichat.R;
import com.awa.aichat.markdown.MarkdownParser;
import com.awa.aichat.model.Message;

import java.util.ArrayList;
import java.util.List;

/**
 * ListView adapter for chat messages. User messages right-aligned with
 * green background; AI messages left-aligned with default background.
 */
public class ChatAdapter extends BaseAdapter {

    private final Context context;
    private final List<Message> messages = new ArrayList<Message>();
    private final LayoutInflater inflater;

    public ChatAdapter(Context ctx) {
        this.context = ctx;
        this.inflater = (LayoutInflater) ctx.getSystemService(Context.LAYOUT_INFLATER_SERVICE);
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
    public View getView(int position, View convertView, ViewGroup parent) {
        Message msg = messages.get(position);
        
        // Simple approach: create a TextView for each message
        // (no view recycling optimization for now — chat lists are small)
        TextView tv = new TextView(context);
        tv.setTextSize(15);
        tv.setPadding(24, 16, 24, 16);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        );
        
        if (msg.isUser()) {
            // User message — green-ish background, right-aligned
            tv.setBackgroundColor(Color.parseColor("#DCF8C6"));
            tv.setTextColor(Color.parseColor("#000000"));
            tv.setText(msg.content);
            lp.gravity = Gravity.RIGHT;
        } else {
            // AI message — markdown rendered, left-aligned
            tv.setBackgroundColor(Color.parseColor("#FFFFFF"));
            tv.setTextColor(Color.parseColor("#1A1A1A"));
            tv.setText(MarkdownParser.parse(msg.content));
            lp.gravity = Gravity.LEFT;
        }
        
        tv.setLayoutParams(lp);
        return tv;
    }
}
