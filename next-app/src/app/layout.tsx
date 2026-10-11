import type { Metadata } from "next";
import { ThemeProvider, ToastProvider } from "@/lib/store";
import Nav, { MobileNav, HeaderRight } from "./nav";
import { manrope, spaceGrotesk, dmMono } from "./fonts";
import "./globals.css";

export const metadata: Metadata = {
  title: "LazyComfy",
  description: "Lightweight generation console for ComfyUI",
};

const THEME_INIT = `(function(){try{var t=localStorage.getItem("lazycomfy.theme");if(t){document.documentElement.dataset.theme=t;}else{document.documentElement.dataset.theme="dark";}}catch(e){document.documentElement.dataset.theme="dark";}})();`;

const FAVICON =
  "data:image/svg+xml," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#09090b"/><rect x="1.5" y="1.5" width="61" height="61" rx="12.5" fill="none" stroke="#ffffff" stroke-opacity=".25" stroke-width="2"/><path d="M38 8 L20 36 h11 L27 56 L45 28 h-11 Z" fill="#fff"/></svg>`,
  );

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_INIT }} />
        <link rel="icon" type="image/svg+xml" href={FAVICON} />
      </head>
      <body className={`${manrope.variable} ${spaceGrotesk.variable} ${dmMono.variable}`}>
        <ThemeProvider>
          <ToastProvider>
            <header className="shell-top">
              <div className="brand">
                <span className="brand-mark">◧</span>
                LazyComfy
              </div>
              <Nav />
              <div className="top-right">
                <HeaderRight />
              </div>
            </header>
            <MobileNav />
            {children}
            <div className="foot">LazyComfy app · one shared session, no page reloads</div>
          </ToastProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
