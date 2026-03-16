# 1. 当前已确认的设计决策

## 1.1 最小核心模型

- `Runtime` 是唯一状态拥有者、唯一公共事件排序者、唯一 `history` 修改者。
- `Agent` 是长寿命进程，持有会话历史、请求队列、`pending_interrupts` 邮箱和当前执行状态。
- `LlmDriver` 代表 Agent 的一次用户态执行片；它不直接修改 Runtime 状态，只把结果投递回 Runtime。
- Tool 统一被建模为 syscall；Tool 的执行可以由 Runtime 直接完成，或交给内核 worker 完成。
- 对外接口必须基于 append-only event log + cursor/subscription，不能使用 pop 式队列。

## 1.2 必须保持的不变量

- 所有 public event 只能由 Runtime 追加。
- `submit()` 返回时，对应 `accepted` 事件已经进入 event log。
- `recv()` 只能按 cursor 顺序读取事件，不能消费或删除事件。
- 每个 Agent 都必须有独立 mailbox，用于积压后台完成事件和其他内核中断。
- 每次 LLM invoke 必须有 `invoke_id`，每次 tool 调用必须有 `syscall_id`。
- 过期的 invoke 或 syscall 结果不得污染当前 Agent 状态。
- detach 型 tool 完成后，必须立刻写入 public event，同时把 completion 投递进对应 Agent 的 mailbox，并默认自动唤醒该 Agent。

## 1.3 简化后的 ID 方案

- 保留以下 ID：
  1. `event_seq`
  2. `agent_id`
  3. `request_id`
  4. `invoke_id`
  5. `syscall_id`
- 暂不单独引入 `command_id` 和 `op_id`；detach 型后台结果继续使用原 `syscall_id` 标识。

## 1.4 Tool syscall 语义

- tool 启动结果统一为 `ToolStartResult`，分三类：
  1. `ready`：立即完成，直接得到 tool result。
  2. `wait`：阻塞当前 Agent，等待 worker 或用户输入完成。
  3. `detach`：立即返回 ack，真实结果稍后通过事件补充。
- `wait` 进一步区分：
  1. `wait.worker`
  2. `wait.user`
- `ask_user` 属于 `wait.user`，不是普通字符串协议返回值。

## 1.5 Agent 最小状态模型

- 第一阶段状态收敛为：
  1. `idle`
  2. `running_llm`
  3. `waiting_sync_tool`
  4. `waiting_user`
  5. `terminated`
- `pending_interrupts` 是每个 Agent 自己的邮箱队列，不是全局共享结构。

## 1.6 第一阶段允许保留的简化

- 暂不实现 event log GC。
- 暂不实现 LLM invoke 中途抢占。
- 暂不实现 tool progress event。
- 暂不实现 detached operation 的独立 `op_id`。
- `submitReply()` 第一阶段只处理当前 `waiting_user` 的 Agent，不做更泛化的 reply 路由。

# 2. 已完成的阶段

## 2.1 阶段一（已完成）

1. 落地 `src/llm/mod.zig`，抽出模型无关的消息类型。
2. 让 `src/llm/openai.zig` 适配新的类型边界。
3. 调整 `src/root.zig` 与现有调用点，经统一 `llm` 模块引用消息类型。

## 2.2 阶段二（已完成）

1. 将 `src/loop.zig` 从 `Runner.next()` 改成 `Runtime`。
2. 引入 `EventLog` 和 `Subscription`。
3. 将前端改为 `submit + recv` 模式。

## 2.3 阶段三（已完成）

1. 引入 `ToolStartResult` 三态。
2. 将现有工具改造为 syscall 语义。
3. 实现 `ask_user -> wait.user`。

# 3. 近期待实现的部分

## 3.1 阶段四：异步 worker 与中断

1. 引入真正的异步 worker。
2. 支持 detach 型工具的后台完成与自动唤醒。
3. 增加中断、取消和更完整的调度策略。

具体需要设计的细节：
- LLM invoke 中途抢占的信号协议：Agent 收到 `cancel` Signal 后如何安全地中止当前 HTTP 流式请求并恢复到一致状态。
- Tool Worker 的超时与强制终止策略：超过 deadline 后如何回收 worker 线程并向 Agent 投递 fault。
- Agent 从 `running_llm` 被取消后的状态恢复路径：是丢弃已收到的 partial delta，还是保留为 incomplete message。

## 3.2 工具审批/权限模型

当前所有工具（包括 `code_run`）均无权限控制，可执行任意代码而无需用户确认。

设计方向：
- 每个工具导出一个编译期常量 `approval_level`，分三级：
  1. `never`：无风险工具（如 `file_read`），无需审批。
  2. `unless_approved`：除非用户在当前会话中预授权，否则需要审批（如 `file_write`）。
  3. `always`：每次调用都需要审批（如 `code_run`）。
- 在 `ToolStartResult` 中增加一个 `approve` 变体，语义类似 `wait.user`，但专用于权限确认。
- Runtime 维护一个 per-session 的 auto-approve 集合，用户可选择"本次会话信任此工具"。

## 3.3 上下文压缩（Context Compaction）

Agent 的 message history 当前会无限增长，最终超出模型上下文窗口。

设计方向：
- 在 Agent 中增加 `compact_history` 能力：当 token 数接近模型上下文限制时触发。
- 实现方式为一个特殊的 `wait.worker` 内部 syscall，调用 LLM 对旧对话做摘要。
- 压缩后的摘要消息替换原始的多条消息，保留最近 N 轮完整对话不压缩。
- 需要记录压缩前后的 token 数变化到 EventLog，供前端展示。

## 3.4 多 LLM Provider 抽象与容错链

当前只有 `openai.zig` 一个 LLM 后端。

设计方向：
- 抽出一个 `LlmProvider` vtable 接口（风格与 `KernelServices` 一致），定义 `complete()` 和 `completeStreaming()` 两个方法。
- 至少支持三种后端：
  1. OpenAI-compatible（当前实现，重构为此接口的一个实现）。
  2. Anthropic（Messages API，content blocks 格式不同）。
  3. Ollama（本地模型，OpenAI-compatible 子集）。
- Provider 装饰器链（每层包装上一层的 vtable）：
  1. `RetryProvider`：指数退避 + 解析 `Retry-After` 头。
  2. `FailoverProvider`：主模型不可用时自动切换到备用模型，按 provider 独立记录冷却时间。
  3. `CircuitBreakerProvider`（可选）：Closed -> Open -> HalfOpen 状态机，连续失败 N 次后短路。
- 所有装饰器保持零外部依赖，仅依赖 `std.time` 和 `std.Thread`。

# 4. 中期待实现的部分

## 4.1 安全层（Safety Layer）

当前工具输出直接拼入 LLM 上下文，没有任何安全边界。

设计方向：
- **工具输出包裹**：工具结果插入 LLM 上下文时，用明确的 XML 标签（如 `<tool_output>...</tool_output>`）包裹，防止工具输出被 LLM 误解为指令。
- **Prompt injection 基础检测**：对工具输出做模式匹配，检测常见注入模式（如 `<|system|>`、`[INST]`、`### System:`、`忽略以上所有指令` 等），命中时在 EventLog 中写入 `fault` 级别告警。
- **敏感参数脱敏**：工具可声明 `sensitive_params` 列表（如密码、token），这些参数在 EventLog 事件和日志中自动替换为 `***`。

## 4.2 多 Agent 编排

DESIGN.md 提到"可能同时运行多个 Agent 实例"，当前只有一个 main Agent。`AgentId` 已存在但未被利用。

设计方向：
- **Agent 生命周期管理**：引入 `spawn_agent` / `kill_agent` / `wait_agent` 三个内核操作，类比 `fork` / `kill` / `waitpid`。主 Agent 作为 init 进程管理子 Agent。
- **Agent 间通信（IPC）**：通过 Runtime inbox 互发信号。引入新的 Signal 变体 `ipc_message`，携带 `sender_agent_id` 和 payload。
- **共享与隔离**：每个 Agent 维护独立的 message history（进程虚拟内存），但可以通过 IPC 交换结构化数据。EventLog 作为全局共享的可观测层。

## 4.3 持久化与记忆系统

DESIGN.md 规定"记忆始终存在，永远不会重置"，当前完全没有实现。

设计方向：
- **EventLog 持久化**：将事件流写入磁盘。SQLite 是零外部依赖的选择（Zig 有 `std.c` 可以链接系统 libsqlite3，或者用纯 Zig 的文件格式）。
- **Agent history 序列化**：Agent 的 message history 支持序列化到磁盘和反序列化恢复，使得进程重启后可以继续对话。
- **记忆 syscall**：引入 `memory_store` / `memory_recall` 两个工具，提供简单的 KV 持久存储。Agent 可以主动存储重要信息供后续会话使用。
- 长期考虑全文搜索（FTS）和向量搜索的混合检索，但第一步先做 KV。

## 4.4 生命周期钩子（Hooks）

当前系统没有任何拦截点，无法在不修改核心代码的情况下添加审计、安全检查或自定义行为。

设计方向：
- 在 EventLog 的 `append` 路径中引入 hook 机制，允许注册的钩子在特定事件类型写入前拦截和修改。
- 关键拦截点：
  1. `before_tool_call`：工具调用前（可用于权限检查、参数校验）。
  2. `before_llm_invoke`：LLM 调用前（可用于 prompt 审计、注入检测）。
  3. `before_outbound`：响应发出前（可用于内容过滤）。
  4. `on_session_start` / `on_session_end`：会话边界（可用于初始化/清理）。
- Hook 结果为三态：`continue`（放行）、`modify`（修改后放行）、`reject`（拒绝，写入 fault 事件）。
- Hook 通过编译期注册（与工具注册方式一致），保持零运行时开销。

# 5. 长期可选增强

## 5.1 MCP（Model Context Protocol）支持

当前工具注册完全在编译期完成，缺乏运行时扩展能力。

设计方向：
- 引入 `mcp_connect` syscall，允许 Agent 连接外部 MCP 服务器（stdio 或 HTTP 传输）。
- 将 MCP 发现的工具包装为 `wait.worker` 类型的动态工具，与编译期注册的静态工具并行存在。
- MCP 工具在 `ToolRegistry` 中以特殊命名空间（如 `mcp.<server>.<tool>`）注册，避免与内置工具冲突。

## 5.2 多通道 I/O

当前只有 CLI/REPL 前端。EventLog + Subscription 架构天然支持多前端。

设计方向：
- 增加 HTTP/WebSocket 前端：通过 SSE 推送事件流，通过 POST 提交查询/回复。
- 确保 `root.zig` 的库 API 足够完整，支持嵌入到其他程序中使用。
- 长期可考虑 Web UI 前端（但不属于运行时内核职责，应作为独立项目）。

## 5.3 成本控制

当前完全没有 token 使用量和成本意识。

设计方向：
- 在 LLM 响应中解析 `usage` 字段（`prompt_tokens` / `completion_tokens`）。
- 记录每次调用的 token 消耗到 EventLog（新增 `llm_usage` 事件类型）。
- 维护累计成本计数器，支持配置每日/每小时限额，超限时拒绝新请求并写入 fault。

## 5.4 沙箱执行

当前 `code_run` 直接裸执行子进程，没有任何文件系统或网络隔离。

设计方向：
- 短期：利用 Zig 子进程 API 的 `chroot` / `setuid` 能力做基本隔离。
- 长期（仅 Linux）：通过 seccomp / landlock 系统调用限制子进程的 syscall 集合和文件系统访问范围。纯系统调用实现，不需要外部依赖。
- 可选：引入执行 budget（CPU 时间 + 内存上限），超限自动 kill。

## 5.5 可观测性

EventLog 已经是很好的可观测性基础，但缺少结构化的性能指标。

设计方向：
- **结构化日志**：统一日志格式，包含时间戳、agent_id、event_seq、级别。
- **指标（Metrics）**：记录 LLM 延迟、工具执行时间、token 使用量等关键指标。可以作为特殊的 EventLog 事件类型。
- **请求追踪**：每个 `request_id` 的完整生命周期链路（accepted -> started -> tool calls -> finished），方便调试和性能分析。

## 5.6 配置系统

当前只有 `.env` 文件 + 代码中的硬编码常量。

设计方向：
- 支持 TOML 或 JSON 配置文件，优先级：命令行参数 > 环境变量 > 配置文件 > 默认值。
- 配置项包括：模型名称、API endpoint、工具开关、审批策略、成本限额、日志级别等。
- 可选：SIGHUP 热重载（不重启进程刷新配置）。
