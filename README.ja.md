<h1 align="center">Neoclaw</h1>

<p align="center">
  Claw ライクな agent system を、異なる設計思想で作り直したプロジェクトです。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Status-🚧%20Building-B45309" alt="Under construction">
  <img src="https://img.shields.io/badge/Zig-0.16+-F7A41D?logo=zig&logoColor=white" alt="Zig">
  <img src="https://img.shields.io/badge/Binary-%3C1MB-2C7A7B" alt="Binary under 1MB">
  <img src="https://img.shields.io/badge/Design-Kernel--like-1F3A5F" alt="Kernel-like design">
</p>

<p align="center">
  <img src="assets/webui.png" alt="Neoclaw WebUI" width="900">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.ja.md">日本語</a>
</p>

> 🚧 **Neoclaw はまだ初期開発段階です。**
>
> 機能要望、設計に関する意見、その他のフィードバックを歓迎します。

## 1. Features

### 1.1. Zig で実装

Neoclaw は Zig で実装されているため、依存関係のない単体バイナリとしてビルドできます。さまざまな環境へ簡単に配布・実行できます。

**とても小さく（< 1MB）、高速です:**

```shell
$ zig build -Doptimize=ReleaseSmall && ls -lh zig-out/bin/neoclaw
-rwxr-xr-x 1 w568w w568w 973K zig-out/bin/neoclaw*
```

### 1.2. Kernel ライクな設計

Neoclaw はコンピュータの kernel に近い考え方で設計されています:

> Agent は **process** のように振る舞い、外部呼び出し（tool call）は **system call** のように扱われます。
>
> ユーザー入力は **interrupt** であり、agent runtime は各 agent に **signal** を送ってイベントを通知します。
>
> Multi-agent system は **並列**（**IPC**）でも、**木構造**（親子 **process group**）でも動作できます。

この設計により、agent system の modularity、scalability、maintainability が高まります。各 agent は独立して開発・検証でき、明確に定義された interface（system call）を通じて相互に通信できます。

また、kernel ライクな設計によって、OS が process を管理するのと同じように、agent の resource management と scheduling も行いやすくなります。

### 1.3. 強固な cancellation mechanism

構造や状態管理をほとんど意識していない *~~雑な~~* OpenClaw クローンとは異なり、Neoclaw は設計の初期段階から **structural cancellation** を重視しています。

Neoclaw が何をしていても、重要な状態を失ったり、システムが不整合な状態に陥ったりする心配なく、いつでも即座に cancel できます。

これは、慎重な状態管理と、Zig の async/await model が提供する堅牢な cancellation mechanism の組み合わせによって実現されています。

## 2. Usage

ビルド（Zig main branch）:

```shell
$ zig build -Doptimize=ReleaseSmall
```

`.env` に API key を設定します:

```dotenv
# 現時点では OpenAI API のみ対応していますが、Codex、Anthropic などの対応も近いうちに追加する予定です。

OPENAI_API_KEY=your_openai_api_key
OPENAI_API_BASE=https://api.openai.com/v1/chat/completions
OPENAI_MODEL=gpt-5
```

実行:

```shell
# CLI として実行:
$ zig-out/bin/neoclaw
# または WebUI を起動:
$ zig-out/bin/neoclaw --webui
```

## 3. Roadmap

- UX の改善（より良い CLI、より使いやすい WebUI など）
- 組み込み tool の拡充
- Memory subsystem
- 対応 LLM provider の追加
