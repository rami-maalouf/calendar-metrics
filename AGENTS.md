# AGENTS.md

## Cursor Cloud specific instructions

This is a Better-T-Stack monorepo (Bun workspaces + Turborepo). See `README.md` for the
canonical scripts. Notes below cover only non-obvious things needed to run it in this VM.

### Services / apps

- `packages/backend` — Convex backend (functions, schema, HTTP routes, Better-Auth). Run cmd: `convex dev`.
- `apps/web` — TanStack Start (React) web app served by Vite on port `3001`. Run cmd: `bun run dev:web`.
- `apps/native` — Expo / React Native app (`bun run dev:native`); needs Expo Go or a simulator, not runnable headless here.
- `apps/Intent`, `apps/IntentIOS`, `apps/IntentCalendar` — Swift/Xcode apps; **cannot be built on this Linux VM** (macOS/Xcode only).

### Running the backend (Convex) locally without a Convex account

The dependency install (`bun install`) is handled by the startup update script. To run the
stack you must start the backend yourself, in anonymous local mode:

```bash
cd packages/backend
CONVEX_AGENT_MODE=anonymous bunx convex dev --tail-logs always
```

Non-obvious gotchas:

- Use `CONVEX_AGENT_MODE=anonymous`; otherwise `convex dev` tries to prompt for login and fails in this non-interactive environment.
- The first run downloads a local Convex backend binary + dashboard and writes `packages/backend/.env.local` (`CONVEX_URL=http://127.0.0.1:3210`). The local HTTP Actions ("site") host is `http://127.0.0.1:3211`.
- `convex dev` must stay running (it hosts the local backend). `convex dev --once` starts, pushes, then **exits and stops the backend** — only use it for a one-shot push/typecheck.
- After a fresh local deployment you must set two Convex env vars or auth (and `/intent/health`) fail with `BetterAuthError: You are using the default secret`:
  ```bash
  cd packages/backend
  CONVEX_AGENT_MODE=anonymous bunx convex env set BETTER_AUTH_SECRET "$(openssl rand -hex 32)"
  CONVEX_AGENT_MODE=anonymous bunx convex env set SITE_URL "http://127.0.0.1:3211"
  ```
- Optional Convex env vars enable extra features but are not needed for email/password auth: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (Google Calendar OAuth/sync), `TOGGL_API_TOKEN`, `TOGGL_WORKSPACE_ID`, `INTENT_SETUP_KEY`, `INTENT_PUBLIC_BASE_URL`. The web waitlist route also needs `NOTION_API_KEY` / `NOTION_WAITLIST_DATASOURCE_ID`.

### Running the web app

The web app reads Convex URLs from `apps/web/.env` (gitignored). Create it before `bun run dev:web`:

```bash
# apps/web/.env
VITE_CONVEX_URL=http://127.0.0.1:3210
VITE_CONVEX_SITE_URL=http://127.0.0.1:3211
```

- Vite binds to `localhost` (IPv6 `::1`); reach it at `http://localhost:3001`, not `http://127.0.0.1:3001`.
- Start the backend before the web app so SSR/queries can connect.
- Quick smoke test of the full stack: sign up at `http://localhost:3001/dashboard` (email/password) → redirects to `/onboarding`.

### Lint / test / typecheck

- No `lint` or `test` scripts are implemented in any package (the `turbo lint` / `turbo check-types` tasks resolve to nothing).
- `bunx tsc --noEmit` in `apps/web` currently reports **pre-existing** type errors in `packages/backend/convex/{debugAuth,intent}.ts`; these do not block `convex dev` (Convex bundles with `--typecheck try`). Do not treat them as caused by your changes.
