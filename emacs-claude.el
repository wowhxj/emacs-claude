;;; emacs-claude.el --- Detachable Emacs client for Claude Code -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1") (markdown-mode "2.3"))
;; Version: 0.1.0
;; Keywords: tools

;;; Commentary:
;; A chat buffer for Claude Code whose agent process outlives the buffer and
;; Emacs itself.  Each session runs in a detached "holder":
;;
;;   nohup sh:  FIFO `in' --> claude -p (stream-json) --> append-only `out.jsonl'
;;
;; The holder keeps the FIFO open read-write, so Claude never sees EOF.  A
;; chat buffer is only a viewer: it replays and follows `out.jsonl' with
;; `tail -f' and writes requests to the FIFO.  Killing the buffer or Emacs
;; kills the viewer, never the holder.  Only `emacs-claude-quit' stops it.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'markdown-mode)

(defgroup emacs-claude nil "Emacs client for Claude Code." :group 'tools)

(defcustom emacs-claude-executable "claude"
  "Claude Code executable." :type 'string)
(defcustom emacs-claude-extra-arguments nil
  "Extra arguments for new Claude holders, e.g. (\"--model\" \"sonnet\")."
  :type '(repeat string))
(defcustom emacs-claude-directory (locate-user-emacs-file "emacs-claude/")
  "Directory holding one subdirectory (FIFO, log, pid) per Claude holder."
  :type 'directory)
(defcustom emacs-claude-config-directory
  (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude")
  "Claude Code configuration directory, used to read saved transcripts."
  :type 'directory)
(defcustom emacs-claude-show-thinking t
  "Whether thinking blocks appear among the process steps." :type 'boolean)
(defcustom emacs-claude-image-max-bytes (* 10 1024 1024)
  "Largest image file attached to a prompt." :type 'integer)
(defcustom emacs-claude-pngpaste-executable "pngpaste"
  "Program that writes the macOS clipboard image to a PNG file."
  :type 'string)
(defcustom emacs-claude-reference-providers nil
  "Alist of (NAME . FUNCTION) for external @NAME references.
TAB after @NAME calls FUNCTION with the chat's project root.  It returns a
file path, inserted as an @ reference, or nil to leave the draft alone.
The same contract as `emacs-pi-reference-providers', so ashub can add
\"ashub\" here."
  :type '(alist :key-type string :value-type function))
(defcustom emacs-claude-session-reference-max-chars 20000
  "Characters of earlier conversation appended for all @session references."
  :type 'integer)

(defface emacs-claude-user-face '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user labels.")
(defface emacs-claude-assistant-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for Claude labels.")
(defface emacs-claude-input-face '((t :inherit widget-field :underline nil :extend t))
  "Background of the composer.")
(defface emacs-claude-status-face '((t :inherit mode-line))
  "Face for Claude activity in the mode line.")

(defconst emacs-claude--composer-prefix "\nYou> ")
(defconst emacs-claude--reference-boundary "\n\n<emacs-claude-session-references>\n"
  "Marker before the conversation context appended for @session references.")
(defconst emacs-claude--session-mention-regexp
  "@\\[[^]\n]*\\](claude-session:\\([[:alnum:]-]+\\))")

(defvar-local emacs-claude--id nil "Session id; also the holder directory name.")
(defvar-local emacs-claude--root nil)
(defvar-local emacs-claude--tail nil "The `tail -f' viewer process.")
(defvar-local emacs-claude--receive nil "Buffer of log text not yet parsed.")
(defvar-local emacs-claude--writer nil "Process that feeds the holder's FIFO.")
(defvar-local emacs-claude--replay-left 0
  "Bytes of pre-existing log not yet replayed; positive means catching up.")
(defvar-local emacs-claude--items nil
  "Newest-first (KIND . DATA): user text, assistant block, or notice text.")
(defvar-local emacs-claude--results nil "Hash: tool_use id -> tool_result block.")
(defvar-local emacs-claude--stream nil "In-flight block as (KIND . TEXT), or nil.")
(defvar-local emacs-claude--running nil)
(defvar-local emacs-claude--pending nil
  "Unanswered control requests from Claude, oldest first, as (ID . EVENT).")
(defvar-local emacs-claude--queued nil
  "Uuids of prompts Claude holds in its queue, next to run first.")
(defvar-local emacs-claude--sent nil
  "Hash: uuid -> content of prompts sent from Emacs, mirrored in `sent.jsonl'.")
(defvar-local emacs-claude--callbacks nil
  "Hash: control request id -> function called with Claude's response.")
(defvar-local emacs-claude--attachments nil
  "Images staged for the next prompt, newest first, as (NAME . BLOCK).")
(defvar-local emacs-claude--image-cache nil)
(defvar-local emacs-claude--queue-buffer nil)
(defvar-local emacs-claude--model nil)
(defvar-local emacs-claude--mode nil "Permission mode.")
(defvar-local emacs-claude--usage nil "Usage object of the latest assistant message.")
(defvar-local emacs-claude--result nil "Latest result event.")
(defvar-local emacs-claude--commands nil)
(defvar-local emacs-claude--models nil)
(defvar-local emacs-claude--input-marker nil)
(defvar-local emacs-claude--input-background nil)
(defvar-local emacs-claude--overlays nil)
(defvar-local emacs-claude--folds nil)
(defvar-local emacs-claude--fold-was-running nil)
(defvar-local emacs-claude--detail-index 0)
(defvar-local emacs-claude--markdown-cache nil)
(defvar-local emacs-claude--render-timer nil)
(defvar-local emacs-claude--spinner-timer nil)
(defvar-local emacs-claude--ask-timer nil)
(defvar-local emacs-claude--copy-mode nil)
(defvar-local emacs-claude--history-index nil)
(defvar-local emacs-claude--history-draft nil)
(defvar emacs-claude--asking nil "Non-nil while a permission prompt is open.")

;;;; JSON

(defun emacs-claude--get (object &rest keys)
  "Follow string KEYS through nested JSON OBJECT; nil when absent."
  (while (and keys (hash-table-p object))
    (setq object (gethash (pop keys) object)))
  (and (null keys) object))

(defun emacs-claude--object (&rest pairs)
  "Build a JSON object from string-key PAIRS."
  (let ((object (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) object))
    object))

(defun emacs-claude--parse (line)
  "Parse one JSON LINE, keeping false and null distinct from nil."
  (json-parse-string line :object-type 'hash-table :array-type 'array
                     :false-object :false :null-object :null))

(defun emacs-claude--encode (object)
  "Encode OBJECT as a JSON string."
  (decode-coding-string
   (encode-coding-string
    (json-serialize object :false-object :false :null-object :null) 'utf-8)
   'utf-8))

(defun emacs-claude--uuid ()
  "Return a random version-4 UUID, as `claude --session-id' requires."
  (let ((h (md5 (format "%s%s%s" (current-time) (random) (emacs-pid)))))
    (format "%s-%s-4%s-%x%s-%s" (substring h 0 8) (substring h 8 12)
            (substring h 13 16) (+ 8 (random 4)) (substring h 17 20)
            (substring h 20 32))))

;;;; Holder: the detached Claude process

(defconst emacs-claude--holder-script
  "cd \"$1\" || exit 1
d=$2; shift 2
exec 3<>\"$d/in\"
printf '%s\\n' '{\"type\":\"control_request\",\"request_id\":\"init\",\"request\":{\"subtype\":\"initialize\"}}' >&3
cat <&3 | {
  \"$@\" <&0 >>\"$d/out.jsonl\" 2>>\"$d/err\" &
  echo $! > \"$d/pid\"
  wait $!
  exec 0<&-
  echo >&3
}"
  "Shell program: ROOT DIR COMMAND...  Opening the FIFO read-write means no
writer ever has to stay connected, and its own first line initializes Claude.
Claude reads through `cat' because it stops reading a FIFO stdin after about
64 KiB, which an image prompt exceeds.  The pid file names Claude itself.
Once Claude exits, nothing reads the pipe, so the final newline makes the
relay `cat' fail on its next write and exit.")

(defun emacs-claude--dir (id)
  "Return holder directory of session ID."
  (expand-file-name (concat "instances/" id "/") emacs-claude-directory))

(defun emacs-claude--file (id name)
  (expand-file-name name (emacs-claude--dir id)))

(defun emacs-claude--pid (id)
  "Return the holder pid recorded for ID, or nil."
  (let ((file (emacs-claude--file id "pid")))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((pid (string-to-number (buffer-string))))
          (and (> pid 0) pid))))))

(defun emacs-claude--alive-p (id)
  "Whether the holder of ID is running."
  ;; ponytail: trusts the pid file; a recycled pid would look alive.
  (when-let* ((pid (emacs-claude--pid id)))
    (eq 0 (ignore-errors (signal-process pid 0)))))

(defun emacs-claude--meta (id)
  "Return holder metadata of ID as a JSON object, or nil."
  (let ((file (emacs-claude--file id "meta.json")))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (ignore-errors (emacs-claude--parse (buffer-string)))))))

(defun emacs-claude--transcript-file (id root)
  "Return Claude Code's saved transcript path for session ID under ROOT."
  (expand-file-name
   (concat id ".jsonl")
   (expand-file-name
    (replace-regexp-in-string "[^a-zA-Z0-9]" "-" (directory-file-name root))
    (expand-file-name "projects" emacs-claude-config-directory))))

(defun emacs-claude--start-holder (id root)
  "Start a detached Claude for session ID in ROOT."
  (let* ((exe (or (executable-find emacs-claude-executable)
                  (user-error "Cannot find `%s'" emacs-claude-executable)))
         (dir (emacs-claude--dir id))
         (resume (file-exists-p (emacs-claude--transcript-file id root)))
         (coding-system-for-write 'utf-8-unix))
    (with-file-modes #o700 (make-directory dir t))
    ;; The dead holder's conversation lives in Claude's transcript; keep one
    ;; previous log anyway rather than destroy it.
    (when (file-exists-p (expand-file-name "out.jsonl" dir))
      (rename-file (expand-file-name "out.jsonl" dir)
                   (expand-file-name "out.prev.jsonl" dir) t))
    (dolist (name '("in" "pid" "err"))
      (when (file-exists-p (expand-file-name name dir))
        (delete-file (expand-file-name name dir))))
    (unless (eq 0 (call-process "mkfifo" nil nil nil (expand-file-name "in" dir)))
      (error "Cannot create FIFO in %s" dir))
    (with-file-modes #o600
      (write-region "" nil (expand-file-name "out.jsonl" dir) nil 'silent)
      (write-region
       (emacs-claude--encode
        (emacs-claude--object
         "root" root "resumed" (if resume t :false)
         "started" (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t)))
       nil (expand-file-name "meta.json" dir) nil 'silent))
    ;; Destination 0: Emacs neither waits for nor owns the process.
    (let ((default-directory root))
      (apply #'call-process "nohup" nil 0 nil "sh" "-c" emacs-claude--holder-script
             "emacs-claude" root dir exe
             "-p" "--input-format" "stream-json" "--output-format" "stream-json"
             "--verbose" "--include-partial-messages" "--replay-user-messages"
             "--permission-prompt-tool" "stdio"
             (append (if resume (list "--resume" id) (list "--session-id" id))
                     emacs-claude-extra-arguments)))))

(defun emacs-claude--write (object)
  "Send JSON OBJECT to this chat's Claude."
  (unless (emacs-claude--alive-p emacs-claude--id)
    (user-error "Claude is not running; C-c C-r resumes this session"))
  ;; One long-lived asynchronous writer: Emacs never waits on the FIFO, and
  ;; messages larger than a pipe buffer cannot interleave.
  (unless (process-live-p emacs-claude--writer)
    (setq emacs-claude--writer
          (make-process :name "emacs-claude-writer" :noquery t
                        :connection-type 'pipe :coding 'utf-8-unix
                        :command (list "sh" "-c" "exec cat > \"$0\""
                                       (emacs-claude--file emacs-claude--id "in")))))
  (process-send-string emacs-claude--writer
                       (concat (emacs-claude--encode object) "\n")))

(defun emacs-claude--control-then (callback subtype &rest pairs)
  "Send control request SUBTYPE with PAIRS; call CALLBACK with its response.
CALLBACK may be nil.  It runs in the chat buffer and receives nil on error."
  ;; A fresh uuid, so an old answer replayed from the log is never mistaken
  ;; for the answer to this request.
  (let ((id (emacs-claude--uuid)))
    (when callback (puthash id callback emacs-claude--callbacks))
    (emacs-claude--write
     (emacs-claude--object
      "type" "control_request" "request_id" id
      "request" (apply #'emacs-claude--object "subtype" subtype pairs)))))

(defun emacs-claude--control (subtype &rest pairs)
  "Send control request SUBTYPE with extra request PAIRS."
  (apply #'emacs-claude--control-then nil subtype pairs))

(defun emacs-claude--submit (content)
  "Send CONTENT, a string or vector of blocks, as a user prompt."
  (let ((uuid (emacs-claude--uuid))
        (coding-system-for-write 'utf-8-unix))
    (emacs-claude--write
     (emacs-claude--object
      "type" "user" "uuid" uuid
      "message" (emacs-claude--object "role" "user" "content" content)))
    ;; Claude's queue events carry only the uuid; this record is what lets a
    ;; later Emacs show and edit the queued prompt.
    ;; ponytail: append-only, images included; prune if it ever grows large.
    (puthash uuid content emacs-claude--sent)
    (write-region
     (concat (emacs-claude--encode
              (emacs-claude--object "uuid" uuid "content" content))
             "\n")
     nil (emacs-claude--file emacs-claude--id "sent.jsonl") t 'silent)))

(defun emacs-claude--respond (id response)
  "Answer Claude's control request ID with RESPONSE object."
  (emacs-claude--write
   (emacs-claude--object
    "type" "control_response"
    "response" (emacs-claude--object "subtype" "success" "request_id" id
                                     "response" response)))
  (setq emacs-claude--pending (assoc-delete-all id emacs-claude--pending)))

;;;; Events

(defun emacs-claude--prompt-text (event)
  "Return the human-written text of user EVENT, or nil."
  (unless (or (eq (emacs-claude--get event "isMeta") t)
              (eq (emacs-claude--get event "isSidechain") t)
              (eq (emacs-claude--get event "isCompactSummary") t)
              (stringp (emacs-claude--get event "parent_tool_use_id")))
    (let* ((content (emacs-claude--get event "message" "content"))
           (text (cond
                  ((stringp content) content)
                  ((vectorp content)
                   (mapconcat (lambda (block)
                                (or (and (equal (emacs-claude--get block "type") "text")
                                         (emacs-claude--get block "text"))
                                    ""))
                              content "")))))
      ;; ponytail: "<" also drops a real prompt that begins with a tag; it is
      ;; how Claude Code marks command output and injected reminders.
      (and text (not (string-blank-p text)) (not (string-prefix-p "<" text))
           ;; Context appended for @session references is not the user's text.
           (substring text 0 (string-search emacs-claude--reference-boundary
                                            text))))))

(defun emacs-claude--content-images (content)
  "Return the image blocks of message CONTENT."
  (and (vectorp content)
       (cl-remove-if-not (lambda (block)
                           (equal (emacs-claude--get block "type") "image"))
                         (append content nil))))

(defun emacs-claude--event (e)
  "Apply log or transcript event E to this chat's state."
  (let ((subagent (stringp (emacs-claude--get e "parent_tool_use_id"))))
    (pcase (emacs-claude--get e "type")
      ("system"
       (pcase (emacs-claude--get e "subtype")
         ("init" (setq emacs-claude--model (emacs-claude--get e "model")
                       emacs-claude--mode (emacs-claude--get e "permissionMode")))
         ("status" (when-let* ((mode (emacs-claude--get e "permissionMode")))
                     (setq emacs-claude--mode mode)))
         ("commands_changed"
          (setq emacs-claude--commands (emacs-claude--get e "commands")))))
      ("stream_event"
       (unless subagent
         (let ((event (emacs-claude--get e "event")))
           (setq emacs-claude--running t)
           (pcase (emacs-claude--get event "type")
             ("content_block_start"
              (let ((block (emacs-claude--get event "content_block")))
                (setq emacs-claude--stream
                      (cons (or (emacs-claude--get block "name")
                                (emacs-claude--get block "type"))
                            ""))))
             ("content_block_delta"
              (when-let* ((stream emacs-claude--stream)
                          (delta (emacs-claude--get event "delta"))
                          (text (or (emacs-claude--get delta "text")
                                    (emacs-claude--get delta "thinking"))))
                (setcdr stream (concat (cdr stream) text))))))))
      ("assistant"
       (unless subagent
         (seq-doseq (block (emacs-claude--get e "message" "content"))
           (push (cons 'assistant block) emacs-claude--items))
         (when-let* ((usage (emacs-claude--get e "message" "usage")))
           (setq emacs-claude--usage usage))
         (setq emacs-claude--stream nil emacs-claude--running t)))
      ("user"
       (unless subagent
         (let ((content (emacs-claude--get e "message" "content")))
           (when (vectorp content)
             (seq-doseq (block content)
               (when (equal (emacs-claude--get block "type") "tool_result")
                 (puthash (emacs-claude--get block "tool_use_id") block
                          emacs-claude--results)))))
         (when (eq (emacs-claude--get e "isCompactSummary") t)
           (push (cons 'notice "earlier context compacted") emacs-claude--items))
         (let* ((images (and (not (eq (emacs-claude--get e "isMeta") t))
                             (emacs-claude--content-images
                              (emacs-claude--get e "message" "content"))))
                (text (or (emacs-claude--prompt-text e) (and images "(image)"))))
           (cond ((null text))
                 ((string-prefix-p "[Request interrupted" text)
                  (push (cons 'notice "interrupted") emacs-claude--items))
                 (t (push (cons 'user text) emacs-claude--items)
                    (when images
                      (push (cons 'images images) emacs-claude--items))
                    (setq emacs-claude--running t))))))
      ("command_lifecycle"
       (let ((uuid (emacs-claude--get e "command_uuid")))
         (setq emacs-claude--queued (delete uuid emacs-claude--queued))
         (when (equal (emacs-claude--get e "state") "queued")
           (setq emacs-claude--queued
                 (append emacs-claude--queued (list uuid))))))
      ("result"
       (let ((text (emacs-claude--get e "result"))
             (last (car (car emacs-claude--items))))
         (setq emacs-claude--running nil emacs-claude--stream nil
               emacs-claude--result e)
         (cond
          ((eq (emacs-claude--get e "is_error") t)
           (unless (eq last 'notice)
             (push (cons 'notice (or (and (stringp text) text)
                                     (emacs-claude--get e "subtype") "error"))
                   emacs-claude--items)))
          ;; A local slash command answers through the result alone.
          ((and (eq last 'user) (stringp text) (not (string-blank-p text)))
           (push (cons 'assistant (emacs-claude--object "type" "text" "text" text))
                 emacs-claude--items)))))
      ("control_request"
       (let ((id (emacs-claude--get e "request_id")))
         (unless (assoc id emacs-claude--pending)
           (setq emacs-claude--pending
                 (append emacs-claude--pending (list (cons id e)))))))
      ("control_cancel_request"
       (setq emacs-claude--pending
             (assoc-delete-all (emacs-claude--get e "request_id")
                               emacs-claude--pending)))
      ("control_response"
       ;; Claude echoes answers too, which is how a replay learns that a
       ;; logged permission request was already answered.
       (let* ((response (emacs-claude--get e "response"))
              (id (emacs-claude--get response "request_id")))
         (setq emacs-claude--pending (assoc-delete-all id emacs-claude--pending))
         (when-let* ((callback (gethash id emacs-claude--callbacks)))
           (remhash id emacs-claude--callbacks)
           (funcall callback (emacs-claude--get response "response")))
         (when (equal id "init")
           (setq emacs-claude--commands
                 (emacs-claude--get response "response" "commands")
                 emacs-claude--models
                 (emacs-claude--get response "response" "models"))))))))

(defun emacs-claude--filter (buffer chunk)
  "Feed log CHUNK from the tail process into chat BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((replaying (> emacs-claude--replay-left 0))
            lines)
        (setq emacs-claude--replay-left
              (max 0 (- emacs-claude--replay-left (string-bytes chunk))))
        ;; A buffer, not string concatenation: an image prompt is one log line
        ;; of megabytes arriving in small chunks, and rescanning it each time
        ;; would be quadratic.
        (with-current-buffer emacs-claude--receive
          (goto-char (point-max))
          (let ((from (point)))
            (insert chunk)
            (goto-char from))
          (while (search-forward "\n" nil t)
            (push (buffer-substring-no-properties (point-min) (1- (point))) lines)
            (delete-region (point-min) (point))))
        (dolist (line (nreverse lines))
          ;; Replayed deltas are superseded by the complete messages that
          ;; follow them; skipping them keeps a long log quick to attach.
          (unless (or (string-empty-p line)
                      (and replaying
                           (string-prefix-p "{\"type\":\"stream_event\"" line)))
            (condition-case err
                (emacs-claude--event (emacs-claude--parse line))
              (error (message "emacs-claude: skipped event: %s"
                              (error-message-string err)))))))
      (emacs-claude--schedule))))

(defun emacs-claude--load-history (file before)
  "Apply saved transcript FILE entries stamped earlier than ISO time BEFORE."
  ;; ponytail: reads the whole transcript; page it if huge sessions get slow.
  (let (events)
    (with-temp-buffer
      (insert-file-contents file)
      (while (not (eobp))
        (let ((line (buffer-substring (point) (line-end-position))))
          (when (string-match-p "\"type\":\"\\(user\\|assistant\\)\"" line)
            (when-let* ((event (ignore-errors (emacs-claude--parse line)))
                        (stamp (emacs-claude--get event "timestamp")))
              (when (and (stringp stamp) (string< stamp before)
                         (not (eq (emacs-claude--get event "isSidechain") t)))
                (push event events)))))
        (forward-line 1)))
    (mapc #'emacs-claude--event (nreverse events))
    (setq emacs-claude--running nil emacs-claude--stream nil)))

;;;; Permission and question prompts

(defun emacs-claude--tool-summary (input)
  "Return a one-line description of tool INPUT."
  (truncate-string-to-width
   (replace-regexp-in-string
    "[\r\n]+" " "
    (or (cl-some (lambda (key)
                   (let ((value (emacs-claude--get input key)))
                     (and (stringp value) value)))
                 '("command" "file_path" "pattern" "url" "query" "skill"
                   "description" "prompt"))
        (if (hash-table-p input) (emacs-claude--encode input) "")))
   80 nil nil "…"))

(defun emacs-claude--ask-questions (input)
  "Answer AskUserQuestion INPUT in the minibuffer; return the updated input."
  (let ((answers (make-hash-table :test #'equal))
        (updated (copy-hash-table input)))
    (seq-doseq (question (emacs-claude--get input "questions"))
      (let ((text (emacs-claude--get question "question"))
            (labels (mapcar (lambda (option) (emacs-claude--get option "label"))
                            (append (emacs-claude--get question "options") nil))))
        (puthash text
                 (if (eq (emacs-claude--get question "multiSelect") t)
                     (string-join
                      (completing-read-multiple (concat text " ") labels) ", ")
                   (completing-read (concat text " ") labels))
                 answers)))
    (puthash "answers" answers updated)
    updated))

(defun emacs-claude--answer (id event)
  "Ask the user about Claude's control request EVENT and reply to ID."
  (let* ((request (emacs-claude--get event "request"))
         (tool (emacs-claude--get request "tool_name"))
         (input (emacs-claude--get request "input"))
         ;; Remember only rule suggestions: accepting a suggested mode or
         ;; directory change would grant far more than this one question.
         (rules (cl-remove-if-not
                 (lambda (suggestion)
                   (equal (emacs-claude--get suggestion "type") "addRules"))
                 (append (emacs-claude--get request "permission_suggestions") nil)))
         (allow (lambda (&rest pairs)
                  (emacs-claude--respond
                   id (apply #'emacs-claude--object "behavior" "allow" pairs))))
         (deny (lambda (message)
                 (emacs-claude--respond
                  id (emacs-claude--object "behavior" "deny" "message" message)))))
    (cond
     ((not (equal (emacs-claude--get request "subtype") "can_use_tool"))
      (emacs-claude--write
       (emacs-claude--object
        "type" "control_response"
        "response" (emacs-claude--object
                    "subtype" "error" "request_id" id
                    "error" "Not supported by emacs-claude")))
      (setq emacs-claude--pending (assoc-delete-all id emacs-claude--pending)))
     ((equal tool "AskUserQuestion")
      (funcall allow "updatedInput" (emacs-claude--ask-questions input)))
     (t
      (pcase (car (read-multiple-choice
                   (format "Claude [%s] wants %s: %s"
                           (file-name-nondirectory
                            (directory-file-name emacs-claude--root))
                           tool (emacs-claude--tool-summary input))
                   `((?y "yes" "Allow this once")
                     ,@(when rules '((?a "always" "Allow and save the suggested rule")))
                     (?n "no" "Deny")
                     (?m "message" "Deny and tell Claude what to do instead"))))
        (?y (funcall allow "updatedInput" input))
        (?a (funcall allow "updatedInput" input
                     "updatedPermissions" (vconcat rules)))
        (?n (funcall deny "The user denied this tool call."))
        (?m (funcall deny (read-string "Tell Claude: "))))))))

(defun emacs-claude-answer ()
  "Answer Claude's pending permission requests and questions."
  (interactive)
  (unless emacs-claude--asking
    (let ((emacs-claude--asking t))
      (condition-case nil
          (while emacs-claude--pending
            (emacs-claude--answer (caar emacs-claude--pending)
                                  (cdar emacs-claude--pending)))
        (quit (message "Claude is still waiting; C-c C-a answers"))))
    (emacs-claude--schedule)))

(defun emacs-claude--ask-soon ()
  "Prompt for pending requests once the log is caught up and Emacs is free."
  (unless emacs-claude--ask-timer
    (let ((buffer (current-buffer)))
      (setq emacs-claude--ask-timer
            (run-at-time
             0.2 nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq emacs-claude--ask-timer nil)
                   (cond ((not emacs-claude--pending))
                         ((or (> emacs-claude--replay-left 0) emacs-claude--asking
                              (active-minibuffer-window))
                          (emacs-claude--ask-soon))
                         (t (emacs-claude-answer)))))))))))

;;;; Composer

(defun emacs-claude--input-beginning ()
  "Return the first editable position of the composer."
  (unless emacs-claude--input-marker (user-error "Not in an emacs-claude chat"))
  (+ (marker-position emacs-claude--input-marker)
     (length emacs-claude--composer-prefix)))

(defun emacs-claude--input-end ()
  "Return the end of the draft, before its read-only line ending."
  (max (emacs-claude--input-beginning) (1- (point-max))))

(defun emacs-claude--input-text ()
  (buffer-substring-no-properties (emacs-claude--input-beginning)
                                  (emacs-claude--input-end)))

(defun emacs-claude--input-set (text)
  "Replace the draft with TEXT."
  (delete-region (emacs-claude--input-beginning) (emacs-claude--input-end))
  (goto-char (emacs-claude--input-beginning))
  (insert text))

(defun emacs-claude-focus-input ()
  "Move point to the end of the composer text."
  (interactive)
  (goto-char (+ (emacs-claude--input-beginning)
                (length (string-trim-right (emacs-claude--input-text))))))

(defun emacs-claude--history (direction)
  "Move DIRECTION steps through sent prompts; -1 heads back to the draft."
  (let* ((prompts (mapcar #'cdr (cl-remove-if-not (lambda (item) (eq (car item) 'user))
                                                  emacs-claude--items)))
         (index (+ (or emacs-claude--history-index -1) direction)))
    (cond ((< index -1) (user-error "End of history"))
          ((>= index (length prompts)) (user-error "No earlier prompt"))
          (t (unless emacs-claude--history-index
               (setq emacs-claude--history-draft (emacs-claude--input-text)))
             (setq emacs-claude--history-index (and (>= index 0) index))
             (emacs-claude--input-set
              (if (>= index 0) (nth index prompts) emacs-claude--history-draft))))))

(defun emacs-claude-previous-prompt ()
  "Show the previous submitted prompt."
  (interactive)
  (emacs-claude--history 1))

(defun emacs-claude-next-prompt ()
  "Show the next submitted prompt or restore the unsent draft."
  (interactive)
  (emacs-claude--history -1))

(defconst emacs-claude--client-commands
  '(("/resume" emacs-claude-resume "Resume a session of this project")
    ("/new" emacs-claude-new-session "New session in this project")
    ("/attach" emacs-claude-attach "Open a Claude still running in the background")
    ("/model" emacs-claude-select-model "Choose the model")
    ("/permission" emacs-claude-select-permission-mode "Choose the permission mode")
    ("/queue" emacs-claude-show-queue "Show and edit prompts waiting to run")
    ("/image" emacs-claude-attach-image "Attach an image to the next prompt")
    ("/copy" emacs-claude-copy-last-response "Copy Claude's last reply")
    ("/detach" emacs-claude-detach "Close the chat; Claude keeps running")
    ("/quit" emacs-claude-quit "Stop Claude and close the chat")
    ("/help" emacs-claude-help "List commands"))
  "Slash commands handled by Emacs instead of Claude.")

(defun emacs-claude--slash-choices ()
  "Return (\"/name\" . DESCRIPTION) for client and Claude commands."
  (append
   (mapcar (lambda (command) (cons (car command) (nth 2 command)))
           emacs-claude--client-commands)
   (mapcar (lambda (command)
             (cons (concat "/" (emacs-claude--get command "name"))
                   (emacs-claude--get command "description")))
           (append emacs-claude--commands nil))))

(defun emacs-claude--file-mention (file)
  "Return an @ reference to FILE in Claude Code's syntax."
  (let* ((relative (file-relative-name file emacs-claude--root))
         (path (if (string-prefix-p ".." relative) (abbreviate-file-name file) relative)))
    (if (string-match-p "[[:space:]]" path) (format "@\"%s\"" path) (concat "@" path))))

(defun emacs-claude-complete ()
  "Complete the /command, @file, @session or @provider before point."
  (interactive)
  (let* ((begin (emacs-claude--input-beginning))
         ;; Markers: Claude's output can redraw the transcript above the
         ;; composer while the minibuffer is open.
         (end (copy-marker (point) t))
         (start (copy-marker
                 (save-excursion (skip-chars-backward "^ \t\n" begin) (point))))
         (token (and (>= end begin) (buffer-substring-no-properties start end)))
         (provider (and token (string-match "\\`@\\([[:alnum:]_-]+\\)\\'" token)
                        (cdr (assoc (match-string 1 token)
                                    emacs-claude-reference-providers)))))
    (cond
     ((and token (= start begin) (string-prefix-p "/" token))
      (let* ((choices (emacs-claude--slash-choices))
             (completion-extra-properties
              (list :annotation-function
                    (lambda (choice)
                      (when-let* ((text (cdr (assoc choice choices))))
                        (concat "  " (truncate-string-to-width
                                      (replace-regexp-in-string "[\r\n]+" " " text)
                                      70 nil nil "…"))))))
             (choice (completing-read "Command: " choices nil nil token)))
        (delete-region start end)
        (goto-char start)
        (insert choice " ")))
     ((and token (string-prefix-p "@session" token))
      (let* ((sessions (cl-remove emacs-claude--id (emacs-claude--sessions)
                                  :key (lambda (session) (plist-get session :id))
                                  :test #'equal))
             (session (emacs-claude--pick
                       (or sessions (user-error "No other saved sessions"))
                       "Claude session reference: " nil t)))
        (delete-region start end)
        (goto-char start)
        (insert (format "@[%s](claude-session:%s) "
                        (truncate-string-to-width
                         (replace-regexp-in-string
                          "]" ")" (replace-regexp-in-string
                                   "[\r\n]+" " " (plist-get session :first)))
                         64 nil nil "…")
                        (plist-get session :id)))))
     (provider
      (when-let* ((file (funcall provider emacs-claude--root)))
        (delete-region start end)
        (goto-char start)
        (insert (emacs-claude--file-mention file) " ")))
     ((and token (string-prefix-p "@" token))
      (let ((file (read-file-name "File: " emacs-claude--root nil nil
                                  (substring token 1))))
        (delete-region start end)
        (goto-char start)
        (insert (emacs-claude--file-mention file))))
     (t (user-error "Type / or @ first, then TAB")))))

(defun emacs-claude-send (&optional steer)
  "Send the draft.  While Claude works it queues as a follow-up.
With STEER, interrupt the current run first."
  (interactive)
  (let* ((text (string-trim (emacs-claude--input-text)))
         (command (assoc (car (split-string text)) emacs-claude--client-commands)))
    (cond
     ((and (string-empty-p text) (null emacs-claude--attachments))
      (user-error "Nothing to send"))
     (command (emacs-claude--input-set "")
              (call-interactively (nth 1 command)))
     (t
      (let ((content (emacs-claude--content (emacs-claude--expand-references text)
                                            emacs-claude--attachments)))
        (when steer (emacs-claude--control "interrupt"))
        (emacs-claude--submit content)
        (setq emacs-claude--history-index nil emacs-claude--attachments nil)
        (emacs-claude--input-set "")
        (emacs-claude--render))))))

(defun emacs-claude-steer ()
  "Interrupt the running turn and send the draft as the next prompt."
  (interactive)
  (emacs-claude-send t))

(defun emacs-claude-stop ()
  "Interrupt Claude's current turn."
  (interactive)
  (emacs-claude--control "interrupt")
  (message "Interrupt sent%s"
           (if emacs-claude--queued "; queued prompts will still run (C-c C-l)" "")))

;;;; Images, message content and @session references

(defvar emacs-claude--attachment-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'emacs-claude-remove-image)
    (define-key map (kbd "RET") #'emacs-claude-remove-image)
    map)
  "Keys on the × that removes a staged image.")

(defun emacs-claude--image-string (block)
  "Return a thumbnail, or a text placeholder, that carries image BLOCK."
  (let ((label (propertize "[image]" 'emacs-claude-image block
                           'help-echo "C-c C-o: open in the system viewer"))
        (image (and (display-images-p)
                    (or (gethash block emacs-claude--image-cache)
                        (puthash block
                                 (ignore-errors
                                   (create-image
                                    (base64-decode-string
                                     (emacs-claude--get block "source" "data"))
                                    nil t :max-width 200 :max-height 120))
                                 emacs-claude--image-cache)))))
    (when image (put-text-property 0 (length label) 'display image label))
    label))

(defun emacs-claude--image-block (file)
  "Read image FILE into a Claude image block."
  (when (> (file-attribute-size (file-attributes file)) emacs-claude-image-max-bytes)
    (user-error "Image exceeds %s (emacs-claude-image-max-bytes)"
                (file-size-human-readable emacs-claude-image-max-bytes 'iec)))
  (let* ((data (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert-file-contents-literally file)
                 (buffer-string)))
         (type (cond ((string-prefix-p (unibyte-string 137 80 78 71) data) "image/png")
                     ((string-prefix-p (unibyte-string 255 216 255) data) "image/jpeg")
                     ((string-prefix-p "GIF8" data) "image/gif")
                     ((and (string-prefix-p "RIFF" data) (> (length data) 12)
                           (equal (substring data 8 12) "WEBP"))
                      "image/webp"))))
    (unless type (user-error "Only PNG, JPEG, GIF and WebP images are supported"))
    (emacs-claude--object
     "type" "image"
     "source" (emacs-claude--object "type" "base64" "media_type" type
                                    "data" (base64-encode-string data t)))))

(defun emacs-claude-attach-image (file &optional name)
  "Attach image FILE to the next prompt, shown as NAME."
  (interactive "fImage file: ")
  (unless emacs-claude--id (user-error "Not in an emacs-claude chat"))
  (push (cons (or name (file-name-nondirectory file))
              (emacs-claude--image-block file))
        emacs-claude--attachments)
  (emacs-claude--render)
  (message "Attached %s" (or name (file-name-nondirectory file))))

(defun emacs-claude-remove-image (&optional event)
  "Remove the staged image whose × is at point or was clicked with EVENT."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((index (or (get-text-property (point) 'emacs-claude-attachment)
                   (user-error "Move to the × of a staged image first")))
        (images (reverse emacs-claude--attachments)))
    (setq emacs-claude--attachments
          (nreverse (append (take index images) (nthcdr (1+ index) images))))
    (emacs-claude--render)))

(defun emacs-claude-open-image ()
  "Open the image at point, or a staged one, in the system viewer."
  (interactive)
  (let* ((block
          (or (get-text-property (point) 'emacs-claude-image)
              (and (> (point) (point-min))
                   (get-text-property (1- (point)) 'emacs-claude-image))
              (pcase emacs-claude--attachments
                ('nil (user-error "Move to an image or attach one first"))
                (`(,only) (cdr only))
                (several (cdr (assoc (completing-read "View image: " several nil t)
                                     several))))))
         (type (emacs-claude--get block "source" "media_type"))
         ;; ponytail: the copy is left for the OS to clean out of the temp dir.
         (file (make-temp-file "emacs-claude-image-" nil
                               (concat "." (car (last (split-string type "/"))))))
         (coding-system-for-write 'no-conversion))
    (write-region (base64-decode-string (emacs-claude--get block "source" "data"))
                  nil file nil 'silent)
    (if (eq system-type 'darwin)
        (call-process "open" nil 0 nil file)
      (call-process (or (executable-find "xdg-open")
                        (user-error "No system image opener found"))
                    nil 0 nil file))))

(defun emacs-claude-paste ()
  "Paste a clipboard image as an attachment, or paste ordinary text.
On macOS, `pngpaste' provides the clipboard image."
  (interactive)
  (when (< (point) (emacs-claude--input-beginning))
    (emacs-claude-focus-input))
  (let ((program (or (executable-find emacs-claude-pngpaste-executable)
                     (cl-find-if #'file-executable-p
                                 '("/opt/homebrew/bin/pngpaste"
                                   "/usr/local/bin/pngpaste"))))
        (file (make-temp-file "emacs-claude-clipboard-" nil ".png")))
    (unwind-protect
        (if (and program
                 (eq 0 (call-process program nil nil nil file))
                 (> (file-attribute-size (file-attributes file)) 0))
            (emacs-claude-attach-image file "clipboard.png")
          (yank))
      (delete-file file))))

(defun emacs-claude--content (text attachments)
  "Return message content for TEXT plus ATTACHMENTS, which are newest first."
  (if (null attachments)
      text
    (vconcat (mapcar #'cdr (reverse attachments))
             (unless (string-empty-p text)
               (list (emacs-claude--object "type" "text" "text" text))))))

(defun emacs-claude--content-text (content)
  "Return the user's own text in message CONTENT."
  (let ((text (if (stringp content)
                  content
                (mapconcat (lambda (block)
                             (or (and (equal (emacs-claude--get block "type") "text")
                                      (emacs-claude--get block "text"))
                                 ""))
                           content ""))))
    (substring text 0 (string-search emacs-claude--reference-boundary text))))

(defun emacs-claude--session-excerpt (file limit)
  "Return the last LIMIT characters of the conversation in transcript FILE."
  (let (parts)
    (with-temp-buffer
      (insert-file-contents file)
      (while (not (eobp))
        (let ((line (buffer-substring (point) (line-end-position))))
          (when (string-match-p "\"type\":\"\\(user\\|assistant\\)\"" line)
            (when-let* ((event (ignore-errors (emacs-claude--parse line))))
              (if (equal (emacs-claude--get event "type") "user")
                  (when-let* ((text (emacs-claude--prompt-text event)))
                    (push (concat "User: " text) parts))
                (unless (eq (emacs-claude--get event "isSidechain") t)
                  (let ((text (emacs-claude--content-text
                               (emacs-claude--get event "message" "content"))))
                    (unless (string-blank-p text)
                      (push (concat "Claude: " text) parts))))))))
        (forward-line 1)))
    (let ((text (string-join (nreverse parts) "\n\n")))
      (if (> (length text) limit)
          (concat "…" (substring text (- limit)))
        text))))

(defun emacs-claude--expand-references (text)
  "Append bounded conversation context for the @session mentions in TEXT."
  (let ((start 0) ids)
    (while (string-match emacs-claude--session-mention-regexp text start)
      (cl-pushnew (match-string 1 text) ids :test #'equal)
      (setq start (match-end 0)))
    (if (null ids)
        text
      (let ((limit (max 1 (/ emacs-claude-session-reference-max-chars (length ids)))))
        (concat
         text emacs-claude--reference-boundary
         "The following saved Claude Code conversations are background context "
         "for the request above:\n\n"
         (mapconcat
          (lambda (id)
            (let ((file (car (file-expand-wildcards
                              (expand-file-name
                               (concat "projects/*/" id ".jsonl")
                               emacs-claude-config-directory)))))
              (unless file (user-error "Referenced session %s was not found" id))
              (format "Session %s:\n%s" id
                      (emacs-claude--session-excerpt file limit))))
          (nreverse ids) "\n\n---\n\n")
         "\n</emacs-claude-session-references>")))))

;;;; Rendering

(defun emacs-claude--markdown (text)
  "Return TEXT fontified by `markdown-mode', keeping its characters."
  (or (gethash text emacs-claude--markdown-cache)
      (puthash text
               (condition-case nil
                   (with-temp-buffer
                     (insert text)
                     (delay-mode-hooks (markdown-mode))
                     (font-lock-ensure)
                     (buffer-string))
                 (error text))
               emacs-claude--markdown-cache)))

(defun emacs-claude--user-message-face ()
  "Use the theme's warning color to highlight user messages."
  (let* ((warning (or (face-foreground 'warning nil t) "#d97706"))
         (rgb (ignore-errors (color-values warning)))
         (luminance (when rgb
                      (/ (+ (* 0.2126 (nth 0 rgb)) (* 0.7152 (nth 1 rgb))
                            (* 0.0722 (nth 2 rgb)))
                         65535.0))))
    (list :background warning
          :foreground (if (and luminance (> luminance 0.5)) "#111111" "#ffffff")
          :extend t)))

(defun emacs-claude--heading (label expanded)
  (propertize (concat (if expanded "▾ " "▸ ") label (unless expanded "\n"))
              'face 'shadow))

(defvar emacs-claude--process-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-claude-toggle-process)
    (define-key map (kbd "TAB") #'emacs-claude-toggle-process)
    (define-key map [mouse-1] #'emacs-claude-toggle-process)
    map)
  "Keys on a foldable heading.")

(defun emacs-claude--fold (start body-start end key label &optional default-expanded)
  "Fold START..END under KEY; text from BODY-START is the hidden detail."
  (let* ((stored (gethash key emacs-claude--folds 'unset))
         (expanded (if (eq stored 'unset) default-expanded (eq stored t)))
         (header (make-overlay start (1- body-start) nil t nil))
         (body (make-overlay (1- body-start) end nil nil nil)))
    (overlay-put header 'display (emacs-claude--heading label expanded))
    (overlay-put header 'emacs-claude-body body)
    (overlay-put header 'emacs-claude-key key)
    (overlay-put header 'emacs-claude-label label)
    (overlay-put header 'keymap emacs-claude--process-map)
    (overlay-put header 'mouse-face 'highlight)
    (overlay-put body 'invisible (unless expanded 'emacs-claude-process))
    (push header emacs-claude--overlays)
    (push body emacs-claude--overlays)))

(defun emacs-claude--process-at-point ()
  "Return the fold heading overlay at point, if any."
  (cl-flet ((heading (position)
              (cl-find-if (lambda (overlay) (overlay-get overlay 'emacs-claude-body))
                          (overlays-at position))))
    (or (heading (point))
        (and (> (point) (point-min)) (not (eq (char-before) ?\n))
             (heading (1- (point)))))))

(defun emacs-claude-toggle-process (&optional event)
  "Show or hide the steps under the heading at point or mouse EVENT."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let* ((header (or (emacs-claude--process-at-point)
                     (user-error "Move to a process heading first")))
         (body (overlay-get header 'emacs-claude-body))
         (expand (overlay-get body 'invisible)))
    (puthash (overlay-get header 'emacs-claude-key) (if expand t 'collapsed)
             emacs-claude--folds)
    (overlay-put body 'invisible (unless expand 'emacs-claude-process))
    (overlay-put header 'display
                 (emacs-claude--heading (overlay-get header 'emacs-claude-label)
                                        expand))))

(defun emacs-claude--insert-detail (label detail key)
  "Insert a collapsed step LABEL whose DETAIL expands under KEY."
  (insert "  ")
  (let ((start (point)))
    (insert "▸ " label "\n")
    (let ((body-start (point)))
      (insert (or detail "") "\n")
      (emacs-claude--fold start body-start (point) key label))))

(defun emacs-claude--result-text (result)
  "Return bounded readable text of tool RESULT block."
  (let ((content (emacs-claude--get result "content")))
    (truncate-string-to-width
     (cond ((stringp content) content)
           ((vectorp content)
            (mapconcat (lambda (block) (or (emacs-claude--get block "text") "[image]"))
                       content "\n"))
           (t ""))
     4000 nil nil "…")))

(defun emacs-claude--visible-p (block)
  "Whether assistant BLOCK has anything to show."
  (pcase (emacs-claude--get block "type")
    ("text" (not (string-blank-p (or (emacs-claude--get block "text") ""))))
    ("thinking" (and emacs-claude-show-thinking
                     (not (string-blank-p (or (emacs-claude--get block "thinking") "")))))
    ("tool_use" t)))

(defun emacs-claude--insert-step (block)
  "Insert assistant BLOCK as one process step."
  (pcase (emacs-claude--get block "type")
    ("text" (insert "  " (emacs-claude--markdown
                          (string-trim (emacs-claude--get block "text")))
                    "\n"))
    ("thinking"
     (let ((thought (emacs-claude--get block "thinking")))
       (emacs-claude--insert-detail
        (concat "✻ Thinking: "
                (truncate-string-to-width
                 (replace-regexp-in-string "[\r\n]+" " " thought) 100 nil nil "…"))
        thought (format "thinking:%d" (cl-incf emacs-claude--detail-index)))))
    ("tool_use"
     (let* ((id (emacs-claude--get block "id"))
            (input (emacs-claude--get block "input"))
            (result (gethash id emacs-claude--results)))
       (emacs-claude--insert-detail
        (format "%s %s  %s"
                (cond ((null result) "●")
                      ((eq (emacs-claude--get result "is_error") t) "✗")
                      (t "✓"))
                (emacs-claude--get block "name")
                (emacs-claude--tool-summary input))
        (concat (format "Arguments: %s\n"
                        (truncate-string-to-width
                         (if (hash-table-p input) (emacs-claude--encode input) "")
                         4000 nil nil "…"))
                (when result
                  (format "Result:\n%s\n" (emacs-claude--result-text result))))
        (concat "tool:" id))))))

(defun emacs-claude--insert-turn (turn key active)
  "Insert TURN, a list of items starting at a user prompt, folded under KEY.
ACTIVE means Claude is still working on it."
  (let* ((user (and (eq (caar turn) 'user) (cdar turn)))
         (blocks (cl-loop for (kind . data) in turn
                          when (and (eq kind 'assistant) (emacs-claude--visible-p data))
                          collect data))
         (last (car (last blocks)))
         (final (and (not active) last
                     (equal (emacs-claude--get last "type") "text") last))
         (steps (if final (butlast blocks) blocks)))
    (when user
      (let ((start (point)))
        (insert (propertize "You: " 'face 'emacs-claude-user-face)
                (emacs-claude--markdown user))
        (when-let* ((images (cdr (assq 'images turn))))
          (insert "\n" (mapconcat #'emacs-claude--image-string images " ")))
        (unless (bolp) (insert "\n"))
        (let ((overlay (make-overlay start (point) nil t nil)))
          (overlay-put overlay 'face (emacs-claude--user-message-face))
          (push overlay emacs-claude--overlays))
        (insert "\n")))
    (when steps
      (let ((start (point))
            (label (format "Process · %d step%s" (length steps)
                           (if (cdr steps) "s" ""))))
        (insert "▸ " label "\n")
        (let ((body-start (point)))
          (mapc #'emacs-claude--insert-step steps)
          (emacs-claude--fold start body-start (point) (format "turn:%d" key)
                              label active))))
    (when final
      (insert (propertize "Claude: " 'face 'emacs-claude-assistant-face)
              (emacs-claude--markdown (string-trim (emacs-claude--get final "text")))
              "\n\n"))
    (cl-loop for (kind . data) in turn
             when (eq kind 'notice)
             do (insert (propertize (format "[Claude: %s]\n" data) 'face 'error)))))

(defun emacs-claude--insert-transcript ()
  "Insert the whole conversation at point."
  (let (turns turn)
    (dolist (item emacs-claude--items)  ; newest first, so turns build in order
      (push item turn)
      (when (eq (car item) 'user)
        (push turn turns)
        (setq turn nil)))
    (when turn (push turn turns))
    (cl-loop for (turn . rest) on turns
             for key from 0
             do (emacs-claude--insert-turn
                 turn key (and emacs-claude--running (null rest)))))
  (pcase emacs-claude--stream
    (`("text" . ,text)
     (insert (propertize "Claude: " 'face 'emacs-claude-assistant-face) text
             (propertize " ▍\n" 'face 'shadow)))
    (`("thinking" . ,text)
     (insert (propertize
              (format "  ✻ Thinking… %s\n"
                      (replace-regexp-in-string
                       "[\r\n]+" " "
                       (substring text (max 0 (- (length text) 80)))))
              'face 'shadow)))
    (`(,name . ,_)
     (insert (propertize (format "  ● %s …\n" name) 'face 'shadow))))
  ;; Images staged for the next prompt sit just above the composer.
  (cl-loop for (name . block) in (reverse emacs-claude--attachments)
           for index from 0
           do (insert "  " (emacs-claude--image-string block) " " name "  "
                      (propertize "×" 'emacs-claude-attachment index
                                  'keymap emacs-claude--attachment-map
                                  'mouse-face 'highlight
                                  'help-echo "mouse-1, RET: remove this image")
                      "\n")))

(defun emacs-claude--render ()
  "Redraw the transcript above the composer."
  ;; ponytail: full redraw each time, O(transcript); go incremental if a
  ;; very long session makes streaming feel slow.
  (when (and emacs-claude--input-marker (not emacs-claude--copy-mode))
    (unless (eq emacs-claude--running emacs-claude--fold-was-running)
      (clrhash emacs-claude--folds)
      (setq emacs-claude--fold-was-running emacs-claude--running))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (start (marker-position emacs-claude--input-marker))
           (position (point))
           (reading (< position start))
           (at-end (>= position (1- (emacs-claude--input-end)))))
      (mapc #'delete-overlay emacs-claude--overlays)
      (setq emacs-claude--overlays nil emacs-claude--detail-index 0)
      (save-excursion
        (delete-region (point-min) start)
        (goto-char (point-min))
        (emacs-claude--insert-transcript)
        (let ((end (marker-position emacs-claude--input-marker)))
          (add-text-properties (point-min) end '(read-only t rear-nonsticky nil))
          (when (< (point-min) end)
            (add-text-properties (point-min) (1+ (point-min))
                                 '(front-sticky (read-only))))))
      (move-overlay emacs-claude--input-background
                    (1+ (marker-position emacs-claude--input-marker)) (point-max))
      (cond (at-end (goto-char (emacs-claude--input-end)))
            (reading (goto-char (min position
                                     (marker-position emacs-claude--input-marker)))))
      (force-mode-line-update))))

(defun emacs-claude--schedule ()
  "Coalesce redraws, keep the spinner in step, and surface pending questions."
  (let ((buffer (current-buffer)))
    (unless emacs-claude--render-timer
      (setq emacs-claude--render-timer
            (run-at-time 0.05 nil
                         (lambda ()
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (setq emacs-claude--render-timer nil)
                               (emacs-claude--render)))))))
    (cond ((and emacs-claude--running (not emacs-claude--spinner-timer))
           (setq emacs-claude--spinner-timer
                 (run-at-time 0.15 0.15 #'force-mode-line-update t)))
          ((and emacs-claude--spinner-timer (not emacs-claude--running))
           (cancel-timer emacs-claude--spinner-timer)
           (setq emacs-claude--spinner-timer nil)))
    (when emacs-claude--pending (emacs-claude--ask-soon))
    (when (buffer-live-p emacs-claude--queue-buffer)
      (emacs-claude--queue-refresh emacs-claude--queue-buffer))))

;;;; Status lines

(defun emacs-claude--active-tool ()
  "Return the name of the tool Claude is waiting on in this turn, or nil."
  (cl-loop for (kind . data) in emacs-claude--items
           until (eq kind 'user)
           when (and (eq kind 'assistant)
                     (equal (emacs-claude--get data "type") "tool_use")
                     (not (gethash (emacs-claude--get data "id") emacs-claude--results)))
           return (emacs-claude--get data "name")))

(defun emacs-claude--state ()
  "Return Claude's activity for the mode line."
  (when emacs-claude--id
    (propertize
     (format " Claude %s%s%s"
             (cond ((> emacs-claude--replay-left 0) "syncing")
                   ((not (emacs-claude--alive-p emacs-claude--id)) "exited")
                   (emacs-claude--pending "waiting for you (C-c C-a)")
                   (emacs-claude--running
                    (format "%s %c"
                            (if-let* ((tool (emacs-claude--active-tool)))
                                (concat "tool: " tool)
                              "thinking")
                            (aref "|/-\\" (mod (floor (* 6 (float-time))) 4))))
                   (t "idle"))
             (if emacs-claude--queued
                 (format " [F%d]" (length emacs-claude--queued))
               "")
             (if emacs-claude--copy-mode " COPY" ""))
     'face 'emacs-claude-status-face)))

(defun emacs-claude--tokens (value)
  (cond ((>= value 1000000) (format "%.1fM" (/ value 1000000.0)))
        ((>= value 1000) (format "%.1fk" (/ value 1000.0)))
        (t (number-to-string value))))

(defun emacs-claude--header ()
  "Return context usage, cost and model for the tab line."
  (when emacs-claude--id
    (let* ((used (and emacs-claude--usage
                      (cl-loop for key in '("input_tokens" "cache_read_input_tokens"
                                            "cache_creation_input_tokens")
                               for value = (emacs-claude--get emacs-claude--usage key)
                               sum (if (numberp value) value 0))))
           (usage (emacs-claude--get emacs-claude--result "modelUsage"))
           (window (and (hash-table-p usage)
                        (cl-some (lambda (model)
                                   (emacs-claude--get model "contextWindow"))
                                 (hash-table-values usage))))
           (cost (emacs-claude--get emacs-claude--result "total_cost_usd"))
           (context (cond ((and used (numberp window) (> window 0))
                           (let ((percent (/ (* 100.0 used) window)))
                             (propertize
                              (format "%s/%s (%.0f%%)" (emacs-claude--tokens used)
                                      (emacs-claude--tokens window) percent)
                              'face (cond ((>= percent 95) 'error)
                                          ((>= percent 80) 'warning)))))
                          (used (emacs-claude--tokens used))
                          (t "context: —")))
           (left (string-join
                  (delq nil
                        (list context
                              (format "%d prompts"
                                      (cl-count 'user emacs-claude--items :key #'car))
                              (and (numberp cost) (format "$%.4f" cost))))
                  " · "))
           (right (format "%s · %s" (or emacs-claude--model "model pending")
                          (or emacs-claude--mode "—"))))
      (concat " " (replace-regexp-in-string "%" "%%" left)
              (propertize " " 'display
                          `(space :align-to (- right ,(1+ (string-width right)))))
              right))))

(defun emacs-claude--pinned ()
  "Return the latest user prompt for the header line."
  (when-let* ((prompt (cdr (assq 'user emacs-claude--items))))
    (truncate-string-to-width
     (replace-regexp-in-string
      "%" "%%" (concat " You: " (replace-regexp-in-string "[\r\n]+" " ↵ " prompt)))
     (max 10 (1- (window-width))) nil nil "…")))

;;;; Mode

(defun emacs-claude-return ()
  "Toggle a process heading or send the draft."
  (interactive)
  (if (emacs-claude--process-at-point)
      (emacs-claude-toggle-process)
    (emacs-claude-send)))

(defun emacs-claude-tab ()
  "Toggle a process heading or complete the draft."
  (interactive)
  (if (emacs-claude--process-at-point)
      (emacs-claude-toggle-process)
    (emacs-claude-complete)))

(defun emacs-claude-i ()
  "Insert i in the composer, or jump to the composer from the transcript."
  (interactive)
  (if (>= (point) (emacs-claude--input-beginning))
      (self-insert-command 1)
    (emacs-claude-focus-input)))

(defun emacs-claude-beginning-of-line ()
  "Move to line start without entering the composer prompt."
  (interactive)
  (let ((prompt-line (save-excursion (goto-char (emacs-claude--input-beginning))
                                     (line-beginning-position))))
    (move-beginning-of-line 1)
    (when (= (point) prompt-line)
      (goto-char (emacs-claude--input-beginning)))))

(defvar emacs-claude-copy-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-j") #'emacs-claude-semi-char-mode)
    (define-key map (kbd "i") #'emacs-claude-semi-char-mode)
    (define-key map (kbd "C-a") #'move-beginning-of-line)
    (define-key map (kbd "M-p") #'backward-paragraph)
    (define-key map (kbd "M-n") #'forward-paragraph)
    map)
  "Keys for reading and copying the frozen transcript.")

(defun emacs-claude-copy-mode ()
  "Freeze transcript updates for navigation and copying."
  (interactive)
  (setq emacs-claude--copy-mode t)
  (setq-local minor-mode-overriding-map-alist
              (list (cons 'emacs-claude--copy-mode emacs-claude-copy-mode-map)))
  (force-mode-line-update)
  (message "Copy mode; C-c C-j returns to input"))

(defun emacs-claude-semi-char-mode ()
  "Resume transcript updates and return to the composer."
  (interactive)
  (setq emacs-claude--copy-mode nil)
  (emacs-claude--render)
  (emacs-claude-focus-input))

(defvar emacs-claude-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-claude-return)
    (define-key map (kbd "C-c C-c") #'emacs-claude-send)
    (define-key map (kbd "S-<return>") #'newline)
    (define-key map (kbd "S-RET") #'newline)
    (define-key map (kbd "C-c C-s") #'emacs-claude-steer)
    (define-key map (kbd "C-c C-k") #'emacs-claude-stop)
    (define-key map (kbd "C-c C-l") #'emacs-claude-show-queue)
    (define-key map (kbd "C-c C-u") #'emacs-claude-show-queue)
    (define-key map (kbd "C-c C-r") #'emacs-claude-resume)
    (define-key map (kbd "C-c C-b") #'emacs-claude-switch-chat)
    (define-key map (kbd "C-c C-i") #'emacs-claude-focus-input)
    (define-key map (kbd "C-c C-t") #'emacs-claude-copy-mode)
    (define-key map (kbd "C-c C-j") #'emacs-claude-semi-char-mode)
    (define-key map (kbd "C-c C-a") #'emacs-claude-answer)
    (define-key map (kbd "C-c C-d") #'emacs-claude-detach)
    (define-key map (kbd "C-c C-q") #'emacs-claude-quit)
    (define-key map (kbd "C-c C-p") #'emacs-claude-paste)
    (define-key map (kbd "s-v") #'emacs-claude-paste)
    (define-key map (kbd "C-c C-o") #'emacs-claude-open-image)
    (define-key map (kbd "i") #'emacs-claude-i)
    (define-key map (kbd "M-p") #'emacs-claude-previous-prompt)
    (define-key map (kbd "M-n") #'emacs-claude-next-prompt)
    (define-key map (kbd "TAB") #'emacs-claude-tab)
    (define-key map (kbd "M-TAB") #'emacs-claude-complete)
    (define-key map (kbd "C-a") #'emacs-claude-beginning-of-line)
    map)
  "Local keys for the Claude chat buffer.")

(define-derived-mode emacs-claude-chat-mode fundamental-mode "emacs-claude"
  "Major mode for chatting with a detached Claude Code process."
  (setq-local truncate-lines nil)
  (setq-local buffer-invisibility-spec (copy-tree buffer-invisibility-spec))
  (add-to-invisibility-spec 'emacs-claude-process)
  (setq-local emacs-claude--folds (make-hash-table :test #'equal)
              emacs-claude--results (make-hash-table :test #'equal)
              emacs-claude--sent (make-hash-table :test #'equal)
              emacs-claude--callbacks (make-hash-table :test #'equal)
              emacs-claude--image-cache (make-hash-table :test #'eq :weakness 'key)
              emacs-claude--markdown-cache (make-hash-table :test #'equal))
  (tab-line-mode 1)
  (setq-local tab-line-format '(:eval (emacs-claude--header)))
  (setq-local header-line-format '(:eval (emacs-claude--pinned)))
  (setq-local mode-line-misc-info
              (cons '(:eval (emacs-claude--state)) mode-line-misc-info))
  (add-hook 'kill-buffer-hook #'emacs-claude--cleanup nil t))

(defun emacs-claude--cleanup ()
  "Drop this viewer.  The holder is deliberately left running."
  (when (process-live-p emacs-claude--tail) (delete-process emacs-claude--tail))
  ;; EOF rather than kill, so a prompt sent just before closing still arrives.
  (when (process-live-p emacs-claude--writer) (process-send-eof emacs-claude--writer))
  (when (buffer-live-p emacs-claude--receive) (kill-buffer emacs-claude--receive))
  (when (buffer-live-p emacs-claude--queue-buffer)
    (kill-buffer emacs-claude--queue-buffer))
  (dolist (timer (list emacs-claude--render-timer emacs-claude--spinner-timer
                       emacs-claude--ask-timer))
    (when timer (cancel-timer timer))))

;;;; Opening chats

(defun emacs-claude--chats ()
  "Return live chat buffers."
  (cl-remove-if-not (lambda (buffer) (buffer-local-value 'emacs-claude--id buffer))
                    (buffer-list)))

(defun emacs-claude--root-of (directory)
  "Return canonical local project root for DIRECTORY."
  (when (file-remote-p directory)
    (user-error "emacs-claude does not support remote directories"))
  (unless (file-directory-p directory)
    (user-error "Not a directory: %s" directory))
  (file-name-as-directory (file-truename (expand-file-name directory))))

(defun emacs-claude--open (id root)
  "Return a chat buffer attached to session ID in ROOT, starting it if needed."
  (let ((open (cl-find id (emacs-claude--chats) :test #'equal
                       :key (lambda (buffer) (buffer-local-value 'emacs-claude--id buffer)))))
    ;; A chat whose Claude has exited is reopened, which resumes it.
    (when (and open (not (emacs-claude--alive-p id)))
      (let ((draft (with-current-buffer open (emacs-claude--input-text))))
        (kill-buffer open)
        (setq open (emacs-claude--open id root))
        (with-current-buffer open (emacs-claude--input-set draft))))
    (or open
	(let ((buffer (generate-new-buffer
                       (format "*claude:%s#%s*"
                               (file-name-nondirectory (directory-file-name root))
                               (substring id 0 6)))))
          (unless (emacs-claude--alive-p id)
            (emacs-claude--start-holder id root))
          (with-current-buffer buffer
            (setq default-directory root)
            (emacs-claude-chat-mode)
            (setq emacs-claude--receive
                  (generate-new-buffer " *emacs-claude-receive*" t))
            (setq emacs-claude--id id emacs-claude--root root)
            (let ((prefix (propertize emacs-claude--composer-prefix 'read-only t)))
              (add-text-properties 0 1 '(front-sticky (read-only)) prefix)
              (add-text-properties (1- (length prefix)) (length prefix)
                                   '(rear-nonsticky (read-only)) prefix)
              (insert prefix)
              (save-excursion
		(insert (propertize "\n" 'read-only t 'rear-nonsticky '(read-only)))))
            (setq emacs-claude--input-marker (copy-marker (point-min) t)
                  emacs-claude--input-background
                  (make-overlay (1+ (point-min)) (point-max) nil t t))
            (overlay-put emacs-claude--input-background 'face 'emacs-claude-input-face)
            (setq buffer-undo-list nil)
            ;; What a resumed holder's log cannot show comes from the transcript.
            (let ((meta (emacs-claude--meta id))
                  (transcript (emacs-claude--transcript-file id root))
                  (log (emacs-claude--file id "out.jsonl"))
                  (sent (emacs-claude--file id "sent.jsonl")))
              (when (file-readable-p sent)
		(with-temp-buffer
                  (insert-file-contents sent)
                  (let ((table (buffer-local-value 'emacs-claude--sent buffer)))
                    (while (not (eobp))
                      (when-let* ((record (ignore-errors
                                            (emacs-claude--parse
                                             (buffer-substring (point)
                                                               (line-end-position))))))
			(puthash (emacs-claude--get record "uuid")
				 (emacs-claude--get record "content") table))
                      (forward-line 1)))))
              (when (and (eq (emacs-claude--get meta "resumed") t)
			 (file-readable-p transcript))
		(emacs-claude--load-history transcript
                                            (emacs-claude--get meta "started")))
              (setq emacs-claude--replay-left
                    (file-attribute-size (file-attributes log))
                    emacs-claude--tail
                    (make-process
                     :name "emacs-claude-tail" :noquery t :connection-type 'pipe
                     :coding 'utf-8-unix
                     :command (list "tail" "-c" "+1" "-f" log)
                     :filter (lambda (_process chunk)
                               (emacs-claude--filter buffer chunk)))))
            (emacs-claude--schedule))
          buffer))))

(defun emacs-claude--show (buffer)
  "Display chat BUFFER alone in the frame, ready for input."
  (switch-to-buffer buffer)
  (delete-other-windows)
  (emacs-claude-focus-input))

(defun emacs-claude--file-prompts (file)
  "Return (FIRST LAST LAST-TIME CWD) of the user prompts in transcript FILE.
Only the head and tail of a large file are read."
  (let ((size (file-attribute-size (file-attributes file)))
        (chunk (* 256 1024))
        first last stamp cwd)
    (cl-flet ((scan (begin end)
                (with-temp-buffer
                  (insert-file-contents file nil begin end)
                  (while (not (eobp))
                    (let ((line (buffer-substring (point) (line-end-position))))
                      (when (string-search "\"type\":\"user\"" line)
                        (when-let* ((event (ignore-errors (emacs-claude--parse line)))
                                    (text (emacs-claude--prompt-text event)))
                          (unless (string-prefix-p "[Request interrupted" text)
                            (unless first (setq first text))
                            (setq last text
                                  cwd (emacs-claude--get event "cwd")
                                  stamp (emacs-claude--get event "timestamp"))))))
                    (forward-line 1)))))
      (scan 0 (min size chunk))
      (when (> size chunk) (scan (max chunk (- size chunk)) size)))
    (list first last stamp cwd)))

(defun emacs-claude--sessions (&optional root)
  "Return saved sessions as plists, most recent prompt first.
With ROOT only that project's sessions, otherwise those of every project."
  ;; ponytail: rescans transcript heads and tails on every call; cache by
  ;; mtime if the all-projects picker gets slow.
  (let ((projects (expand-file-name "projects" emacs-claude-config-directory)))
    (sort
     (cl-loop for directory in
              (cond (root (list (file-name-directory
                                 (emacs-claude--transcript-file "x" root))))
                    ((file-directory-p projects)
                     (directory-files projects t "\\`[^.]")))
              append
              (cl-loop for file in (and (file-directory-p directory)
                                        (directory-files directory t "\\.jsonl\\'"))
                       for (first last stamp cwd) = (emacs-claude--file-prompts file)
                       when first
                       collect (list :id (file-name-base file) :file file
                                     :cwd cwd :first first :last last
                                     :stamp stamp)))
     (lambda (a b) (string> (or (plist-get a :stamp) "")
                            (or (plist-get b :stamp) ""))))))

(defvar vertico-group-format)

(defun emacs-claude--column (text width &optional face)
  "Make TEXT a one-line column of display WIDTH, optionally in FACE."
  (let ((column (truncate-string-to-width
                 (string-trim (replace-regexp-in-string "[[:space:]]+" " " (or text "—")))
                 width nil ?\s "…")))
    (if face (propertize column 'face face) column)))

(defun emacs-claude--middle-truncate (value width)
  "Shorten VALUE to WIDTH, keeping its beginning and end."
  (let ((total (string-width value)))
    (if (<= total width)
        value
      (let* ((head (/ width 2)) (tail (- width head 1)))
        (concat (truncate-string-to-width value head) "…"
                (truncate-string-to-width value total (- total tail)))))))

(defun emacs-claude--pick (sessions prompt &optional new-label project)
  "Choose among SESSIONS with PROMPT; return a plist, or `new' for NEW-LABEL.
Columns follow emacs-pi: last user time | first query | last query |
project (with PROJECT, on wide frames) | ID, under a header row."
  (let* ((width (- (window-body-width (minibuffer-window)) 4))
         (ids (mapcar (lambda (session) (plist-get session :id)) sessions))
         (id-width 12)
         (_ (while (< (length (delete-dups
                                (mapcar (lambda (id) (substring id 0 (min id-width (length id))))
                                        ids)))
                      (length ids))
              (cl-incf id-width)))
         (project-width (if (and project (>= width 120)) (min 30 (/ width 6)) 0))
         (query-space (max 12 (- width 16 id-width 9
                                 (if (> project-width 0) (+ project-width 3) 0))))
         (first-width (/ query-space 2))
         (row (lambda (time first last cwd id &optional heading)
                (string-join
                 (append
                  (list (emacs-claude--column time 16)
                        (emacs-claude--column first first-width)
                        (emacs-claude--column last (- query-space first-width)))
                  (when (> project-width 0)
                    (list (emacs-claude--column
                           (emacs-claude--middle-truncate
                            (if cwd (abbreviate-file-name cwd) "—") project-width)
                           project-width (unless heading 'shadow))))
                  (list (emacs-claude--column
                         (substring id 0 (min id-width (length id)))
                         id-width (unless heading 'shadow))))
                 (propertize " │ " 'face 'shadow))))
         (header (funcall row "最后交互" "用户首句" "用户末句" "项目" "ID" t))
         (choices
          (append
           (and new-label (list (cons new-label 'new)))
           (mapcar
            (lambda (session)
              (let ((id (plist-get session :id)))
                (cons (concat
                       (funcall row
                                (if-let* ((stamp (plist-get session :stamp)))
                                    (format-time-string "%Y-%m-%d %H:%M"
                                                        (date-to-time stamp))
                                  "—")
                                (plist-get session :first) (plist-get session :last)
                                (plist-get session :cwd) id)
                       (if (emacs-claude--alive-p id)
                           (propertize " ● running" 'face 'success)
                         ""))
                      session)))
            sessions)))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata (category . emacs-claude-session)
                                 (display-sort-function . identity)
                                 (cycle-sort-function . identity)
                                 (group-function
                                  . ,(lambda (candidate transform)
                                       (if transform candidate header))))
                    (complete-with-action action choices string predicate))))
         ;; The header is a column row, not a Vertico group title.
         (vertico-group-format "%s")
         (completion-ignore-case t)
         (completion-styles (if (memq 'substring completion-styles)
                                completion-styles
                              (append completion-styles '(substring)))))
    (cdr (assoc (completing-read prompt table nil t) choices))))

;;;###autoload
(defun emacs-claude-chat (root)
  "Chat with Claude Code in ROOT: continue a saved session or start one."
  (interactive (list (read-directory-name "Claude project: ")))
  (let* ((root (emacs-claude--root-of root))
         (sessions (emacs-claude--sessions root))
         (choice (if sessions
                     (emacs-claude--pick sessions "Session: " "+ New session")
                   'new)))
    (emacs-claude--show
     (emacs-claude--open (if (eq choice 'new) (emacs-claude--uuid)
                           (plist-get choice :id))
                         root))))

(defun emacs-claude-new-session ()
  "Start another session in this chat's project."
  (interactive)
  (emacs-claude--show
   (emacs-claude--open (emacs-claude--uuid)
                       (or emacs-claude--root
                           (emacs-claude--root-of default-directory)))))

;;;###autoload
(defun emacs-claude-resume ()
  "Resume a saved session of this project; attach if it is still running."
  (interactive)
  (let* ((root (or emacs-claude--root
                   (emacs-claude--root-of (read-directory-name "Claude project: "))))
         (session (emacs-claude--pick
                   (or (emacs-claude--sessions root)
                       (user-error "No saved sessions for %s" root))
                   "Resume: ")))
    (emacs-claude--show (emacs-claude--open (plist-get session :id) root))))

;;;###autoload
(defun emacs-claude-attach ()
  "Open a Claude that is still running in the background, in any project."
  (interactive)
  (let* ((instances (expand-file-name "instances" emacs-claude-directory))
         (running
          (cl-loop for id in (and (file-directory-p instances)
                                  (directory-files instances nil "\\`[^.]"))
                   for root = (emacs-claude--get (emacs-claude--meta id) "root")
                   when (and root (emacs-claude--alive-p id))
                   collect (cons (format "%s  %s" (substring id 0 8)
                                         (abbreviate-file-name root))
                                 (cons id root))))
         (choice (cdr (assoc (completing-read
                              "Running Claude: "
                              (or running (user-error "No Claude is running"))
                              nil t)
                             running))))
    (emacs-claude--show (emacs-claude--open (car choice) (cdr choice)))))

(defun emacs-claude-switch-chat ()
  "Switch to another open Claude chat."
  (interactive)
  (emacs-claude--show
   (completing-read "Chat: " (mapcar #'buffer-name (emacs-claude--chats)) nil t)))

;;;; Session commands

(defun emacs-claude-detach ()
  "Close this chat; Claude keeps running and can be resumed later."
  (interactive)
  (kill-buffer))

(defun emacs-claude-quit ()
  "Stop this chat's Claude process and close the chat."
  (interactive)
  (let ((pid (emacs-claude--pid emacs-claude--id)))
    (when (and emacs-claude--running (emacs-claude--alive-p emacs-claude--id)
               (not (y-or-n-p "Claude is still working.  Stop it? ")))
      (user-error "Kept running; C-c C-d closes only the chat"))
    (when (emacs-claude--alive-p emacs-claude--id)
      (signal-process pid 'SIGTERM))
    (kill-buffer)))

(defun emacs-claude-select-model ()
  "Choose the model for the following turns."
  (interactive)
  (let* ((models (mapcar (lambda (model)
                           (cons (format "%-22s %-26s %s"
                                         (emacs-claude--get model "displayName")
                                         (emacs-claude--get model "resolvedModel")
                                         (or (emacs-claude--get model "description") ""))
                                 model))
                         (append emacs-claude--models nil)))
         (model (cdr (assoc (completing-read
                             "Model: "
                             (or models (user-error "Models not reported yet"))
                             nil t)
                            models))))
    (emacs-claude--control "set_model" "model" (emacs-claude--get model "value"))
    (setq emacs-claude--model (emacs-claude--get model "resolvedModel"))
    (force-mode-line-update)))

(defun emacs-claude-select-permission-mode ()
  "Choose how Claude asks before using tools."
  (interactive)
  (emacs-claude--control
   "set_permission_mode" "mode"
   (completing-read "Permission mode: "
                    '("default" "acceptEdits" "plan" "auto" "dontAsk"
                      "bypassPermissions")
                    nil t)))

;;;; Queue editing

(defvar-local emacs-claude--queue-chat nil)
(defvar-local emacs-claude--queue-staged nil
  "Queue as edited here: plists (:uuid :content :deleted :edited), in order.")
(defvar-local emacs-claude--queue-dirty nil)

(defvar emacs-claude-queue-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "RET") #'emacs-claude-queue-edit)
    (define-key map (kbd "d") #'emacs-claude-queue-delete)
    (define-key map (kbd "M-<up>") #'emacs-claude-queue-move-up)
    (define-key map (kbd "M-<down>") #'emacs-claude-queue-move-down)
    (define-key map (kbd "x") #'emacs-claude-queue-apply)
    (define-key map (kbd "g") #'emacs-claude-queue-revert)
    (define-key map (kbd "q") #'kill-buffer-and-window)
    map))

(define-derived-mode emacs-claude-queue-mode special-mode "claude-queue"
  "Review, edit, reorder and delete the prompts Claude has not started yet.")

(defun emacs-claude--queue-render ()
  "Redraw the staged queue, keeping point on its line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize
             "RET edit · d delete · M-↑/M-↓ move · x apply · g refresh · q quit\n\n"
             'face 'shadow))
    (unless emacs-claude--queue-staged (insert "No queued prompts.\n"))
    (cl-loop
     for entry in emacs-claude--queue-staged
     for index from 1
     for content = (plist-get entry :content)
     for images = (length (emacs-claude--content-images content))
     do (insert
         (propertize
          (format "%2d. %s%s%s%s\n" index
                  (if (plist-get entry :deleted) "[delete] " "")
                  (if (plist-get entry :edited) "[edited] " "")
                  (if content
                      (truncate-string-to-width
                       (replace-regexp-in-string
                        "[\r\n]+" " ↵ " (emacs-claude--content-text content))
                       100 nil nil "…")
                    "(sent from another client)")
                  (if (> images 0) (format "  [%d image%s]" images
                                           (if (> images 1) "s" ""))
                    ""))
          'emacs-claude-entry entry
          'face (and (plist-get entry :deleted) 'shadow))))
    (when emacs-claude--queue-dirty
      (insert "\n" (propertize "Staged changes are not applied yet; press x.\n"
                               'face 'warning)))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun emacs-claude--queue-refresh (buffer &optional force)
  "Reload queue BUFFER from its chat unless edits are staged, or FORCE."
  (with-current-buffer buffer
    (let ((chat emacs-claude--queue-chat))
      (when (and (buffer-live-p chat)
                 (or force
                     (and (not emacs-claude--queue-dirty)
                          (not (equal (buffer-local-value 'emacs-claude--queued chat)
                                      (mapcar (lambda (entry) (plist-get entry :uuid))
                                              emacs-claude--queue-staged))))))
        (setq emacs-claude--queue-dirty nil
              emacs-claude--queue-staged
              (mapcar (lambda (uuid)
                        (list :uuid uuid
                              :content (gethash uuid (buffer-local-value
                                                      'emacs-claude--sent chat))
                              :deleted nil :edited nil))
                      (buffer-local-value 'emacs-claude--queued chat)))
        (emacs-claude--queue-render)))))

(defun emacs-claude-show-queue ()
  "Show the prompts waiting to run, for editing."
  (interactive)
  (let ((chat (current-buffer)))
    (unless (buffer-live-p emacs-claude--queue-buffer)
      (setq emacs-claude--queue-buffer
            (generate-new-buffer
             (format "*claude-queue:%s*" (substring emacs-claude--id 0 6))))
      (with-current-buffer emacs-claude--queue-buffer
        (emacs-claude-queue-mode)
        (setq emacs-claude--queue-chat chat)))
    (emacs-claude--queue-refresh emacs-claude--queue-buffer t)
    (pop-to-buffer emacs-claude--queue-buffer)))

(defun emacs-claude--queue-entry ()
  "Return the staged entry on this line."
  (or (get-text-property (line-beginning-position) 'emacs-claude-entry)
      (user-error "No queued prompt on this line")))

(defun emacs-claude--queue-changed ()
  (setq emacs-claude--queue-dirty t)
  (emacs-claude--queue-render))

(defun emacs-claude-queue-delete ()
  "Stage or unstage deleting the prompt on this line."
  (interactive)
  (let ((entry (emacs-claude--queue-entry)))
    (plist-put entry :deleted (not (plist-get entry :deleted)))
    (emacs-claude--queue-changed)))

(defun emacs-claude--queue-move (delta)
  "Stage moving the prompt on this line by DELTA places."
  (let* ((entry (emacs-claude--queue-entry))
         (from (cl-position entry emacs-claude--queue-staged))
         (to (+ from delta)))
    (unless (< -1 to (length emacs-claude--queue-staged))
      (user-error "Cannot move further"))
    (cl-rotatef (nth from emacs-claude--queue-staged)
                (nth to emacs-claude--queue-staged))
    (emacs-claude--queue-changed)
    (forward-line delta)))

(defun emacs-claude-queue-move-up ()
  "Stage running the prompt on this line earlier."
  (interactive)
  (emacs-claude--queue-move -1))

(defun emacs-claude-queue-move-down ()
  "Stage running the prompt on this line later."
  (interactive)
  (emacs-claude--queue-move 1))

(defun emacs-claude-queue-revert ()
  "Discard staged changes and reload the queue."
  (interactive)
  (emacs-claude--queue-refresh (current-buffer) t))

(defun emacs-claude-queue-edit ()
  "Edit the text of the prompt on this line in its own buffer.
Its images are kept.  C-c C-c stages the edit, C-c C-k discards it."
  (interactive)
  (let* ((entry (emacs-claude--queue-entry))
         (queue (current-buffer))
         (content (or (plist-get entry :content)
                      (user-error "This Emacs does not know that prompt's text")))
         (images (mapcar (lambda (block) (cons "image" block))
                         (reverse (emacs-claude--content-images content))))
         (map (make-sparse-keymap)))
    (pop-to-buffer (generate-new-buffer "*claude-queue-edit*"))
    (text-mode)
    (insert (emacs-claude--content-text content))
    (goto-char (point-min))
    (setq header-line-format " C-c C-c: stage this edit    C-c C-k: discard")
    (set-keymap-parent map (current-local-map))
    (define-key map (kbd "C-c C-k") #'kill-buffer-and-window)
    (define-key map (kbd "C-c C-c")
                (lambda ()
                  (interactive)
                  (let ((text (string-trim (buffer-string))))
                    (when (and (string-empty-p text) (null images))
                      (user-error "Empty prompt; use d in the queue to delete it"))
                    (kill-buffer-and-window)
                    (when (buffer-live-p queue)
                      (pop-to-buffer queue)
                      (plist-put entry :content
                                 (emacs-claude--content
                                  (emacs-claude--expand-references text) images))
                      (plist-put entry :edited t)
                      (emacs-claude--queue-changed)))))
    (use-local-map map)))

(defun emacs-claude-queue-apply ()
  "Write the staged queue back to Claude.
Claude can only withdraw a queued prompt, so every prompt from the first
difference on is withdrawn and sent again in the staged order.  A prompt
that started running meanwhile is left alone."
  (interactive)
  (let ((staged emacs-claude--queue-staged)
        (chat emacs-claude--queue-chat))
    (unless (buffer-live-p chat) (user-error "The chat is closed"))
    (setq emacs-claude--queue-dirty nil)
    (with-current-buffer chat
      (let* ((remote emacs-claude--queued)
             (known (mapcar (lambda (entry) (plist-get entry :uuid)) staged))
             ;; Wanted order: what is staged and still queued, then anything
             ;; that joined the queue after this window loaded it.
             (target
              (append
               (cl-remove-if (lambda (entry)
                               (or (plist-get entry :deleted)
                                   (not (member (plist-get entry :uuid) remote))))
                             staged)
               (cl-loop for uuid in remote
                        unless (member uuid known)
                        collect (list :uuid uuid
                                      :content (gethash uuid emacs-claude--sent)))))
             (lost 0))
        (while (and remote target
                    (equal (car remote) (plist-get (car target) :uuid))
                    (not (plist-get (car target) :edited)))
          (pop remote)
          (pop target))
        (when (cl-some (lambda (entry) (null (plist-get entry :content))) target)
          (user-error "Cannot resend a prompt sent from another client; leave it in place"))
        (if (null remote)
            (message "Queue already matches")
          (let ((waiting (length remote)))
            (dolist (uuid remote)
              (emacs-claude--control-then
               (lambda (response)
                 (unless (eq (emacs-claude--get response "cancelled") t)
                   (cl-incf lost)
                   (setq target (cl-remove uuid target :test #'equal
                                           :key (lambda (entry)
                                                  (plist-get entry :uuid)))))
                 (when (zerop (cl-decf waiting))
                   (dolist (entry target)
                     (emacs-claude--submit (plist-get entry :content)))
                   (message "Queue updated%s"
                            (if (> lost 0)
                                (format "; %d prompt(s) had already started" lost)
                              ""))))
               "cancel_async_message" "message_uuid" uuid))))))))

(defun emacs-claude-copy-last-response ()
  "Copy Claude's most recent reply as Markdown."
  (interactive)
  (kill-new
   (or (cl-loop for (kind . data) in emacs-claude--items
                when (and (eq kind 'assistant)
                          (equal (emacs-claude--get data "type") "text"))
                return (emacs-claude--get data "text"))
       (user-error "No reply yet")))
  (message "Copied"))

(defun emacs-claude-help ()
  "List client commands, Claude's own commands, and where to look on failure."
  (interactive)
  (let ((choices (emacs-claude--slash-choices))
        (errors (emacs-claude--file emacs-claude--id "err")))
    (with-output-to-temp-buffer "*claude-help*"
      (princ "C-c C-d detaches (Claude keeps running); C-c C-q stops Claude.\n")
      (princ (format "Claude's stderr: %s\n\n" errors))
      (pcase-dolist (`(,name . ,description) choices)
        (princ (format "%-24s %s\n" name
                       (truncate-string-to-width
                        (replace-regexp-in-string "[\r\n]+" " " (or description ""))
                        90 nil nil "…")))))))

(provide 'emacs-claude)
;;; emacs-claude.el ends here
