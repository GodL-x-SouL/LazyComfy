"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useTheme, wsHub, useComfyWs } from "@/lib/store";

const TABS = [
  { href: "/", label: "Images" },
  { href: "/video", label: "Video" },
  { href: "/upscale", label: "Upscale" },
  { href: "/forge", label: "Forge" },
  { href: "/custom", label: "Custom" },
];

function isActive(pathname: string, href: string): boolean {
  if (href === "/") return pathname === "/";
  return pathname === href || pathname.startsWith(href + "/");
}

export default function Nav() {
  const pathname = usePathname();
  return (
    <nav className="glass-pill nav" aria-label="Sections">
      {TABS.map((t) => (
        <Link key={t.href} href={t.href} className={isActive(pathname, t.href) ? "active" : ""}>
          {t.label}
        </Link>
      ))}
    </nav>
  );
}

export function MobileNav() {
  const pathname = usePathname();
  return (
    <nav className="nav-mobile" aria-label="Sections">
      {TABS.map((t) => (
        <Link key={t.href} href={t.href} className={isActive(pathname, t.href) ? "active" : ""}>
          {t.label}
        </Link>
      ))}
    </nav>
  );
}

export function HeaderRight() {
  const { theme, toggle } = useTheme();
  const pathname = usePathname();
  const router = useRouter();
  const [online, setOnline] = useState(false);
  useEffect(() => wsHub.onConn(setOnline), []);
  useComfyWs(() => {});
  const openModels = () => {
    if (pathname === "/") {
      window.dispatchEvent(new CustomEvent("lazycomfy:open-downloads"));
    } else {
      try {
        sessionStorage.setItem("lazycomfy.openDl", "1");
      } catch {
        /* ignore */
      }
      router.push("/");
    }
  };
  return (
    <div className="glass-pill">
      <button className="navbtn" type="button" onClick={openModels}>
        ⬇ Models
      </button>
      <span className="conn" id="connPill">
        <span className={"dot" + (online ? " on" : "")} />
        <span className="lbl">Backend</span>
      </span>
      <button className="icon-btn" type="button" onClick={toggle} title="Toggle theme" aria-label="Toggle theme">
        {theme === "dark" ? (
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
            <circle cx="12" cy="12" r="5" />
            <line x1="12" y1="1" x2="12" y2="3" /><line x1="12" y1="21" x2="12" y2="23" />
            <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" /><line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
            <line x1="1" y1="12" x2="3" y2="12" /><line x1="21" y1="12" x2="23" y2="12" />
            <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" /><line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
          </svg>
        ) : (
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
          </svg>
        )}
      </button>
    </div>
  );
}
