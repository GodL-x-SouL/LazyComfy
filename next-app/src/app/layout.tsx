import type { Metadata } from "next";
import { ThemeProvider, ToastProvider } from "@/lib/store";
import Nav, { MobileNav, ThemeButton } from "./nav";
import "./globals.css";

export const metadata: Metadata = {
  title: "LazyComfy",
  description: "Lightweight generation console for ComfyUI",
};

const THEME_INIT = `(function(){try{if(localStorage.getItem("lazycomfy.theme")==="dark"){document.documentElement.dataset.theme="dark";}}catch(e){}})();`;

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_INIT }} />
      </head>
      <body>
        <ThemeProvider>
          <ToastProvider>
            <header className="shell-top">
              <div className="brand">
                <span className="brand-mark">◧</span>
                LazyComfy
              </div>
              <Nav />
              <div className="top-right">
                <ThemeButton />
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
