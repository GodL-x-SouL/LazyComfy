"use client";

import React, { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";

/* ---------- theme ---------- */

type Theme = "light" | "dark";
const ThemeCtx = createContext<{ theme: Theme; toggle: () => void }>({ theme: "light", toggle: () => {} });

function initialTheme(): Theme {
  try {
    if (document.documentElement.dataset.theme === "light") return "light";
    const stored = localStorage.getItem("lazycomfy.theme");
    if (stored === "light" || stored === "dark") return stored;
  } catch {
    /* ignore */
  }
  return "dark";
}

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const [theme, setTheme] = useState<Theme>("dark");
  useEffect(() => {
    const t = initialTheme();
    document.documentElement.dataset.theme = t;
    setTheme(t);
  }, []);
  const toggle = useCallback(() => {
    setTheme((prev) => {
      const next = prev === "dark" ? "light" : "dark";
      document.documentElement.dataset.theme = next;
      try {
        localStorage.setItem("lazycomfy.theme", next);
      } catch {
        /* ignore */
      }
      try {
        (window as any).ThemeMode?.postMessage(next);
      } catch {
        /* no flutter bridge */
      }
      return next;
    });
  }, []);
  return <ThemeCtx.Provider value={{ theme, toggle }}>{children}</ThemeCtx.Provider>;
}

export const useTheme = () => useContext(ThemeCtx);

/* ---------- toasts ---------- */

interface Toast {
  id: number;
  text: string;
  kind: string;
}
const ToastCtx = createContext<{ toast: (text: string, kind?: string) => void }>({
  toast: () => {},
});

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [items, setItems] = useState<Toast[]>([]);
  const idRef = useRef(1);
  const toast = useCallback((text: string, kind = "") => {
    const id = idRef.current++;
    setItems((prev) => [...prev.slice(-4), { id, text, kind }]);
    setTimeout(() => setItems((prev) => prev.filter((t) => t.id !== id)), 4500);
  }, []);
  return (
    <ToastCtx.Provider value={{ toast }}>
      {children}
      <div className="toasts" aria-live="polite">
        {items.map((t) => (
          <div key={t.id} className={"toast" + (t.kind ? " " + t.kind : "")}>
            {t.text}
          </div>
        ))}
      </div>
    </ToastCtx.Provider>
  );
}

export const useToast = () => useContext(ToastCtx).toast;

/* ---------- client id (stable per browser, shared with ComfyUI ws) ---------- */

export function getClientId(): string {
  try {
    let id = localStorage.getItem("lazycomfy.clientId");
    if (!id) {
      id =
        typeof crypto !== "undefined" && "randomUUID" in crypto
          ? "lazycomfy-" + crypto.randomUUID().slice(0, 8)
          : "lazycomfy-" + Math.random().toString(36).slice(2, 10);
      localStorage.setItem("lazycomfy.clientId", id);
    }
    return id;
  } catch {
    return "lazycomfy-" + Math.random().toString(36).slice(2, 10);
  }
}

/* ---------- shared ComfyUI websocket ---------- */

export interface WsMessage {
  type: string;
  data: any;
}

type WsListener = (msg: WsMessage) => void;

/**
 * Single shared /ws connection for the whole SPA (one per tab, not one per
 * page — this is the main win over the multi-page HTML stack). Components
 * subscribe with onMessage; messages are fanned out to all listeners.
 */
class WsHub {
  private ws: WebSocket | null = null;
  private listeners = new Set<WsListener>();
  private retry = 0;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  connected = false;
  private connListeners = new Set<(on: boolean) => void>();

  onConn(fn: (on: boolean) => void): () => void {
    this.connListeners.add(fn);
    fn(this.connected);
    return () => this.connListeners.delete(fn);
  }

  private setConnected(on: boolean) {
    this.connected = on;
    this.connListeners.forEach((fn) => fn(on));
  }

  subscribe(fn: WsListener): () => void {
    this.listeners.add(fn);
    this.ensure();
    return () => this.listeners.delete(fn);
  }

  private ensure() {
    if (typeof window === "undefined") return;
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING))
      return;
    let url: string;
    try {
      const proto = location.protocol === "https:" ? "wss" : "ws";
      url = proto + "://" + location.host + "/ws?clientId=" + encodeURIComponent(getClientId());
    } catch {
      return;
    }
    try {
      this.ws = new WebSocket(url);
    } catch {
      this.schedule();
      return;
    }
    this.ws.onopen = () => {
      this.retry = 0;
      this.setConnected(true);
      try {
        this.ws?.send(JSON.stringify({ type: "feature_flags", data: {} }));
      } catch {
        /* ignore */
      }
      if (this.pingTimer) clearInterval(this.pingTimer);
      this.pingTimer = setInterval(() => {
        try {
          this.ws?.send(JSON.stringify({ type: "ping" }));
        } catch {
          /* ignore */
        }
      }, 25000);
    };
    this.ws.onmessage = (ev) => {
      let m: WsMessage;
      try {
        m = JSON.parse(ev.data);
      } catch {
        return;
      }
      if (m?.data?.sid && typeof m.data.sid === "string") {
        try {
          if (localStorage.getItem("lazycomfy.clientId") !== m.data.sid)
            localStorage.setItem("lazycomfy.clientId", m.data.sid);
        } catch {
          /* ignore */
        }
      }
      this.listeners.forEach((fn) => fn(m));
    };
    const down = () => {
      this.setConnected(false);
      if (this.pingTimer) {
        clearInterval(this.pingTimer);
        this.pingTimer = null;
      }
      this.ws = null;
      this.schedule();
    };
    this.ws.onclose = down;
    this.ws.onerror = down;
  }

  private schedule() {
    if (this.retryTimer || typeof window === "undefined") return;
    const wait = Math.min(1000 * 2 ** Math.min(this.retry, 6), 30000);
    this.retry++;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      if (this.listeners.size > 0) this.ensure();
    }, wait);
  }
}

export const wsHub = new WsHub();

export function useComfyWs(listener: WsListener): boolean {
  const [connected, setConnected] = useState(wsHub.connected);
  const ref = useRef(listener);
  ref.current = listener;
  useEffect(() => {
    const off = wsHub.subscribe((m) => ref.current(m));
    const offConn = wsHub.onConn(setConnected);
    return () => {
      off();
      offConn();
    };
  }, []);
  return connected;
}
