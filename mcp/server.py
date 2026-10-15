#!/usr/bin/env python3
"""mem0 MCP bridge.

Exposes your self-hosted mem0 REST server (github.com/taxin-404/mem0, deployed
on Render) as MCP tools, so AI agents get durable long-term memory across
sessions. Runs over stdio; configured in OpenCode as a local MCP server.

Environment:
  MEM0_API_KEY       - optional: X-API-Key from POST /api-keys on the server
  MEM0_API_KEY_FILE  - optional: path to a file containing that key
                       (defaults to ~/.config/opencode/mem0-api-key)
  MEM0_API_URL       - optional: defaults to the Render deployment
  MEM0_USER_ID       - optional: memory scope, defaults to "taxin"
"""

import os

import httpx
from mcp.server.fastmcp import FastMCP

BASE_URL = os.environ.get("MEM0_API_URL", "https://mem0-api-po1n.onrender.com").rstrip("/")
USER_ID = os.environ.get("MEM0_USER_ID", "taxin")


def _load_api_key() -> str:
    if key := os.environ.get("MEM0_API_KEY"):
        return key
    key_file = os.environ.get(
        "MEM0_API_KEY_FILE", os.path.expanduser("~/.config/opencode/mem0-api-key")
    )
    with open(key_file) as f:
        return f.read().strip()


API_KEY = _load_api_key()

mcp = FastMCP("mem0")


def _request(method: str, path: str, *, json: dict | None = None, params: dict | None = None):
    response = httpx.request(
        method,
        BASE_URL + path,
        json=json,
        params=params,
        headers={"X-API-Key": API_KEY},
        timeout=120,  # add() makes real Gemini round-trips; allow for cold starts too
    )
    response.raise_for_status()
    return response.json() if response.text.strip() else {}


def _format_memories(payload: dict) -> str:
    results = payload.get("results") or []
    if not results:
        return "No memories found."
    lines = []
    for m in results:
        score = m.get("score")
        score_bit = f" (score {score:.2f})" if isinstance(score, (int, float)) else ""
        lines.append(f"- [{m.get('id')}] {m.get('memory')}{score_bit}")
    return "\n".join(lines)


@mcp.tool()
def add_memory(content: str) -> str:
    """Store a durable fact about the user for long-term recall: preferences,
    decisions, identity, project state, things learned mid-conversation.
    Use proactively when something worth remembering across sessions comes up."""
    payload = _request(
        "POST",
        "/memories",
        json={"user_id": USER_ID, "messages": [{"role": "user", "content": content}]},
    )
    stored = [m.get("memory", "?") for m in payload.get("results", [])]
    return "Stored: " + ("; ".join(stored) if stored else "acknowledged (no facts extracted)")


@mcp.tool()
def search_memory(query: str) -> str:
    """Semantic search over long-term memories. Call this early in conversations
    about ongoing work or a returning user to recall relevant context."""
    payload = _request("POST", "/search", json={"user_id": USER_ID, "query": query})
    return _format_memories(payload)


@mcp.tool()
def list_memories() -> str:
    """List every stored memory for this user."""
    payload = _request("GET", "/memories", params={"user_id": USER_ID})
    return _format_memories(payload if isinstance(payload, dict) else {"results": payload})


@mcp.tool()
def delete_memory(memory_id: str) -> str:
    """Delete a memory by its id (use ids returned by search_memory or list_memories)."""
    _request("DELETE", f"/memories/{memory_id}")
    return f"Deleted memory {memory_id}."


if __name__ == "__main__":
    mcp.run()  # stdio transport
