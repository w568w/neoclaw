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
        break;
      case "started":
        setAgentRunning(true);
        break;
      case "assistant_delta":
        appendAssistantDelta(msg.text);
        break;
      case "tool_started":
        addToolCard(msg.syscall_id, msg.name);
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

  function addToolCard(syscallId, name) {
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
    details.appendChild(output);
    dom.messages.appendChild(details);
    scrollToBottom();
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

    dom.input.value = "";
    autoResizeInput();
    addMessage("msg msg-user", text);
    send({ cmd: "query", agent_id: state.currentAgentId, text: text });
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
