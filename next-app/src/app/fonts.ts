import localFont from "next/font/local";

export const manrope = localFont({
  src: "../fonts/manrope.woff2",
  weight: "500 800",
  display: "swap",
  variable: "--font-sans",
});

export const spaceGrotesk = localFont({
  src: "../fonts/space-grotesk.woff2",
  weight: "500 700",
  display: "swap",
  variable: "--font-display",
});

export const dmMono = localFont({
  src: [
    { path: "../fonts/dm-mono-400.woff2", weight: "400" },
    { path: "../fonts/dm-mono-500.woff2", weight: "500" },
  ],
  display: "swap",
  variable: "--font-mono",
});
