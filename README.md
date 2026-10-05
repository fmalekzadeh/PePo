# Petit Pomme (PePo)

A tiny macOS menu bar app that runs a local, OpenAI-compatible HTTP API in
front of Apple's on-device Foundation Model (Apple Intelligence). Start it,
and any tool that speaks the OpenAI chat completions format can talk to your
Mac's on-device model at `http://127.0.0.1:<port>/v1`.

## Provenance / independence from any employer

This project was conceived, designed, and built entirely on the author's own
personal time, using the author's own personal hardware (a Mac Mini at home),
the author's own Anthropic Claude account, and the author's own Apple
developer tools — none of it on employer time, employer equipment, or
employer confidential information or trade secrets.

Petit Pomme is **not a ServiceNow product**. It is not built, sponsored,
endorsed, reviewed, or supported by ServiceNow in any capacity, and nothing
about its name, content, or distribution should be read as implying
otherwise. Any ServiceNow trademarks are the property of their respective
owner and are not implicated by this project.

Petit Pomme is published by **PathPilot LLC**.

## Disclaimer / No Warranty

This software is provided **"AS IS"**, without warranty of any kind, express
or implied, including but not limited to the warranties of merchantability,
fitness for a particular purpose, and noninfringement. In no event shall
PathPilot LLC, its principals, or any contributors be liable for any claim,
damages, or other liability, whether in an action of contract, tort, or
otherwise, arising from, out of, or in connection with the software or the
use or other dealings in the software.

**Use entirely at your own risk.** This is a personal side project, not a
supported product — there is no SLA, no guarantee of correctness, and no
commitment to ongoing maintenance.

See [LICENSE](LICENSE) for the full MIT license text, which includes this
disclaimer in its standard legal form as well.

## What it does

- Runs a minimal HTTP/1.1 server (built directly on `Network.framework`, no
  dependencies) bound to `127.0.0.1` only — it never listens on your network.
- Exposes an OpenAI-compatible API:
  - `GET /health` — status check
  - `GET /v1/models` — lists the one available model (`apple-on-device`)
  - `POST /v1/chat/completions` — standard chat completions, including
    `"stream": true` for Server-Sent-Events streaming
  - `GET /v1/sessions` — lists active named sessions (see below) and their
    current token usage
  - `POST /v1/sessions/clear` — ends a named session (`{"session":"<name>"}`)
    so its next message starts a brand new one
- Multi-turn conversations are replayed through `FoundationModels`' own
  `Transcript` type, not flattened into hand-labeled text — this matters: a
  naive "User: ... / Assistant: ..." text flattening measurably degrades the
  on-device model's answers once there's more than one turn of history.
- **Named, server-held sessions** (optional): pass `"session": "<name>"` in a
  request and the server keeps that conversation alive itself — persisted to
  disk, surviving even an app restart — so the client only needs to send its
  newest message instead of replaying full history every call. Near the
  model's context window limit, the session is automatically summarized —
  by a separate, disposable model session fed the flattened transcript, not
  the live (already nearly-full) one — and reset to a much shorter transcript
  so the conversation keeps going; the full pre-summary transcript is
  archived to disk first, so nothing is ever lost.
- **Instructions/persona, set once**: an optional `"role": "system"` message
  is applied only the moment a named session is first created, then ignored
  on every later turn in that same session — matching how a "system prompt"
  behaves elsewhere, without silently re-sending it (and spending tokens on
  it) every turn. Changing persona means starting a new session.
- A minimal, native-feeling menu bar UI: a Start/Stop switch, live status and
  Apple Intelligence availability, port (editable), request count, a
  token-usage gauge (colors the menu bar apple icon green/orange/red as the
  most recent request approaches the 4096-token context window), an
  **Instruction prompt** box (edit/cancel/save — greyed out once the app's
  session is actually live, since edits wouldn't apply until a new one
  starts), a built-in **Test Chat** window (⌘T) for trying the server without
  any external tool, **New Session** (⌘N) to end the current conversation and
  reset the instruction prompt back to its default, and an **About** panel
  (⌘A).

## Requirements

- macOS 26 or later, with Apple Intelligence enabled
- Xcode's Command Line Tools (`xcode-select --install`) — a full Xcode
  install is not required; this is a plain AppKit app with no SwiftUI/Storyboard
  dependency

## Installing a pre-built app

If you were just handed a `Petit Pomme.app` rather than building it yourself,
see [`docs/install.html`](docs/install.html) — it covers getting past macOS's
Gatekeeper warning for an app that isn't notarized (including the Terminal
command, and why that's a quarantine-flag thing, not a SIP thing).

## Building and running

```bash
cd FoundationModelServer
./build-app.sh          # builds a release binary and assembles Petit Pomme.app
open "Petit Pomme.app"
```

The menu bar icon appears — click it for Start/Stop and settings. If macOS
blocks the app with a Gatekeeper warning (expected for an ad-hoc signed app
not downloaded from the App Store), see
[`docs/install.html`](docs/install.html). Or, for quick iteration without the
`.app` bundle:

```bash
swift build
.build/debug/FoundationModelServer
```

## Example usage

```bash
curl http://127.0.0.1:11535/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hi"}]}'
```

With a named, server-held session (only send the newest message each time):

```bash
curl http://127.0.0.1:11535/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"session":"my-chat","messages":[{"role":"user","content":"My name is Alex."}]}'

curl http://127.0.0.1:11535/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"session":"my-chat","messages":[{"role":"user","content":"What is my name?"}]}'
```

Setting a persona — only honored on the message that actually creates the
session (the first one under a given `"session"` name); a system message on
any later turn in that same session is silently ignored:

```bash
curl http://127.0.0.1:11535/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"session":"editor","messages":[{"role":"system","content":"You are an expert copy editor."},{"role":"user","content":"Fix this: Its a nice day outside"}]}'
```

Ending a session so its next message starts fresh (e.g. to change persona):

```bash
curl http://127.0.0.1:11535/v1/sessions/clear \
  -H "Content-Type: application/json" \
  -d '{"session":"editor"}'
```

## Known limitations

- Token usage reported in the API's `usage` field and the menu bar gauge is
  estimated via the model's own tokenizer, not pulled from a billing-grade
  counter — accurate, but treat it as an estimate.
- Only plain string message `content` is supported (not the multi-part
  `[{type, text}]` array form some clients send).
- This is a single-machine, single-user local tool. It has no
  authentication — anything that can reach `127.0.0.1:<port>` on this Mac can
  use it.

## License

[MIT](LICENSE) — Copyright (c) 2026 PathPilot LLC.

## Contact

Feridoon "Doon" Malekzadeh — doon@malekzadeh.net

Found this helpful? [Buy me a coffee](https://buymeacoffee.com/doon).
