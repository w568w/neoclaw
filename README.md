# Neoclaw

Another Claw-like agent, but with a different design concept.

## 1. Feature

### 1.1. Written in Zig

By implementing in Zig, Neoclaw can be compiled into a standalone binary without any dependencies, making it easy to deploy and run on various platforms.

**It's really small (< 1MB) and fast:**

```shell
$ zig build -Doptimize=ReleaseSmall && ls -lh zig-out/bin/neoclaw
-rwxr-xr-x 1 w568w w568w 973K zig-out/bin/neoclaw*
```

### 1.2. Kernel-like design

Neoclaw is designed in a similar way to computer kernels:

> Agents are like **processes**, and the external call (tool call) is like a **system call**.
>
> User input is an **interrupt**, and agent runtime sends **signals** to agents to notify them of events.
>
> Multi-agent systems are running either in **parallel** (**IPC**) or in a **tree structure** (parent-child **process group**).

This design allows for better modularity, scalability, and maintainability of the agent system. Each agent can be developed and tested independently, and they can communicate with each other through well-defined interfaces (system calls).

The kernel-like design also allows for better resource management and scheduling of agents, similar to how an operating system manages processes.

### 1.3. Robust cancellation mechanism

Unlike many *~~sloppy~~* OpenClaw clones that is never aware of the structure of an agent system and state management, Neoclaw has kept **structural cancellation** in mind since the beginning of the design.

Whenever Neoclaw is doing something, you can always cancel it immediately without worrying about losting important state or leaving the system in an inconsistent state.

This is achieved through a combination of careful state management and a robust cancellation mechanism provided by Zig's async/await model.

## 2. Usage

Build:

```shell
$ zig build -Doptimize=ReleaseSmall
```

Configure your API keys in a `.env` file:

```dotenv
# Only OpenAI API is supported for now, but more (Codex, Anthropics, etc.) is right around the corner!

OPENAI_API_KEY=your_openai_api_key
OPENAI_API_BASE=https://api.openai.com/v1/chat/completions
OPENAI_MODEL=gpt-5
```

Run:

```shell
# As CLI:
$ zig-out/bin/neoclaw
# Or start a WebUI:
$ zig-out/bin/neoclaw --webui
```

## 3. Roadmap

- UX improvements (e.g., better CLI interface, more user-friendly WebUI)
- More built-in tools
- Memory Subsystem
- More LLM providers
