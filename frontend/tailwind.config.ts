import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        brand: {
          50:  "#fff3ef",
          100: "#ffe1d5",
          200: "#ffc1ab",
          300: "#ff9c7c",
          400: "#ff7d56",
          500: "#ff6b3d",
          600: "#f0552a",
          700: "#c43f1a",
          800: "#992f12",
          900: "#71210b",
        },
      },
      fontFamily: {
        sans: [
          "Plus Jakarta Sans",
          "DM Sans",
          "Inter",
          "ui-sans-serif",
          "system-ui",
          "sans-serif",
        ],
      },
      borderRadius: {
        xl: "16px",
        "2xl": "20px",
      },
      boxShadow: {
        card: "0 1px 2px rgba(20,20,30,0.03), 0 1px 1px rgba(20,20,30,0.02)",
        "card-hover": "0 4px 12px rgba(20,20,30,0.06)",
      },
    },
  },
  plugins: [],
};
export default config;
