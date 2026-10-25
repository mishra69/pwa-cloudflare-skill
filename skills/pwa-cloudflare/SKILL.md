---
name: pwa-cloudflare
version: 1.1.0
description: Turn a web app into an installable PWA served from a single Cloudflare Worker — manifest, icons, offline service worker, iOS/Safari install prompt, versioned deploys, Web Push and scheduling notifications at a local time of day. Use when adding PWA/offline/"add to home screen" support or time-of-day push reminders, scaffolding a new PWA, consolidating a Pages + Worker split into one Worker, or debugging stale caches, install prompts, or iOS status-bar/safe-area problems.
---

# PWA on Cloudflare Workers

Two paths. Decide first, then follow Part 2.

- **Converting an existing app** — audit against the Part 1 checklist, fix only what's missing. Most apps already have a manifest and a half-working service worker; the gaps are usually icons, offline, and iOS.
- **New app from scratch** — same checklist, but scaffold `frontend/` + `worker/` first. Everything below still applies; nothing is convert-specific.

---

# Part 1 — The checklist (human-readable)

## Structure
- One Worker serves **both** the static frontend and `/api/*`. No separate Pages project.
- `[assets] directory = "../frontend"` in `wrangler.toml`. Assets match first; non-matching paths fall through to the Worker.
- Same-origin API means **all CORS code can be deleted**.

## Files you need
- `manifest.json` — name, `start_url`, `display: standalone`, icons, theme colour
- `sw.js` — precache the shell, serve it offline
- `_headers` — `no-cache` on `sw.js` and the shell
- `icons/` — 180 (apple-touch), 192, 512, maskable-512
- `deploy.sh` + `deploy.conf` — stamp a version, deploy, wait for propagation

## Icons
- Opaque background, **no transparency** — iOS renders alpha as black
- **No pre-rounded corners** — iOS applies its own squircle mask
- ~12% padding on the apple-touch icon, ~20% on the maskable one
- Simple shapes only; detail disappears at 180px

## Offline
- **Vendor every CDN dependency locally** — an un-precached CDN script means the app installs and then can't run
- Precache files **individually**, not with `addAll` — one 404 otherwise kills the whole install silently
- Precache `/`, never `/index.html`

## iOS / Safari
- Safari **never** fires `beforeinstallprompt`. Instructions are the only install mechanism.
- The status bar style is **baked in at install time** — changing it later doesn't reach an installed app
- Honour `env(safe-area-inset-*)` on every full-screen container
- `touch-action: manipulation`, `overscroll-behavior: none`, size with `dvh` not `vh`

## Sign-in (if you need accounts)
- Google's **ID token** flow needs only a client ID — **no client secret**
- Verifying the signature isn't enough — check the token was issued **for your app**
- Identify users by Google's `sub`, never by email
- Sign-in can't work offline, and the install prompt must not cover the sign-in button
- **Test inside the installed iOS app, not just Safari** — sign-in can bounce out to the browser, which has separate storage

## Notifications (Web Push)
- On iPhone/iPad it works **only from a home-screen install** — never in a browser tab
- The permission prompt must be triggered **inside a user gesture**
- Apple accepts only the `aes128gcm` payload coding; the older one returns **201 and displays nothing**
- Use `webpush-edge` — don't hand-roll the encryption or VAPID signing
- A service worker `push` handler is required; Declarative Web Push alone doesn't display on iOS
- Handle `pushsubscriptionchange`, or subscriptions silently die and notifications just stop

## Scheduling notifications ("at 9 pm their time")
- **Don't poll with a cron.** One Durable Object per user, with its alarm set for that user's next send
- **Decide at fire time** against fresh data, not when the alarm is armed
- **Re-plan on events** (a subscription re-sent on app open carries the device's zone, so travel re-plans itself), plus a **daily** cron as a safety net
- **Write the "sent" row before sending**, so a retried alarm can't double-send
- **Local time to an instant has to survive DST** and half-hour zones; test both
- The free plan only has **SQLite-backed** Durable Objects (`new_sqlite_classes`)

## Deploying
- Version stamp drives the service worker cache name, so every deploy busts the cache automatically
- Cloudflare asset propagation lags the deploy by seconds — poll before concluding it failed
- A cache-first service worker needs **two reloads**: the first installs the new worker, the second runs it
- Secrets are per-Worker; renaming a Worker means re-running `wrangler secret put`

## Reusable assets in `assets/`
| File | What it is |
|---|---|
| `pwa-install.js` | Drop-in install prompt. Handles Chromium + iOS + iPadOS |
| `deploy.sh` + `deploy.conf.example` | Generic stamp-deploy-verify script |
| `make-icons.py` | Generates all icon sizes, no dependencies |
| `sw.js` | Service worker template |
| `manifest.json`, `head.html`, `pwa.css` | Templates |
| `version-check.js` | Build stamp + stale-build detection |
| `oidc.js` | Verifies Google/Microsoft/Apple ID tokens in a Worker |

**Copy them into the app — don't import across projects.** A relative import into
a sibling folder breaks the moment the app is cloned on its own or built in CI.
The cost is drift, so make it visible: list what you copied in a `.skill-assets`
manifest at the app root, then run `sync-assets.sh` from there to compare, and
`sync-assets.sh --apply` to take the skill's version. Templates every app
customises (`sw.js`, `pwa.css`, `head.html`) shouldn't be listed — a diff
against those is expected and tells you nothing.

## Depend on, don't copy
| Package | For |
|---|---|
| [`webpush-edge`](https://github.com/mishra69/webpush-edge) | Web Push — aes128gcm, VAPID, and the iOS constraints |

Once a shared file has a second consumer, publish it and depend on it instead of
copying — a package carries its own tests and version, and a fix reaches every
app with an install rather than a diff. `oidc.js` is the next candidate. The
exception is code that runs in the **browser**: with no bundler, a package half
still has to be copied into the assets directory, so depend on it for the Worker
and vendor it unmodified for the page.

---

# Part 2 — Implementation notes (agent)

Work through this in order. Verify each phase before moving on — several failures here are silent.

## 0. Audit first (convert path)

Don't assume anything is missing or present. Check:

```bash
ls frontend/{manifest.json,sw.js,_headers} frontend/icons/ 2>&1
grep -n "apple-mobile-web-app\|theme-color\|manifest\|apple-touch" frontend/index.html
grep -rn "cdn\.\|https://unpkg\|https://cdn" frontend/index.html   # offline blockers
grep -n "API_BASE\|apiBase" frontend/js/*.js                       # cross-origin API?
```

A referenced-but-missing `icons/` directory is the single most common gap — the manifest points at files that were never created, and nothing warns you.

## 1. Consolidate onto one Worker

```toml
name = "APP"
main = "index.js"
compatibility_date = "2026-05-01"   # bump old dates; static assets need a recent one

[assets]
directory = "../frontend"
```

**No file moves are required.** `directory` is just a pointer; leave the existing layout alone. Do not restructure someone's repo to fit a convention.

Then:
- Set the client's API base to `/api` (relative)
- Delete the `cors()` helper, the `OPTIONS` preflight branch, and any `ALLOWED_ORIGIN` var
- Keep the `if (!path.startsWith('/api/'))` guard as a 404 fallback

Deleting a Pages project: `wrangler pages project delete NAME --yes`. Deleting a Worker: `wrangler delete --name NAME --force` — note `--force`, **not** `--yes`; the wrong flag prints usage and silently deletes nothing.

## 2. Icons

`assets/make-icons.py` writes 180/192/512/maskable-512 with no dependencies (pure `zlib` + `struct` PNG encoder — PIL is usually not installed).

**Always look at the output** before shipping it:

```
Read the generated 512 PNG and check it reads as intended at a glance.
```

Two failure modes that only show up visually: grid lines thick enough to merge into a solid mass, and foreground shapes the same colour as the lines, which makes the design vanish. Both look fine in code.

## 3. Service worker

Start from `assets/sw.js`. The non-obvious parts:

- **`/index.html` 307-redirects to `/`** on Workers Static Assets, and the Cache API *refuses to store a redirected response*. Precaching `/index.html` always fails. Precache `/` only, and guard the navigation handler with `!res.redirected` before caching.
- **`cache.addAll()` is atomic.** One 404 rejects the entire install, and since registration errors are usually swallowed by a `.catch(() => {})`, the app silently loses offline support. Use per-file `c.add(url).catch(...)`.
- **Cross-origin and non-GET requests must bypass the cache entirely**, or POSTs land in the cache-first branch.
- **`?_v=` probes must go straight to the network.** `cache: 'no-store'` bypasses the HTTP cache but *not* the service worker, so a version probe without this is served from the same cache the app booted from and can never detect staleness.
- **Navigations network-first, assets cache-first.** Navigation-first is what lets a deploy land on next launch.
- **Stamp the version into `sw.js` itself.** A worker installs only when its script's bytes change, so that's the trigger. Reading the version from a file the worker caches instead deadlocks — it serves the old value, and the page re-registers the version it already has.

Verify by killing the dev server and reloading — the app must still boot and function.

## 4. `_headers`

Copy `assets/_headers`. The critical rule is `no-cache` on `sw.js`: a long-cached service worker pins users to an old build with no recovery path.

Wrangler prints `Parsed N valid header rules` on startup — check that number matches.

## 5. iOS and safe areas

Copy the `<head>` block from `assets/head.html` and merge `assets/pwa.css`.

**The status-bar trap.** `apple-mobile-web-app-status-bar-style` is read once, when the user adds the app to the home screen, and baked into that install. Changing it later does **not** reach an installed app — only new installs. So:

- Default to `default`. It's safe: iOS keeps the web view below the status bar.
- `black-translucent` looks better but only works if *every* screen honours `env(safe-area-inset-top)`.
- If a user reports occlusion on an existing install, changing the meta tag will not fix it. **Fix the CSS instead** — that reaches them through a normal update. Make the layout correct under both styles.

**Watch for a later rule wiping the inset.** A pattern like:

```css
.screen   { padding: env(safe-area-inset-top) ...; }
#screen-x { padding: 0; }   /* silently removes it for this screen */
```

is harmless under `default` (inset is 0) and breaks the moment anything goes full-bleed. Grep for `padding: 0` on containers after adding safe-area rules.

For a top bar, make the bar absorb the inset itself — grow its height and pad its contents down — so its background fills behind the status bar rather than leaving a gap.

## 6. Install prompt

Copy `assets/pwa-install.js`, then:

```html
<script src="/js/pwa-install.js"></script>
<script>PWAInstall.init({ appName: 'NAME', remember: 7 });</script>
```

Theme it by mapping the app's own variables — custom properties inherit through the shadow boundary, so it follows a `data-theme` switch with no extra wiring:

```css
:root { --pwa-accent: var(--primary); --pwa-surface: var(--surface); --pwa-text: var(--text); }
```

What the module encodes:
- `beforeinstallprompt` is **Chromium-only**; Safari has no equivalent and never will. iOS gets static instructions.
- The event must be captured at load and stashed — `.prompt()` only works inside a user gesture.
- **iPadOS 13+ reports a `Macintosh` UA**, so `/iPad|iPhone|iPod/` misses every modern iPad. It adds `navigator.maxTouchPoints > 1`.
- Chrome/Firefox on iOS (`CriOS`/`FxiOS`) need different wording — their Share menus differ from Safari's.
- Installed-detection needs `navigator.standalone` **and** `display-mode: standalone`; neither alone covers everything.
- Shows nothing when there's no install path, rather than a dead prompt.

## 7. Versioned deploys

Copy `assets/deploy.sh` + `deploy.conf`, and `assets/version-check.js` into the app's boot.

Derive the service worker cache name from the stamped version:

```js
const VERSION = 'dev';              // stamped by deploy.sh
const CACHE = 'APP-' + VERSION;
```

This is worth doing purely because hand-bumping a cache version is easy to forget, and forgetting ships stale CSS that looks like the deploy silently failed.

Put `[data-version]` on **every** screen a user can land on — including the post-login landing screen, not just the login screen. A signed-in user never sees the login screen, so a stamp only there is invisible in practice.

## 8. Verify

Don't declare success from a successful `wrangler deploy`. Actually check:

```
- curl the shell, an asset, an icon, and /api/* — all 200/expected
- confirm sw.js returns Cache-Control: no-cache
- in a browser: service worker active, precache count matches SHELL, zero failures
- kill the server, reload → app still boots and works offline
- check the version tag shows the build you just deployed
```

**Propagation lag is real.** Assets 404 or serve stale for ~3–30s after `wrangler deploy` completes, inconsistently across files — `sw.js` can be current while `index.html` is not. `deploy.sh` polls for this. Never conclude a deploy failed without re-checking after ~30s.

**Two reloads.** After a deploy the first load still runs the old build (the new worker installs during it); the second runs the new one. On iOS that means force-quitting from the app switcher and relaunching twice. Expect this when testing on a phone, and check the version tag rather than guessing.

## Local development

`wrangler dev --local` needs its own setup — production state does not carry over:

- **Secrets**: create `.dev.vars` (gitignored). Missing `TOKEN_SECRET` produces a confusing failure where a *wrong* password 401s correctly but a *correct* one 500s, because it fails at token signing, not lookup.
- **D1**: apply the schema locally — `wrangler d1 execute DB --local --file=schema.sql`. A missing table surfaces as a generic 500.

Gitignore `.dev.vars`, `.wrangler/`, `node_modules/`, `.DS_Store`.

## Web Push (if the app needs notifications)

Depend on [`webpush-edge`](https://github.com/mishra69/webpush-edge) — zero-dependency, edge-native, and it already handles the parts that fail silently. `createPusher({ publicKey, privateJwk, contact, store })`, then `push.subscribe(userId, sub)` and `push.send(userId, notification)`.

**The package is a dependency for the Worker and a copy for the browser.** Wrangler bundles the Worker, so `import { createPusher } from 'webpush-edge'` just works. The browser has no bundler and can't resolve a bare specifier, so the page half must be served from your assets directory. Copy the file **unmodified** and import it by path from a small inline module — do not hand-flatten it to a classic script, or every local fix becomes a divergence that re-vendoring drops:

```html
<script type="module">
  import * as PushLib from '/js/vendor/webpush-edge/client.js';
  window.Push = PushLib;   // module scripts are deferred, so this lands before DOMContentLoaded
</script>
```

`deploy.sh`'s `VENDOR_COPY` refreshes those copies from `node_modules` on each deploy, so the package stays the single source. Note `client.js` imports `./sw.js`, so copy both.

- **The service-worker half stays inlined** if your `sw.js` is classic. Importing it needs `{ type: 'module' }` registration, and iOS is the whole point of the feature — not worth the bet.
- **`pushsubscriptionchange` fires with no session token.** A service worker can't authenticate, so endpoint rotation needs a *public* route. Authorise it by possession of the old endpoint — a capability URL only that device and your server ever held — and let it do nothing but swap one endpoint for another.
- **The VAPID public key endpoint must be unauthenticated.** It's public by definition; gating it means the browser can't subscribe at all.
- **Bearer-token apps need `subscribe({ headers })`** (v1.1.0+). Without it the client issues bare fetches and your own endpoints answer 401.
- **Storage**: `kvStore(env.KV)`, or any `{ get(id), set(id, subs) }` — a D1 table works fine. The store receives the *whole list* on every change, so a naive "delete all then reinsert" resets `created_at` and defeats upserts.
- **Re-send the browser's subscription on every app open.** The browser can hold a live subscription the server never stored (made under another account, pruned, a lost POST, a wiped store). The page then shows "Turn on" while permission is already granted, and the test trigger answers "no devices". When `Notification.permission === "granted"` and `currentSubscription()` returns one the server doesn't list, call `subscribe({ prompt: false })`; it's idempotent on endpoint and needs no gesture.
- **Ship a hidden test trigger.** Tapping the build stamp to subscribe and fire a one-off push turns "notifications don't work" into a status code: 201 accepted, 403 VAPID mismatch, 400 encryption, 410 subscription gone.

## Scheduling sends (if notifications go out at a time of day)

"Remind them at 21:00 their time" has an obvious implementation: a cron every few minutes that asks every user "is it 21:00 for you yet?". Don't. A cron fires only on its own ticks, so it either quantises every send to :00/:30 or runs constantly. A per-minute cron was measured at ~85% of an app's D1 queries, nearly all finding nothing to do. **Use a Durable Object alarm per user instead.** It fires at the exact minute, costs nothing between sends, and there is no sweep to keep cheap.

```toml
[[durable_objects.bindings]]
name = "CLOCK"
class_name = "UserClock"

[[migrations]]
tag = "v1"
new_sqlite_classes = ["UserClock"]   # the free plan only offers SQLite-backed objects
```

```js
import { DurableObject } from 'cloudflare:workers';

// One per user (idFromName(userId)). A DO holds a single alarm: set it for the next thing due.
export class UserClock extends DurableObject {
  async wake(userId) {                       // RPC from the Worker
    await this.ctx.storage.put('userId', userId);
    await this.plan(userId);
  }
  async alarm() {
    const userId = await this.ctx.storage.get('userId');
    try {
      await sendDue(this.env, userId, Date.now());   // decides now, from D1; claims before sending
    } finally {
      await this.plan(userId);                       // whatever happened, the chain continues
    }
  }
  async plan(userId) {
    const next = await nextDue(this.env, userId, Date.now());   // re-derived from D1 every time
    if (next == null) await this.ctx.storage.deleteAlarm();
    else await this.ctx.storage.setAlarm(Math.max(next, Date.now()));  // past = fire now
  }
}

export const wake = (env, userId) => env.CLOCK.get(env.CLOCK.idFromName(userId)).wake(userId);
```

- **Keep `sendDue` and `nextDue` pure** (an injected `now`, zone and state; no I/O). Unit tests can then cover any hour, DST weekend or flight without waiting for 21:00. Keep them in modules that don't import the DO file: `cloudflare:workers` doesn't resolve under Node, and one transitive import fails the whole test file.
- **`nextDue` must return `now` when something is due now.** The obvious "first time strictly after now" skips the send that's due *right now*. That's exactly the case of a user subscribing at 21:10, when the alarm should fire at once. Add a property test: for many values of `now`, the time it returns is one at which `sendDue` would actually send.
- **Decide at fire time, not at plan time.** An armed alarm is a *prediction* that a send will be wanted. The real answer (cap reached, already logged today, quiet day or not) only exists when it fires. Checking then has no race. A sweep that disarms alarms races the alarm it's trying to cancel.
- **Claim before sending.** Insert the `(user, kind, local_date)` row with `INSERT OR IGNORE` first, and send only if it inserted. Alarms are retried on failure, and a retry must not double-send.
- **Wake the clock on events, not on a schedule:**
  - on anything that changes what's due next;
  - on every push subscription. The page already re-sends it on each app open (see above), so send the device's IANA zone with it (`X-Timezone: Intl.DateTimeFormat().resolvedOptions().timeZone`). Travel then re-plans the next send by itself.
  - The alarm itself doesn't need waking for data that only makes a send *unnecessary*: the fire-time check covers that.
- **Keep one daily cron as a safety net** that calls `wake()` for every subscribed user, in case an alarm was lost to a bad deploy or migration. Alarms are durable and retried, so this is insurance, not the delivery path.
- **Local time to instant, DST-safe.** Guess the UTC instant from the wall-clock fields, read the zone's wall clock back at the guess with `Intl.DateTimeFormat(…, { timeZone })`, and correct by the difference. Two corrections settle across any transition. Test a fall-back night and a `+05:30` zone.
- **Guard sane hours after travel.** An alarm armed for 21:00 Pacific fires at about 04:00 for someone who has just landed in India. Re-check the local hour at fire time and drop the send if it's outside, say, 07:00–24:00. Or re-plan on the next app open, which the subscription re-send already does.
- **Two ways to plan, both fine:**
  - **Plan ahead:** choose the target hours early (e.g. at a 04:00 rollover), with random jitter so the notification doesn't become a cue of its own. Store it, and keep a frequent safety-net cron for the planning step.
  - **Re-derive:** every wake computes the next send from the data, with no stored plan, so it can't drift. Only a daily safety net is needed.
- **The same clock can run other per-user work** that has to happen later, such as a queued background job with retry backoff. Make `nextDue` the earliest of everything the user is waiting for. There's still one alarm per user, and nothing polls.
- **Local testing:** `wrangler dev` and the Cloudflare Vite plugin run alarms for real, so an end-to-end test can subscribe and poll for the "sent" row instead of faking the clock.

## Google sign-in (if the app needs accounts)

Use the Google Identity Services **ID token** flow, not the authorization code flow. The browser gets a signed JWT, the Worker verifies it, done.

**Don't hand-roll the verification — copy `assets/oidc.js`.** It's provider-agnostic (`verifyIdToken(token, { ...GOOGLE, audience })`, with presets for Google, Microsoft and Apple) and it already handles the parts that are easy to get wrong. The notes below are why it does what it does, not a spec to reimplement.

- **No client secret.** Only the code-exchange flow needs one. The client ID ships to browsers anyway, so it belongs in `wrangler.toml` `[vars]`, not `wrangler secret put`. Serve it to the client from an endpoint so the config stays single-sourced.
- **Verifying the signature is not enough — check `aud` against your client ID.** A token Google issued for any *other* app carries a perfectly valid signature. Also check `iss` and `exp`.
- **Key players on `sub`, never email.** Emails get changed and recycled; `sub` is immutable.
- **Fetch the JWKS with `cf: { cacheTtl }`.** Google rotates keys, so it can't be hardcoded, but one fetch per sign-in is wasteful.
- **GIS is cross-origin and can't be vendored**, so sign-in never works offline. Fine — but keep the rest of the shell independent of it, and let the service worker ignore it (it already skips cross-origin).
- **Turn off the install prompt's `autoShow`.** It renders over the sign-in button and blocks login on a first visit. Trigger it after the user is signed in.
- **Test inside the installed iOS PWA, not just Safari.** The sign-in flow can punt the user out to Safari, and a standalone install has its own storage jar — so signing in there can leave the app still signed out. This is the most likely thing to break, and it only shows up on-device.
