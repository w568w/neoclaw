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

# 2. 本次准备实现的部分

## 2.1 立即开始实现

1. 新增 `src/llm/mod.zig`，抽出模型无关的消息类型与 `LlmDriver` 抽象。
2. 让 `src/llm/openai.zig` 适配新的 `llm/mod.zig` 类型边界。
3. 调整 `src/root.zig` 与现有调用点，开始经统一 `llm` 模块引用消息类型。
4. 尽量不在第一步就推翻现有 CLI 行为，先把抽象边界切出来。

## 2.2 如果进度允许，接着做

1. 在 `src/loop.zig` 中引入新的基础类型雏形：`Runtime`、`EventRecord`、`Subscription`、`ToolStartResult`。
2. 先以最小可编译骨架形式落地，不要求一次完成全部调度逻辑。
3. 保持现有代码能继续编译和运行，逐步替换旧的 `Runner.next()` 路径。

# 3. 明确留给后续完成的部分

## 3.1 Runtime 主体重构

- 现有 `src/loop.zig` 仍是同步 `Runner.next()` 风格，尚未改成 `Runtime + Subscription + EventLog`。
- 现有 loop 仍由前端主动拉取推进，尚未改成真正的消息驱动运行时。
- 现有 public event 仍未具备全局 `event_seq`、cursor 读取和严格不丢事件语义。

## 3.2 Agent 进程模型

- 尚未正式引入持久化 `Agent` 结构来持有：
  1. `history`
  2. request 队列
  3. `pending_interrupts`
  4. invoke/syscall 计数器
  5. 运行状态
- 尚未实现 interactive/background 优先级调度。

## 3.3 Tool syscall 化

- 现有 `schema` 和 `tools` 仍返回 `StepOutcome`，尚未切换为 `ToolStartResult`。
- 现有工具还没有区分 `ready / wait / detach` 三种完成语义。
- 现有 `ask_user` 仍是基于文本约定的中断方式，尚未变为结构化 `wait.user`。

## 3.4 异步与 mailbox

- 尚未实现 Runtime 内部 inbox。
- 尚未实现 detach 型 tool 完成后自动写入 Agent mailbox 并唤醒 Agent 的完整流程。
- 尚未实现 invoke 安全点投递中断的规则。
- 尚未实现 cancel / stale result 过滤。

## 3.5 事件流可靠性细节

- 尚未实现 `accepted / started / tool_detached / waiting_user / finished` 等新的 public event 类型。
- 尚未实现 `Subscription`、cursor 和基于 condvar 的无丢唤醒接收逻辑。
- 尚未定义 event log 的保留、回放和 GC 策略；第一阶段默认不做 GC。

# 4. 当前建议的实施顺序

## 4.1 阶段一

1. 落地 `src/llm/mod.zig`。
2. 让 `src/llm/openai.zig` 依赖新抽象。
3. 调整现有代码引用路径，但暂不推翻现有 loop 执行模型。

## 4.2 阶段二

1. 将 `src/loop.zig` 从 `Runner.next()` 改成 `Runtime`。
2. 引入 `EventLog` 和 `Subscription`。
3. 将前端改为 `submit + recv` 模式。

## 4.3 阶段三

1. 引入 `ToolStartResult`。
2. 将现有工具改造为 syscall 语义。
3. 实现 `ask_user -> wait.user`。

## 4.4 阶段四

1. 引入真正的异步 worker。
2. 支持 detach 型工具的后台完成与自动唤醒。
3. 增加中断、取消和更完整的调度策略。
