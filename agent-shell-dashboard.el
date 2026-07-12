;;; agent-shell-dashboard.el --- A landing page for agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Wanderson Ferreira

;; Author: Wanderson Ferreira
;; Maintainer: Wanderson Ferreira
;; URL: https://github.com/wandersoncferreira/agent-shell-dashboard
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (agent-shell "0.1"))
;; Keywords: convenience, tools

;; This file is not part of GNU Emacs.

;; Released under the MIT License; see the LICENSE file for details.

;;; Commentary:

;; A dashboard / landing page for `agent-shell', modelled after
;; doom-dashboard but focused on live agent sessions.  It surfaces, in a
;; single read-only buffer:
;;
;;   - an ASCII banner + a one-line heartbeat (session counts)
;;   - "Needs you": the triage queue (permission requests + finished-but-
;;     unreviewed sessions, with a one-line excerpt of the last message)
;;   - "Sessions": every live agent-shell buffer with a status badge,
;;     working directory, model and relative activity time
;;   - "Quick actions": a keybinding menu
;;   - "Recent sessions": the latest previous (closed) agent-shell sessions,
;;     discovered from transcript files; RET on one resumes it
;;   - a stats footer line
;;
;; All state is read from `agent-shell' *core* only (`agent-shell-buffers',
;; `agent-shell-status', `agent-shell-get-model-name', the buffer's
;; `default-directory').  The "Done" (finished-but-unreviewed) distinction and
;; activity-recency come from this package's own lightweight tracker — there is
;; no dependency on `agent-shell-manager' or any personal configuration.
;;
;; Every action key delegates to a configurable command
;; (`agent-shell-dashboard-*-function'), defaulting to agent-shell core
;; commands.  Point them at your own commands to customise behaviour without
;; touching this file.  See the Customization section.
;;
;; Refresh: on-demand (`g'), a single idle timer, and a debounced
;; event refresh driven by agent output.  No animation.
;;
;; Colors are pulled from the live modus palette (via
;; `modus-themes-with-colors') and re-applied on `enable-theme-functions',
;; so the light/dark toggle keeps working — matching the approach in the
;; author's `my-theme-overrides.el'.  Without modus, the static face
;; defaults below are used.
;;
;; Landing page:
;;   (setq initial-buffer-choice #'agent-shell-dashboard)

;;; Code:

(require 'agent-shell)
(require 'subr-x)
(require 'seq)
(require 'map)
(require 'cl-lib)
(require 'modus-themes nil t)

;;;; Customization

(defgroup agent-shell-dashboard nil
  "A landing page for `agent-shell'."
  :group 'agent-shell
  :prefix "agent-shell-dashboard-")

(defcustom agent-shell-dashboard-buffer-name "*agent-shell-dashboard*"
  "Name of the dashboard buffer."
  :type 'string)

(defcustom agent-shell-dashboard-banner
  '("   __ _  __ _  ___ _ __ | |_   ___| |__   ___| | |"
    "  / _` |/ _` |/ _ \\ '_ \\| __| / __| '_ \\ / _ \\ | |"
    " | (_| | (_| |  __/ | | | |_  \\__ \\ | | |  __/ | |"
    "  \\__,_|\\__, |\\___|_| |_|\\__| |___/_| |_|\\___|_|_|"
    "        |___/")
  "ASCII banner shown at the top of the dashboard, as a list of lines."
  :type '(repeat string))

(defcustom agent-shell-dashboard-idle-refresh-seconds 30
  "Idle seconds after which a *visible* dashboard is refreshed.
Set to nil to disable idle refreshing (use `g'/`r' to refresh manually)."
  :type '(choice (const :tag "Disabled" nil) (integer :tag "Seconds")))

(defcustom agent-shell-dashboard-event-refresh t
  "When non-nil, refresh a visible dashboard shortly after agent activity.
Hooks `agent-shell' transcript/manager updates so status transitions
\(Working -> Done, a new Waiting permission) appear without waiting for the
idle timer.  Refreshes are debounced by
`agent-shell-dashboard-event-refresh-delay' so a burst of streaming output
collapses into a single refresh."
  :type 'boolean)

(defcustom agent-shell-dashboard-event-refresh-delay 0.4
  "Debounce delay, in seconds, for event-driven refreshes.
A burst of activity within this window triggers a single refresh once it
settles, so continuous streaming does not re-render on every chunk."
  :type 'number)

(defcustom agent-shell-dashboard-recent-sessions-count 4
  "Maximum number of recent (previous) agent-shell sessions to list.
Sessions are discovered from agent-shell transcript files under each
recent project's `.agent-shell/transcripts/' directory, newest first,
excluding sessions that are already open."
  :type 'integer)

(defcustom agent-shell-dashboard-recent-sessions-function
  #'agent-shell-dashboard--recent-sessions-default
  "Function returning recent resumable sessions, newest first.
Called with no arguments; must return a list of plists, each with
`:id' (session id string), `:cwd' (working directory), `:agent'
\(display name), `:opened' (a `float-time' for when the session was
started) and `:time' (a `float-time' for recency ordering).  An
optional `:name' overrides the displayed buffer name.  The default
scans transcript files written by agent-shell; override to source
sessions differently."
  :type 'function)

(defcustom agent-shell-dashboard-session-name-function nil
  "Function mapping a recent-session plist to its buffer name, or nil.
Called with the session plist; should return the buffer/session name
string to show in the first column of the Recent sessions section, or
nil to fall back.  A closed session's buffer name is not recorded in the
transcript, so set this to look it up in your own session-name store
\(keyed by the plist's `:id').  When nil or it returns nil, the column
falls back to the plist's `:name', then the working-directory name."
  :type '(choice function (const :tag "Unset" nil)))

(defcustom agent-shell-dashboard-resume-recent-function
  #'agent-shell-dashboard--resume-recent-default
  "Function invoked to reopen a recent session chosen with RET.
Called with one argument: the session plist (see
`agent-shell-dashboard-recent-sessions-function').  The default binds
`default-directory' to the session's `:cwd' and calls the core
`agent-shell-resume-session' with its `:id'."
  :type 'function)

(defcustom agent-shell-dashboard-excerpt-width 90
  "Maximum width of the last-message excerpt in the \"Needs you\" section."
  :type 'integer)

(defcustom agent-shell-dashboard-path-width 30
  "Column width for the working-directory path in the Sessions table."
  :type 'integer)

;; Action commands.  Each key in the dashboard delegates to the command named
;; here, so the UI stays decoupled from any particular workflow.  Defaults are
;; `agent-shell' *core* commands; a nil value means the action is unconfigured
;; and its key reports how to enable it.  Override these to wire in your own
;; richer commands (e.g. a manager that prompts for a directory + name).

(defcustom agent-shell-dashboard-new-session-function #'agent-shell-new-shell
  "Command invoked by `c' to start a new session."
  :type '(choice function (const :tag "Unconfigured" nil)))

(defcustom agent-shell-dashboard-new-worktree-function #'agent-shell-new-worktree-shell
  "Command invoked by `w' to start a new session in a git worktree."
  :type '(choice function (const :tag "Unconfigured" nil)))

(defcustom agent-shell-dashboard-set-model-function
  #'agent-shell-dashboard--set-model-default
  "Command invoked by `m' to set the model of the session at point.
Called with that session's buffer current.  Defaults to a built-in that
pops up the models the session advertises and applies the choice."
  :type '(choice function (const :tag "Unconfigured" nil)))

(defcustom agent-shell-dashboard-rename-function
  #'agent-shell-dashboard--rename-default
  "Command invoked by `r' to rename the session on the row at point.
Called with that session's buffer current.  Defaults to a built-in that
renames the buffer; override with a command that also persists the name
so it survives resume."
  :type '(choice function (const :tag "Unconfigured" nil)))

(defcustom agent-shell-dashboard-conclusions-function
  #'agent-shell-dashboard-conclusions-default
  "Command invoked by `a' to summarise session conclusions.
Defaults to a built-in that runs one async summarizer job (via
`agent-shell-dashboard-summary-command') over all live sessions and
shows a report buffer of per-session <=N-word conclusions.  Falls back
to a message when the summarizer CLI is unavailable.  Override to plug
in your own summariser."
  :type '(choice function (const :tag "Unconfigured" nil)))

(defcustom agent-shell-dashboard-close-all-function
  #'agent-shell-dashboard--close-all-default
  "Command invoked by `X' to close all sessions.
Defaults to a built-in that kills every agent-shell buffer after
confirmation.  Override to add pre-close checks."
  :type '(choice function (const :tag "Unconfigured" nil)))

(defcustom agent-shell-dashboard-fork-session-function #'agent-shell-fork
  "Command invoked by `f' to fork the session on the row at point.
Called with the session buffer at point current, so core
`agent-shell-fork' (the default) forks that row's conversation into a
new shell, leaving the original intact.  The agent must advertise
session-fork support, else forking reports it is unavailable."
  :type '(choice function (const :tag "Unconfigured" nil)))

(defcustom agent-shell-dashboard-resume-session-function
  #'agent-shell-resume-session
  "Command invoked by `R' to reopen a previous (closed) session.
No session row is required — this reopens a session that has no live
buffer.  Defaults to core `agent-shell-resume-session', which prompts
for a session id; override with a command that presents a session
picker (e.g. one that starts a shell with the `prompt' strategy)."
  :type '(choice function (const :tag "Unconfigured" nil)))

;;;; Faces
;;
;; Static defaults are tuned for a dark background; when a modus theme is
;; active they are recolored from the live palette (see the theme layer at
;; the bottom of this file), so light/dark toggling stays correct.

(defface agent-shell-dashboard-banner
  '((t :foreground "#79a8ff" :weight bold))
  "Face for the ASCII banner.")

(defface agent-shell-dashboard-subtitle
  '((t :inherit shadow))
  "Face for the heartbeat/subtitle line.")

(defface agent-shell-dashboard-attention
  '((t :foreground "#ff7f86" :weight bold))
  "Face for the \"Needs you\" heading and decision hints (rust/red).")

(defface agent-shell-dashboard-heading-sessions
  '((t :foreground "#79a8ff" :weight bold))
  "Face for the Sessions heading (blue).")

(defface agent-shell-dashboard-heading-actions
  '((t :foreground "#4ae2f0" :weight bold))
  "Face for the Quick actions heading (teal/cyan).")

(defface agent-shell-dashboard-heading-projects
  '((t :foreground "#fec43f" :weight bold))
  "Face for the Recent sessions heading (amber/yellow).")

(defface agent-shell-dashboard-key
  '((t :foreground "#79a8ff" :weight bold))
  "Face for keybinding hints like [c].")

(defface agent-shell-dashboard-model
  '((t :foreground "#b6a0ff"))
  "Face for the model column (plum/magenta).")

(defface agent-shell-dashboard-dim
  '((t :inherit shadow))
  "Face for dim secondary text (paths, times).")

(defface agent-shell-dashboard-quote
  '((t :inherit shadow :slant italic))
  "Face for the excerpt/quote sub-line.")

(defface agent-shell-dashboard-badge-done
  '((t :foreground "#00c06f" :background "#00422a"
       :box (:line-width (1 . -1) :color "#00c06f") :weight bold))
  "Badge face for finished, unreviewed sessions (green).")

(defface agent-shell-dashboard-badge-working
  '((t :foreground "#fec43f" :background "#4a4000"
       :box (:line-width (1 . -1) :color "#fec43f") :weight bold))
  "Badge face for in-progress sessions (amber).")

(defface agent-shell-dashboard-badge-waiting
  '((t :foreground "#ff7f86" :background "#620f2a"
       :box (:line-width (1 . -1) :color "#ff7f86") :weight bold))
  "Badge face for sessions awaiting a permission decision (rust).")

(defface agent-shell-dashboard-badge-ready
  '((t :foreground "#88ca9f"
       :box (:line-width (1 . -1) :color "#61677f")))
  "Badge face for finished, already-reviewed sessions.")

(defface agent-shell-dashboard-badge-wt
  '((t :foreground "#4ae2f0" :background "#004065"
       :box (:line-width (1 . -1) :color "#4ae2f0") :weight bold))
  "Badge face for the worktree tag.")

;;;; Data layer — read agent-shell state
;;
;; Everything here uses `agent-shell' *core* public API only:
;;   - `agent-shell-buffers'      — the live shells
;;   - `agent-shell-status'       — `busy' / `blocked' / `ready'
;;   - `agent-shell-get-model-name' — model display name from state
;;   - the buffer's `default-directory' — its working directory
;; No dependency on `agent-shell-manager' or any personal config.  The
;; "Done" (finished-but-unreviewed) distinction is provided by this
;; package's own lightweight tracker (see the hooks section below).

(defun agent-shell-dashboard--buffers ()
  "Return the list of live agent-shell buffers."
  (seq-filter #'buffer-live-p (agent-shell-buffers)))

(defun agent-shell-dashboard--cwd (buffer)
  "Return BUFFER's working directory."
  (buffer-local-value 'default-directory buffer))

(defun agent-shell-dashboard--humanize-tokens (n)
  "Format token count N compactly: 1500->2k, 500303->500k, 1000000->1M."
  (cond
   ((null n) "?")
   ((>= n 1000000) (let ((m (/ n 1000000.0)))
                     (if (or (>= m 10) (= m (ftruncate m)))
                         (format "%dM" (round m))
                       (format "%.1fM" m))))
   ((>= n 1000) (format "%dk" (round (/ n 1000.0))))
   (t (format "%d" n))))

(defun agent-shell-dashboard--slim-model-name (name)
  "Strip a trailing \" (… context)\" parenthetical from model NAME."
  (if name
      (string-trim (replace-regexp-in-string " *([^)]*)\\'" "" name))
    "—"))

(defun agent-shell-dashboard--model (buffer)
  "Return BUFFER's slim model cell: \"Model [used/ctx] Thought\".
Context is the tokens used vs the session's context window; Thought is
the reasoning level (omitted when unavailable).  Falls back to \"—\"."
  (or (ignore-errors
        (with-current-buffer buffer
          (let* ((state (agent-shell--state))
                 (name (agent-shell-dashboard--slim-model-name
                        (agent-shell-get-model-name state)))
                 (usage (map-elt state :usage))
                 (used (map-elt usage :context-used))
                 (size (map-elt usage :context-size))
                 (ctx (when (and used size (> size 0) (> used 0))
                        (format " [%s/%s]"
                                (agent-shell-dashboard--humanize-tokens used)
                                (agent-shell-dashboard--humanize-tokens size))))
                 (thought (agent-shell-get-thought-level-name state))
                 (thl (when (and thought (not (string-empty-p thought)))
                        (concat " " thought))))
            (concat name (or ctx "") (or thl "")))))
      "—"))

;; --- unseen / activity tracker (in-package; installed in the hooks section) ---

(defvar agent-shell-dashboard--activity (make-hash-table :test 'eq)
  "Hash of agent-shell buffer -> `float-time' of its last agent output.")

(defvar agent-shell-dashboard--unseen (make-hash-table :test 'eq)
  "Hash of agent-shell buffers with agent output the user has not yet seen.")

(defun agent-shell-dashboard--activity-of (buffer)
  "Return BUFFER's last-activity `float-time', or 0 when unknown."
  (gethash buffer agent-shell-dashboard--activity 0))

(defun agent-shell-dashboard--unseen-p (buffer)
  "Return non-nil when BUFFER finished with output the user has not seen."
  (gethash buffer agent-shell-dashboard--unseen))

(defun agent-shell-dashboard--mark-seen (buffer)
  "Clear BUFFER's unseen flag."
  (remhash buffer agent-shell-dashboard--unseen))

(defun agent-shell-dashboard--category (buffer)
  "Return a display category symbol for BUFFER.
One of `waiting', `working', `done' (finished, unseen), `ready'
\(finished, seen), `killed', or `other'."
  (if (not (buffer-live-p buffer))
      'killed
    (pcase (ignore-errors (agent-shell-status :shell-buffer buffer))
      ('busy 'working)
      ('blocked 'waiting)
      ('ready (if (agent-shell-dashboard--unseen-p buffer) 'done 'ready))
      (_ 'other))))

(defconst agent-shell-dashboard--category-rank
  '((done . 0) (working . 1) (waiting . 2) (ready . 3) (other . 5) (killed . 9))
  "Sort rank per category; lower sorts higher.")

(defun agent-shell-dashboard--rank (buffer)
  "Return the sort rank for BUFFER's category."
  (alist-get (agent-shell-dashboard--category buffer)
             agent-shell-dashboard--category-rank 5))

(defun agent-shell-dashboard--sorted-buffers (&optional buffers)
  "Return BUFFERS (default all) sorted by category then recency (newest first)."
  (let ((bufs (or buffers (agent-shell-dashboard--buffers))))
    (sort (copy-sequence bufs)
          (lambda (a b)
            (let ((ra (agent-shell-dashboard--rank a))
                  (rb (agent-shell-dashboard--rank b)))
              (if (/= ra rb)
                  (< ra rb)
                (> (agent-shell-dashboard--activity-of a)
                   (agent-shell-dashboard--activity-of b))))))))

;;;; Last-message analysis (generic; mirrors my-ai.el, reimplemented here)

(defun agent-shell-dashboard--last-agent-message (buffer)
  "Return the last agent message prose in BUFFER's transcript, or nil."
  (let ((tf (buffer-local-value 'agent-shell--transcript-file buffer)))
    (when (and tf (file-readable-p tf))
      (with-temp-buffer
        (insert-file-contents tf)
        (goto-char (point-max))
        (when (re-search-backward "^## Agent (" nil t)
          (forward-line 1)
          (let ((start (point))
                (end (if (re-search-forward "^\\(## \\|### \\)" nil t)
                         (match-beginning 0)
                       (point-max))))
            (let ((msg (string-trim (buffer-substring-no-properties start end))))
              (unless (string-empty-p msg) msg))))))))

(defun agent-shell-dashboard--decision-hint (text)
  "Return a short hint when TEXT looks like it awaits a user decision, else nil."
  (when text
    (let ((s (downcase text)))
      (cond
       ((string-suffix-p "?" (string-trim text)) "ends with a question")
       ((string-match-p
         (concat "\\b\\(should i\\|shall i\\|do you want\\|would you like\\|"
                 "let me know\\|which \\|option [0-9a-z]\\|proceed\\|"
                 "confirm\\|approve\\|prefer\\|choose\\)\\b")
         s)
        "asks for input")
       (t nil)))))

(defun agent-shell-dashboard--excerpt (text &optional width)
  "Return a single-line tail excerpt of TEXT (default WIDTH), or nil.
The tail is shown because prompts/questions tend to land at the end."
  (when (and text (not (string-empty-p (string-trim text))))
    (let* ((w (or width agent-shell-dashboard-excerpt-width))
           (clean (replace-regexp-in-string "[ \t\n]+" " " (string-trim text))))
      (if (> (length clean) w)
          (concat "…" (substring clean (- (length clean) w)))
        clean))))

(defun agent-shell-dashboard-excerpt-tail (_buffer message)
  "Sub-line variant: a truncated tail of MESSAGE (BUFFER is ignored).
Opt in by setting `agent-shell-dashboard-excerpt-function' to this if
you prefer the raw last-message tail over the default summary."
  (agent-shell-dashboard--excerpt message))

;;;; Last-reply summary (the default sub-line)
;;
;; The "Needs you" sub-line defaults to a short (<= N words) summary of the
;; agent's last reply, produced by an external CLI (Claude by default) run
;; ASYNCHRONOUSLY and cached per buffer.  Rendering never blocks: on a cache
;; miss it kicks off one background job and shows a head-of-message
;; placeholder, then refreshes the dashboard when the summary lands.  When the
;; summarizer program is not installed, it degrades to the plain tail excerpt,
;; so the default is safe with zero configuration.

(defcustom agent-shell-dashboard-summary-command
  '("claude" "-p" "--allowed-tools" "")
  "Command (program + args) run to summarize an agent's last reply.
The prompt is written to the process's stdin and the summary read from
its stdout.  The default uses the `claude' CLI in headless print mode.
When the program is not found on `exec-path', the sub-line falls back to
a plain tail excerpt.  Add e.g. \"--model\" \"haiku\" for a faster model."
  :type '(repeat string))

(defcustom agent-shell-dashboard-summary-word-limit 10
  "Maximum number of words requested for a last-reply summary."
  :type 'integer)

(defcustom agent-shell-dashboard-summary-input-chars 1500
  "Trailing characters of the last reply sent to the summarizer."
  :type 'integer)

(defvar agent-shell-dashboard--summary-cache
  (make-hash-table :test 'eq :weakness 'key)
  "Cache of agent-shell BUFFER -> (MSG-HASH . SUMMARY).")

(defvar agent-shell-dashboard--summary-inflight
  (make-hash-table :test 'eq :weakness 'key)
  "Agent-shell BUFFER -> MSG-HASH of an in-flight summary job (dedup guard).")

(defun agent-shell-dashboard--summary-placeholder (message)
  "Return a head-of-MESSAGE placeholder shown while a summary is pending."
  (let* ((clean (replace-regexp-in-string "[ \t\n]+" " " (string-trim message)))
         (head (if (> (length clean) 60) (concat (substring clean 0 60) "…") clean)))
    (concat "summarizing… " head)))

(defun agent-shell-dashboard--summarize-async (buffer msg-hash text)
  "Summarize TEXT for BUFFER via `agent-shell-dashboard-summary-command'.
Stores (MSG-HASH . SUMMARY) in the cache and refreshes the dashboard on
success.  MSG-HASH tags the request so a result is cached under the
message it actually describes."
  (puthash buffer msg-hash agent-shell-dashboard--summary-inflight)
  (condition-case _err
      (let* ((tail (let ((len (length text))
                         (n agent-shell-dashboard-summary-input-chars))
                     (if (> len n) (substring text (- len n)) text)))
             (prompt (format (concat "In AT MOST %d words, summarize what this "
                                     "agent message says or asks. Output only the "
                                     "summary — no quotes, no preamble, no trailing "
                                     "period.\n\n%s")
                             agent-shell-dashboard-summary-word-limit tail))
             (proc (make-process
                    :name "agent-shell-dashboard-summary"
                    :buffer (generate-new-buffer " *asd-summary*")
                    :command agent-shell-dashboard-summary-command
                    :connection-type 'pipe
                    :noquery t
                    :sentinel
                    (lambda (p _event)
                      (when (memq (process-status p) '(exit signal))
                        (let ((out (with-current-buffer (process-buffer p)
                                     (string-trim (buffer-string)))))
                          (kill-buffer (process-buffer p))
                          (when (buffer-live-p buffer)
                            (remhash buffer agent-shell-dashboard--summary-inflight)
                            (unless (string-empty-p out)
                              (puthash buffer
                                       (cons msg-hash (car (split-string out "\n" t)))
                                       agent-shell-dashboard--summary-cache)
                              (agent-shell-dashboard-refresh)))))))))
        (process-send-string proc prompt)
        (process-send-eof proc))
    ;; make-process (or the pipe) failed — don't leave the guard stuck.
    (error (remhash buffer agent-shell-dashboard--summary-inflight))))

(defun agent-shell-dashboard-excerpt-summary (buffer message)
  "Default sub-line: a cached <=N-word summary of MESSAGE for BUFFER.
On a cache miss for the current MESSAGE, launch one async summarizer job
and return a placeholder; the dashboard refreshes when it lands.
Re-summarizes only when MESSAGE changes.  Falls back to the tail excerpt
when `agent-shell-dashboard-summary-command's program is unavailable."
  (when (and message (not (string-empty-p (string-trim message))))
    (if (not (executable-find (car agent-shell-dashboard-summary-command)))
        (agent-shell-dashboard--excerpt message)
      (let ((hash (sxhash-equal message))
            (cached (gethash buffer agent-shell-dashboard--summary-cache)))
        (if (and cached (eql (car cached) hash))
            (cdr cached)
          (unless (eql (gethash buffer agent-shell-dashboard--summary-inflight) hash)
            (agent-shell-dashboard--summarize-async buffer hash message))
          (agent-shell-dashboard--summary-placeholder message))))))

(defcustom agent-shell-dashboard-excerpt-function
  #'agent-shell-dashboard-excerpt-summary
  "Function producing the sub-line shown under a \"Needs you\" row.
Called with (BUFFER MESSAGE): BUFFER is the agent-shell buffer and
MESSAGE its last agent message (a string, possibly nil).  Should return
a one-line string to display verbatim, or nil for no sub-line.

The default, `agent-shell-dashboard-excerpt-summary', shows a short
async, cached LLM summary of the last reply (falling back to the tail
when no summarizer CLI is present).  Set this to
`agent-shell-dashboard-excerpt-tail' for the raw last-message tail
instead, or to your own function.  It runs during render on every
refresh, so any expensive work must be cached and asynchronous."
  :type '(choice (const :tag "Async LLM summary (default)"
                        agent-shell-dashboard-excerpt-summary)
                 (const :tag "Raw last-message tail"
                        agent-shell-dashboard-excerpt-tail)
                 (function :tag "Custom function")))

;;;; Conclusions — a per-session <=N-word "what did we conclude?" report
;;
;; One async batch job (via `agent-shell-dashboard-summary-command', the same
;; CLI the sub-line summary uses) over every live session, rendered into a
;; report buffer.  Reuses the summary word-limit and input-chars knobs.

(defun agent-shell-dashboard--transcript-tail (buffer chars)
  "Return the last CHARS characters of BUFFER's transcript, trimmed, or nil."
  (let ((tf (buffer-local-value 'agent-shell--transcript-file buffer)))
    (when (and tf (file-readable-p tf))
      (with-temp-buffer
        (insert-file-contents tf)
        (let* ((s (string-trim (buffer-string)))
               (len (length s)))
          (if (> len chars) (substring s (- len chars)) s))))))

(defun agent-shell-dashboard--conclusions-prompt (indexed)
  "Build the batch conclusions prompt from INDEXED, a list of (N . BUFFER)."
  (concat
   (format (concat "For each session below, state in AT MOST %d words the "
                   "conclusion reached in its last messages. If there is no "
                   "clear conclusion, say \"no clear conclusion\". Output "
                   "exactly one line per session in the form `N| conclusion` "
                   "where N is the session number. Output nothing else.\n\n")
           agent-shell-dashboard-summary-word-limit)
   (mapconcat
    (lambda (pair)
      (let ((tail (or (agent-shell-dashboard--transcript-tail
                       (cdr pair) agent-shell-dashboard-summary-input-chars)
                      "(no transcript)")))
        (format "=== Session %d: %s ===\n%s\n"
                (car pair) (buffer-name (cdr pair)) tail)))
    indexed "\n")))

(defun agent-shell-dashboard--conclusions-render (indexed output out-buffer)
  "Parse OUTPUT lines `N| text' and render INDEXED conclusions into OUT-BUFFER."
  (let ((table (make-hash-table :test 'eql)))
    (dolist (line (split-string output "\n" t))
      (when (string-match
             "^[ \t]*\\[?\\([0-9]+\\)\\]?[ \t]*[|:.)-][ \t]*\\(.+\\)$" line)
        (puthash (string-to-number (match-string 1 line))
                 (string-trim (match-string 2 line))
                 table)))
    (with-current-buffer out-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Agent-Shell — Conclusions\n"
                "=========================\n\n")
        (dolist (pair indexed)
          (insert (format "%-34s %s\n"
                          (buffer-name (cdr pair))
                          (or (gethash (car pair) table) "—"))))))))

(defun agent-shell-dashboard-conclusions-default ()
  "Summarize, in <=N words each, every live session's last-message conclusion.
Runs one async job via `agent-shell-dashboard-summary-command' over all
live agent-shell buffers and shows the results in a report buffer.
Default for `agent-shell-dashboard-conclusions-function'; degrades to a
message when the summarizer program is unavailable."
  (interactive)
  (let ((program (car agent-shell-dashboard-summary-command))
        (buffers (agent-shell-dashboard--buffers)))
    (cond
     ((null buffers) (message "No agent-shell sessions to analyze"))
     ((not (and program (executable-find program)))
      (message "Conclusions need `%s' on PATH (see `agent-shell-dashboard-summary-command')"
               (or program "a summarizer")))
     (t
      (let* ((indexed (seq-map-indexed (lambda (b i) (cons (1+ i) b)) buffers))
             (prompt (agent-shell-dashboard--conclusions-prompt indexed))
             (out (get-buffer-create "*agent-shell-conclusions*")))
        (with-current-buffer out
          (special-mode)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Analyzing %d session(s)…\n" (length buffers)))))
        (display-buffer out)
        (condition-case _err
            (let ((proc (make-process
                         :name "agent-shell-dashboard-conclusions"
                         :buffer (generate-new-buffer " *asd-conclusions*")
                         :command agent-shell-dashboard-summary-command
                         :connection-type 'pipe
                         :noquery t
                         :sentinel
                         (lambda (p _event)
                           (when (memq (process-status p) '(exit signal))
                             (let ((output (with-current-buffer (process-buffer p)
                                             (buffer-string))))
                               (kill-buffer (process-buffer p))
                               (when (buffer-live-p out)
                                 (if (string-empty-p (string-trim output))
                                     (with-current-buffer out
                                       (let ((inhibit-read-only t))
                                         (erase-buffer)
                                         (insert "No output from the summarizer CLI.\n")))
                                   (agent-shell-dashboard--conclusions-render
                                    indexed output out)))))))))
              (process-send-string proc prompt)
              (process-send-eof proc))
          (error
           (when (buffer-live-p out)
             (with-current-buffer out
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert "Failed to start the summarizer process.\n")))))))))))

;;;; Worktree awareness (generic; mirrors my-ai.el)

(defun agent-shell-dashboard--linked-worktree-p (dir)
  "Return non-nil if DIR is a linked git worktree (not the main tree)."
  (let ((dotgit (expand-file-name ".git" dir)))
    (and (file-exists-p dotgit) (file-regular-p dotgit))))

;;;; Formatting helpers

(defun agent-shell-dashboard--relative-time (secs)
  "Return a compact relative time for the epoch SECS, or \"—\"."
  (if (or (null secs) (<= secs 0))
      "—"
    (let ((d (- (float-time) secs)))
      (cond
       ((< d 10) "now")
       ((< d 60) (format "%ds ago" (round d)))
       ((< d 3600) (format "%dm ago" (round (/ d 60))))
       ((< d 86400) (format "%dh ago" (round (/ d 3600))))
       (t (format "%dd ago" (round (/ d 86400))))))))

(defun agent-shell-dashboard--clean-name (buffer)
  "Return BUFFER's name with surrounding asterisks stripped."
  (replace-regexp-in-string "\\`\\*\\|\\*\\'" "" (buffer-name buffer)))

(defun agent-shell-dashboard--truncate-left (str width)
  "Truncate STR to WIDTH, keeping the tail and prefixing \"…\" when cut."
  (if (<= (length str) width)
      (concat str (make-string (- width (length str)) ?\s))
    (concat "…" (substring str (- (length str) (1- width))))))

(defun agent-shell-dashboard--fit (str width)
  "Fit STR to exactly WIDTH: pad with spaces, or truncate with a trailing ellipsis."
  (cond
   ((= (length str) width) str)
   ((< (length str) width) (concat str (make-string (- width (length str)) ?\s)))
   (t (concat (substring str 0 (max 0 (1- width))) "…"))))

;;;; Rendering

(defun agent-shell-dashboard--insert (str &rest props)
  "Insert STR, applying text PROPS (a plist) to it."
  (let ((start (point)))
    (insert str)
    (when props
      (add-text-properties start (point) props))))

(defun agent-shell-dashboard--insert-heading (label face &optional suffix)
  "Insert a section heading LABEL in FACE with an optional dim SUFFIX."
  (insert "\n")
  (agent-shell-dashboard--insert "▌ " 'face face)
  (agent-shell-dashboard--insert label 'face face)
  (when suffix
    (agent-shell-dashboard--insert (concat "   " suffix) 'face 'agent-shell-dashboard-dim))
  (insert "\n\n"))

;; Absolute column stops (in default-face character units).  Fields are placed
;; with `:align-to' stretch spaces so every column starts at the same x on
;; every row — independent of the badge glyph/label widths and of the
;; proportional prose font.  This is what keeps the table from jittering.
(defconst agent-shell-dashboard--col-name 18 "Column where the name field starts.")
(defconst agent-shell-dashboard--col-path 38 "Column where the path field starts.")
(defconst agent-shell-dashboard--col-model 70 "Column where the model field starts.")
(defconst agent-shell-dashboard--col-time 100 "Column where the time field starts.")

(defun agent-shell-dashboard--align-to (col)
  "Return a space whose display stretches point to COL (char units)."
  (propertize " " 'display `(space :align-to ,col)))

(defun agent-shell-dashboard--badge (category worktree)
  "Return a propertized status badge for CATEGORY (WORKTREE tag optional).
The label is padded to a fixed width so every badge is the same size."
  ;; All glyphs are single-width, text-presentation symbols (no emoji): the
  ;; hourglass/warning emoji render double-width and colored, which made
  ;; badges different sizes.  These are uniform.
  (let* ((spec (pcase category
                 ('done    '("●" "Done"    agent-shell-dashboard-badge-done))
                 ('working '("◐" "Working" agent-shell-dashboard-badge-working))
                 ('waiting '("▲" "Waiting" agent-shell-dashboard-badge-waiting))
                 ('ready   '("✓" "Ready"   agent-shell-dashboard-badge-ready))
                 ('killed  '("✗" "Killed"  agent-shell-dashboard-dim))
                 (_        '("•" "…"       agent-shell-dashboard-dim))))
         (base (propertize (format "%s %-7s" (nth 0 spec) (nth 1 spec))
                           'face (nth 2 spec))))
    (if worktree
        (concat (propertize "[WT]" 'face 'agent-shell-dashboard-badge-wt) " " base)
      base)))

(defun agent-shell-dashboard--insert-session-row (buffer)
  "Insert one Sessions/Needs-you row for BUFFER, propertized for navigation."
  (let* ((cat (agent-shell-dashboard--category buffer))
         (wt (agent-shell-dashboard--linked-worktree-p
              (agent-shell-dashboard--cwd buffer)))
         (badge (agent-shell-dashboard--badge cat wt))
         (name (agent-shell-dashboard--clean-name buffer))
         (path (agent-shell-dashboard--truncate-left
                (abbreviate-file-name (agent-shell-dashboard--cwd buffer))
                agent-shell-dashboard-path-width))
         (model (agent-shell-dashboard--model buffer))
         (time (agent-shell-dashboard--relative-time
                (agent-shell-dashboard--activity-of buffer)))
         (start (point)))
    ;; Columns are pinned with `:align-to' so nothing shifts when badge
    ;; widths differ.  Fields are truncated (not space-padded) since the
    ;; stretch spaces provide the gaps.
    (insert "  " badge)
    (insert (agent-shell-dashboard--align-to agent-shell-dashboard--col-name))
    (agent-shell-dashboard--insert (agent-shell-dashboard--fit name 18) 'face 'default)
    (insert (agent-shell-dashboard--align-to agent-shell-dashboard--col-path))
    (agent-shell-dashboard--insert path 'face 'agent-shell-dashboard-dim)
    (insert (agent-shell-dashboard--align-to agent-shell-dashboard--col-model))
    (agent-shell-dashboard--insert (agent-shell-dashboard--fit model 28)
                                   'face 'agent-shell-dashboard-model)
    (insert (agent-shell-dashboard--align-to agent-shell-dashboard--col-time))
    (agent-shell-dashboard--insert time 'face 'agent-shell-dashboard-dim)
    (insert "\n")
    ;; Whole row carries its buffer object so RET/o/K/m act on it.  Rows are
    ;; distinguished for navigation by this per-row value (a boolean marker
    ;; would merge adjacent rows into one text-property run).
    (add-text-properties start (point)
                         (list 'agent-shell-dashboard-buffer buffer))))

(defun agent-shell-dashboard--insert-needs-you (buffers)
  "Insert the \"Needs you\" section for the needy subset of BUFFERS."
  (let ((needy (seq-filter
                (lambda (b) (memq (agent-shell-dashboard--category b) '(waiting done)))
                buffers)))
    (agent-shell-dashboard--insert-heading
     "Needs you" 'agent-shell-dashboard-attention
     (if needy "— triage first" "— all clear"))
    (if (null needy)
        (agent-shell-dashboard--insert
         "  Nothing waiting on you. \n" 'face 'agent-shell-dashboard-dim)
      (dolist (b needy)
        (agent-shell-dashboard--insert-session-row b)
        (let* ((msg (agent-shell-dashboard--last-agent-message b))
               (hint (or (agent-shell-dashboard--decision-hint msg)
                         (and (eq (agent-shell-dashboard--category b) 'waiting)
                              "permission request")))
               (excerpt (ignore-errors
                          (funcall agent-shell-dashboard-excerpt-function b msg))))
          (when hint
            (agent-shell-dashboard--insert (concat "    ↳ " hint "\n")
                                           'face 'agent-shell-dashboard-attention))
          (when excerpt
            (agent-shell-dashboard--insert (concat "    │ " excerpt "\n")
                                           'face 'agent-shell-dashboard-quote)))))))

(defun agent-shell-dashboard--insert-sessions (buffers)
  "Insert the Sessions section listing all BUFFERS."
  (agent-shell-dashboard--insert-heading
   "Sessions" 'agent-shell-dashboard-heading-sessions "— RET open · g refresh")
  (if (null buffers)
      (agent-shell-dashboard--insert
       "  No agent-shell sessions. Press c to start one.\n"
       'face 'agent-shell-dashboard-dim)
    (dolist (b buffers)
      (agent-shell-dashboard--insert-session-row b))))

(defun agent-shell-dashboard--insert-action (spec)
  "Insert one `[key] label' cell for SPEC, a (KEY . LABEL) cons, padded."
  (agent-shell-dashboard--insert (format "  [%s] " (car spec))
                                 'face 'agent-shell-dashboard-key)
  (agent-shell-dashboard--insert (agent-shell-dashboard--fit (cdr spec) 26)
                                 'face 'default))

(defun agent-shell-dashboard--insert-actions ()
  "Insert the Quick actions keybinding menu in two columns."
  (agent-shell-dashboard--insert-heading
   "Quick actions" 'agent-shell-dashboard-heading-actions)
  (let ((specs '(("c" . "New session")
                 ("w" . "New worktree session")
                 ("R" . "Reopen a previous session")
                 ("f" . "Fork session at point")
                 ("a" . "Conclusions report")
                 ("m" . "Set model")
                 ("r" . "Rename session at point")
                 ("K" . "Kill session at point")
                 ("X" . "Close all"))))
    (while specs
      (agent-shell-dashboard--insert-action (pop specs))
      (when specs (agent-shell-dashboard--insert-action (pop specs)))
      (insert "\n"))))

;;;; Recent sessions — previous (closed) sessions, resumable via RET
;;
;; Sourced from agent-shell's own transcript files
;; (`<project>/.agent-shell/transcripts/*.md'), whose header records the
;; resumable Session ID, the Working Directory and the agent.  We scan the
;; transcript dirs of recent projects (projectile when available, plus the
;; working directories of live sessions), take the most-recently-modified
;; files, parse only their headers, drop sessions already open, and keep the
;; newest N.  No dependency on any particular agent's on-disk session store.

(defun agent-shell-dashboard--transcript-dirs ()
  "Return existing `.agent-shell/transcripts' directories to scan.
Drawn from recent projectile projects (when available), the working
directories of live sessions, and `default-directory' — deduplicated."
  (let ((roots '()))
    (when (fboundp 'projectile-relevant-known-projects)
      (setq roots (append roots
                          (ignore-errors (projectile-relevant-known-projects)))))
    (dolist (b (agent-shell-dashboard--buffers))
      (push (agent-shell-dashboard--cwd b) roots))
    (push default-directory roots)
    (thread-last
      roots
      (delq nil)
      (mapcar (lambda (r) (expand-file-name ".agent-shell/transcripts/" r)))
      (seq-filter #'file-directory-p)
      (delete-dups))))

(defun agent-shell-dashboard--transcript-files (dirs)
  "Return (FILE . MTIME) pairs for transcript .md files in DIRS, newest first."
  (let ((files '()))
    (dolist (dir dirs)
      (dolist (f (ignore-errors (directory-files dir t "\\.md\\'")))
        (when (file-regular-p f)
          (push (cons f (float-time (file-attribute-modification-time
                                     (file-attributes f))))
                files))))
    (sort files (lambda (a b) (> (cdr a) (cdr b))))))

(defun agent-shell-dashboard--header-field (name)
  "Return the value of a `**NAME:** value' header line in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           (format "^\\*\\*%s:\\*\\* +\\(.+\\)$" (regexp-quote name)) nil t)
      (string-trim (match-string 1)))))

(defun agent-shell-dashboard--parse-time (s)
  "Parse header timestamp S (e.g. \"2026-07-09 22:38:46\") to `float-time', or nil."
  (when (and s (not (string-empty-p s)))
    (ignore-errors (float-time (date-to-time s)))))

(defun agent-shell-dashboard--parse-transcript (file)
  "Parse FILE's transcript header into a session plist, or nil.
Reads only the header region (not the whole transcript).  `:opened' is
when the session was started (from the header); `:name' is left nil here
and resolved for display via `agent-shell-dashboard-session-name-function'."
  (with-temp-buffer
    (insert-file-contents file nil 0 8192)
    (let ((id (agent-shell-dashboard--header-field "Session ID"))
          (cwd (agent-shell-dashboard--header-field "Working Directory"))
          (agent (agent-shell-dashboard--header-field "Agent"))
          (started (agent-shell-dashboard--header-field "Started")))
      (when (and id (not (string-empty-p id)))
        (list :id id
              :cwd (or cwd default-directory)
              :agent (or agent "Agent")
              :opened (agent-shell-dashboard--parse-time started)
              :file file)))))

(defun agent-shell-dashboard--live-session-ids ()
  "Return a hash set of session ids for currently live shells."
  (let ((ids (make-hash-table :test 'equal)))
    (dolist (b (agent-shell-dashboard--buffers))
      (when-let* ((id (ignore-errors
                        (map-nested-elt (buffer-local-value 'agent-shell--state b)
                                        '(:session :id)))))
        (puthash id t ids)))
    ids))

(defun agent-shell-dashboard--recent-sessions-default ()
  "Default source: recent resumable sessions from transcript headers.
Newest first, excluding sessions that are already open, capped at
`agent-shell-dashboard-recent-sessions-count'."
  (let ((n agent-shell-dashboard-recent-sessions-count)
        (live (agent-shell-dashboard--live-session-ids))
        (seen (make-hash-table :test 'equal))
        (out '()))
    (catch 'done
      (dolist (fm (agent-shell-dashboard--transcript-files
                   (agent-shell-dashboard--transcript-dirs)))
        (when-let* ((s (ignore-errors
                         (agent-shell-dashboard--parse-transcript (car fm))))
                    (id (plist-get s :id)))
          (unless (or (gethash id live) (gethash id seen))
            (puthash id t seen)
            (push (plist-put s :time (cdr fm)) out)
            (when (>= (length out) n) (throw 'done nil))))))
    (nreverse out)))

(defun agent-shell-dashboard--resume-recent-default (session)
  "Reopen SESSION by resuming its id in its working directory.
Binds `default-directory' to SESSION's `:cwd' and calls the core
`agent-shell-resume-session'."
  (let ((default-directory (or (plist-get session :cwd) default-directory))
        (id (plist-get session :id)))
    (unless id (user-error "Session has no id to resume"))
    (agent-shell-resume-session id)))

(defun agent-shell-dashboard--session-label (session)
  "Return the buffer-name label to display for SESSION.
Prefers `agent-shell-dashboard-session-name-function', then the plist's
`:name', then the working-directory name."
  (or (and agent-shell-dashboard-session-name-function
           (ignore-errors
             (funcall agent-shell-dashboard-session-name-function session)))
      (plist-get session :name)
      (let ((cwd (plist-get session :cwd)))
        (and cwd (file-name-nondirectory (directory-file-name cwd))))
      "session"))

(defun agent-shell-dashboard--insert-recent-session-row (session)
  "Insert one Recent-sessions row for SESSION plist, propertized for RET.
Columns: buffer name, working directory, and when the session was opened."
  (let* ((name (agent-shell-dashboard--fit
                (agent-shell-dashboard--session-label session) 34))
         (cwd (agent-shell-dashboard--truncate-left
               (abbreviate-file-name
                (directory-file-name (or (plist-get session :cwd) "")))
               agent-shell-dashboard-path-width))
         (time (agent-shell-dashboard--relative-time
                (or (plist-get session :opened) (plist-get session :time))))
         (start (point)))
    ;; Same absolute column stops as the session rows so both tables line up.
    (agent-shell-dashboard--insert "  ↻ " 'face 'agent-shell-dashboard-key)
    (agent-shell-dashboard--insert (agent-shell-dashboard--fit name 34) 'face 'default)
    (insert (agent-shell-dashboard--align-to agent-shell-dashboard--col-model))
    (agent-shell-dashboard--insert cwd 'face 'agent-shell-dashboard-dim)
    (insert (agent-shell-dashboard--align-to agent-shell-dashboard--col-time))
    (agent-shell-dashboard--insert time 'face 'agent-shell-dashboard-dim)
    (insert "\n")
    ;; Whole row carries its session plist so RET/o resumes it.
    (add-text-properties start (point)
                         (list 'agent-shell-dashboard-session session))))

(defun agent-shell-dashboard--insert-recent-sessions ()
  "Insert the Recent sessions section (previous, resumable sessions)."
  (when-let* ((sessions (ignore-errors
                          (funcall agent-shell-dashboard-recent-sessions-function))))
    (agent-shell-dashboard--insert-heading
     "Recent sessions" 'agent-shell-dashboard-heading-projects "— RET reopens")
    (dolist (s sessions)
      (agent-shell-dashboard--insert-recent-session-row s))))

(defun agent-shell-dashboard--insert-banner ()
  "Insert the ASCII banner and heartbeat subtitle."
  (insert "\n")
  (dolist (line agent-shell-dashboard-banner)
    (agent-shell-dashboard--insert (concat " " line "\n")
                                   'face 'agent-shell-dashboard-banner)))

(defun agent-shell-dashboard--counts (buffers)
  "Return an alist of category -> count for BUFFERS.
The accumulator is built with `list'/`cons' (not a quoted literal): a
quoted list is a shared constant, and the `setf' below mutates it in
place, so a literal would accumulate across every call and refresh."
  (let ((counts (list (cons 'done 0) (cons 'working 0) (cons 'waiting 0)
                      (cons 'ready 0) (cons 'killed 0) (cons 'other 0))))
    (dolist (b buffers counts)
      (let ((cat (agent-shell-dashboard--category b)))
        (setf (alist-get cat counts) (1+ (alist-get cat counts 0)))))))

(defun agent-shell-dashboard--insert-subtitle (buffers)
  "Insert the heartbeat line summarising BUFFERS."
  (let* ((counts (agent-shell-dashboard--counts buffers))
         (needy (+ (alist-get 'waiting counts 0) (alist-get 'done counts 0)))
         (live (seq-count (lambda (b) (not (eq (agent-shell-dashboard--category b)
                                               'killed)))
                          buffers)))
    (insert " ")
    (agent-shell-dashboard--insert
     (format-time-string "%A, %-d %B %Y")
     'face 'agent-shell-dashboard-subtitle)
    (agent-shell-dashboard--insert "  ·  " 'face 'agent-shell-dashboard-dim)
    (agent-shell-dashboard--insert (format "%d session%s"
                                           live (if (= live 1) "" "s"))
                                   'face 'agent-shell-dashboard-subtitle)
    (agent-shell-dashboard--insert "  ·  " 'face 'agent-shell-dashboard-dim)
    (if (zerop needy)
        (agent-shell-dashboard--insert "all clear" 'face 'agent-shell-dashboard-dim)
      (agent-shell-dashboard--insert (format "%d need%s you"
                                             needy (if (= needy 1) "s" ""))
                                     'face 'agent-shell-dashboard-attention))
    (insert "\n")))

(defun agent-shell-dashboard--insert-footer (buffers)
  "Insert the stats footer line for BUFFERS."
  (let ((counts (agent-shell-dashboard--counts buffers)))
    (insert "\n")
    (agent-shell-dashboard--insert
     (format "  ● %d done · ◐ %d working · ▲ %d waiting · ✓ %d ready"
             (alist-get 'done counts 0)
             (alist-get 'working counts 0)
             (alist-get 'waiting counts 0)
             (alist-get 'ready counts 0))
     'face 'agent-shell-dashboard-dim)
    (insert "\n")))

(defun agent-shell-dashboard--render ()
  "Render the whole dashboard into the current buffer.
Assumes the buffer is current and writable."
  (let* ((buffers (agent-shell-dashboard--sorted-buffers))
         (live (seq-remove (lambda (b) (eq (agent-shell-dashboard--category b) 'killed))
                           buffers)))
    (erase-buffer)
    (agent-shell-dashboard--insert-banner)
    (agent-shell-dashboard--insert-subtitle buffers)
    (agent-shell-dashboard--insert-needs-you live)
    (agent-shell-dashboard--insert-sessions buffers)
    (agent-shell-dashboard--insert-actions)
    (agent-shell-dashboard--insert-recent-sessions)
    (agent-shell-dashboard--insert-footer buffers)
    (goto-char (point-min))))

;;;; Refresh

(defun agent-shell-dashboard--get-buffer ()
  "Return the dashboard buffer if it exists and is live, else nil."
  (let ((buf (get-buffer agent-shell-dashboard-buffer-name)))
    (and (buffer-live-p buf) buf)))

(defun agent-shell-dashboard--goto-buffer-row (buffer)
  "Put point on the row whose live session is BUFFER.  Return non-nil if found.
Restores position by session identity (robust to re-sorting), unlike a
raw line number."
  (when (buffer-live-p buffer)
    (let (found)
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (if (eq (get-text-property (line-beginning-position)
                                   'agent-shell-dashboard-buffer)
                buffer)
            (setq found (goto-char (line-beginning-position)))
          (forward-line 1)))
      found)))

(defun agent-shell-dashboard-refresh ()
  "Rebuild the dashboard, keeping point on the same session when possible.
Prefers restoring to the session row at point by identity (survives
re-sorting); falls back to the previous line number otherwise."
  (interactive)
  (when-let* ((buf (agent-shell-dashboard--get-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (line (line-number-at-pos))
            (target (agent-shell-dashboard--buffer-at-point)))
        (agent-shell-dashboard--render)
        (unless (and target (agent-shell-dashboard--goto-buffer-row target))
          (goto-char (point-min))
          (forward-line (1- line)))))))

(defun agent-shell-dashboard--maybe-refresh ()
  "Refresh the dashboard only when it is displayed in some window."
  (when-let* ((buf (agent-shell-dashboard--get-buffer)))
    (when (get-buffer-window buf 'visible)
      (agent-shell-dashboard-refresh))))

(defvar agent-shell-dashboard--idle-timer nil
  "The single idle timer used to refresh a visible dashboard.")

(defun agent-shell-dashboard--ensure-idle-timer ()
  "Start the idle refresh timer if configured and not already running."
  (when (and agent-shell-dashboard-idle-refresh-seconds
             (null agent-shell-dashboard--idle-timer))
    (setq agent-shell-dashboard--idle-timer
          (run-with-idle-timer agent-shell-dashboard-idle-refresh-seconds t
                               #'agent-shell-dashboard--maybe-refresh))))

(defun agent-shell-dashboard--cancel-idle-timer ()
  "Cancel the idle refresh timer."
  (when agent-shell-dashboard--idle-timer
    (cancel-timer agent-shell-dashboard--idle-timer)
    (setq agent-shell-dashboard--idle-timer nil)))

;;;; Event-driven refresh (debounced)
;;
;; `agent-shell' calls `agent-shell--append-transcript' on every agent output
;; chunk and `agent-shell-manager-refresh' on status transitions.  We advise
;; both to schedule a debounced refresh, so a *visible* dashboard tracks live
;; activity without polling.  The debounce means a stream of chunks collapses
;; into one refresh once output settles (typically when the turn ends or a
;; permission request appears), avoiding per-token re-renders and flicker.

(defvar agent-shell-dashboard--debounce-timer nil
  "One-shot timer coalescing event-driven refreshes.")

(defun agent-shell-dashboard--schedule-refresh (&rest _)
  "Schedule a debounced dashboard refresh in response to agent activity.
No-op unless `agent-shell-dashboard-event-refresh' is enabled and a
dashboard buffer exists.  Accepts and ignores any advice arguments."
  (when (and agent-shell-dashboard-event-refresh
             (agent-shell-dashboard--get-buffer))
    (when (timerp agent-shell-dashboard--debounce-timer)
      (cancel-timer agent-shell-dashboard--debounce-timer))
    (setq agent-shell-dashboard--debounce-timer
          (run-with-timer agent-shell-dashboard-event-refresh-delay nil
                          #'agent-shell-dashboard--maybe-refresh))))

;; --- activity / unseen tracker ---
;; `agent-shell--append-transcript' is called with the shell buffer current on
;; every agent output chunk (the only activity signal agent-shell exposes).  We
;; stamp the buffer's activity time and, unless it is on screen, flag it unseen
;; so a finished session the user has not looked at shows as "Done".

(defun agent-shell-dashboard--record-activity (&rest _)
  "Stamp the current agent-shell buffer's activity time; flag unseen if hidden."
  (let ((buf (current-buffer)))
    (when (buffer-live-p buf)
      (puthash buf (float-time) agent-shell-dashboard--activity)
      (unless (get-buffer-window buf 'visible)
        (puthash buf t agent-shell-dashboard--unseen)))))

(defun agent-shell-dashboard--track-seen (&optional _window)
  "Mark the current buffer seen when it is an agent-shell buffer."
  (when (derived-mode-p 'agent-shell-mode)
    (agent-shell-dashboard--mark-seen (current-buffer))))

(defun agent-shell-dashboard--forget-buffer ()
  "Drop the current buffer from the tracker hashes (on kill)."
  (agent-shell-dashboard--mark-seen (current-buffer))
  (remhash (current-buffer) agent-shell-dashboard--activity))

(defun agent-shell-dashboard--register-tracker ()
  "Register buffer-local kill cleanup for the current agent-shell buffer."
  (add-hook 'kill-buffer-hook #'agent-shell-dashboard--forget-buffer nil t))

(defun agent-shell-dashboard--install-hooks ()
  "Advise `agent-shell' activity functions and install the tracker.
Idempotent — `advice-add'/`add-hook' dedup by symbol, so re-evaluating this
file does not stack anything."
  (when (fboundp 'agent-shell--append-transcript)
    (advice-add 'agent-shell--append-transcript :after
                #'agent-shell-dashboard--record-activity)
    (advice-add 'agent-shell--append-transcript :after
                #'agent-shell-dashboard--schedule-refresh))
  ;; Optional: if the third-party manager is present, its refresh also marks
  ;; status transitions (e.g. a new permission prompt) worth reflecting.
  (when (fboundp 'agent-shell-manager-refresh)
    (advice-add 'agent-shell-manager-refresh :after
                #'agent-shell-dashboard--schedule-refresh))
  (add-hook 'window-selection-change-functions #'agent-shell-dashboard--track-seen)
  (add-hook 'agent-shell-mode-hook #'agent-shell-dashboard--register-tracker))

;; agent-shell is a hard `require' at the top, so it is already loaded here;
;; the `with-eval-after-load' is belt-and-suspenders for lazy load orders.
(with-eval-after-load 'agent-shell
  (agent-shell-dashboard--install-hooks))
(agent-shell-dashboard--install-hooks)

;;;; Navigation & actions

(defun agent-shell-dashboard--buffer-at-point ()
  "Return the agent-shell buffer described by the row at point, or nil."
  (get-text-property (point) 'agent-shell-dashboard-buffer))

(defun agent-shell-dashboard--session-at-point ()
  "Return the recent-session plist described by the row at point, or nil."
  (get-text-property (point) 'agent-shell-dashboard-session))

(defun agent-shell-dashboard--row-at-point-p (&optional pos)
  "Return non-nil when POS (or point) is on a navigable row.
Navigable rows are live-session rows (`agent-shell-dashboard-buffer')
and recent-session rows (`agent-shell-dashboard-session')."
  (let ((p (or pos (point))))
    (or (get-text-property p 'agent-shell-dashboard-buffer)
        (get-text-property p 'agent-shell-dashboard-session))))

(defun agent-shell-dashboard-open ()
  "Open or reopen the session on the row at point.
A live-session row is switched to; a recent-session row is resumed via
`agent-shell-dashboard-resume-recent-function'."
  (interactive)
  (let ((buf (agent-shell-dashboard--buffer-at-point))
        (session (agent-shell-dashboard--session-at-point)))
    (cond
     (buf (if (buffer-live-p buf)
              (pop-to-buffer buf)
            (user-error "That session's buffer is gone — press g to refresh")))
     (session (funcall agent-shell-dashboard-resume-recent-function session))
     (t (user-error "Point is not on a session row")))))

(defun agent-shell-dashboard--goto-first-row ()
  "Move point to the first navigable row, if any."
  (goto-char (point-min))
  (while (and (not (eobp))
              (not (agent-shell-dashboard--row-at-point-p (line-beginning-position))))
    (forward-line 1)))

(defun agent-shell-dashboard-next-row ()
  "Move point to the next navigable row."
  (interactive)
  (let ((start (point)) found)
    (save-excursion
      (forward-line 1)
      (while (and (not (eobp)) (not found))
        (if (agent-shell-dashboard--row-at-point-p (line-beginning-position))
            (setq found (line-beginning-position))
          (forward-line 1))))
    (if found (goto-char found) (goto-char start) (message "No more sessions"))))

(defun agent-shell-dashboard-prev-row ()
  "Move point to the previous navigable row."
  (interactive)
  (let ((start (point)) found)
    (save-excursion
      (while (and (not (bobp)) (not found))
        (forward-line -1)
        (when (agent-shell-dashboard--row-at-point-p (line-beginning-position))
          (setq found (line-beginning-position)))))
    (if found (goto-char found) (goto-char start) (message "No previous sessions"))))

(defun agent-shell-dashboard--invoke (fn var-symbol &optional buffer)
  "Call command FN interactively, in BUFFER when given.
FN is the value of the customization variable VAR-SYMBOL; when FN is nil or
not a defined command, report how to enable the action instead of erroring."
  (cond
   ((null fn)
    (message "Unconfigured — set `%s' to a command to enable this action"
             var-symbol))
   ((not (fboundp fn))
    (message "`%s' is set to `%s', which is not defined" var-symbol fn))
   ((and buffer (buffer-live-p buffer))
    (with-current-buffer buffer (call-interactively fn)))
   (t (call-interactively fn))))

(defun agent-shell-dashboard--close-all-default ()
  "Kill every live agent-shell buffer after confirmation.
Built-in default for `agent-shell-dashboard-close-all-function'."
  (interactive)
  (let ((buffers (agent-shell-dashboard--buffers)))
    (if (null buffers)
        (message "No agent-shell sessions to close")
      (when (yes-or-no-p (format "Kill all %d agent-shell session(s)? "
                                 (length buffers)))
        (let ((kill-buffer-query-functions nil))
          (dolist (b buffers) (when (buffer-live-p b) (kill-buffer b))))
        (message "Closed %d session(s)" (length buffers))))))

(defun agent-shell-dashboard-new-session ()
  "Start a new agent-shell session.
Delegates to `agent-shell-dashboard-new-session-function'."
  (interactive)
  (agent-shell-dashboard--invoke agent-shell-dashboard-new-session-function
                                 'agent-shell-dashboard-new-session-function))

(defun agent-shell-dashboard-new-worktree ()
  "Start a new agent-shell session in a git worktree.
Delegates to `agent-shell-dashboard-new-worktree-function'."
  (interactive)
  (agent-shell-dashboard--invoke agent-shell-dashboard-new-worktree-function
                                 'agent-shell-dashboard-new-worktree-function))

(defun agent-shell-dashboard-conclusions ()
  "Summarise every session's conclusion.
Delegates to `agent-shell-dashboard-conclusions-function'."
  (interactive)
  (agent-shell-dashboard--invoke agent-shell-dashboard-conclusions-function
                                 'agent-shell-dashboard-conclusions-function))

(defun agent-shell-dashboard--set-model-default ()
  "Pick a model for the current session from its advertised options.
Default for `agent-shell-dashboard-set-model-function'.  Prompts with
completion over the models the session advertises and applies the choice;
messages (does not error) when the chosen model is already active."
  (interactive)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell session"))
  (let* ((state (agent-shell--state))
         (models (agent-shell--get-available-models state)))
    (unless models
      (user-error "This session advertises no models"))
    (let* ((current (agent-shell--current-model-id state))
           (choices (mapcar (lambda (m)
                              (cons (format "%s  (%s)"
                                            (map-elt m :name) (map-elt m :model-id))
                                    (map-elt m :model-id)))
                            models))
           (pick (completing-read "Model: " (mapcar #'car choices) nil t))
           (id (cdr (assoc pick choices)))
           (name (map-elt (seq-find (lambda (m) (equal (map-elt m :model-id) id))
                                    models)
                          :name)))
      (cond
       ((null id) (user-error "No model selected"))
       ((and current (string= id current)) (message "Model already set: %s" name))
       (t (agent-shell--config-option-set-model-id
           :model-id id
           :on-success (lambda () (message "Set model: %s" name))
           :on-failure (lambda (err _raw) (message "Failed to set model: %s" err))))))))

(defun agent-shell-dashboard-set-model ()
  "Set the model of the session on the row at point.
Only acts when point is on a live session row; delegates to
`agent-shell-dashboard-set-model-function' with that buffer current."
  (interactive)
  (let ((buf (agent-shell-dashboard--buffer-at-point)))
    (unless (and buf (buffer-live-p buf))
      (user-error "Point is not on a live session row"))
    (agent-shell-dashboard--invoke agent-shell-dashboard-set-model-function
                                   'agent-shell-dashboard-set-model-function
                                   buf)))

(defun agent-shell-dashboard--rename-default ()
  "Default rename action: rename the current agent-shell buffer.
Run with the row's buffer current by `agent-shell-dashboard-rename-at-point'."
  (interactive)
  (let ((new (string-trim (read-string "New session name: "))))
    (unless (string-empty-p new)
      (if (fboundp 'shell-maker-set-buffer-name)
          (shell-maker-set-buffer-name (current-buffer) (format "*%s*" new))
        (rename-buffer (format "*%s*" new) t)))))

(defun agent-shell-dashboard-rename-at-point ()
  "Rename the agent-shell session on the row at point.
Delegates to `agent-shell-dashboard-rename-function', run with that
session's buffer current, then refreshes."
  (interactive)
  (let ((buf (agent-shell-dashboard--buffer-at-point)))
    (unless (and buf (buffer-live-p buf))
      (user-error "Point is not on a live session row"))
    (agent-shell-dashboard--invoke agent-shell-dashboard-rename-function
                                   'agent-shell-dashboard-rename-function
                                   buf)
    (agent-shell-dashboard-refresh)))

(defun agent-shell-dashboard-close-all ()
  "Close all agent-shell sessions, then refresh.
Delegates to `agent-shell-dashboard-close-all-function'."
  (interactive)
  (agent-shell-dashboard--invoke agent-shell-dashboard-close-all-function
                                 'agent-shell-dashboard-close-all-function)
  (agent-shell-dashboard-refresh))

(defun agent-shell-dashboard-kill-at-point ()
  "Kill the agent-shell session on the row at point."
  (interactive)
  (if-let* ((buf (agent-shell-dashboard--buffer-at-point)))
      (when (and (buffer-live-p buf)
                 (yes-or-no-p (format "Kill %s? " (buffer-name buf))))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf))
        (agent-shell-dashboard-refresh))
    (user-error "Point is not on a session row")))

(defun agent-shell-dashboard-fork-at-point ()
  "Fork the agent-shell session on the row at point into a new shell.
Delegates to `agent-shell-dashboard-fork-session-function', run with the
session buffer at point current.  Refreshes afterwards so the forked
session appears."
  (interactive)
  (let ((buf (agent-shell-dashboard--buffer-at-point)))
    (unless (and buf (buffer-live-p buf))
      (user-error "Point is not on a live session row"))
    (agent-shell-dashboard--invoke agent-shell-dashboard-fork-session-function
                                   'agent-shell-dashboard-fork-session-function
                                   buf)
    (agent-shell-dashboard-refresh)))

(defun agent-shell-dashboard-resume-session ()
  "Reopen a previous (closed) agent-shell session.
Delegates to `agent-shell-dashboard-resume-session-function'.  Unlike
`RET' (which opens a live session), this reopens a session that has no
live buffer.  Refreshes afterwards so the reopened session appears."
  (interactive)
  (agent-shell-dashboard--invoke agent-shell-dashboard-resume-session-function
                                 'agent-shell-dashboard-resume-session-function)
  (agent-shell-dashboard-refresh))

(defun agent-shell-dashboard-help ()
  "Show the dashboard keybindings."
  (interactive)
  (with-help-window "*agent-shell-dashboard help*"
    (princ "agent-shell-dashboard — keybindings\n")
    (princ "===================================\n\n")
    (princ "Navigation\n")
    (princ "  TAB / S-TAB   Next / previous session row\n")
    (princ "  RET / o       Open live session / reopen recent session at point\n\n")
    (princ "Sessions\n")
    (princ "  c   New session\n")
    (princ "  w   New worktree session\n")
    (princ "  R   Reopen a previous (closed) session\n")
    (princ "  f   Fork session at point into a new shell\n")
    (princ "  m   Set model of session at point\n")
    (princ "  r   Rename session at point\n")
    (princ "  K   Kill session at point\n")
    (princ "  X   Close all sessions\n\n")
    (princ "Insight\n")
    (princ "  a   Conclusions report (async summary of every session)\n\n")
    (princ "Misc\n")
    (princ "  g   Refresh\n")
    (princ "  q   Quit window\n")
    (princ "  ?   This help\n")))

;;;; Mode

(defvar-keymap agent-shell-dashboard-mode-map
  :doc "Keymap for `agent-shell-dashboard-mode' (Emacs state)."
  "TAB"       #'agent-shell-dashboard-next-row
  "<backtab>" #'agent-shell-dashboard-prev-row
  "RET"       #'agent-shell-dashboard-open
  "o"         #'agent-shell-dashboard-open
  "c"         #'agent-shell-dashboard-new-session
  "w"         #'agent-shell-dashboard-new-worktree
  "R"         #'agent-shell-dashboard-resume-session
  "f"         #'agent-shell-dashboard-fork-at-point
  "a"         #'agent-shell-dashboard-conclusions
  "m"         #'agent-shell-dashboard-set-model
  "r"         #'agent-shell-dashboard-rename-at-point
  "K"         #'agent-shell-dashboard-kill-at-point
  "X"         #'agent-shell-dashboard-close-all
  "g"         #'agent-shell-dashboard-refresh
  "?"         #'agent-shell-dashboard-help
  "q"         #'quit-window)

(define-derived-mode agent-shell-dashboard-mode special-mode "Agent-Dashboard"
  "Major mode for the agent-shell landing page."
  (setq-local truncate-lines t
              cursor-type nil
              buffer-read-only t)
  (setq-local revert-buffer-function
              (lambda (&rest _) (agent-shell-dashboard-refresh))))

;; `define-derived-mode' + `defvar-keymap' only wire Emacs-state bindings.
;; Doom runs Evil, whose normal state shadows most of these letters, so the
;; bindings MUST be duplicated into evil normal state explicitly — the single
;; most common Doom regression for list-style modes.
(with-eval-after-load 'evil
  (evil-set-initial-state 'agent-shell-dashboard-mode 'normal)
  (evil-define-key* 'normal agent-shell-dashboard-mode-map
    (kbd "TAB")       #'agent-shell-dashboard-next-row
    (kbd "<backtab>") #'agent-shell-dashboard-prev-row
    (kbd "RET")       #'agent-shell-dashboard-open
    "o" #'agent-shell-dashboard-open
    "c" #'agent-shell-dashboard-new-session
    "w" #'agent-shell-dashboard-new-worktree
    "R" #'agent-shell-dashboard-resume-session
    "f" #'agent-shell-dashboard-fork-at-point
    "a" #'agent-shell-dashboard-conclusions
    "m" #'agent-shell-dashboard-set-model
    "r" #'agent-shell-dashboard-rename-at-point
    "K" #'agent-shell-dashboard-kill-at-point
    "X" #'agent-shell-dashboard-close-all
    "g" #'agent-shell-dashboard-refresh
    "?" #'agent-shell-dashboard-help
    "q" #'quit-window))

;;;; Entry point

;;;###autoload
(defun agent-shell-dashboard ()
  "Open (creating if needed) the agent-shell dashboard.
Suitable as an `initial-buffer-choice'."
  (interactive)
  (let* ((existing (agent-shell-dashboard--get-buffer))
         (buf (get-buffer-create agent-shell-dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'agent-shell-dashboard-mode)
        (agent-shell-dashboard-mode)))
    ;; Returning to an existing dashboard: re-render but keep point on the
    ;; same session row (via refresh's identity restore).  Only a freshly
    ;; created dashboard renders from scratch and jumps to the first row.
    (if existing
        (agent-shell-dashboard-refresh)
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (agent-shell-dashboard--render))))
    (agent-shell-dashboard--ensure-idle-timer)
    (if (called-interactively-p 'interactive)
        (progn (pop-to-buffer-same-window buf)
               (unless existing
                 (with-current-buffer buf (agent-shell-dashboard--goto-first-row)))
               buf)
      buf)))

;;;; Theme layer — recolor faces from the live modus palette

(defun agent-shell-dashboard--modus-active-p ()
  "Return non-nil when a modus theme is currently enabled."
  (and (featurep 'modus-themes)
       (seq-some (lambda (th) (string-prefix-p "modus-" (symbol-name th)))
                 custom-enabled-themes)))

(defun agent-shell-dashboard--apply-theme-faces (&rest _)
  "Recolor dashboard faces from the active modus palette.
No-op unless a modus theme is active; registered on
`enable-theme-functions' so it tracks the light/dark toggle."
  ;; Guarded: a half-loaded modus (stale daemon, or palette not yet realized
  ;; during load-theme) can leave palette names void; never abort the
  ;; enable-theme-functions hook and strand startup.
  (when (agent-shell-dashboard--modus-active-p)
    (ignore-errors
    (modus-themes-with-colors
      (custom-set-faces
       `(agent-shell-dashboard-banner ((t :foreground ,blue-warmer :weight bold)))
       `(agent-shell-dashboard-subtitle ((t :foreground ,fg-dim)))
       `(agent-shell-dashboard-attention ((t :foreground ,red-warmer :weight bold)))
       `(agent-shell-dashboard-heading-sessions ((t :foreground ,blue-warmer :weight bold)))
       `(agent-shell-dashboard-heading-actions ((t :foreground ,cyan-cooler :weight bold)))
       `(agent-shell-dashboard-heading-projects ((t :foreground ,yellow-warmer :weight bold)))
       `(agent-shell-dashboard-key ((t :foreground ,blue-warmer :weight bold)))
       `(agent-shell-dashboard-model ((t :foreground ,magenta-cooler)))
       `(agent-shell-dashboard-dim ((t :foreground ,fg-dim)))
       `(agent-shell-dashboard-quote ((t :foreground ,fg-dim :slant italic)))
       `(agent-shell-dashboard-badge-done
         ((t :foreground ,green-cooler :background ,bg-green-subtle
             :box (:line-width (1 . -1) :color ,green-cooler) :weight bold)))
       `(agent-shell-dashboard-badge-working
         ((t :foreground ,yellow-warmer :background ,bg-yellow-subtle
             :box (:line-width (1 . -1) :color ,yellow-warmer) :weight bold)))
       `(agent-shell-dashboard-badge-waiting
         ((t :foreground ,red-warmer :background ,bg-red-subtle
             :box (:line-width (1 . -1) :color ,red-warmer) :weight bold)))
       `(agent-shell-dashboard-badge-ready
         ((t :foreground ,green-faint
             :box (:line-width (1 . -1) :color ,border))))
       `(agent-shell-dashboard-badge-wt
         ((t :foreground ,cyan-cooler :background ,bg-cyan-subtle
             :box (:line-width (1 . -1) :color ,cyan-cooler) :weight bold))))))))

(add-hook 'enable-theme-functions #'agent-shell-dashboard--apply-theme-faces)
(agent-shell-dashboard--apply-theme-faces)

(provide 'agent-shell-dashboard)
;;; agent-shell-dashboard.el ends here
