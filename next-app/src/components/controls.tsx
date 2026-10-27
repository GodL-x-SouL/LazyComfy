"use client";

import { useEffect, useRef, useState } from "react";

export interface SelectOption {
  value: string;
  label: string;
  hint?: string;
}

interface SelectProps {
  value: string;
  options: SelectOption[];
  onChange: (value: string) => void;
  placeholder?: string;
  disabled?: boolean;
  label?: string;
}

/** Glass custom dropdown — single source of truth stays in `value`/`onChange`. */
export function Select({ value, options, onChange, placeholder, disabled, label }: SelectProps) {
  const [open, setOpen] = useState(false);
  const [flip, setFlip] = useState(false);
  const [focusIdx, setFocusIdx] = useState(-1);
  const rootRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const current = options.find((o) => o.value === value);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open ]);

  useEffect(() => {
    if (open && rootRef.current) {
      const rect = rootRef.current.getBoundingClientRect();
      setFlip(window.innerHeight - rect.bottom < 250 && rect.top > 250);
      const idx = options.findIndex((o) => o.value === value);
      setFocusIdx(idx);
      requestAnimationFrame(() => {
        menuRef.current?.querySelector(".select-option.active")?.scrollIntoView({ block: "nearest" });
      });
    }
  }, [open, options, value]);

  const pick = (v: string) => {
    setOpen(false);
    if (v !== value) onChange(v);
  };

  const moveFocus = (dir: 1 | -1) => {
    const next = Math.max(0, Math.min(options.length - 1, (focusIdx < 0 ? (dir === 1 ? -1 : options.length) : focusIdx) + dir));
    setFocusIdx(next);
    menuRef.current?.querySelectorAll(".select-option")[next]?.scrollIntoView({ block: "nearest" });
  };

  const onTriggerKey = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!open) {
        setOpen(true);
        return;
      }
      moveFocus(e.key === "ArrowDown" ? 1 : -1);
    } else if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      if (!open) setOpen(true);
      else if (focusIdx >= 0 && options[focusIdx]) pick(options[focusIdx].value);
      else setOpen(false);
    } else if (e.key === "Tab") {
      setOpen(false);
    }
  };

  return (
    <div ref={rootRef} className={"select" + (open ? " open" : "")}>
      <button
        type="button"
        className="select-trigger"
        aria-haspopup="listbox"
        aria-expanded={open}
        disabled={disabled}
        aria-label={label}
        onClick={() => !disabled && setOpen(!open)}
        onKeyDown={onTriggerKey}
      >
        <span className={"select-value" + (current ? "" : " is-placeholder")}>
          {current ? current.label : placeholder || "Select…"}
        </span>
        <span className="select-chevron" aria-hidden>
          <svg width="13" height="8" viewBox="0 0 12 7" fill="none">
            <path d="M1 1.5l5 4 5-4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </span>
      </button>
      {open && !disabled && (
        <div ref={menuRef} className={"select-menu" + (flip ? " flip" : "")} role="listbox">
          <div className="select-options">
            {options.length === 0 && <div className="select-option" aria-disabled>Nothing here</div>}
            {options.map((o, i) => (
              <button
                key={o.value + i}
                type="button"
                role="option"
                aria-selected={o.value === value}
                className={"select-option" + (o.value === value ? " active" : "")}
                onClick={() => pick(o.value)}
                onMouseEnter={() => setFocusIdx(i)}
              >
                <span className="select-option-text">
                  <span className="select-option-label">{o.label}</span>
                  {o.hint && <span className="select-option-hint">{o.hint}</span>}
                </span>
                {o.value === value && <span className="tick">✓</span>}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

interface SwitchProps {
  checked: boolean;
  onChange: (on: boolean) => void;
  disabled?: boolean;
  label?: string;
}

/** iOS-style toggle switch for booleans. */
export function Switch({ checked, onChange, disabled, label }: SwitchProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      className="switch"
      disabled={disabled}
      onClick={() => onChange(!checked)}
    >
      <span className="knob" />
    </button>
  );
}
