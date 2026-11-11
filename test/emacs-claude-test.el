;;; emacs-claude-test.el --- Offline checks -*- lexical-binding: t; -*-

;; emacs -Q --batch -L MARKDOWN-MODE-DIR -L . -l test/emacs-claude-test.el \
;;   -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'emacs-claude)

(defconst emacs-claude-test--fake
  (expand-file-name "fake-claude.py"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun emacs-claude-test--wait (predicate)
  "Run timers and process output until PREDICATE holds."
  (with-timeout (15 (ert-fail "Timed out"))
    (while (not (funcall predicate))
      (accept-process-output nil 0.05))))

(ert-deftest emacs-claude-survives-detach ()
  "Claude keeps working without a chat buffer and catches a new one up."
  (let* ((tmp (file-name-as-directory (make-temp-file "emacs-claude-test" t)))
         (emacs-claude-directory (concat tmp "state/"))
         (emacs-claude-config-directory (concat tmp "config/"))
         (emacs-claude-executable emacs-claude-test--fake)
         (emacs-claude-extra-arguments nil)
         (root (concat tmp "project/"))
         (id (emacs-claude--uuid))
         buffer)
    (make-directory root)
    (unwind-protect
        (progn
          (setq buffer (emacs-claude--open id root))
          (with-current-buffer buffer
            (emacs-claude-test--wait (lambda () emacs-claude--models))
            (emacs-claude--input-set "hello")
            (emacs-claude-send)
            (emacs-claude-test--wait
             (lambda () (string-search "Claude: echo:hello" (buffer-string))))
            (should-not emacs-claude--running)
            (should-not emacs-claude--queued)
            (should (equal (emacs-claude--input-text) ""))
            ;; Leave while Claude is busy and about to ask for permission.
            (emacs-claude--input-set "perm please")
            (emacs-claude-send))
          (kill-buffer buffer)
          (should (emacs-claude--alive-p id))
          ;; A fresh viewer replays the past and answers the waiting request.
          (cl-letf (((symbol-function 'read-multiple-choice)
                     (lambda (&rest _) '(?y "yes"))))
            (setq buffer (emacs-claude--open id root))
            (with-current-buffer buffer
              (emacs-claude-test--wait
               (lambda () (string-search "Claude: perm:allow" (buffer-string))))
              (should (string-search "echo:hello" (buffer-string)))
              (should-not emacs-claude--pending)
              (emacs-claude-quit)))
          (emacs-claude-test--wait (lambda () (not (emacs-claude--alive-p id)))))
      (when-let* ((pid (emacs-claude--pid id)))
        (ignore-errors (signal-process pid 'SIGKILL)))
      (delete-directory tmp t))))

(defmacro emacs-claude-test--with-chat (&rest body)
  "Run BODY with a fake Claude; `id', `root' and `tmp' are bound."
  `(let* ((tmp (file-name-as-directory (make-temp-file "emacs-claude-test" t)))
          (emacs-claude-directory (concat tmp "state/"))
          (emacs-claude-config-directory (concat tmp "config/"))
          (emacs-claude-executable emacs-claude-test--fake)
          (emacs-claude-extra-arguments nil)
          (root (concat tmp "project/"))
          (id (emacs-claude--uuid)))
     (make-directory root)
     (unwind-protect (progn ,@body)
       (when-let* ((pid (emacs-claude--pid id)))
         (ignore-errors (signal-process pid 'SIGKILL)))
       (delete-directory tmp t))))

(defun emacs-claude-test--send (text)
  (emacs-claude--input-set text)
  (emacs-claude-send))

(ert-deftest emacs-claude-queue-survives-and-edits ()
  "The queue is rebuilt after reattaching and can be reordered and edited."
  (emacs-claude-test--with-chat
   (with-current-buffer (emacs-claude--open id root)
     (emacs-claude-test--wait (lambda () emacs-claude--models))
     (mapc #'emacs-claude-test--send '("slow a" "b" "c" "d"))
     (kill-buffer))
   (with-current-buffer (emacs-claude--open id root)
     (emacs-claude-test--wait (lambda () (= 3 (length emacs-claude--queued))))
     (let ((chat (current-buffer)))
       (save-window-excursion
         (emacs-claude-show-queue)
         ;; Known text proves `sent.jsonl' was read back.
         (should (search-forward " 3. d" nil t))
         (emacs-claude-queue-delete)
         (goto-char (point-min))
         (search-forward " 2. c")
         (emacs-claude-queue-move-up)
         (search-forward "b")
         (let ((entry (emacs-claude--queue-entry)))
           (plist-put entry :content "B2")
           (plist-put entry :edited t))
         (emacs-claude-queue-apply))
       (set-buffer chat))
     (emacs-claude-test--wait
      (lambda () (and (not emacs-claude--running) (null emacs-claude--queued)
                      (string-search "echo:B2" (buffer-string)))))
     (let ((text (buffer-string)))
       (should (< (string-search "echo:slow a" text) (string-search "echo:c" text)
                  (string-search "echo:B2" text)))
       (should-not (string-search "echo:d" text))
       (should-not (string-search "echo:b" text))))))

(ert-deftest emacs-claude-images-and-session-references ()
  "Images travel as blocks; @session context is sent but not shown."
  (emacs-claude-test--with-chat
   (let* ((old "11111111-2222-4333-8444-555555555555")
          (dir (concat emacs-claude-config-directory "projects/-other/"))
          (png (concat tmp "shot.png")))
     (make-directory dir t)
     (write-region
      (concat "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"old question\"},\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"/other\"}\n"
              "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"old answer\"}]}}\n")
      nil (concat dir old ".jsonl") nil 'silent)
     (let ((coding-system-for-write 'no-conversion))
       (write-region (unibyte-string 137 80 78 71 13 10 26 10 0 0) nil png nil 'silent))
     (should (equal (plist-get (car (emacs-claude--sessions)) :first) "old question"))
     (with-current-buffer (emacs-claude--open id root)
       (emacs-claude-test--wait (lambda () emacs-claude--models))
       (emacs-claude-attach-image png)
       (emacs-claude-test--send (format "look @[old](claude-session:%s)" old))
       (should-not emacs-claude--attachments)
       (emacs-claude-test--wait (lambda () (and (assq 'assistant emacs-claude--items)
                                                (not emacs-claude--running))))
       (let ((reply (emacs-claude--get (cdr (assq 'assistant emacs-claude--items)) "text")))
         (should (string-search "User: old question" reply))
         (should (string-search "Claude: old answer" reply))
         (should (string-suffix-p "+1 image" reply)))
       (should (equal (cdr (assq 'user emacs-claude--items))
                      (format "look @[old](claude-session:%s)" old)))
       (should (= 1 (length (cdr (assq 'images emacs-claude--items)))))
       (emacs-claude--render)
       (should (string-search "[image]" (buffer-string)))))))

(ert-deftest emacs-claude-large-prompt-round-trip ()
  "A multi-megabyte image prompt is written and its echo parsed quickly."
  (emacs-claude-test--with-chat
   (let ((png (concat tmp "big.png"))
         (coding-system-for-write 'no-conversion))
     (write-region (concat (unibyte-string 137 80 78 71 13 10 26 10)
                           (make-string (* 3 1024 1024) ?a))
                   nil png nil 'silent)
     (with-current-buffer (emacs-claude--open id root)
       (emacs-claude-test--wait (lambda () emacs-claude--models))
       (let ((emacs-claude-image-max-bytes (* 8 1024 1024))
             (start (float-time)))
         (emacs-claude-attach-image png)
         (emacs-claude-test--send "big")
         (emacs-claude-test--wait
          (lambda () (string-search "echo:big +1 image" (buffer-string))))
         (message "large prompt round trip: %.2fs" (- (float-time) start))
         (should (< (- (float-time) start) 5)))))))

(ert-deftest emacs-claude-reference-provider ()
  "TAB after @NAME inserts the file a registered provider returns."
  (emacs-claude-test--with-chat
   (let ((emacs-claude-reference-providers
          `(("ashub" . ,(lambda (r) (should (equal r root)) "/tmp/ref dir/a.md")))))
     (with-current-buffer (emacs-claude--open id root)
       (emacs-claude--input-set "see @ashub")
       (emacs-claude-complete)
       (should (equal (emacs-claude--input-text) "see @\"/tmp/ref dir/a.md\" "))
       (emacs-claude--input-set "@nothing")
       (cl-letf (((symbol-function 'read-file-name)
                  (lambda (&rest _) (concat root "src.el"))))
         (emacs-claude-complete))
       (should (equal (emacs-claude--input-text) "@src.el"))))))

;;; emacs-claude-test.el ends here
