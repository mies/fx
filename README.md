```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             A fork with direct model providers.
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent harness and CLI written in Zig, optimized for research and embeddability as part of larger systems.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and small native binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## About this fork

This is a fork of [vercel-labs/fx](https://github.com/vercel-labs/fx). It adds **direct model providers** so you can point fx at an OpenAI-compatible endpoint or an OpenAI Codex ChatGPT subscription instead of only the Vercel AI Gateway. See [Model providers](#model-providers).

There is no hosted installer for this fork — build it from source (below). The upstream `curl | bash` installer is not used here.

## Build

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/).

```bash
git clone https://github.com/mies/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

The binary is written to `./zig-out/bin/fx`. Run it directly as `./zig-out/bin/fx`, or put it on your `PATH` (for example `ln -s "$PWD/zig-out/bin/fx" ~/.local/bin/fx`) to run it as `fx`. The examples below use `fx` for brevity.

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

## Run fx

Run fx from a project:

```bash
cd your_project
fx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands. Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
```

fx starts in `auto` permission mode, which reviews unresolved sensitive actions. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules. Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action; `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes one.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

## Model providers

fx selects one model provider per run. By default it uses the Vercel AI Gateway; set `FX_PROVIDER` to use a direct provider instead. Any unrecognized value falls back to the gateway.

While a direct provider is active, gateway-only features degrade gracefully: web search, vision, credits, usage reconciliation, and automatic permission review are unavailable, and auto permission mode prompts instead of reviewing. `fx login` and gateway API keys are ignored while `FX_PROVIDER` is set.

### Vercel AI Gateway (default)

Sign in with Vercel, or use an AI Gateway API key:

```bash
fx login   # sign in with Vercel
fx setup   # or paste an AI Gateway API key
```

### OpenCode Go / Zen (OpenAI-compatible)

Use an [OpenCode](https://opencode.ai) API key. Create one at <https://opencode.ai/auth>.

```bash
FX_PROVIDER=opencode OPENCODE_API_KEY=your-key fx
FX_PROVIDER=opencode OPENCODE_API_KEY=your-key fx ask "explain this repo"
```

### Z.AI GLM (OpenAI-compatible)

Use a [Z.AI](https://z.ai) GLM Coding Plan API key (its coding-plan endpoint).

```bash
FX_PROVIDER=zai ZAI_API_KEY=your-key fx
```

For both OpenCode and Z.AI, the key can also live in `~/.fx/provider-keys.json` instead of the environment (the environment variable wins when both are set). The file must be valid JSON and private (mode 600), or fx treats it as absent:

```bash
printf '{"opencode":"your-key","zai":"your-other-key"}' > ~/.fx/provider-keys.json
chmod 600 ~/.fx/provider-keys.json
FX_PROVIDER=opencode fx
```

Pick a model with `FX_MODEL` or the `/model` menu; each provider serves its own catalog.

### OpenAI Codex (ChatGPT subscription)

`FX_PROVIDER=codex` uses your own ChatGPT subscription through OpenAI's Codex backend.

> **Experimental, personal use only.** fx authenticates as the Codex client against an undocumented OpenAI endpoint. OpenAI does not sanction third-party clients using it. Use it solely with your own ChatGPT subscription — never for shared, resold, or commercial access.

```bash
fx codex login        # sign in with ChatGPT in the browser (localhost:1455 callback)
fx codex import       # or adopt an existing Codex CLI / pi login
fx codex status       # show the stored session
fx codex logout       # remove it

FX_PROVIDER=codex fx  # use it
```

If the official Codex CLI is already signed in, fx adopts that session automatically on first use and refreshes it as needed. Available models are per-account (recent ChatGPT plans serve the `gpt-5.6-*` line); pick one with `FX_MODEL` or `/model` if the default is not offered.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

## Extend fx

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Project instruction files may link within their scope, and read-only workspace or compatibility skill directories may link within their owning workspace or home; managed skills, `SKILL.md` files, resources, and escaping links remain no-follow. `fx status` and `fx doctor` report an invalid trusted MCP profile without starting its servers.

## Documentation

Read the upstream [fx documentation](https://fx.sh/docs). Provider setup specific to this fork is documented above.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

fx is a fork of [vercel-labs/fx](https://github.com/vercel-labs/fx). Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
