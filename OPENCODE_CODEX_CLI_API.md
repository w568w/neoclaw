# 1. OpenCode 中 OpenAI 订阅版 Codex CLI API 请求实现

## 1.1. 范围

本文只整理 `anomalyco/opencode` 里“OpenAI 订阅版 Codex CLI”相关实现，不讨论 GitHub Copilot 专有鉴权。

关键代码位置：

- `packages/opencode/src/plugin/codex.ts`
- `packages/opencode/src/session/llm.ts`
- `packages/opencode/src/session/system.ts`
- `packages/opencode/src/provider/provider.ts`
- `packages/opencode/src/provider/transform.ts`
- `packages/opencode/src/provider/sdk/copilot/responses/convert-to-openai-responses-input.ts`
- `packages/opencode/src/provider/sdk/copilot/responses/openai-responses-language-model.ts`
- `packages/opencode/src/provider/sdk/copilot/responses/openai-responses-prepare-tools.ts`

## 1.2. 结论先看

- OpenCode 对 OpenAI 的 `openai` provider 固定走 `Responses API`，即内部始终调用 `sdk.responses(modelID)`。
- 当 `openai` 鉴权类型是 `oauth` 时，会启用 `CodexAuthPlugin`，把原本发往 `/v1/responses` 或 `/chat/completions` 的请求，统一改写到 `https://chatgpt.com/backend-api/codex/responses`。
- 认证不是 OpenAI 普通 API Key，而是 ChatGPT 订阅账号 OAuth / Device Auth 拿到的 `access_token` / `refresh_token`。
- 实际请求体仍然是 OpenAI `Responses API` 风格 JSON，只是目标地址和认证头变成了 ChatGPT Web Codex 后端接口。

## 1.3. 请求总流程

1. 用户通过浏览器 OAuth 或无头 Device Auth 登录 ChatGPT 订阅账号。
2. OpenCode 保存 `refresh_token`、`access_token`、过期时间，以及从 JWT 中解析出的 `accountId`。
3. 发起模型请求时，OpenCode 先按 `Responses API` 规则构造 JSON body。
4. 插件删除占位 `Authorization`，改为真实 `Bearer <access_token>`。
5. 如果拿到了组织 / 订阅账号 ID，再补 `ChatGPT-Account-Id` 请求头。
6. 只要路径是 `/v1/responses` 或 `/chat/completions`，最终都会被重写到 `https://chatgpt.com/backend-api/codex/responses`。

# 2. 登录方法与发送的请求

## 2.1. 浏览器 OAuth 登录

### 2.1.1. 发起授权页

OpenCode 本地启动一个回调服务：

- 监听端口：`1455`
- 回调地址：`http://localhost:1455/auth/callback`

然后拼接浏览器授权地址：

`GET https://auth.openai.com/oauth/authorize`

查询参数如下：

```text
response_type=code
client_id=app_EMoamEEZ73f0CkXaXp7hrann
redirect_uri=http://localhost:1455/auth/callback
scope=openid profile email offline_access
code_challenge=<PKCE challenge>
code_challenge_method=S256
id_token_add_organizations=true
codex_cli_simplified_flow=true
state=<random state>
originator=opencode
```

说明：

- 使用 PKCE，`code_verifier` 长度固定 43。
- `state` 用于防 CSRF。
- `id_token_add_organizations=true` 使返回的 token 带上组织信息，后续可提取 `ChatGPT-Account-Id`。
- `originator=opencode` 用于标记来源。

### 2.1.2. 本地回调处理

本地服务只处理两个路径：

- `GET /auth/callback`
- `GET /cancel`

`/auth/callback` 会读取：

- `code`
- `state`
- `error`
- `error_description`

校验通过后，用授权码换 token。

### 2.1.3. 授权码换 token

`POST https://auth.openai.com/oauth/token`

请求头：

```http
Content-Type: application/x-www-form-urlencoded
```

请求体：

```text
grant_type=authorization_code
code=<callback code>
redirect_uri=http://localhost:1455/auth/callback
client_id=app_EMoamEEZ73f0CkXaXp7hrann
code_verifier=<pkce verifier>
```

期望返回：

```json
{
  "id_token": "...",
  "access_token": "...",
  "refresh_token": "...",
  "expires_in": 3600
}
```

### 2.1.4. 刷新 access token

如果本地保存的 `access_token` 过期，OpenCode 会自动刷新：

`POST https://auth.openai.com/oauth/token`

请求头：

```http
Content-Type: application/x-www-form-urlencoded
```

请求体：

```text
grant_type=refresh_token
refresh_token=<saved refresh_token>
client_id=app_EMoamEEZ73f0CkXaXp7hrann
```

刷新成功后会覆盖本地保存的：

- `refresh`
- `access`
- `expires`
- `accountId`（若新 token 中能重新解析出来）

## 2.2. 无头 Device Auth 登录

这是代码里标记为 `ChatGPT Pro/Plus (headless)` 的方式。

### 2.2.1. 申请用户码

`POST https://auth.openai.com/api/accounts/deviceauth/usercode`

请求头：

```http
Content-Type: application/json
User-Agent: opencode/<version>
```

请求体：

```json
{
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"
}
```

返回示例结构：

```json
{
  "device_auth_id": "...",
  "user_code": "XXXX-XXXX",
  "interval": "5"
}
```

CLI 会提示用户打开：

`https://auth.openai.com/codex/device`

并输入 `user_code`。

### 2.2.2. 轮询设备授权状态

`POST https://auth.openai.com/api/accounts/deviceauth/token`

请求头：

```http
Content-Type: application/json
User-Agent: opencode/<version>
```

请求体：

```json
{
  "device_auth_id": "<device_auth_id>",
  "user_code": "<user_code>"
}
```

轮询逻辑：

- 若返回 `200`，拿到：

```json
{
  "authorization_code": "...",
  "code_verifier": "..."
}
```

- 若返回 `403` 或 `404`，继续等待并轮询。
- 其他状态码直接视为失败。
- 轮询等待时间为：`interval * 1000 + 3000ms`。

### 2.2.3. 设备授权码换 token

拿到 `authorization_code` 后，再请求：

`POST https://auth.openai.com/oauth/token`

请求头：

```http
Content-Type: application/x-www-form-urlencoded
```

请求体：

```text
grant_type=authorization_code
code=<authorization_code>
redirect_uri=https://auth.openai.com/deviceauth/callback
client_id=app_EMoamEEZ73f0CkXaXp7hrann
code_verifier=<code_verifier>
```

返回 token 结构与浏览器 OAuth 相同。

## 2.3. Account ID 的提取规则

OpenCode 会优先从 `id_token`，其次从 `access_token` 解 JWT claim，按以下顺序取账号 / 组织 ID：

1. `chatgpt_account_id`
2. `https://api.openai.com/auth.chatgpt_account_id`
3. `organizations[0].id`

如果拿到了该值，后续模型请求会补：

```http
ChatGPT-Account-Id: <accountId>
```

# 3. 模型请求是如何发出的

## 3.1. OpenAI provider 固定走 Responses API

`packages/opencode/src/provider/provider.ts` 中，`openai` provider 的 `getModel()` 固定返回：

```ts
return sdk.responses(modelID)
```

因此 OpenCode 对 OpenAI 的正常调用入口就是 `Responses API`，不是旧式 Chat Completions。

## 3.2. Codex 模式的触发条件

满足以下条件时会进入 Codex 模式：

- provider 是 `openai`
- auth 类型是 `oauth`

也就是：

- 如果你手填 API Key，不会走 ChatGPT 订阅版 Codex 后端。
- 只有 ChatGPT Pro/Plus 的 OAuth / Device Auth 登录，才会启用这套改写逻辑。

## 3.3. 允许使用的模型

OAuth 模式下插件会裁剪模型列表，只保留允许的模型。代码里显式允许：

- `gpt-5.1-codex`
- `gpt-5.1-codex-max`
- `gpt-5.1-codex-mini`
- `gpt-5.2`
- `gpt-5.2-codex`
- `gpt-5.3-codex`
- `gpt-5.4`
- `gpt-5.4-mini`

如果缺少 `gpt-5.3-codex`，还会在本地补一份模型定义，API 地址标记为：

`https://chatgpt.com/backend-api/codex`

## 3.4. 发送前统一加的请求头

插件在 `chat.headers` 钩子里额外加入：

```http
originator: opencode
User-Agent: opencode/<version> (<platform> <release>; <arch>)
session_id: <sessionID>
```

真正发送时，`fetch` 包装层还会处理认证头：

```http
Authorization: Bearer <access_token>
ChatGPT-Account-Id: <accountId>   // 可选
```

注意：

- 先删除占位用的 dummy `Authorization`。
- 再写入真实 OAuth Bearer token。

## 3.5. 最终目标地址

插件会检查原始 URL：

- 如果路径包含 `/v1/responses`
- 或路径包含 `/chat/completions`

则统一重写成：

`https://chatgpt.com/backend-api/codex/responses`

也就是说，OpenCode 内部虽然按 OpenAI SDK 的常规路径组装请求，但真正发出去时，已经被接管到 ChatGPT Web 的 Codex 专用后端。

# 4. 请求体构造规则

## 4.1. 顶层 body 字段

`openai-responses-language-model.ts` 里最终提交的 body 由以下字段组成：

```json
{
  "model": "gpt-5.3-codex",
  "input": [],
  "temperature": 0.7,
  "top_p": 1,
  "max_output_tokens": 8192,
  "text": {
    "format": { "type": "json_schema" },
    "verbosity": "low"
  },
  "max_tool_calls": 8,
  "metadata": {},
  "parallel_tool_calls": true,
  "previous_response_id": "resp_xxx",
  "store": true,
  "user": "user_xxx",
  "instructions": "...",
  "service_tier": "auto",
  "include": ["reasoning.encrypted_content"],
  "prompt_cache_key": "session_xxx",
  "safety_identifier": "safe_xxx",
  "top_logprobs": 20,
  "reasoning": {
    "effort": "medium",
    "summary": "auto"
  },
  "truncation": "auto",
  "tools": [],
  "tool_choice": "auto",
  "stream": true
}
```

其中：

- `stream` 只在流式请求里加。
- 并非所有字段每次都会出现，绝大部分是按条件拼接。
- `Codex` 常见请求一定会有：`model`、`input`、`instructions`，通常还会带 `reasoning`。

## 4.2. Codex 会把系统提示放进 `instructions`

Codex 会话下，`packages/opencode/src/session/llm.ts` 有一个特殊处理：

- 不再把 provider 级 system prompt 放入消息数组。
- 而是把 `SystemPrompt.instructions()` 的内容直接写入 provider options 的 `instructions` 字段。

该内容来源于：

`packages/opencode/src/session/prompt/codex_header.txt`

因此发到后端的风格更接近：

- `instructions`: 大段系统规则
- `input`: 实际对话消息

而不是把完整 system prompt 塞进 `input[0]`。

## 4.3. gpt-5 / codex 默认 provider options

对 `gpt-5` 且非 `gpt-5-chat` 模型，默认会附加：

- `reasoningEffort: "medium"`
- `reasoningSummary: "auto"`

但如果是 `gpt-5-pro`，不会自动加这两个值。

对于 `codex` 模型，不会自动加 `textVerbosity: "low"`，因为代码显式排除了 `codex`。

## 4.4. reasoning 模型的特殊限制

对 `gpt-5` / `codex` / `o` 系列，代码把它们视为 reasoning model：

- `system` message 会转成 `developer` role
- `temperature` 不支持时会被删掉
- `top_p` 不支持时会被删掉

另有一些统一不支持项会记 warning：

- `topK`
- `seed`
- `presencePenalty`
- `frequencyPenalty`
- `stopSequences`

## 4.5. `input` 的消息映射规则

### 4.5.1. system / developer

输入消息里的 `system` role 会按模型能力映射成：

- `system`
- `developer`
- 或直接丢弃

对 `gpt-5` / `codex`，这里会走 `developer`。

### 4.5.2. user 消息

用户文本：

```json
{ "role": "user", "content": [{ "type": "input_text", "text": "..." }] }
```

用户图片支持三种形式：

- 远程 URL -> `image_url`
- 已上传 file id -> `file_id`
- 二进制 -> 转 `data:<mime>;base64,...`

用户 PDF 支持三种形式：

- 远程 URL -> `file_url`
- 已上传 file id -> `file_id`
- 本地内容 -> `file_data` + `filename`

### 4.5.3. assistant 消息

普通文本：

```json
{
  "role": "assistant",
  "content": [{ "type": "output_text", "text": "..." }]
}
```

如果 assistant 消息里包含工具调用：

- 普通工具 -> `function_call`
- `local_shell` -> `local_shell_call`

如果 assistant 消息里包含 provider 已执行工具的结果：

- 当 `store=true` 时，转成 `item_reference`
- 当 `store=false` 时，不回传工具结果，并记录 warning

### 4.5.4. tool 角色消息

工具执行结果会被转成：

- 普通工具 -> `function_call_output`
- `local_shell` -> `local_shell_call_output`

输出值统一被折叠成字符串：

- 文本原样传
- JSON / content 类型 `JSON.stringify()` 后再传

## 4.6. input item 的 `id` 会被剥离

`packages/opencode/src/provider/provider.ts` 里有额外一层处理：

- 只要是 `@ai-sdk/openai` 且 `POST` body 里有 `input`
- 就会删除各个 input item 上的 `id`

注释写得很明确：这是“跟随 codex 的做法”。

因此对 OpenAI 订阅版 Codex，请求体里的输入 items 最终通常不带 `id`。

# 5. 工具请求是怎么编码进 body 的

## 5.1. 支持的工具类型

`prepareResponsesTools()` 会把内部工具描述映射成 OpenAI Responses tool 定义，支持：

- `function`
- `openai.file_search`
- `openai.local_shell`
- `openai.web_search_preview`
- `openai.web_search`
- `openai.code_interpreter`
- `openai.image_generation`

## 5.2. tool 定义映射

### 5.2.1. 普通 function

会编码成：

```json
{
  "type": "function",
  "name": "tool_name",
  "description": "...",
  "parameters": { "type": "object" },
  "strict": false
}
```

### 5.2.2. local shell

工具声明：

```json
{ "type": "local_shell" }
```

assistant 发起调用时的 input item：

```json
{
  "type": "local_shell_call",
  "call_id": "call_xxx",
  "action": {
    "type": "exec",
    "command": ["bash", "-lc", "pwd"],
    "timeout_ms": 10000,
    "working_directory": "/repo",
    "env": { "FOO": "bar" }
  }
}
```

工具结果：

```json
{
  "type": "local_shell_call_output",
  "call_id": "call_xxx",
  "output": "stdout/stderr merged text"
}
```

### 5.2.3. code interpreter

工具声明示例：

```json
{
  "type": "code_interpreter",
  "container": {
    "type": "auto",
    "file_ids": ["file-xxx"]
  }
}
```

### 5.2.4. web / file / image 工具

也都按 Responses API 的内建工具结构编码：

- `web_search`
- `web_search_preview`
- `file_search`
- `image_generation`

`tool_choice` 会被映射成：

- `auto`
- `none`
- `required`
- `{ "type": "function", "name": "..." }`
- 或内建工具的 `{ "type": "file_search" }` / `{ "type": "web_search" }` 等

# 6. 一个接近真实的 Codex 请求示例

## 6.1. 请求头

```http
POST /backend-api/codex/responses HTTP/1.1
Host: chatgpt.com
Authorization: Bearer <oauth access_token>
ChatGPT-Account-Id: <account_id>
Content-Type: application/json
originator: opencode
User-Agent: opencode/<version> (<platform> <release>; <arch>)
session_id: <session_id>
```

## 6.2. 请求体

```json
{
  "model": "gpt-5.3-codex",
  "input": [
    {
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "阅读这个仓库，并告诉我登录请求是怎么发的。"
        }
      ]
    }
  ],
  "instructions": "You are OpenCode, the best coding agent on the planet.\n...",
  "reasoning": {
    "effort": "medium",
    "summary": "auto"
  },
  "store": true,
  "tools": [
    { "type": "local_shell" }
  ],
  "tool_choice": "auto",
  "stream": true
}
```

说明：

- 这里的 `instructions` 实际是 `codex_header.txt` 的完整内容。
- `store` 默认值来自 `openaiOptions?.store ?? true`。
- 如果对话已经依赖前一次 response，也可能带 `previous_response_id`。

# 7. 流式响应事件是怎么解析的

## 7.1. 流式请求

流式模式与非流式模式的差异只有一点：

```json
{ "stream": true }
```

响应按 SSE 事件流解析。

## 7.2. 已实现解析的事件类型

代码里显式处理了这些事件：

- `response.created`
- `response.output_item.added`
- `response.output_item.done`
- `response.output_text.delta`
- `response.function_call_arguments.delta`
- `response.image_generation_call.partial_image`
- `response.code_interpreter_call_code.delta`
- `response.code_interpreter_call_code.done`
- `response.output_text.annotation.added`
- `response.reasoning_summary_part.added`
- `response.reasoning_summary_text.delta`
- `response.completed`
- `response.incomplete`
- `error`

## 7.3. 解析后的内部语义

这些事件会被转回 OpenCode 内部统一流：

- 文本增量 -> `text-start` / `text-delta` / `text-end`
- reasoning 增量 -> `reasoning-start` / `reasoning-delta` / `reasoning-end`
- 工具调用 -> `tool-input-start` / `tool-input-delta` / `tool-input-end` / `tool-call`
- provider 已执行工具 -> `tool-result`
- 引用来源 -> `source`
- 结束事件 -> `finish`

最终还会附带：

- `responseId`
- `usage.inputTokens`
- `usage.outputTokens`
- `usage.reasoningTokens`
- `usage.cachedInputTokens`
- `serviceTier`

# 8. 可以直接复现的最小实现要点

如果你要自己复刻 OpenCode 的 OpenAI 订阅版 Codex CLI 请求逻辑，最小必要条件是：

1. 用 `auth.openai.com` 完成 OAuth 或 Device Auth，拿到 `access_token` / `refresh_token`。
2. 从 JWT claim 中提取 `chatgpt_account_id` 或组织 ID。
3. 把消息按 OpenAI `Responses API` 的 `input` 格式编码。
4. 把系统提示放在 `instructions`，不要只塞进普通对话消息。
5. 请求发往 `https://chatgpt.com/backend-api/codex/responses`。
6. 带上 `Authorization: Bearer <token>`，有账号 ID 时再带 `ChatGPT-Account-Id`。
7. 流式场景按 SSE 解析 `response.*` 事件。

## 8.1. 与普通 OpenAI API Key 调用的差异

- 认证方式不同：不是 `sk-...`，而是 ChatGPT OAuth token。
- 目标地址不同：不是 `https://api.openai.com/v1/responses`，而是 `https://chatgpt.com/backend-api/codex/responses`。
- 可能需要 `ChatGPT-Account-Id`。
- 系统提示的注入方式更偏向 `instructions`。
