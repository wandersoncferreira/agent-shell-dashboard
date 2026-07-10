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

The sub-line under each "Needs you" row is produced by
`agent-shell-dashboard-excerpt-function`, called with `(buffer message)`:

- **Default** — a truncated tail of the last agent message (no dependencies).
- **Custom** — point it at your own function to show a short **summary** of the
  last reply instead. Because it runs on every (visible) refresh, an expensive
  summarizer must cache its result and work asynchronously, returning a
  placeholder until ready:

  ```elisp
  (setq agent-shell-dashboard-excerpt-function #'my/agent-summary)
  ;; my/agent-summary: hash the message; if cached return it, else launch an
  ;; async `claude -p' (≤10 words), cache the result keyed by the hash, and
  ;; call `agent-shell-dashboard-refresh' when it lands.
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
