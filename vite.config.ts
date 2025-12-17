import { defineConfig } from "vite";
import metadata from "./public/oauth-client-metadata.json";

const SERVER_PORT = 5173;

export default defineConfig({
  plugins: [
    {
      name: "oauth",
      config(_conf, { command }) {
        if (command === "build") {
          process.env.VITE_OAUTH_CLIENT_ID = metadata.client_id;
          process.env.VITE_OAUTH_REDIRECT_URL = metadata.redirect_uris[0];
        } else {
          // local dev: use http://localhost client ID trick
          const redirectUri = `http://127.0.0.1:${SERVER_PORT}/`;
          const clientId =
            `http://localhost` +
            `?redirect_uri=${encodeURIComponent(redirectUri)}` +
            `&scope=${encodeURIComponent(metadata.scope)}`;

          process.env.VITE_OAUTH_CLIENT_ID = clientId;
          process.env.VITE_OAUTH_REDIRECT_URL = redirectUri;
        }
      },
    },
  ],
  server: {
    host: "127.0.0.1",
    port: SERVER_PORT,
    strictPort: true,
  },
  build: {
    target: "esnext",
  },
});
