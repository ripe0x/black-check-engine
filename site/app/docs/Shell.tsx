"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { PAGES, SECTIONS } from "./nav";
import { DOCS } from "./content";

const href = (slug: string) => (slug ? `/docs/${slug}/` : "/docs/");

/** A docs page, GitBook-style: the contents on the left, the article, and "On this page" from its h2s on the right. */
export function DocsShell({ slug }: { slug: string }) {
  const i = PAGES.findIndex((p) => p.slug === slug), page = PAGES[i];
  const Body = DOCS[slug];
  const article = useRef<HTMLElement>(null);
  const [toc, setToc] = useState<{ id: string; text: string }[]>([]);
  const [open, setOpen] = useState(false);
  useEffect(() => {
    const hs = [...(article.current?.querySelectorAll("h2") ?? [])];
    hs.forEach((h) => { h.id ||= h.textContent!.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, ""); });
    setToc(hs.map((h) => ({ id: h.id, text: h.textContent ?? "" })));
    setOpen(false);
  }, [slug]);
  const prev = PAGES[i - 1], next = PAGES[i + 1];
  return (
    <div className="docs">
      <button type="button" className="docs-menu" aria-expanded={open} onClick={() => setOpen((o) => !o)}>{open ? "Close" : "Contents"}</button>
      <nav className={`docs-side${open ? " open" : ""}`} aria-label="Docs">
        {SECTIONS.map((s) => (
          <div key={s.title}>
            <span className="docs-sec">{s.title}</span>
            {s.pages.map(([sl, title]) => <Link key={sl} href={href(sl)} className={sl === slug ? "on" : ""}>{title}</Link>)}
          </div>
        ))}
      </nav>
      <article ref={article} className="docs-body">
        <span className="docs-crumb">{page.section}</span>
        <h1>{page.title}</h1>
        <Body />
        <div className="docs-pager">
          {prev ? <Link href={href(prev.slug)}><span>Previous</span>{prev.title}</Link> : <span />}
          {next ? <Link href={href(next.slug)} className="next"><span>Next</span>{next.title}</Link> : <span />}
        </div>
      </article>
      <aside className="docs-toc" aria-label="On this page">
        {toc.length ? <><span className="docs-sec">On this page</span>{toc.map((t) => <a key={t.id} href={`#${t.id}`}>{t.text}</a>)}</> : null}
      </aside>
    </div>
  );
}
