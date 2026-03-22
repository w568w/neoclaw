<h1 align="center">Neoclaw</h1>

<p align="center">
  另一个类似 Claw 的 Agent System，但采用了不同的设计理念。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-0.16+-F7A41D?logo=zig&logoColor=white" alt="Zig">
  <img src="https://img.shields.io/badge/Binary-%3C1MB-2C7A7B" alt="Binary under 1MB">
  <img src="https://img.shields.io/badge/Design-Kernel--like-1F3A5F" alt="Kernel-like design">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a>
</p>

## 1. 特性

### 1.1. 使用 Zig 编写

通过使用 Zig 实现，Neoclaw 可以被编译为一个无依赖的独立二进制文件，便于在不同平台上部署和运行。

**它非常小（< 1MB）而且很快：**

```shell
$ zig build -Doptimize=ReleaseSmall && ls -lh zig-out/bin/neoclaw
-rwxr-xr-x 1 w568w w568w 973K zig-out/bin/neoclaw*
```

### 1.2. 类 Kernel 的设计

Neoclaw 的设计方式与计算机内核类似：

> Agent 就像 **进程**，而外部调用（tool call）就像 **系统调用**。
>
> 用户输入是一次 **中断**，agent runtime 会向 agent 发送 **信号** 以通知事件。
>
> 多 agent 系统既可以 **并行** 运行（**IPC**），也可以按 **树状结构** 组织（父子 **进程组**）。

这种设计让 agent 系统拥有更好的模块化能力、可扩展性和可维护性。每个 agent 都可以独立开发和测试，并通过定义清晰的接口（系统调用）彼此通信。

类 Kernel 的设计也带来了更好的资源管理和调度能力，方式上类似于操作系统管理进程。

### 1.3. 健壮的取消机制

不同于许多 *~~草率~~* 的 OpenClaw 克隆实现，它们从未真正理解 agent 系统的结构和状态管理，Neoclaw 从设计之初就将 **结构化取消** 纳入核心考量。

无论 Neoclaw 正在执行什么操作，你都可以随时立即取消，而不用担心丢失重要状态，或者让系统进入不一致状态。

这依赖于谨慎的状态管理，以及 Zig async/await 模型提供的可靠取消机制。

## 2. 用法

构建（Zig 主分支）：

```shell
$ zig build -Doptimize=ReleaseSmall
```

在 `.env` 文件中配置你的 API Key：

```dotenv
# 目前只支持 OpenAI API，但更多支持（Codex、Anthropic 等）很快就会到来！

OPENAI_API_KEY=your_openai_api_key
OPENAI_API_BASE=https://api.openai.com/v1/chat/completions
OPENAI_MODEL=gpt-5
```

运行：

```shell
# 作为 CLI：
$ zig-out/bin/neoclaw
# 或启动 WebUI：
$ zig-out/bin/neoclaw --webui
```

## 3. 路线图

- UX 改进（例如更好的 CLI 界面、更易用的 WebUI）
- 更多内置工具
- Memory 子系统
- 更多 LLM 提供商
