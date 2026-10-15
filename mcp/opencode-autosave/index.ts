import { Plugin } from "@opencode/plugin"
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

/**
 * mem0 auto-save — hands finished conversation slices to your self-hosted
 * mem0 server, whose LLM pipeline (Gemini) extracts durable facts automatically.
 *
 * Every N minutes, for each session active in the last 24h: take the text
 * turns not yet pushed (tracked in plugin storage), scrub anything that looks
 * like a secret, and POST them to mem0 /memories. mem0 deduplicates and only
 * stores what its extraction considers durable.
 *
 * Options (opencode.json plugins entry):
 *   apiUrl          default https://mem0-api-po1n.onrender.com
 *   userId          default "taxin"  (mem0 memory scope)
 *   keyFile         default: first of ~/.config/opencode/mem0-api-key,
 *                   ~/.config/mem0/mem0-api-key, then $MEM0_API_KEY_FILE
 *   intervalMinutes default 10
 *   maxChars        per-push transcript cap, default 24000
 *   minSessionAgeMs ignore, tuning knob for very short sessions
 */

interface Options {
  apiUrl?: string
  userId?: string
  keyFile?: string
  intervalMinutes?: number
  maxChars?: number
}

const REDACTIONS: [RegExp, string][] = [
  [/\bsk-[A-Za-z0-9_-]{16,}\b/g, "[redacted-key]"],
  [/\bm0sk_[A-Za-z0-9]+\b/g, "[redacted-key]"],
  [/\bnpg_[A-Za-z0-9]+\b/g, "[redacted-key]"],
  [/\bAIza[A-Za-z0-9_-]{12,}\b/g, "[redacted-key]"],
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/g, "Bearer [redacted]"],
  [
    /((?:password|passwd|secret|token|api[_-]?key|access_token)["']?\s*[:=]\s*["'`]?)([^\s"'`,}]+)/gi,
    "$1[redacted]",
  ],
]

function redact(text: string): string {
  for (const [pattern, replacement] of REDACTIONS) text = text.replace(pattern, replacement)
  return text
}

function loadKey(explicit?: string): string | undefined {
  if (process.env.MEM0_API_KEY) return process.env.MEM0_API_KEY
  const candidates = [
    explicit,
    process.env.MEM0_API_KEY_FILE,
    join(homedir(), ".config", "opencode", "mem0-api-key"),
    join(homedir(), ".config", "mem0", "mem0-api-key"),
  ].filter((p): p is string => Boolean(p))
  for (const path of candidates) {
    try {
      const key = readFileSync(path, "utf8").trim()
      if (key) return key
    } catch {
      /* try next */
    }
  }
  return undefined
}

function messageText(message: any): string {
  const parts = message?.content ?? message?.parts ?? []
  if (!Array.isArray(parts)) return ""
  return parts
    .filter((p: any) => p?.type === "text" && typeof p.text === "string")
    .map((p: any) => p.text)
    .join("\n")
    .trim()
}

function messageRole(message: any): "user" | "assistant" {
  const role = message?.type ?? message?.role
  return role === "user" ? "user" : "assistant"
}

export default Plugin.define({
  id: "mem0-autosave",
  async setup(ctx) {
    const options = (ctx.options ?? {}) as Options
    const apiUrl = (options.apiUrl ?? "https://mem0-api-po1n.onrender.com").replace(/\/+$/, "")
    const userId = options.userId ?? "taxin"
    const intervalMs = (options.intervalMinutes ?? 10) * 60_000
    const maxChars = options.maxChars ?? 24_000
    const key = loadKey(options.keyFile)
    if (!key) {
      console.warn("[mem0-autosave] no API key found — autosave disabled")
      return
    }

    type Cursors = Record<string, number>
    const cursors = ((await ctx.storage.get("cursors")) ?? {}) as Cursors

    const pushSession = async (session: any) => {
      const messages: any[] = await ctx.session.context({ sessionID: session.id })
      const fresh = messages.slice(cursors[session.id] ?? 0)
      const turns = fresh
        .map((m) => ({ role: messageRole(m), text: redact(messageText(m)) }))
        .filter((t) => t.text.length > 0)
      if (turns.length === 0) {
        cursors[session.id] = messages.length
        await ctx.storage.set("cursors", cursors)
        return
      }

      // keep the newest turns within the char budget, in original order
      const kept: typeof turns = []
      let used = 0
      for (let i = turns.length - 1; i >= 0; i--) {
        if (used + turns[i].text.length > maxChars) break
        kept.unshift(turns[i])
        used += turns[i].text.length
      }
      if (kept.length === 0) return // newest turn alone exceeds budget; skip

      const response = await fetch(`${apiUrl}/memories`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-API-Key": key },
        body: JSON.stringify({ user_id: userId, messages: kept }),
        signal: AbortSignal.timeout(120_000),
      })
      if (!response.ok) {
        console.warn(`[mem0-autosave] push failed (${response.status}): ${await response.text()}`)
        return
      }
      cursors[session.id] = messages.length
      await ctx.storage.set("cursors", cursors)
      const result = await response.json().catch(() => ({}) as any)
      const stored = (result.results ?? [])
        .map((r: any) => r.memory)
        .filter(Boolean)
      if (stored.length > 0) {
        console.log(`[mem0-autosave] +${stored.length} fact(s) from "${session.title ?? session.id}"`)
      }
    }

    const tick = async () => {
      try {
        const sessions = await ctx.session.list()
        const dayAgo = Date.now() - 24 * 3600_000
        for (const session of sessions) {
          if ((session.time?.updated ?? 0) < dayAgo) continue
          try {
            await pushSession(session)
          } catch (error) {
            console.warn(`[mem0-autosave] session ${session.id}:`, error)
          }
        }
      } catch (error) {
        console.warn("[mem0-autosave] tick failed:", error)
      }
    }

    const timer = setInterval(() => void tick(), intervalMs)
    return () => clearInterval(timer)
  },
})
