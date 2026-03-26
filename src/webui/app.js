(function () {
  "use strict";

  var state = {
    ws: null,
    lastSeq: 0,
    currentAgentId: null,
    reconnectDelay: 500,
    agentRunning: false,
    currentAssistantEl: null,
    currentAssistantBuf: "",
    nextClientQueryId: 1,
    queryStatusEls: Object.create(null),
  };

  var dom = {
    messages: document.getElementById("messages"),
    input: document.getElementById("input"),
    btnSend: document.getElementById("btn-send"),
    btnCancel: document.getElementById("btn-cancel"),
    status: document.getElementById("status"),
  };

  function connect() {
    setStatus("connecting");
    var proto = location.protocol === "https:" ? "wss:" : "ws:";
    var url = proto + "//" + location.host + "/ws?from=" + state.lastSeq;
    state.ws = new WebSocket(url);

    state.ws.onopen = function () {
      setStatus("connected");
      state.reconnectDelay = 500;
    };

    state.ws.onmessage = function (e) {
      try {
        var msg = JSON.parse(e.data);
        if (msg.seq) state.lastSeq = msg.seq;
        handleEvent(msg);
      } catch (err) {
        console.error("Failed to parse message:", err, e.data);
      }
    };

    state.ws.onclose = function () {
      setStatus("disconnected");
      state.ws = null;
      setTimeout(function () {
        state.reconnectDelay = Math.min(state.reconnectDelay * 1.5, 10000);
        connect();
      }, state.reconnectDelay);
    };

    state.ws.onerror = function () {
      state.ws.close();
    };
  }

  function send(cmd) {
    if (state.ws && state.ws.readyState === WebSocket.OPEN) {
      state.ws.send(JSON.stringify(cmd));
    }
  }

  function setStatus(status) {
    dom.status.textContent = status;
    dom.status.className = "status " + status;
  }

  function setAgentRunning(running) {
    state.agentRunning = running;
    dom.btnCancel.disabled = !running;
  }

  // -- Event handling --

  function handleEvent(msg) {
    switch (msg.type) {
      case "accepted":
        state.currentAgentId = msg.agent_id;
        if (msg.client_query_id != null) {
          updateQueryStatus(msg.client_query_id, "queued");
        }
        break;
      case "started":
        setAgentRunning(true);
        if (msg.client_query_id != null) {
          updateQueryStatus(msg.client_query_id, "processing");
        }
        break;
      case "assistant_delta":
        appendAssistantDelta(msg.text);
        break;
      case "tool_started":
        if (msg.name !== "ask_user") {
          addToolCard(msg.syscall_id, msg.name, msg.args_json || "{}");
        }
        break;
      case "tool_waiting":
        updateToolStatus(msg.syscall_id, "running", "waiting...");
        break;
      case "tool_detached":
        updateToolStatus(msg.syscall_id, "running", "detached");
        break;
      case "tool_completed":
        updateToolStatus(msg.syscall_id, msg.ok ? "ok" : "failed", msg.ok ? "done" : "failed");
        setToolOutput(msg.syscall_id, msg.output);
        break;
      case "tool_cancelled":
        updateToolStatus(msg.syscall_id, "cancelled", "cancelled");
        break;
      case "waiting_user":
        addAskPrompt(msg.agent_id, msg.syscall_id, msg.question);
        break;
      case "message_incomplete":
        finalizeAssistant();
        addMessage("msg msg-system", "incomplete: " + msg.partial_content);
        break;
      case "finished":
        finalizeAssistant();
        setAgentRunning(false);
        if (msg.client_query_id != null) {
          updateQueryStatus(msg.client_query_id, "done");
        }
        break;
      case "fault":
        addMessage("msg msg-fault", "[fault] " + msg.message);
        setAgentRunning(false);
        break;
    }
  }

  // -- DOM helpers --

  function addMessage(className, text) {
    var el = document.createElement("div");
    el.className = className;
    el.textContent = text;
    dom.messages.appendChild(el);
    scrollToBottom();
  }

  function addUserQueryMessage(text, clientQueryId) {
    var el = document.createElement("div");
    el.className = "msg msg-user";

    var textSpan = document.createElement("span");
    textSpan.textContent = text;
    el.appendChild(textSpan);

    var statusSpan = document.createElement("span");
    statusSpan.className = "query-status queued";
    statusSpan.title = "排队中";
    statusSpan.setAttribute("aria-label", "排队中");
    el.appendChild(statusSpan);

    state.queryStatusEls[String(clientQueryId)] = statusSpan;
    dom.messages.appendChild(el);
    scrollToBottom();
  }

  function appendAssistantDelta(text) {
    if (!state.currentAssistantEl) {
      state.currentAssistantEl = document.createElement("div");
      state.currentAssistantEl.className = "msg msg-assistant";
      dom.messages.appendChild(state.currentAssistantEl);
    }

    state.currentAssistantBuf += text;
    state.currentAssistantEl.innerHTML = renderMarkdown(state.currentAssistantBuf);
    scrollToBottom();
  }

  function finalizeAssistant() {
    state.currentAssistantEl = null;
    state.currentAssistantBuf = "";
  }

  function addToolCard(syscallId, name, argsJson) {
    finalizeAssistant();

    var details = document.createElement("details");
    details.className = "tool-card";
    details.id = "tool-" + syscallId;

    var summary = document.createElement("summary");
    var nameSpan = document.createElement("span");
    nameSpan.className = "tool-name";
    nameSpan.textContent = name;
    var statusSpan = document.createElement("span");
    statusSpan.className = "tool-status running";
    statusSpan.id = "tool-status-" + syscallId;
    statusSpan.textContent = "running";
    summary.appendChild(nameSpan);
    summary.appendChild(statusSpan);

    var output = document.createElement("div");
    output.className = "tool-output";
    output.id = "tool-output-" + syscallId;

    details.appendChild(summary);
    var argsSpec = formatToolArgs(name, argsJson);
    if (argsSpec.show) {
      details.appendChild(renderToolArgs(argsSpec));
    }
    details.appendChild(output);
    dom.messages.appendChild(details);
    scrollToBottom();
  }

  function renderToolArgs(spec) {
    var wrap = document.createElement("div");
    wrap.className = "tool-args";

    var title = document.createElement("div");
    title.className = "tool-args-title";
    title.textContent = "arguments";
    wrap.appendChild(title);

    if (spec.lines && spec.lines.length > 0) {
      for (var i = 0; i < spec.lines.length; i++) {
        var row = document.createElement("div");
        row.className = "tool-args-row";

        var key = document.createElement("span");
        key.className = "tool-args-key";
        key.textContent = spec.lines[i][0];

        var value = document.createElement("span");
        value.className = "tool-args-value";
        value.textContent = spec.lines[i][1];

        row.appendChild(key);
        row.appendChild(value);
        wrap.appendChild(row);
      }
    }

    if (spec.code != null) {
      var codeBlock = document.createElement("pre");
      codeBlock.className = "tool-args-code";
      var code = document.createElement("code");
      code.textContent = spec.code;
      codeBlock.appendChild(code);
      wrap.appendChild(codeBlock);
    }

    if (spec.text != null) {
      var text = document.createElement("pre");
      text.className = "tool-args-text";
      text.textContent = spec.text;
      wrap.appendChild(text);
    }

    return wrap;
  }

  function formatToolArgs(name, argsJson) {
    var parsed = null;
    try {
      parsed = JSON.parse(argsJson);
    } catch (e) {}

    if (name === "code_run") {
      if (!parsed || typeof parsed !== "object") {
        return { show: true, lines: [], code: argsJson, text: null };
      }
      return {
        show: true,
        lines: [
          ["type", asText(parsed.type, "python")],
          ["timeout", asText(parsed.timeout, 10) + "s"],
          ["cwd", asText(parsed.cwd, ".")],
        ],
        code: asText(parsed.code, ""),
        text: null,
      };
    }

    if (name === "file_read") {
      return {
        show: true,
        lines: [["path", pickField(parsed, "path", "")]],
        code: null,
        text: null,
      };
    }

    if (name === "file_write") {
      var content = pickRawField(parsed, "content", "");
      return {
        show: true,
        lines: [
          ["path", pickField(parsed, "path", "")],
          ["mode", pickField(parsed, "mode", "overwrite")],
          ["content_bytes", String(content.length)],
        ],
        code: null,
        text: null,
      };
    }

    if (name === "memory_store") {
      return {
        show: true,
        lines: [
          ["key", pickField(parsed, "key", "")],
          ["operation", pickField(parsed, "operation", "set")],
        ],
        code: null,
        text: null,
      };
    }

    if (name === "memory_recall") {
      return {
        show: true,
        lines: [["query", pickField(parsed, "query", "")]],
        code: null,
        text: null,
      };
    }

    if (name === "memory_checkpoint") {
      var info = pickRawField(parsed, "key_info", "");
      return {
        show: true,
        lines: [["key_info_bytes", String(info.length)]],
        code: null,
        text: null,
      };
    }

    if (name === "ask_user") {
      return { show: false, lines: [], code: null, text: null };
    }

    return {
      show: true,
      lines: [],
      code: null,
      text: stringifyWithLimit(parsed, argsJson, 4096),
    };
  }

  function pickRawField(obj, key, fallback) {
    if (!obj || typeof obj !== "object") return fallback;
    if (!Object.prototype.hasOwnProperty.call(obj, key)) return fallback;
    var value = obj[key];
    if (typeof value === "string") return value;
    if (value == null) return "";
    try {
      return JSON.stringify(value);
    } catch (e) {
      return fallback;
    }
  }

  function pickField(obj, key, fallback) {
    return asText(pickRawField(obj, key, fallback), fallback);
  }

  function asText(value, fallback) {
    if (value == null) return String(fallback);
    if (typeof value === "string") return value;
    return String(value);
  }

  function stringifyWithLimit(parsed, raw, maxLen) {
    var text = raw;
    if (parsed != null) {
      try {
        text = JSON.stringify(parsed, null, 2);
      } catch (e) {
        text = raw;
      }
    }
    if (text.length <= maxLen) return text;
    return text.slice(0, maxLen) + "\n... (truncated)";
  }

  function updateToolStatus(syscallId, cls, label) {
    var el = document.getElementById("tool-status-" + syscallId);
    if (!el) return;
    el.className = "tool-status " + cls;
    el.textContent = label;
  }

  function setToolOutput(syscallId, output) {
    var el = document.getElementById("tool-output-" + syscallId);
    if (!el) return;
    el.textContent = output;
  }

  function updateQueryStatus(clientQueryId, status) {
    var key = String(clientQueryId);
    var el = state.queryStatusEls[key];
    if (!el) return;
    el.className = "query-status " + status;
    if (status === "queued") {
      el.title = "排队中";
      el.setAttribute("aria-label", "排队中");
    } else if (status === "processing") {
      el.title = "处理中";
      el.setAttribute("aria-label", "处理中");
    } else {
      el.title = "已完成";
      el.setAttribute("aria-label", "已完成");
    }
    if (status === "done") {
      delete state.queryStatusEls[key];
    }
  }

  function addAskPrompt(agentId, syscallId, question) {
    finalizeAssistant();

    var el = document.createElement("div");
    el.className = "ask-prompt";

    var questionDiv = document.createElement("div");
    questionDiv.className = "ask-question";
    questionDiv.textContent = question;

    var row = document.createElement("div");
    row.className = "ask-input-row";
    var inp = document.createElement("input");
    inp.type = "text";
    inp.placeholder = "Your reply...";
    var btn = document.createElement("button");
    btn.textContent = "Reply";
    row.appendChild(inp);
    row.appendChild(btn);

    el.appendChild(questionDiv);
    el.appendChild(row);
    dom.messages.appendChild(el);

    function submitReply() {
      var text = inp.value.trim();
      if (!text) return;
      send({ cmd: "reply", agent_id: agentId, syscall_id: syscallId, text: text });

      while (el.lastChild) el.removeChild(el.lastChild);
      var q = document.createElement("div");
      q.className = "ask-question";
      q.textContent = question;
      var replied = document.createElement("div");
      replied.style.cssText = "color:var(--fg-dim);font-size:12px";
      replied.textContent = "replied: " + text;
      el.appendChild(q);
      el.appendChild(replied);
    }

    btn.onclick = submitReply;
    inp.onkeydown = function (e) {
      if (e.key !== "Enter") return;
      e.preventDefault();
      submitReply();
    };
    inp.focus();
    scrollToBottom();
  }

  // -- Input handling --

  function submitQuery() {
    var text = dom.input.value.trim();
    if (!text) return;

    var clientQueryId = state.nextClientQueryId;
    state.nextClientQueryId += 1;

    dom.input.value = "";
    autoResizeInput();
    addUserQueryMessage(text, clientQueryId);
    send({ cmd: "query", agent_id: state.currentAgentId, client_query_id: clientQueryId, text: text });
  }

  function autoResizeInput() {
    dom.input.style.height = "auto";
    dom.input.style.height = Math.min(dom.input.scrollHeight, 150) + "px";
  }

  function scrollToBottom() {
    dom.messages.scrollTop = dom.messages.scrollHeight;
  }

  // -- Minimal Markdown renderer --

  function renderMarkdown(src) {
    var html = "";
    var parts = src.split(/(```[\s\S]*?```)/g);
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].match(/^```/)) {
        var m = parts[i].match(/^```(\w*)\n?([\s\S]*?)```$/);
        if (m) {
          html += "<pre><code>" + escapeHtml(m[2]) + "</code></pre>";
        } else {
          html += escapeHtml(parts[i]);
        }
      } else {
        html += renderInlineMarkdown(parts[i]);
      }
    }
    return html;
  }

  function renderInlineMarkdown(src) {
    var lines = src.split("\n");
    var html = "";
    var inParagraph = false;

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var hm = line.match(/^(#{1,6})\s+(.+)$/);
      if (hm) {
        if (inParagraph) {
          html += "</p>";
          inParagraph = false;
        }
        var level = hm[1].length;
        html += "<h" + level + ">" + inlineFormat(hm[2]) + "</h" + level + ">";
        continue;
      }

      if (line.trim() === "") {
        if (inParagraph) {
          html += "</p>";
          inParagraph = false;
        }
        continue;
      }

      if (!inParagraph) {
        html += "<p>";
        inParagraph = true;
      } else {
        html += "<br>";
      }
      html += inlineFormat(line);
    }

    if (inParagraph) html += "</p>";
    return html;
  }

  function inlineFormat(text) {
    text = text.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
    text = text.replace(/\*(.+?)\*/g, "<em>$1</em>");
    text = text.replace(/`([^`]+)`/g, "<code>$1</code>");
    text = text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
    return text;
  }

  function escapeHtml(s) {
    return s
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // -- Initialization --

  dom.btnSend.onclick = submitQuery;
  dom.input.onkeydown = function (e) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submitQuery();
    }
  };
  dom.input.oninput = autoResizeInput;
  dom.btnCancel.onclick = function () {
    if (state.currentAgentId != null) {
      send({ cmd: "cancel", agent_id: state.currentAgentId });
    }
  };

  connect();
})();
