# agent-shell-dashboard

A landing page for [`agent-shell`](https://github.com/xenodium/agent-shell) —
one read-only buffer that shows every agent session at a glance, in the spirit
of doom-dashboard.

<img width="771" height="928" alt="Screenshot 2026-07-10 at 09 21 14" src="https://github.com/user-attachments/assets/e824dabf-3b2b-4564-9478-244284d23aa0" />


## Sections

- **Needs you** — the triage queue: sessions awaiting a permission decision or
  finished-but-unreviewed, each with a **one-line summary of the agent's last
  reply** (see below) and a hint when it looks like it's asking you something.
- **Sessions** — every live session with a status badge (`● Done`, `⏳ Working`,
  `⚠ Waiting`, `✓ Ready`, `[WT]` worktree), directory, model, and last activity.
- **Quick actions** — the keybinding menu.
- **Recent sessions** — the latest _previous_ (closed) sessions, read from
  agent-shell transcripts under recent projects. `RET` reopens one. Max
  `agent-shell-dashboard-recent-sessions-count` (default 4).

## The last-reply summarizer

By **default**, the sub-line under each "Needs you" row is a short **≤10-word
summary of the agent's last reply** — built in, no configuration needed. It:

- runs `agent-shell-dashboard-summary-command` (default `claude -p`)
  **asynchronously**, so rendering never blocks;
- **caches** per session keyed by the message, re-summarizing only when the
  reply changes; shows a `summarizing…` placeholder until the first result lands
  (then auto-refreshes);
- **falls back** to a plain last-message tail when the summarizer CLI isn't on
  your `PATH` — so it's safe even with zero setup.

Tune or replace it:

```elisp
;; Faster/cheaper model, or a different summarizer CLI entirely:
(setq agent-shell-dashboard-summary-command '("claude" "-p" "--model" "haiku"
                                              "--allowed-tools" ""))
(setq agent-shell-dashboard-summary-word-limit 8)

;; Prefer the raw last-message tail instead of a summary:
(setq agent-shell-dashboard-excerpt-function #'agent-shell-dashboard-excerpt-tail)

;; Or supply your own: a function of (buffer message) returning a one-line
;; string (see agent-shell-dashboard-excerpt-function).
```

## Install (Doom Emacs)

`packages.el`:

```elisp
(package! agent-shell-dashboard
  :recipe (:host github :repo "wandersoncferreira/agent-shell-dashboard"))
```

`config.el`:

```elisp
(use-package! agent-shell-dashboard
  :after agent-shell
  :commands (agent-shell-dashboard)
  :config
  ;; Optional: open it on startup
  (setq initial-buffer-choice #'agent-shell-dashboard))
```

Then `doom sync` and restart. Bind it if you like: `(map! :leader "d" #'agent-shell-dashboard)`.

<details>
<summary>straight.el / vanilla</summary>

```elisp
(use-package agent-shell-dashboard
  :straight (:host github :repo "wandersoncferreira/agent-shell-dashboard")
  :after agent-shell)
```
</details>

## Keybindings

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `RET` / `o` | Open (live) / reopen (recent) session | `R` | Reopen a previous session |
| `TAB` / `S-TAB` | Next / prev row | `f` | Fork session at point |
| `c` | New session | `m` | Set model at point |
| `w` | New worktree session | `K` | Kill session at point |
| `a` | Conclusions (`claude -p`) | `X` | Close all |
| `d` | Pending decisions | `g` / `r` | Refresh |
| `P` | Switch project | `q` / `?` | Quit / Help |

Every action delegates to a configurable `agent-shell-dashboard-*-function`, so
you can wire keys to your own commands without editing the package.

## Dependencies

Only hard dependency: **`agent-shell`**. Optional, auto-detected: `modus-themes`
(faces recolor on theme toggle), `projectile` (widens the Recent sessions scan +
`P`), `agent-shell-manager` (extra refresh trigger). A visible dashboard
refreshes on demand (`g`), on an idle timer, and (debounced) on agent activity.

## License

MIT — see [LICENSE](LICENSE).
