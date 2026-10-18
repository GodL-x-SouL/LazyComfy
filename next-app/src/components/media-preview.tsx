"use client";

import { useEffect, useState } from "react";
import type { MediaFile } from "@/lib/api";

export interface PreviewItem extends MediaFile {
  meta?: string;
  badge?: string;
  video?: boolean;
}

interface MediaPreviewProps {
  item: PreviewItem;
  onClose: () => void;
  onDelete?: () => Promise<boolean>;
}

const isVideoFile = (name?: string) => !!name && /\.(mp4|webm|mov|mkv)$/i.test(name);

/** Full-media lightbox used by the image, video, and custom galleries. */
export function MediaPreview({ item, onClose, onDelete }: MediaPreviewProps) {
  const [busy, setBusy] = useState(false);
  const video = item.video ?? isVideoFile(item.filename);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  const remove = async () => {
    if (!onDelete || busy) return;
    if (!confirm("Delete " + item.filename + "?")) return;
    setBusy(true);
    try {
      if (await onDelete()) onClose();
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 95,
        background: "rgba(0,0,0,.55)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: 12,
      }}
      onClick={onClose}
    >
      <div
        className="panel"
        style={{ width: "min(920px, 100%)", maxHeight: "92vh", overflow: "auto", position: "relative" }}
        onClick={(e) => e.stopPropagation()}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
          <span className="badge" style={{ overflow: "hidden", textOverflow: "ellipsis" }}>
            {item.badge || item.filename}
          </span>
          <span style={{ flex: 1 }} />
          <button className="icon-circle" type="button" aria-label="Close preview" onClick={onClose}>
            ✕
          </button>
        </div>
        {video ? (
          // eslint-disable-next-line jsx-a11y/media-has-caption
          <video
            src={item.url}
            controls
            playsInline
            style={{ display: "block", width: "100%", maxHeight: "70vh", borderRadius: 10, background: "#000" }}
          />
        ) : (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={item.url}
            alt={item.filename}
            style={{ display: "block", width: "100%", maxHeight: "70vh", objectFit: "contain", borderRadius: 10, background: "var(--accent-soft)" }}
          />
        )}
        {item.meta && (
          <p className="meta-line" style={{ margin: "8px 0 0", overflowWrap: "anywhere" }}>
            {item.meta}
          </p>
        )}
        <div className="row-actions">
          <a
            className="act-btn"
            href={item.url}
            download={item.filename || (video ? "lazycomfy.mp4" : "lazycomfy.png")}
          >
            Download
          </a>
          {onDelete && (
            <button className="act-btn danger" type="button" disabled={busy} onClick={remove}>
              {busy ? "Deleting…" : "Delete"}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
