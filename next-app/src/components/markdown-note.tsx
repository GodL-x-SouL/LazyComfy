import type { ReactNode } from "react";

const INLINE =
  /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*]+)\*|_([^_]+)_|`([^`]+)`|~~([^~]+)~~/g;

function inline(text: string, key: string): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let n = 0;
  for (const m of text.matchAll(INLINE)) {
    const i = m.index ?? 0;
    if (i > last) out.push(text.slice(last, i));
    const k = `${key}-${n++}`;
    if (m[1] != null) {
      out.push(
        <a key={k} href={m[2]} target="_blank" rel="noreferrer noopener">
          {m[1]}
        </a>,
      );
    } else if (m[3] != null || m[4] != null) {
      out.push(<strong key={k}>{m[3] ?? m[4]}</strong>);
    } else if (m[5] != null || m[6] != null) {
      out.push(<em key={k}>{m[5] ?? m[6]}</em>);
    } else if (m[7] != null) {
      out.push(<code key={k}>{m[7]}</code>);
    } else {
      out.push(<del key={k}>{m[8]}</del>);
    }
    last = i + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function MarkdownNote({ text }: { text: string }) {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const blocks: ReactNode[] = [];
  let para: string[] = [];
  let list: { marker: string; text: string }[] = [];
  let n = 0;
  const key = () => `md-${n++}`;

  const flushPara = () => {
    if (para.length === 0) return;
    blocks.push(<p key={key()}>{inline(para.join(" "), key())}</p>);
    para = [];
  };

  const flushList = () => {
    if (list.length === 0) return;
    blocks.push(
      <ul key={key()}>
        {list.map((it, i) => (
          <li key={i}>
            <span className="md-marker">{it.marker}</span>
            {inline(it.text, key())}
          </li>
        ))}
      </ul>,
    );
    list = [];
  };

  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith("```")) {
      flushPara();
      flushList();
      const buf: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith("```")) {
        buf.push(lines[i]);
        i++;
      }
      if (buf.length > 0) blocks.push(<pre key={key()}>{buf.join("\n")}</pre>);
      continue;
    }
    if (t === "") {
      flushPara();
      flushList();
      continue;
    }
    const h = /^(#{1,6})\s+(.*)$/.exec(t);
    if (h) {
      flushPara();
      flushList();
      const level = Math.min(h[1].length, 4) as 1 | 2 | 3 | 4;
      const Tag = `h${level}` as "h1" | "h2" | "h3" | "h4";
      blocks.push(<Tag key={key()}>{inline(h[2], key())}</Tag>);
      continue;
    }
    if (/^([-*_])\1{2,}$/.test(t)) {
      flushPara();
      flushList();
      blocks.push(<hr key={key()} />);
      continue;
    }
    const bullet = /^[-*+]\s+(.*)$/.exec(t);
    const ordered = /^(\d+)[.)]\s+(.*)$/.exec(t);
    if (bullet || ordered) {
      flushPara();
      list.push(
        bullet
          ? { marker: "•", text: bullet[1] }
          : { marker: `${ordered![1]}.`, text: ordered![2] },
      );
      continue;
    }
    const quote = /^>\s?(.*)$/.exec(t);
    if (quote) {
      flushPara();
      flushList();
      blocks.push(<blockquote key={key()}>{inline(quote[1], key())}</blockquote>);
      continue;
    }
    flushList();
    para.push(t);
  }
  flushPara();
  flushList();

  if (blocks.length === 0) return null;
  return <div className="md">{blocks}</div>;
}
