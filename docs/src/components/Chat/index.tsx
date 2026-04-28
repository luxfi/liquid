import React, { useEffect, useMemo, useRef, useState } from "react";
import useIsBrowser from "@docusaurus/useIsBrowser";

type Chunk = { id: string; url: string; title: string; text: string };
type Index = { v: number; count: number; docs: Chunk[] };
type Msg = { role: "user" | "assistant"; content: string; sources?: Chunk[] };

const ENDPOINT =
  (typeof window !== "undefined" && (window as any).__LIQUID_CHAT_ENDPOINT__) ||
  "https://api.lux.network/v1/chat";
const MODEL =
  (typeof window !== "undefined" && (window as any).__LIQUID_CHAT_MODEL__) ||
  "qwen3-coder";

function tokenize(s: string) {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9\s]+/g, " ")
    .split(/\s+/)
    .filter((t) => t.length > 1);
}

function rank(query: string, docs: Chunk[]): Chunk[] {
  const qt = new Set(tokenize(query));
  if (qt.size === 0) return [];
  return docs
    .map((d) => {
      const dt = tokenize(d.text + " " + d.title);
      let score = 0;
      for (const t of dt) if (qt.has(t)) score++;
      return { d, score };
    })
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, 5)
    .map((x) => x.d);
}

async function ask(messages: Msg[], context: Chunk[]): Promise<string> {
  const sysContext = context
    .map((c, i) => `[${i + 1}] ${c.title} (${c.url})\n${c.text}`)
    .join("\n\n---\n\n");
  const body = {
    model: MODEL,
    messages: [
      {
        role: "system",
        content:
          "You answer questions about Liquid Protocol on Lux. Use the supplied context. Cite sources by [n]. If unsure, say so.\n\nContext:\n" +
          sysContext,
      },
      ...messages.map((m) => ({ role: m.role, content: m.content })),
    ],
  };
  const r = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`chat ${r.status}`);
  const j = await r.json();
  return j.choices?.[0]?.message?.content ?? j.content ?? "";
}

export default function Chat() {
  const isBrowser = useIsBrowser();
  const [open, setOpen] = useState(false);
  const [index, setIndex] = useState<Index | null>(null);
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState(false);
  const log = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!isBrowser || index) return;
    fetch("/search-index.json")
      .then((r) => (r.ok ? r.json() : null))
      .then((j) => j && setIndex(j))
      .catch(() => {});
  }, [isBrowser, index]);

  useEffect(() => {
    log.current?.scrollTo({ top: log.current.scrollHeight });
  }, [msgs]);

  const send = async () => {
    if (!q.trim() || busy) return;
    const user: Msg = { role: "user", content: q.trim() };
    const next = [...msgs, user];
    setMsgs(next);
    setQ("");
    setBusy(true);
    try {
      const ctx = index ? rank(user.content, index.docs) : [];
      const answer = await ask(next, ctx);
      setMsgs([...next, { role: "assistant", content: answer, sources: ctx }]);
    } catch (e: any) {
      setMsgs([
        ...next,
        { role: "assistant", content: `Error: ${e.message ?? e}` },
      ]);
    } finally {
      setBusy(false);
    }
  };

  if (!isBrowser) return null;

  return (
    <>
      <button
        aria-label="Open chat"
        onClick={() => setOpen((v) => !v)}
        style={{
          position: "fixed",
          right: 20,
          bottom: 20,
          zIndex: 1000,
          padding: "10px 14px",
          borderRadius: 999,
          border: "none",
          background: "var(--ifm-color-primary)",
          color: "#fff",
          cursor: "pointer",
          boxShadow: "0 4px 14px rgba(0,0,0,0.18)",
          fontWeight: 600,
        }}
      >
        {open ? "Close" : "Ask Liquid"}
      </button>

      {open && (
        <div
          style={{
            position: "fixed",
            right: 20,
            bottom: 76,
            width: 380,
            maxWidth: "calc(100vw - 40px)",
            height: 520,
            maxHeight: "calc(100vh - 120px)",
            zIndex: 1000,
            display: "flex",
            flexDirection: "column",
            background: "var(--ifm-background-color)",
            border: "1px solid var(--ifm-color-emphasis-300)",
            borderRadius: 12,
            boxShadow: "0 12px 32px rgba(0,0,0,0.22)",
            overflow: "hidden",
          }}
        >
          <div
            style={{
              padding: "10px 14px",
              borderBottom: "1px solid var(--ifm-color-emphasis-300)",
              fontWeight: 600,
            }}
          >
            Ask Liquid
            <span
              style={{
                marginLeft: 8,
                fontSize: 12,
                color: "var(--ifm-color-emphasis-700)",
              }}
            >
              {index ? `${index.count} chunks indexed` : "loading…"}
            </span>
          </div>

          <div
            ref={log}
            style={{
              flex: 1,
              overflow: "auto",
              padding: 12,
              fontSize: 14,
              lineHeight: 1.45,
            }}
          >
            {msgs.length === 0 && (
              <div style={{ color: "var(--ifm-color-emphasis-700)" }}>
                Ask anything about Liquid: contracts, the transmuter,
                self-repaying loans, integration.
              </div>
            )}
            {msgs.map((m, i) => (
              <div key={i} style={{ marginBottom: 12 }}>
                <div
                  style={{
                    fontSize: 11,
                    textTransform: "uppercase",
                    color: "var(--ifm-color-emphasis-600)",
                    marginBottom: 4,
                  }}
                >
                  {m.role}
                </div>
                <div style={{ whiteSpace: "pre-wrap" }}>{m.content}</div>
                {m.sources && m.sources.length > 0 && (
                  <div style={{ marginTop: 6, fontSize: 12 }}>
                    {m.sources.map((s, j) => (
                      <a
                        key={s.id}
                        href={s.url}
                        style={{ marginRight: 8 }}
                      >
                        [{j + 1}] {s.title}
                      </a>
                    ))}
                  </div>
                )}
              </div>
            ))}
            {busy && (
              <div style={{ color: "var(--ifm-color-emphasis-600)" }}>
                thinking…
              </div>
            )}
          </div>

          <form
            onSubmit={(e) => {
              e.preventDefault();
              send();
            }}
            style={{
              display: "flex",
              borderTop: "1px solid var(--ifm-color-emphasis-300)",
              padding: 8,
              gap: 8,
            }}
          >
            <input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Ask about Liquid…"
              style={{
                flex: 1,
                padding: "8px 10px",
                border: "1px solid var(--ifm-color-emphasis-300)",
                borderRadius: 8,
                background: "transparent",
                color: "inherit",
              }}
              disabled={busy}
            />
            <button
              type="submit"
              disabled={busy || !q.trim()}
              style={{
                padding: "8px 14px",
                border: "none",
                borderRadius: 8,
                background: "var(--ifm-color-primary)",
                color: "#fff",
                cursor: busy ? "not-allowed" : "pointer",
              }}
            >
              Send
            </button>
          </form>
        </div>
      )}
    </>
  );
}
