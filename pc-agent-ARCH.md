# 1. 项目定位

`pc-agent-loop` 是一个以“最小内核 + 原子工具 + 文件化记忆/SOP”为核心思路的本地 Agent 框架。它并不追求预置大量内建能力，而是只提供少量高杠杆工具，让模型在真实环境中自行摸索方案，并把成功经验沉淀为 SOP 或脚本，逐步长成一套面向个人环境的技能树。

从源码实现看，它更像一个“可自举的 seed agent”，而不是强调复杂规划器、多 Agent 编排或平台化抽象的重量级框架。整个系统的关键逻辑主要集中在 `agent_loop.py`、`ga.py`、`sidercall.py`、`agentmain.py`、`TMWebDriver.py` 几个文件中。

# 2. 总体架构

## 2.1 分层视图

项目可以拆成 6 个相互配合的层次：

1. 入口与运行模式层：负责接受任务、创建会话、启动主循环。
2. Agent 循环层：负责一轮轮执行“生成 -> 调工具 -> 回填结果”。
3. 工具执行层：负责文件、代码、网页、人机协作、记忆更新等原子动作。
4. 模型协议层：负责把 system prompt、历史、工具协议拼成文本 prompt，并解析模型输出中的伪工具调用。
5. 浏览器桥接层：负责连接用户真实浏览器，而不是无头浏览器。
6. 记忆与 SOP 层：负责长期事实、任务经验、操作规范的存储与复用。

## 2.2 核心设计判断

- 主循环极小：`agent_loop.py` 只有非常薄的一层回合调度。
- 工具是原子级：只暴露少量高自由度工具，尤其是 `code_run` 和 `web_execute_js`。
- 协议是文本驱动：不依赖模型原生 function calling，而是要求模型输出 `<thinking>`、`<summary>`、`<tool_use>` 标签。
- 记忆是文件系统：长期记忆不是向量库，而是 `memory/` 下可读写的文本和脚本。
- 浏览器是真浏览器：通过 Tampermonkey 与 Chrome 扩展桥接已有会话，保留登录态。

# 3. 运行入口与会话编排

## 3.1 统一入口

`agentmain.py` 是系统总控。它在启动时完成几件事：

- 读取 `assets/tools_schema.json` 并生成工具描述。
- 初始化 `memory/global_mem.txt`、`memory/global_mem_insight.txt` 等长期记忆文件。
- 根据 `mykey.py` 或 `mykey.json` 自动装载多个 LLM backend。
- 创建 `GeneraticAgent`，并通过后台线程消费任务队列。

`GeneraticAgent` 自身并不复杂，核心是：

- `task_queue`：任务输入队列。
- `history`：跨任务保留的简要历史。
- `handler`：当前任务绑定的 `GenericAgentHandler`。
- `llmclient`：统一包装后的 `ToolClient`。

## 3.2 支持的运行模式

围绕同一个核心 Agent，项目提供了多种前端和触发方式：

- CLI：`python agentmain.py`，直接读终端输入。
- 文件 IO 子任务模式：`python agentmain.py --task IODIR`，通过 `temp/<task>/input.txt` 和 `reply.txt` 进行多轮交互，适合子代理或外部编排。
- 反射模式：`python agentmain.py --reflect SCRIPT`，周期调用外部脚本中的 `check()`，当其返回 prompt 时自动触发任务。
- 定时调度模式：`python agentmain.py --scheduled`，轮询 `sche_tasks/pending` 中到期任务。
- Streamlit 前端：`stapp.py`。
- Telegram 前端：`tgapp.py`。
- 飞书前端：`fsapp.py`。
- 桌面壳：`launch.pyw`，负责拉起 Streamlit、可选 Telegram、可选调度器，并在空闲时自动注入自主任务。

这些入口的共同点是：都不改变内核逻辑，只是把用户输入或外部事件转换成 `GeneraticAgent.put_task()` 的任务对象。

# 4. Agent 主循环

## 4.1 回合状态对象

`agent_loop.py` 定义了统一的回合结果结构 `StepOutcome`：

- `data`：工具执行结果。
- `next_prompt`：下一轮喂给模型的文本。
- `should_exit`：是否立即结束当前任务。

这使工具层可以只关心“这一步做完了，下一步该给模型什么上下文”，而不需要关心外部前端。

## 4.2 回合执行流程

`agent_runner_loop()` 实际上实现了一个极简的 Sense-Think-Act 闭环：

1. 首轮构造 `system + user` 两条消息。
2. 调用 `client.chat(messages, tools)` 请求模型。
3. 从模型输出中解析工具调用。
4. 通过 `handler.dispatch()` 调用对应 `do_<tool>` 方法。
5. 将工具返回的 `data` 包装成 `<tool_result>`，再与 `next_prompt` 组合成下一轮输入。
6. 若 `next_prompt is None` 或 `should_exit=True`，则结束任务。

## 4.3 关键实现特点

- 每轮结束后，本地 `messages` 会被重置为只包含一条新的 user 消息，而不是无限堆积完整对话历史。
- 连续上下文主要靠两套机制维持：
  - LLM backend 内部维护的 `raw_msgs`。
  - `GenericAgentHandler` 注入的工作记忆锚点，如 `<history>`、`<key_info>`、`related_sop`。
- 系统强制模型在每轮给出 `<summary>`，并把这段摘要沉淀到工作记忆中，降低长任务时的信息漂移。

这说明它的重点不是“构造一棵完整消息树”，而是“让模型每轮拿到压缩后的可操作状态”。

# 5. 工具系统

## 5.1 工具声明方式

工具协议定义在 `assets/tools_schema.json`。当前核心工具包括：

- `code_run`
- `file_read`
- `file_patch`
- `file_write`
- `web_scan`
- `web_execute_js`
- `update_working_checkpoint`
- `ask_user`
- `start_long_term_update`

README 将其概括为少量原子工具，实际源码中 `update_working_checkpoint` 和 `start_long_term_update` 进一步补足了工作记忆与长期记忆的闭环。

## 5.2 工具调度方式

工具实现集中在 `ga.py` 的 `GenericAgentHandler` 中。调度机制很简单：

- 主循环拿到工具名后调用 `BaseHandler.dispatch()`。
- `dispatch()` 根据命名约定反射到 `do_<tool>` 方法。
- 如果模型没调工具，则进入隐式工具 `do_no_tool()`。
- 如果模型输出了坏 JSON，则内核伪造 `bad_json` 工具调用，让模型下一轮自我修复。

## 5.3 各类工具的职责

### 5.3.1 代码与系统执行

`code_run()` 是最重要的扩展点：

- `python` 模式会把代码写入临时 `.ai.py` 文件，再由当前 Python 解释器执行。
- `powershell`/`bash` 模式用于系统命令执行。
- 运行过程支持超时、停止信号、stdout 流式采集。

其意义不只是“运行脚本”，而是让 Agent 在运行时临时制造新工具。很多仓库 README 中提到的 Gmail、ADB、数据分析、桌面自动化能力，本质上都可以通过 `code_run` 现场拼装出来，再沉淀为 SOP 或脚本。

### 5.3.2 文件操作

- `file_read`：分页读取、关键字定位、附带行号。
- `file_patch`：基于唯一 `old_content` 做精确局部替换。
- `file_write`：覆盖、追加、前插三种模式。

其中 `file_patch` 被刻意设计得比较保守：要求匹配块唯一，失败时宁可报错，也不允许模糊改写。这体现了项目对“最小化破坏”的偏好。

### 5.3.3 网页操作

- `web_scan`：获取当前页面的简化 DOM 和标签页列表。
- `web_execute_js`：执行任意 JavaScript，对真实浏览器进行完全控制，并返回执行结果、页面变化、标签页变化等附加信息。

网页操作的设计思路是“少看整页，多做精准动作”。源码和工具描述都在引导模型尽量用 `web_execute_js` 做精确交互，只有在需要感知页面结构时再用 `web_scan`。

### 5.3.4 人机协作与记忆钩子

- `ask_user`：中断当前任务，把控制权交还给用户。
- `update_working_checkpoint`：更新短期工作便签。
- `start_long_term_update`：在任务完成后显式触发长期记忆提炼流程。

这几个工具很关键，因为它们把“执行”“上下文保持”“经验沉淀”连成了完整链路。

# 6. 模型接入与协议实现

## 6.1 多 backend 适配

`sidercall.py` 提供多个模型后端适配器：

- `LLMSession`：OpenAI 兼容接口。
- `ClaudeSession`：Anthropic SSE。
- `SiderLLMSession`：Sider 聚合接口。
- `XaiSession`：xAI SDK。
- `GeminiSession`：Gemini API。

`agentmain.py` 会扫描配置，把可用 backend 都挂进 `ToolClient`，并允许轮换使用。

## 6.2 文本协议而非原生函数调用

这个项目最核心的实现选择，是不用模型 API 的原生 function calling，而是在 `ToolClient._build_protocol_prompt()` 中把工具协议直接拼进文本 prompt。其要求模型按以下结构回复：

1. `<thinking>`：内部思考。
2. `<summary>`：极短的物理状态摘要。
3. `<tool_use>`：JSON 格式的工具调用。

因此，这个系统的“工具调用”本质上是一个由 prompt 约束出来的文本协议。

## 6.3 响应解析与容错

`ToolClient._parse_mixed_response()` 会从模型输出中提取：

- `<thinking>` 内容。
- `<tool_use>...</tool_use>` 中的 JSON。
- 剩余自然语言正文。

其容错设计比较务实：

- 支持弱格式 `<tool_use>` 块。
- 支持直接从正文里抓形似工具 JSON 的片段。
- `tryparse()` 会尝试清理反引号、截断残缺 JSON。
- 若仍失败，则生成 `bad_json` 调用，要求下一轮修正。

这说明项目更重视“让模型继续跑下去”，而不是追求严格协议的一次性完美解析。

## 6.4 上下文压缩

为了控制上下文长度，源码做了几层压缩：

- `compress_history_tags()` 会截断旧消息中的 `<thinking>`、`<tool_use>`、`<tool_result>` 内容。
- `LLMSession.summary_history()` 会在上下文过长时异步总结旧历史。
- `ToolClient` 会缓存工具 schema，避免每轮重复注入完整工具描述。

这一套策略说明：该项目虽然整体简单，但非常明确地围绕“低成本长回合运行”做了工程取舍。

# 7. 浏览器与环境桥接

## 7.1 为什么不是 Selenium

项目刻意避开了标准无头浏览器路线，而是通过 `TMWebDriver.py` 连接用户已经登录的真实浏览器。这样做的好处是：

- 保留登录态和本地环境。
- 更容易操作真实网页、真实标签页、真实扩展。
- 能把浏览器作为用户日常环境的一部分，而不是隔离沙箱。

## 7.2 TMWebDriver 的工作方式

浏览器桥接由两部分构成：

- Python 侧：`TMWebDriver.py`。
- 浏览器侧：`assets/ljq_web_driver.user.js` Tampermonkey 脚本。

通信机制：

- 优先 WebSocket。
- 降级为 HTTP long-poll。
- 每个标签页以 `sessionId` 为单位注册成一个会话。
- Python 侧向指定 session 下发 JS，等待 ACK 与结果回传。

`TMWebDriver.execute_js()` 在运行时还会处理标签页重连、超时、会话切换、新标签页检测等问题，因此并不是一次简单的“发 JS 字符串”。

## 7.3 高层网页感知

`simphtml.py` 在浏览器桥上又封了一层高层能力：

- `get_html()`：提取主内容并压缩 HTML，减少 token 消耗。
- `execute_js_rich()`：执行 JS 后补充 transient text、DOM diff、刷新状态、新标签页信息。

因此，`web_scan` 和 `web_execute_js` 不只是“读网页”和“执行 JS”，而是一组经过内容压缩和变更观测包装后的网页操作原语。

## 7.4 CDP 桥扩展

`assets/tmwd_cdp_bridge/` 还提供了一个浏览器扩展，用于访问 `debugger`、`tabs`、`cookies` 等更底层能力。它补足了 Tampermonkey 方案在 `isTrusted` 事件、文件上传、跨标签页控制等方面的局限。

这表明浏览器层的总体策略是：

- 优先用最轻量的用户脚本桥接真实页面。
- 必要时再落到 CDP 级能力。

# 8. 记忆与 SOP 机制

## 8.1 记忆不是数据库，而是文件系统

项目的长期记忆完全建立在 `memory/` 目录上。`agentmain.py` 在启动时会自动创建缺失的记忆文件，而 `get_system_prompt()` 会把系统提示词、当前日期和全局记忆拼进首轮 system prompt。

## 8.2 三层记忆结构

`memory/memory_management_sop.md` 把记忆分为三层：

- L1：`global_mem_insight.txt`，极简索引层。
- L2：`global_mem.txt`，环境事实层。
- L3：`memory/` 下的专项 SOP 或脚本。

核心原则有三个：

- 只记录行动验证成功的信息。
- 不记录高频易变状态。
- 上层只保留最小足够指针，不堆细节。

## 8.3 短期工作记忆

除了长期记忆，`GenericAgentHandler` 还维护一套短期工作记忆：

- `history_info`：最近若干轮压缩后的任务摘要。
- `key_info`：当前任务便签。
- `related_sop`：提醒模型必要时重新读取 SOP。

`_get_anchor_prompt()` 会把这些内容封装进 `### [WORKING MEMORY]`，作为每轮工具执行后的回填锚点。这是它能在长任务里保持稳定的重要原因。

## 8.4 SOP 的真实作用

在这个项目里，SOP 不只是说明文档，而是 Agent 的外置执行规范。模型会主动读取 SOP，然后按 SOP 约束自己的工具调用和记忆更新方式。

因此 SOP 兼具三种角色：

- 行为规则。
- 经验压缩结果。
- 下一次任务的可执行模板。

# 9. 调度、自主与反射机制

## 9.1 定时任务

`--scheduled` 模式通过轮询 `sche_tasks/pending` 触发任务，并配合 `memory/scheduled_task_sop.md` 执行。它不是复杂的调度中心，而是一个基于文件夹的轻量 cron 变体。

## 9.2 反射触发

`--reflect SCRIPT` 允许外部 Python 脚本提供 `check()`，Agent 定期调用它；一旦 `check()` 返回 prompt，就立即触发任务。`reflect/` 目录下给了示例脚本。

这种机制本质上是一个非常轻量的 trigger hook：把“是否该行动”的判断外包给脚本，而不是把 planner 写死在内核里。

## 9.3 空闲自主

`launch.pyw` 还实现了 idle monitor：如果用户长时间没有回复，就向前端自动注入一条 `[AUTO]` 任务，让 Agent 读取自主 SOP 并执行自动探索或维护工作。

这说明项目的“自主性”并不是一个独立复杂模块，而是通过若干触发器把已有主循环重复利用起来。

# 10. 关键文件职责速查

- `agentmain.py`：统一入口、任务队列、backend 装载、运行模式编排。
- `agent_loop.py`：极简主循环、`StepOutcome`、handler 分发机制。
- `ga.py`：核心工具实现、工作记忆、长期记忆触发、无工具保护逻辑。
- `sidercall.py`：多模型适配、协议 prompt 构造、工具调用解析、上下文压缩。
- `TMWebDriver.py`：真实浏览器会话管理、JS RPC 桥。
- `simphtml.py`：页面主内容提取、HTML 压缩、DOM 变化观察。
- `launch.pyw`：桌面壳、Streamlit 启动、空闲自动任务、调度器拉起。
- `stapp.py` / `tgapp.py` / `fsapp.py`：不同交互前端。
- `assets/tools_schema.json`：工具协议定义。
- `assets/sys_prompt.txt`：最小系统提示词。
- `assets/ljq_web_driver.user.js`：Tampermonkey 注入脚本。
- `assets/tmwd_cdp_bridge/`：CDP/Tab/Cookie 扩展桥。
- `memory/`：长期记忆、SOP、专项脚本。
- `reflect/`：触发脚本示例。

# 11. 架构特点与实现原理总结

## 11.1 它为什么能用很少代码做很多事

原因不在于预置了多少模块，而在于它把能力增长押在三件事上：

1. 用 `code_run` 提供几乎无限的即时扩展能力。
2. 用真实浏览器桥接获得真实环境操作能力。
3. 用文件化 SOP 和记忆把一次成功经验沉淀为下一次可复用能力。

因此，它的实现原理不是“内建所有能力”，而是“用少量原子原语制造能力，并把成功路径外化保存”。

## 11.2 它的优势

- 内核极小，容易读透和二次改造。
- 工具非常通用，扩展上限高。
- 通过 SOP 和记忆机制具备明显的自举与复用能力。
- 浏览器桥接走真实用户环境，适合需要保留登录态的任务。

## 11.3 它的代价与边界

- 对模型输出格式稳定性有要求，文本协议天然脆弱。
- 工具权限大，必须依赖 SOP、工作记忆和 `ask_user` 控制风险。
- 浏览器桥接依赖本地环境、插件、脚本注入状态，环境漂移会影响稳定性。
- 记忆系统是文件式而非结构化数据库，随着规模增长会越来越依赖 SOP 质量。

# 12. 一句话结论

`pc-agent-loop` 的本质，是一个把 LLM、少量高自由度工具、真实浏览器桥、文件化记忆和 SOP 串成闭环的本地 Agent 种子内核：主循环负责回合推进，`ga.py` 提供行动原语，`sidercall.py` 负责文本协议，`TMWebDriver.py` 打通真实环境，`memory/` 则把一次次成功任务沉淀为未来可直接调用的能力。
