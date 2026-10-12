// worker.js - iOS 5/6 兼容优化版 (全屏滑动与搜索数量修复版)
// 路由：/ 公共版 / ?p=121126 个人版 / /api/chat-personal / /api/chat / /api/tavily

const PERSONAL_API_KEY = 'sk-cd1f546c1f12544977b9f4bd6123fb8e7029a900bb2431d57b95b8dcab91ec5b'; // 替换为你的完整 Key
const PERSONAL_API_URL = 'https://discovery-api.intern-ai.org.cn/v1/chat/completions';

const TAVILY_API_KEY = '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'; // <--- 在这里填入你的 Tavily API Key

const API_KEYS = [
  'cb2707a6f7884463b7fb66e0a99feecd.bIK8xwqS98fF8gy3',
  '8a9c6ff9d4084e10bc7be0444cca001a.olgpi6Pebs1WoZaP'
];
const API_URL = 'https://open.bigmodel.cn/api/paas/v4/chat/completions';

const HTML_PUBLIC = `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><meta name="apple-mobile-web-app-capable" content="yes"><title>AI Chat</title><style>body{font-family:Helvetica,Arial,sans-serif;background:#ededed;color:#1a1a1a;margin:10px}.b{display:block;padding:10px;background:#fff;border:1px solid #ccc;border-radius:8px;margin-bottom:10px;text-decoration:none;color:#007aff}</style></head><body><div>AI 助手 (公共版)</div><a class="b" href="?p=121126">进入个人版</a></body></html>`;

const HTML_PERSONAL = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<title>AI Assistant</title>
<style>
*{margin:0;padding:0;-webkit-box-sizing:border-box;box-sizing:border-box;-webkit-text-size-adjust:100%}
html,body{height:100%;width:100%;overflow:hidden}
body{font-family:-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5;background:#ededed;color:#1a1a1a}
.header{position:absolute;top:0;left:0;right:0;height:44px;background:#f7f7f7;border-bottom:1px solid #ccc;z-index:10}
.title{font-size:17px;font-weight:bold;line-height:44px;text-align:center;color:#1a1a1a;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;margin:0 100px}
.header-btn{display:inline-block;height:44px;padding:0 12px;line-height:44px;font-size:15px;color:#007aff;cursor:pointer}
.header-left{position:absolute;top:0;left:0;height:44px}
.header-right{position:absolute;top:0;right:0;height:44px}
.panel{display:none;position:absolute;top:44px;left:0;right:0;background:#f7f7f7;border-bottom:1px solid #ccc;z-index:10;max-height:70%;overflow-y:scroll;-webkit-overflow-scrolling:touch}
.panel.show{display:block}
.panel-pad{padding:10px}
.settings-row{padding:6px 0}
.settings-label{display:inline-block;width:80px;font-size:14px;color:#1a1a1a;vertical-align:middle}
.settings-select{width:60%;font-size:14px;padding:5px;border:1px solid #ccc;border-radius:4px;background:#fff;color:#1a1a1a;vertical-align:middle}
.session-item{padding:10px;background:#fff;border-bottom:1px solid #eee;cursor:pointer;position:relative}
.session-item.active{background:#e6f2ff}
.session-item-title{font-size:14px;font-weight:bold;color:#333;padding-right:40px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
.session-item-del{position:absolute;right:10px;top:50%;margin-top:-10px;font-size:13px;color:#cc0000;padding:4px 6px;background:#f0f0f0;border-radius:4px}
.chat-area{position:absolute;top:44px;bottom:88px;left:0;right:0;overflow-y:scroll;-webkit-overflow-scrolling:touch;padding:10px;z-index:1}
.msg-wrap{margin-bottom:10px;overflow:hidden;zoom:1}
.msg-user{float:right;max-width:80%;padding:8px 12px;background:#007aff;color:#fff;border-radius:14px;word-wrap:break-word;word-break:break-word}
.msg-user img{max-width:100%;border-radius:8px;margin-top:4px}
.msg-ai{float:left;clear:both;max-width:88%;padding:10px 14px;background:#fff;color:#1a1a1a;border:1px solid #e0e0e0;border-radius:14px;word-wrap:break-word;word-break:break-word}
.input-area{position:absolute;bottom:0;left:0;right:0;min-height:88px;padding:6px 10px 10px 10px;background:#f7f7f7;border-top:1px solid #ccc;z-index:10}
.input-toolbar{height:32px;line-height:32px;margin-bottom:6px}
.tool-btn{display:inline-block;height:28px;line-height:26px;padding:0 10px;font-size:13px;color:#007aff;cursor:pointer;margin-right:6px;border:1px solid #ccc;border-radius:4px;background:#fff;position:relative}
.tool-btn.active{background:#007aff;color:#fff;border-color:#007aff}
.input-row{display:table;width:100%}
.input-cell{display:table-cell;width:100%;vertical-align:middle}
.btn-cell{display:table-cell;vertical-align:middle;padding-left:8px;white-space:nowrap}
.input-box{width:100%;height:40px;max-height:80px;padding:8px 10px;border:1px solid #ccc;border-radius:8px;font-size:16px;background:#fff;color:#1a1a1a;outline:none;-webkit-appearance:none;resize:none;overflow-y:auto;line-height:1.5}
.btn-send{height:40px;padding:0 14px;border-radius:8px;font-size:18px;cursor:pointer;-webkit-appearance:none;font-weight:bold;text-align:center;background:#007aff;color:#fff;border:1px solid #007aff}
.btn-send.stop-mode{background:#cc0000;border-color:#cc0000}
.img-badge{position:absolute;top:-5px;right:-5px;background:#cc0000;color:#fff;border-radius:8px;min-width:16px;height:16px;font-size:10px;line-height:16px;text-align:center;padding:0 3px;display:none}
.code-block{padding:8px;margin:6px 0;background:#f5f5f5;border-radius:4px;overflow-x:auto;font-family:monospace;font-size:13px;white-space:pre;color:#333}
.inline-code{padding:1px 5px;background:#f5f5f5;border-radius:3px;font-family:monospace;font-size:13px;color:#333}
.msg-ai h1,.msg-ai h2,.msg-ai h3{margin:8px 0 4px 0;font-weight:bold}.msg-ai h1{font-size:20px}.msg-ai h2{font-size:18px}.msg-ai h3{font-size:17px}
.msg-ai p{margin:4px 0}.msg-ai ul,.msg-ai ol{margin:6px 0;padding-left:24px}.msg-ai li{margin:2px 0}
.msg-ai blockquote{margin:6px 0;padding:6px 12px;border-left:3px solid #007aff;background:#f5f5f5;color:#555}
.msg-ai a{color:#007aff;text-decoration:underline}.msg-ai strong{font-weight:bold}.msg-ai em{font-style:italic}
.loading{color:#999}.hint{color:#999;font-size:13px;text-align:center;padding:20px 10px}
.tool-status{clear:left;max-width:88%;padding:8px 10px;margin-bottom:6px;background:#fffbe6;border:1px solid #ffe58f;border-radius:6px;font-size:13px;color:#ad6800}
.tool-status b{display:block;margin-bottom:4px}
.search-results{margin-top:6px;font-size:12px;color:#666;max-height:150px;overflow-y:scroll;-webkit-overflow-scrolling:touch;background:#fff;padding:6px;border-radius:4px;border:1px solid #eee}
body.dark{background:#121212;color:#e0e0e0}
body.dark .header,body.dark .panel,body.dark .input-area,body.dark .msg-ai{background:#1e1e1e;border-color:#333}
body.dark .title,body.dark .settings-label,body.dark .msg-ai{color:#e0e0e0}
body.dark .header-btn,body.dark .tool-btn{color:#5a9ff7;border-color:#5a9ff7;background:#1e1e1e}
body.dark .tool-btn.active{background:#5a9ff7;color:#fff}
body.dark .settings-select,body.dark .input-box{background:#2a2a2a;color:#e0e0e0;border-color:#444}
body.dark .session-item{background:#1e1e1e;border-bottom-color:#333}
body.dark .btn-send{background:#5a9ff7;border-color:#5a9ff7}
body.dark .msg-user{background:#0a5cb8}
body.dark .code-block,body.dark .inline-code{background:#2a2a2a;color:#e0e0e0}
</style>
</head>
<body>
<div class="header">
  <div class="header-left"><span class="header-btn" id="btnSessions">会话</span></div>
  <div class="title" id="titleView">AI 助手</div>
  <div class="header-right"><span class="header-btn" id="btnSettings">设置</span></div>
</div>
<div class="panel" id="sessionsPanel">
  <div style="padding:10px;background:#f0f0f0;border-bottom:1px solid #ccc">
    <span class="header-btn" id="btnNewSession" style="color:#007aff;font-weight:bold">+ 新建对话</span>
    <span class="header-btn" id="btnClearAll" style="color:#cc0000;float:right">清空全部</span>
  </div>
  <div id="sessionsList"></div>
</div>
<div class="panel" id="settingsPanel">
  <div class="panel-pad">
    <div class="settings-row"><span class="settings-label">模型</span>
      <select class="settings-select" id="modelSelect">
        <option value="deepseek-v4-flash-vision">DeepSeek Vision</option>
        <option value="glm-4.7-flash">GLM-4.7-Flash</option>
        <option value="GLM-4-Flash-250414">GLM-4-Flash</option>
        <option value="GLM-4.5-Flash">GLM-4.5-Flash</option>
      </select>
    </div>
    <div class="settings-row"><span class="settings-label">联网搜索</span>
      <select class="settings-select" id="searchSelect">
        <option value="off">关闭</option>
        <option value="on">开启</option>
      </select>
    </div>
    <div class="settings-row"><span class="settings-label">搜索结果数</span>
      <select class="settings-select" id="searchLimitSelect">
        <option value="1">1 条</option>
        <option value="2">2 条</option>
        <option value="3">3 条</option>
        <option value="4">4 条</option>
        <option value="5">5 条</option>
        <option value="6">6 条</option>
        <option value="7">7 条</option>
      </select>
    </div>
    <div class="settings-row"><span class="settings-label">主题</span><select class="settings-select" id="themeSelect"><option value="light">浅色</option><option value="dark">深色</option></select></div>
    <div class="settings-row"><span class="settings-label">缩放</span><select class="settings-select" id="zoomSelect"><option value="80">80%</option><option value="90">90%</option><option value="100">100%</option><option value="110">110%</option><option value="120">120%</option></select></div>
  </div>
</div>
<div class="chat-area" id="chatArea"><div class="hint">你好，qwq672。请输入消息。</div></div>
<div class="input-area">
  <div class="input-toolbar">
    <span class="tool-btn" id="btnImg">图片<span class="img-badge" id="imgBadge">0</span></span>
    <span class="tool-btn" id="btnThink">深度思考</span>
  </div>
  <div class="input-row">
    <div class="input-cell"><textarea class="input-box" id="inputBox" placeholder="输入消息... (Ctrl+Enter发送)" rows="1"></textarea></div>
    <div class="btn-cell"><button class="btn-send" id="btnSend">➤</button></div>
  </div>
</div>
<input type="file" id="imgInput" accept="image/*" style="display:none">
<script>
(function(){
  function $(id){return document.getElementById(id)}
  function lsGet(k,d){try{var v=localStorage.getItem(k);return v===null?d:v}catch(e){return d}}
  function lsSet(k,v){try{localStorage.setItem(k,v)}catch(e){}}
  function lsDel(k){try{localStorage.removeItem(k)}catch(e){}}
  function escapeHTML(s){s=String(s);return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
  
  function parseMarkdown(src){
    src = escapeHTML(src);
    var codeBlocks = [];
    src = src.replace(/\\x60\\x60\\x60([a-zA-Z0-9+#]*)\\n?([\\s\\S]*?)\\x60\\x60\\x60/g, function(m, lang, code){
      var idx = codeBlocks.length;
      codeBlocks.push(code);
      return '\\n\\x00CB' + idx + '\\x00\\n';
    });
    var ics = [];
    src = src.replace(/\\x60([^\\x60]+)\\x60/g, function(m, code){
      var idx = ics.length;
      ics.push(code);
      return '\\x00IC' + idx + '\\x00';
    });
    var lines = src.split('\\n');
    var html = '';
    var inUl = false, inOl = false, inQuote = false, inPara = false;
    function closeLists(){if(inUl){html += '</ul>'; inUl = false} if(inOl){html += '</ol>'; inOl = false}}
    function closeQuote(){if(inQuote){html += '</blockquote>'; inQuote = false}}
    function closePara(){if(inPara){html += '</p>'; inPara = false}}
    for(var i = 0; i < lines.length; i++){
      var line = lines[i];
      var cbMatch = line.match(/^\\x00CB(\\d+)\\x00$/);
      if(cbMatch){closeLists();closeQuote();closePara();html += '<pre class="code-block">' + codeBlocks[parseInt(cbMatch[1],10)] + '</pre>';continue;}
      var hMatch = line.match(/^(#{1,4})\\s+(.*)$/);
      if(hMatch){closeLists();closeQuote();closePara();var level = hMatch[1].length;html += '<h' + level + '>' + hMatch[2] + '</h' + level + '>';continue;}
      if(/^(-{3,}|\\*{3,}|_{3,})\\s*$/.test(line)){closeLists();closeQuote();closePara();html += '<hr>';continue;}
      if(line.charAt(0) === '>'){closeLists();closePara();if(!inQuote){html += '<blockquote>'; inQuote = true}html += '<p>' + line.replace(/^>\\s?/, '') + '</p>';continue;}
      if(/^[-*+]\\s+/.test(line)){closeQuote();closePara();if(inOl){html += '</ol>'; inOl = false}if(!inUl){html += '<ul>'; inUl = true}html += '<li>' + line.replace(/^[-*+]\\s+/, '') + '</li>';continue;}
      var olMatch = line.match(/^(\\d+)\\.\\s+(.*)$/);
      if(olMatch){closeQuote();closePara();if(inUl){html += '</ul>'; inUl = false}if(!inOl){html += '<ol>'; inOl = true}html += '<li>' + olMatch[2] + '</li>';continue;}
      if(line.replace(/^\\s+/, '').replace(/\\s+$/, '') === ''){closeLists();closeQuote();closePara();continue;}
      closeLists();closeQuote();
      if(!inPara){html += '<p>';inPara = true;} else {html += '<br>';}
      html += line;
    }
    closeLists();closeQuote();closePara();
    return html;
  }
  
  function compressImg(file, callback) {
    var reader = new FileReader();
    reader.onload = function(e) {
      var img = new Image();
      img.onload = function() {
        var canvas = document.createElement('canvas');
        var ctx = canvas.getContext('2d');
        var maxW = 1024, maxH = 1024;
        var w = img.width, h = img.height;
        if (w > maxW) { h = h * (maxW / w); w = maxW; }
        if (h > maxH) { w = w * (maxH / h); h = maxH; }
        canvas.width = w; canvas.height = h;
        ctx.drawImage(img, 0, 0, w, h);
        var dataUrl = canvas.toDataURL('image/jpeg', 0.7);
        callback(dataUrl);
      };
      img.src = e.target.result;
    };
    reader.readAsDataURL(file);
  }
  
  var chatArea = $('chatArea');
  var inputBox = $('inputBox');
  var btnSend = $('btnSend');
  var btnThink = $('btnThink');
  var btnSettings = $('btnSettings');
  var btnSessions = $('btnSessions');
  var settingsPanel = $('settingsPanel');
  var sessionsPanel = $('sessionsPanel');
  var sessionsList = $('sessionsList');
  var modelSelect = $('modelSelect');
  var themeSelect = $('themeSelect');
  var zoomSelect = $('zoomSelect');
  var searchSelect = $('searchSelect');
  var searchLimitSelect = $('searchLimitSelect');
  var btnNewSession = $('btnNewSession');
  var btnClearAll = $('btnClearAll');
  var titleView = $('titleView');
  var btnImg = $('btnImg');
  var imgInput = $('imgInput');
  var imgBadge = $('imgBadge');
  
  var thinking = false;
  var thinkEnabled = false;
  var srchEnabled = false;
  var srchLimit = 3;
  var imgs = [];
  var model = lsGet('p_model', 'deepseek-v4-flash-vision');
  srchEnabled = lsGet('p_search', 'off') === 'on';
  srchLimit = lsGet('p_search_limit', '3');
  var theme = lsGet('p_theme', 'light');
  var zoom = lsGet('p_zoom', '100');
  var SESSIONS_KEY = 'p_sessions_v1';
  var CURRENT_SID = lsGet('p_sid', '');
  
  modelSelect.value = model;
  themeSelect.value = theme;
  zoomSelect.value = zoom;
  searchSelect.value = srchEnabled ? 'on' : 'off';
  searchLimitSelect.value = srchLimit;
  if(theme === 'dark'){document.body.className = 'dark'}
  document.body.style.zoom = zoom / 100;
  
  function updateImgBadge() {
    if(imgs.length > 0) {imgBadge.style.display = 'block'; imgBadge.innerHTML = imgs.length;} 
    else {imgBadge.style.display = 'none';}
  }
  
  function genId(){return 'sid_' + new Date().getTime() + '_' + Math.floor(Math.random()*10000)}
  function getSessions(){try{return JSON.parse(lsGet(SESSIONS_KEY, '[]'))||[]}catch(e){return[]}}
  function saveSessions(arr){try{lsSet(SESSIONS_KEY, JSON.stringify(arr))}catch(e){}}
  function getCurrentSession(){
    var arr = getSessions();
    for(var i=0; i<arr.length; i++){if(arr[i].id === CURRENT_SID) return arr[i]}
    if(arr.length > 0){CURRENT_SID = arr[0].id; lsSet('p_sid', CURRENT_SID); return arr[0]}
    return null;
  }
  function createNewSession(){
    var sid = genId(); var arr = getSessions();
    var s = {id: sid, t: '新对话', m: []};
    arr.unshift(s); if(arr.length > 20) arr = arr.slice(0, 20);
    saveSessions(arr); CURRENT_SID = sid; lsSet('p_sid', CURRENT_SID);
    renderSessions(); renderChat(); hidePanels();
  }
  function deleteSession(sid){
    var arr = getSessions(); var newArr = [];
    for(var i=0; i<arr.length; i++){if(arr[i].id !== sid) newArr.push(arr[i])}
    saveSessions(newArr);
    if(CURRENT_SID === sid){
      if(newArr.length > 0){CURRENT_SID = newArr[0].id; lsSet('p_sid', CURRENT_SID)}
      else {CURRENT_SID = ''; lsDel('p_sid')}
    }
    renderSessions(); renderChat();
  }
  function clearAllSessions(){lsDel(SESSIONS_KEY); lsDel('p_sid'); CURRENT_SID = ''; renderSessions(); renderChat()}
  function renderSessions(){
    var arr = getSessions(); sessionsList.innerHTML = '';
    if(arr.length === 0){sessionsList.innerHTML = '<div class="hint">暂无历史对话</div>'; return}
    for(var i=0; i<arr.length; i++){
      var s = arr[i]; var div = document.createElement('div');
      div.className = 'session-item' + (s.id === CURRENT_SID ? ' active' : '');
      div.innerHTML = '<div class="session-item-title">' + escapeHTML(s.t || '新对话') + '</div><div class="session-item-del" sid="' + s.id + '">删除</div>';
      div.setAttribute('sid', s.id); sessionsList.appendChild(div);
    }
  }
  function renderChat(){
    var s = getCurrentSession(); chatArea.innerHTML = '';
    if(!s || s.m.length === 0){chatArea.innerHTML = '<div class="hint">你好，qwq672。请输入消息。</div>'; titleView.innerHTML = 'AI 助手'; return}
    titleView.innerHTML = escapeHTML(s.t);
    for(var i=0; i<s.m.length; i++){
      var m = s.m[i];
      if(m.role === 'user'){addUserMsg(m.content, m.images)}
      else {
        var wrap = document.createElement('div'); wrap.className = 'msg-wrap';
        var content = document.createElement('div'); content.className = 'msg-ai';
        content.innerHTML = parseMarkdown(m.content || '');
        wrap.appendChild(content); chatArea.appendChild(wrap);
      }
    }
    scrollBottom();
  }
  function hidePanels(){settingsPanel.className = 'panel'; sessionsPanel.className = 'panel'}
  function scrollBottom(){setTimeout(function(){chatArea.scrollTop = chatArea.scrollHeight}, 0)}
  function clearHint(){
    var h = chatArea.firstChild;
    while(h){var next = h.nextSibling; if(h.className === 'hint') chatArea.removeChild(h); h = next}
  }
  function addUserMsg(text, images){
    clearHint(); var wrap = document.createElement('div'); wrap.className = 'msg-wrap';
    var div = document.createElement('div'); div.className = 'msg-user';
    var html = '';
    if(text) html += escapeHTML(text).replace(/\\n/g, '<br>');
    if(images && images.length){for(var i=0; i<images.length; i++){html += '<img src="' + images[i] + '">'}}
    div.innerHTML = html; wrap.appendChild(div); chatArea.appendChild(wrap); scrollBottom();
  }
  function createAIMsg(){
    clearHint(); var wrap = document.createElement('div'); wrap.className = 'msg-wrap';
    var content = document.createElement('div'); content.className = 'msg-ai';
    content.innerHTML = '<span class="loading">正在生成...</span>';
    wrap.appendChild(content); chatArea.appendChild(wrap); scrollBottom();
    return content;
  }
  function addToolStatus(text){
    clearHint(); var wrap = document.createElement('div'); wrap.className = 'msg-wrap';
    var div = document.createElement('div'); div.className = 'tool-status';
    div.innerHTML = '<b>' + escapeHTML(text) + '</b>';
    wrap.appendChild(div); chatArea.appendChild(wrap); scrollBottom();
    return div;
  }
  
  var currentXhr = null, isAborted = false;
  function setStopMode(isStop) {
    btnSend.innerHTML = isStop ? '■' : '➤';
    btnSend.className = 'btn-send' + (isStop ? ' stop-mode' : '');
  }
  function stopGeneration() {if(!thinking || !currentXhr) return; isAborted = true; try{currentXhr.abort()}catch(e){}}
  
  var currentMsgEl = null, reqMessages = [], reqBody = {};
  var userText = '', userImgs = [];
  
  function send() {
    if(thinking) {stopGeneration(); return}
    var text = inputBox.value;
    var currentImgs = imgs.slice();
    if(!text && !currentImgs.length) return;
    if(!CURRENT_SID) createNewSession();
    var s = getCurrentSession(); if(!s) return;
    
    addUserMsg(text, currentImgs);
    inputBox.value = ''; inputBox.style.height = '40px'; imgs = []; updateImgBadge();
    
    userText = text; userImgs = currentImgs;
    currentMsgEl = createAIMsg();
    thinking = true; isAborted = false; setStopMode(true);
    reqMessages = [];
    
    for(var i=0; i<s.m.length; i++){
      var hm = s.m[i];
      if(hm.role === 'tool') continue;
      if(hm.content && typeof hm.content === 'object' && hm.content.tool_calls) continue;
      
      if(hm.images && hm.images.length){
        var cnt = [{type:'text', text: hm.content || '请描述这张图片'}];
        for(var j=0; j<hm.images.length; j++) cnt.push({type:'image_url', image_url:{url: hm.images[j]}});
        reqMessages.push({role: hm.role, content: cnt});
      } else {
        reqMessages.push({role: hm.role, content: hm.content});
      }
    }
    
    var curCnt = [];
    if(text) curCnt.push({type:'text', text: text});
    for(var k=0; k<currentImgs.length; k++) curCnt.push({type:'image_url', image_url:{url: currentImgs[k]}});
    reqMessages.push({role: 'user', content: curCnt.length === 1 && text ? text : curCnt});
    
    reqBody = {model: model, messages: reqMessages, stream: true};
    if(thinkEnabled) reqBody.thinking = {type: 'enabled'};
    
    var isSearchStream = false;
    if(srchEnabled) {
      reqBody.stream = false;
      reqBody.tools = [{type:'function', function:{name:'web_search', description:'Search the web', parameters:{type:'object', properties:{query:{type:'string', description:'Search query'}}, required:['query']}}}];
      isSearchStream = true;
    }
    
    startStream(isSearchStream);
  }
  
  function getApiPath() {
    var isPersonal = (model === 'deepseek-v4-flash-vision');
    return isPersonal ? '/api/chat-personal' : '/api/chat';
  }
  
  var lastIndex = 0, buffer = '', thinkText = '', contentText = '', done = false;
  var pollTimeout = null, renderTimeout = null;
  
  function doRender() {
    var html = '';
    if(thinkText) {
      html += '<div style="color:#999;font-size:13px;margin-bottom:5px;border-left:2px solid #ccc;padding-left:5px">' + parseMarkdown(thinkText) + '</div>';
    }
    html += parseMarkdown(contentText || '<span class="loading">正在生成...</span>');
    currentMsgEl.innerHTML = html;
    scrollBottom();
  }
  
  function scheduleRender() {
    if(renderTimeout) return;
    renderTimeout = setTimeout(function(){
      renderTimeout = null;
      doRender();
    }, 250);
  }
  
  function processChunk() {
    if(done) return;
    try {
      var rt = currentXhr.responseText;
      if(rt && rt.length > lastIndex) {
        var newText = rt.substring(lastIndex);
        lastIndex = rt.length;
        buffer += newText;
        var parts = buffer.split('\\n');
        buffer = parts.pop(); 
        for(var i = 0; i < parts.length; i++) {
          var line = parts[i];
          if(line.indexOf('data:') !== 0) continue;
          var data = line.substring(5).replace(/^\\s+/, '').replace(/\\s+$/, '');
          if(!data) continue;
          if(data === '[DONE]') {done = true; continue}
          try {
            var json = JSON.parse(data);
            var choice = json.choices && json.choices[0];
            if(!choice) continue;
            var delta = choice.delta || {};
            if(delta.reasoning_content) thinkText += delta.reasoning_content;
            if(delta.reasoning) thinkText += delta.reasoning; 
            if(delta.content) contentText += delta.content;
          } catch(e){}
        }
      }
    } catch(e) {}
    scheduleRender();
    if(!done && currentXhr.readyState < 4) {
      pollTimeout = setTimeout(processChunk, 50);
    }
  }
  
  function handleResponse(isSearchStream) {
    if(isAborted) {
      doRender();
      currentMsgEl.innerHTML += '<div style="color:#999;font-size:12px">(已停止)</div>';
      finishRequest();
      return;
    }
    if(currentXhr.status !== 200) {
      currentMsgEl.innerHTML = '<span style="color:#cc0000">请求失败 HTTP ' + currentXhr.status + '</span>';
      finishRequest();
      return;
    }
    
    if(isSearchStream) {
      try {
        var res = JSON.parse(currentXhr.responseText);
        var ch = res.choices[0];
        if(ch.finish_reason === 'tool_calls' && ch.message.tool_calls) {
          var tc = ch.message.tool_calls[0];
          var q = JSON.parse(tc.function.arguments).query;
          var tsEl = addToolStatus('正在搜索: ' + q);
          
          var cleanMsg = {role: 'assistant', content: ch.message.content || '', tool_calls: ch.message.tool_calls};
          reqMessages.push(cleanMsg);
          
          // 传递搜索数量限制给后端
          var searchUrl = '/api/tavily?q=' + encodeURIComponent(q) + '&limit=' + srchLimit;
          fetch(searchUrl).then(function(r){return r.text()}).then(function(r){
            tsEl.innerHTML = '<b>已搜索: ' + escapeHTML(q) + '</b><div class="search-results">' + escapeHTML(r) + '</div>';
            reqMessages.push({role: 'tool', tool_call_id: tc.id, content: r});
            reqBody.stream = true;
            delete reqBody.tools;
            startStream(false); 
          }).catch(function(err){
            currentMsgEl.innerHTML = '<span style="color:#cc0000">联网搜索失败</span>';
            finishRequest();
          });
          return;
        } else {
          contentText = ch.message.content || '';
          doRender();
        }
      } catch(e) {
        currentMsgEl.innerHTML = '<span style="color:#cc0000">解析错误</span>';
      }
    } else {
      processChunk();
      doRender();
      if(!contentText && !thinkText) currentMsgEl.innerHTML = '<span style="color:#999">(无内容)</span>';
    }
    finishRequest();
  }
  
  function startStream(isSearchStream) {
    currentXhr = new XMLHttpRequest();
    currentXhr.open('POST', getApiPath());
    currentXhr.setRequestHeader('Content-Type', 'application/json');
    lastIndex = 0; buffer = ''; thinkText = ''; contentText = ''; done = false;
    pollTimeout = null; renderTimeout = null;
    
    currentXhr.onreadystatechange = function() {
      if(currentXhr.readyState === 3) {
        if(pollTimeout) {clearTimeout(pollTimeout); pollTimeout = null}
        processChunk();
      } else if(currentXhr.readyState === 4) {
        if(pollTimeout) {clearTimeout(pollTimeout); pollTimeout = null}
        if(renderTimeout) {clearTimeout(renderTimeout); renderTimeout = null}
        handleResponse(isSearchStream);
      }
    };
    
    pollTimeout = setTimeout(processChunk, 50);
    try {
      currentXhr.send(JSON.stringify(reqBody));
    } catch(e) {
      currentMsgEl.innerHTML = '<span style="color:#cc0000">发送失败</span>';
      finishRequest();
    }
  }
  
  function finishRequest() {
    thinking = false; currentXhr = null; setStopMode(false); scrollBottom();
    var s = getCurrentSession();
    if(contentText && !isAborted && s) {
      s.m.push({role: 'user', content: userText, images: userImgs});
      s.m.push({role: 'assistant', content: contentText, thinking: thinkText});
      if(s.m.length > 40) s.m = s.m.slice(s.m.length - 40);
      if(s.t === '新对话') {s.t = (userText || '[图片]').substring(0, 15); titleView.innerHTML = escapeHTML(s.t)}
      var arr = getSessions();
      for(var k=0; k<arr.length; k++){if(arr[k].id === s.id){arr[k] = s; break}}
      saveSessions(arr); renderSessions();
    }
  }
  
  btnSend.onclick = send;
  inputBox.onkeydown = function(e){e = e || window.event; if(e.keyCode === 13){if(e.ctrlKey || e.metaKey){send(); return false}} return true};
  inputBox.oninput = function(){inputBox.style.height = '40px'; if(inputBox.scrollHeight > 40) inputBox.style.height = (inputBox.scrollHeight > 80 ? 80 : inputBox.scrollHeight) + 'px'};
  
  btnThink.onclick = function(){
    thinkEnabled = !thinkEnabled; 
    btnThink.className = thinkEnabled ? 'tool-btn active' : 'tool-btn';
  };
  btnImg.onclick = function(){imgInput.click()};
  imgInput.onchange = function(e){var f = e.target.files[0]; if(!f) return; compressImg(f, function(dataUrl){imgs.push(dataUrl); updateImgBadge()})};
  btnSettings.onclick = function(){var is = settingsPanel.className.indexOf('show') >= 0; hidePanels(); if(!is) settingsPanel.className = 'panel show'};
  btnSessions.onclick = function(){var is = sessionsPanel.className.indexOf('show') >= 0; hidePanels(); if(!is){renderSessions(); sessionsPanel.className = 'panel show'}};
  btnNewSession.onclick = createNewSession;
  btnClearAll.onclick = function(){if(confirm('清空所有对话？')) clearAllSessions()};
  sessionsList.onclick = function(e){e = e || window.event; var t = e.target || e.srcElement; if(t.className === 'session-item-del'){if(confirm('删除此对话？')) deleteSession(t.getAttribute('sid'))} else if(t.className === 'session-item' || t.parentNode.className === 'session-item'){var id = t.getAttribute('sid') || t.parentNode.getAttribute('sid'); if(id){CURRENT_SID = id; lsSet('p_sid', CURRENT_SID); renderSessions(); renderChat(); hidePanels()}}};
  themeSelect.onchange = function(){theme = this.value; lsSet('p_theme', theme); document.body.className = theme === 'dark' ? 'dark' : ''};
  zoomSelect.onchange = function(){zoom = this.value; lsSet('p_zoom', zoom); document.body.style.zoom = zoom / 100};
  modelSelect.onchange = function(){model = this.value; lsSet('p_model', model)};
  searchSelect.onchange = function(){srchEnabled = this.value === 'on'; lsSet('p_search', this.value)};
  searchLimitSelect.onchange = function(){srchLimit = this.value; lsSet('p_search_limit', this.value)};
  
  if(!getCurrentSession()) {createNewSession()} else {renderSessions(); renderChat()}
})();
</script>
</body>
</html>`;

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;
    const p = url.searchParams.get('p');
    
    const noCacheHeaders = {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate'
    };
    
    if (p === '121126') {
      return new Response(HTML_PERSONAL, { headers: noCacheHeaders });
    }
    if (path === '/api/chat-personal') return handlePersonalChat(request);
    if (path === '/api/chat') return handlePublicChat(request);
    if (path === '/api/tavily') return handleTavilySearch(request);
    
    return new Response(HTML_PUBLIC, { headers: noCacheHeaders });
  }
};

async function handlePersonalChat(request) {
  try {
    const body = await request.json();
    const resp = await fetch(PERSONAL_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + PERSONAL_API_KEY
      },
      body: JSON.stringify(body)
    });
    
    if (!resp.ok) {
      const text = await resp.text();
      return new Response('上游错误: ' + text, { status: resp.status, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    }
    
    if (body.stream) {
      return new Response(resp.body, {
        headers: { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no' }
      });
    } else {
      const text = await resp.text();
      return new Response(text, { headers: { 'Content-Type': 'application/json; charset=utf-8' } });
    }
  } catch(e) {
    return new Response('Error: ' + e.message, { status: 500 });
  }
}

async function handleTavilySearch(request) {
  try {
    const url = new URL(request.url);
    const query = url.searchParams.get('q') || '';
    let limit = parseInt(url.searchParams.get('limit') || '3', 10);
    
    // 严格限制 1-7 条
    if(isNaN(limit) || limit < 1) limit = 1;
    if(limit > 7) limit = 7;
    
    if (!query) return new Response('Missing query', { status: 400 });
    
    const resp = await fetch('https://api.tavily.com/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ api_key: TAVILY_API_KEY, query: query, max_results: limit })
    });
    
    if (!resp.ok) {
      const text = await resp.text();
      return new Response('Tavily error: ' + text, { status: resp.status });
    }
    
    const data = await resp.json();
    let results = '';
    if (data.results && data.results.length > 0) {
      for (let i = 0; i < data.results.length; i++) {
        results += `[${i+1}] ${data.results[i].title}\nURL: ${data.results[i].url}\n${data.results[i].content}\n\n`;
      }
    }
    return new Response(results || 'No results', { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
  } catch(e) {
    return new Response('Server error: ' + e.message, { status: 500 });
  }
}

async function handlePublicChat(request) {
  try {
    const body = await request.json();
    const reqBody = {
      model: body.model || 'glm-4.7-flash',
      messages: body.messages || [],
      stream: body.stream !== false
    };
    if (body.thinking) reqBody.thinking = body.thinking;
    
    let lastErrResp = null;
    let keys = API_KEYS.slice();
    
    for (let i = 0; i < 3; i++) {
      const key = keys[Math.floor(Math.random() * keys.length)];
      const resp = await fetch(API_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + key,
          'Accept': reqBody.stream ? 'text/event-stream' : 'application/json'
        },
        body: JSON.stringify(reqBody)
      });
      
      if (resp.ok || (resp.status < 500 && resp.status !== 429 && resp.status !== 401)) {
        if (reqBody.stream) {
          return new Response(resp.body, {
            headers: {
              'Content-Type': 'text/event-stream; charset=utf-8',
              'Cache-Control': 'no-cache',
              'Connection': 'keep-alive',
              'X-Accel-Buffering': 'no'
            }
          });
        } else {
          const text = await resp.text();
          return new Response(text, { headers: { 'Content-Type': 'application/json; charset=utf-8' } });
        }
      }
      lastErrResp = resp;
    }
    
    const text = await lastErrResp.text();
    let displayMsg = text;
    if (lastErrResp.status === 429) {
      displayMsg = '请求过多，请稍候再试';
    } else if (text.indexOf('429') >= 0 || text.indexOf('请求过多') >= 0) {
      displayMsg = '请求过多，请稍候再试';
    }
    return new Response(displayMsg, {
      status: lastErrResp.status,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' }
    });
    
  } catch(e) {
    return new Response('Error: ' + e.message, { status: 500, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
  }
}