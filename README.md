# pwa-cloudflare-skill

A [Claude Code](https://claude.com/claude-code) skill for building installable PWAs served
from a single Cloudflare Worker — and, more usefully, a written record of the things that
silently don't work.

Most of it exists because something failed on a real device rather than in theory:

- **Apple's push service accepts only `aes128gcm`.** The older coding returns `201 Created`
  and displays nothing at all.
- **`apple-mobile-web-app-status-bar-style` is baked in when the app is added to the Home
  Screen.** Changing the meta tag later never reaches an existing install — the fix has to be
  CSS.
- **`cache.addAll()` is atomic.** One 404 rejects the whole service worker install, and
  because registration errors are usually swallowed, offline support just quietly disappears.
- **Workers Static Assets 307-redirects `/index.html` to `/`**, and the Cache API refuses to
  store a redirected response — so precaching `/index.html` always fails.
- **iPadOS 13+ reports a `Macintosh` user agent**, so the usual `/iPad|iPhone|iPod/` test
  misses every modern iPad.
- **Verifying a Google ID token's signature is not enough.** Without checking `aud`, a token
  minted for any other application passes.

## Layout

```
skills/pwa-cloudflare/
  SKILL.md          Part 1: a human checklist. Part 2: implementation notes for the agent
  assets/           drop-in files — install prompt, deploy script, icon generator, OIDC verifier
  sync-assets.sh    compare an app's copies against the canonical ones
```

## Using it

Clone into your `.claude/` directory — either `~/.claude/` for every project, or a project's
own `.claude/` to scope it:

```bash
git clone https://github.com/mishra69/pwa-cloudflare-skill ~/.claude
```

Assets are **copied into** each app rather than imported across projects: a relative import
into a sibling folder breaks the moment an app is cloned on its own or built in CI. The cost
of copying is drift, so it's made visible — record what you copied in a `.skill-assets`
manifest at the app root and run:

```bash
~/.claude/skills/pwa-cloudflare/sync-assets.sh            # report differences
~/.claude/skills/pwa-cloudflare/sync-assets.sh --apply    # take the skill's version
```

`--apply` records the skill version it synced from, so a later run tells you what you're
behind and hands you the `git diff` to read.

## Versioning

The version lives in `SKILL.md`'s frontmatter and is tagged here. Apps record the version
they were built against, which is what makes "what changed since?" answerable.

## Related

[`webpush-edge`](https://github.com/mishra69/webpush-edge) — Web Push for edge runtimes,
covering the encryption and VAPID signing this skill tells you not to hand-roll.

MIT.
