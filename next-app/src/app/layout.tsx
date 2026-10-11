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

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_INIT }} />
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
