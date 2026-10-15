# Auto-setup: mem0 MCP for any AI agent

Copy the prompt below into any AI coding agent (OpenCode, Claude Code, Cursor,
Codex, …) on the machine that should get persistent memory. The agent does the
rest — no other context needed.

## The prompt

```text
Set up the mem0 MCP server on this machine so you (the agent) get persistent
long-term memory across sessions. Follow these steps exactly.

1. GET THE BRIDGE
   Clone https://github.com/taxin-404/mem0 (default branch main).
   The bridge is mcp/server.py — a stdio MCP server that talks to a deployed
   mem0 REST API over HTTP.

2. PYTHON ENVIRONMENT
   python3 -m venv mem0/mcp/.venv
   mem0/mcp/.venv/bin/pip install "mcp<2" httpx

3. API KEY — ask me for it; never invent or generate one yourself
   - If I give you an m0sk_... key: use it as is.
   - If I give you admin login credentials instead: create a key yourself:
       POST https://mem0-api-po1n.onrender.com/auth/login  (JSON email+password)
         -> access_token
       POST https://mem0-api-po1n.onrender.com/api-keys
         Authorization: Bearer <access_token>
         body: {"label": "agent-mem0-mcp"}
         -> the response contains "key" (m0sk_...) — shown only once.
   - Store the key and nothing else in a file:
       mkdir -p ~/.config/mem0
       write the raw key into ~/.config/mem0/mem0-api-key
       chmod 600 ~/.config/mem0/mem0-api-key
   - Never commit it, never paste it into any file under version control,
     never print it after storing it.

4. REGISTER THE SERVER with the client you are running inside (detect which):
   - OpenCode:
       opencode mcp add mem0 --global -- <clone>/mcp/.venv/bin/python <clone>/mcp/server.py
     then edit ~/.config/opencode/opencode.json, in mcp.servers.mem0 add:
       "environment": {
         "MEM0_API_KEY_FILE": "<home>/.config/mem0/mem0-api-key",
         "MEM0_API_URL": "https://mem0-api-po1n.onrender.com",
         "MEM0_USER_ID": "taxin"
       }
   - Claude Code:
       claude mcp add mem0 --scope user \
         --env MEM0_API_KEY_FILE=$HOME/.config/mem0/mem0-api-key \
         --env MEM0_API_URL=https://mem0-api-po1n.onrender.com \
         --env MEM0_USER_ID=taxin \
         -- <clone>/mcp/.venv/bin/python <clone>/mcp/server.py
     (check `claude mcp add --help` if the flag order differs)
   - Cursor (~/.cursor/mcp.json) or Claude Desktop (claude_desktop_config.json):
       "mcpServers": {
         "mem0": {
           "command": "<clone>/mcp/.venv/bin/python",
           "args": ["<clone>/mcp/server.py"],
           "environment": {
             "MEM0_API_KEY_FILE": "<home>/.config/mem0/mem0-api-key",
             "MEM0_API_URL": "https://mem0-api-po1n.onrender.com",
             "MEM0_USER_ID": "taxin"
           }
         }
       }
   The bridge reads the key from MEM0_API_KEY_FILE (or MEM0_API_KEY directly);
   MEM0_API_URL and MEM0_USER_ID default to the values above if omitted.

5. VERIFY IT WORKS
   - Restart the client if it does not pick up new servers automatically.
   - Confirm the server exposes 4 tools: add_memory, search_memory,
     list_memories, delete_memory.
   - Call list_memories: expect a JSON/text list of memories (can be empty).
     An auth error means the key file is wrong — re-check step 3.

Report back with which client you registered it in and the tool names you see.
```

## What the agent gets

| Tool | Purpose |
|---|---|
| `add_memory(content)` | Store a durable fact (Gemini extracts the essence, embeds it, Neon stores it) |
| `search_memory(query)` | Semantic recall over everything stored |
| `list_memories()` | Dump all memories with ids |
| `delete_memory(id)` | Remove one by id |

Server behind it: this repo's own deployment (Render free + Neon free +
Gemini free — see the main README). Multiple agents on one machine (or
several machines) can share the same `MEM0_USER_ID` scope or each use their
own — memories are namespaced per user id.
