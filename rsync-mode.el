;;; rsync-mode.el --- Rsync projects to remote machines  -*- lexical-binding: t; coding: utf-8 -*-

;; Copyright (C) 2020-2021 Ryan Pilgrim

;; Author: Ryan Pilgrim <ryan.z.pilgrim@gmail.com>
;; URL: https://github.com/r-zip/rsync-mode.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (spinner "1.7.1"))
;; Keywords: comm

;; rsync-mode requires at least GNU Emacs 27.1 and rsync 3.1.3,
;; protocol version 31.

;; rsync-mode is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; rsync-mode is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with rsync-mode.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; rsync-mode is an interface to the command line tool rsync,
;; implemented as an Emacs package, and oriented toward project-based
;; development. It includes a minor mode and stand-alone commands for
;; running rsync to synchronize a project to single or multiple hosts.

;;; Code:

(require 'spinner)
(require 'time-stamp)
(require 'subr-x)
(require 'seq)

(defgroup rsync nil
  "Convenient remote synchronization."
  :group 'convenience
  :prefix "rsync-"
  :link '(url-link "https://github.com/r-zip/rsync-mode"))

(defvar rsync-local-path nil
  "Local path to the project, as a string.")

(defvar rsync-remote-paths nil
  "Remote paths to the project as a list of strings.
Each path should have the form 'host:/path/to/project'.")

(defvar rsync-excluded-dirs nil)

;; to override, delete entry and save in dir-locals
(defcustom rsync-default-excluded-dirs nil
  "List of directories to exclude from all projects for rsync."
  :group 'rsync
  :type (list 'string))

(defcustom rsync-sync-on-save nil
  "Whether to activate a hook that synchronizes the project after each save."
  :group 'rsync
  :type 'boolean)

(defvar-local rsync-mode nil
  "Whether rsync-mode is enabled.")

(defvar-local rsync--process nil
  "Rsync process object.")

(defvar rsync--pending-sync nil
  "Flag to indicate if a sync request was made while another was in progress.")

(defvar-local rsync--spinner nil
  "Rsync spinner object.")

(defvar rsync--process-exit-hook nil
  "Closure defining the process cleanup code.")

(defconst rsync--lighter
  '(" rsync" (:eval (spinner-print rsync--spinner)))
  "The mode lighter.")

(defvar rsync-local-path nil
  "The path to the local repository to be rsync'ed to the remote.")

(defvar rsync-remote-paths nil
  "The paths to the remote repositories.
These must have the form hostname:path/to/repo (relative or absolute).")

(defun rsync--start-spinner ()
  "Create and start a spinner on this buffer."
  (message "rsync--start-spinner called")
  (when rsync-mode
    (unless rsync--spinner
      (setq rsync--spinner (spinner-create 'progress-bar-filled t)))
    (spinner-start rsync--spinner)))

(define-minor-mode rsync-mode
  "Toggle rsync mode."
  ;; The initial value
  :init-value nil
  ;; The indicator for the mode line
  :lighter rsync--lighter
  :group 'rsync
  (message "rsync-mode toggled: %s" (if rsync-mode "ON" "OFF"))
  (if (not rsync-remote-paths)
      (message "Failed to activate rsync-mode: No remote configuration for rsync-mode found in dir-locals.")
    (if (not rsync-mode)
        (remove-hook 'after-save-hook #'rsync-all t)
      ;; taken from the spinner readme: https://github.com/Malabarba/spinner.el
      (setq rsync--spinner nil)
      (setq rsync--process nil)
      (when rsync-sync-on-save
        (add-hook 'after-save-hook #'rsync-all 0 t)))))

(defun rsync--get-hostname (path)
  "Get the hostname from the remote path PATH."
  (let ((user-and-hostname (car (split-string path ":"))))
    (if (string-match-p "@" user-and-hostname)
        (cadr (split-string user-and-hostname "@"))
      user-and-hostname)))

(defun rsync--get-rsync-buffer-name (remote-path)
  "Generate the buffer name for the rsync process.
REMOTE-PATH is the path to the rsync destination."
  (format "*rsync to %s*"
          (rsync--get-hostname remote-path)))

(defun rsync--run-process-exit-hook (proc event)
  "Run the closure defined by the variable `rsync--process-exit-hook'.
PROC is the rsync process, which is present for call signature
compatibility only. EVENT is the description of the event that
changed the state of the rsync process."
  (funcall rsync--process-exit-hook proc event)
  (when rsync--pending-sync
    (setq rsync--pending-sync nil)
    (message "Processing queued sync request.")
    (rsync-all)))

(defun rsync--make-process-exit-hook (buffer)
  "Create function to clean up the spinner for BUFFER.
The created function will also message the user when the rsync
process is complete and forward abnormal event strings."
  (lambda (_ event)
    (message "rsync--make-process-exit-hook closure called: %s" event)
    (with-current-buffer buffer
      (when rsync-mode
        (spinner-stop rsync--spinner))
      (when rsync--process
        (delete-process rsync--process))
      (setq rsync--process nil))
    (if (not (string-equal event "finished\n"))
        (message "Rsync process received abnormal event %s" event)
      (message "Rsync complete."))))

(defun rsync--make-process-exit-hook (buffer)
  "Create function to clean up the spinner for BUFFER.
The created function will also message the user when the rsync
process is complete and forward abnormal event strings."
  (lambda (_ event)
    (with-current-buffer buffer
      (when rsync-mode
        (spinner-stop rsync--spinner))
      (when rsync--process
        (delete-process rsync--process))
      (setq rsync--process nil))
    (if (not (string-equal event "finished\n"))
        (message "Rsync process received abnormal event %s" event)
      (message "Rsync complete."))))

(defun rsync--build-args (remote-path excludes local-path &optional dry-run file)
  "Create an argument list to be passed to the rsync process.
If FILE is non-nil, only that file will be synced.
If DRY-RUN is t, rsync will be run in dry-run mode.
If EXCLUDES is non-nil, those directories will be excluded from
the synchronization.
LOCAL-PATH specifies the path to the local directory root, or the
local file, if FILE is non-nil.
REMOTE-PATH specifies the path to the remote repository."
  (message "rsync--build-args called: remote-path=%s dry-run=%s file=%s" remote-path (if dry-run "true" "false") (or file "nil"))
  (let ((remote-path (string-join
                      (mapcar
                       (lambda (x) (shell-quote-argument x))
                       (split-string remote-path ":"))
                      ":")))
    (seq-filter
     #'identity
     `(,(if file "-avR" "-av")
       ,(if dry-run "--dry-run" nil)
       ,@excludes
       ,(shell-quote-argument (if file (concat local-path "/./" file) local-path))
       ,remote-path))))

(defun rsync--get-excludes ()
  "Get excluded directories for rsync call.

Merges the list of RSYNC-EXCLUDED-DIRS with
RSYNC-DEFAULT-EXCLUDED-DIRS and deletes duplicates."
  (message "rsync--get-excludes called")
  (flatten-list
   (mapcar (lambda (x) (format "--exclude=%s" (shell-quote-argument x)))
           (delete-dups
            `(,@rsync-excluded-dirs
              ,@rsync-default-excluded-dirs)))))

(defun rsync--run (remote-path excludes local-path &optional dry-run file)
  "Synchronize the current project from LOCAL-PATH to REMOTE-PATH.
Exclude according to EXCLUDES and the variable
`rsync-default-excluded-dirs'. If DRY-RUN is t, call rsync with
the dry-run flag.

If FILE is non-nil, sync only that file. The path specified
by FILE is assumed to be relative to LOCAL-PATH."
  (message "rsync--run called: remote-path=%s local-path=%s dry-run=%s file=%s" remote-path local-path (if dry-run "true" "false") (or file "nil"))
  (if rsync--process
      (progn
        (message "Rsync already in progress, queuing sync request.")
        (setq rsync--pending-sync t))
    (progn
      (rsync--start-spinner)
      (setq rsync--process
            (apply
             #'start-process
             `("rsync"
               ,(rsync--get-rsync-buffer-name remote-path)
               "rsync"
               ,@(rsync--build-args remote-path excludes local-path dry-run file))))
      (with-current-buffer (rsync--get-rsync-buffer-name remote-path)
        (goto-char (point-max))
        (skip-chars-backward "\n[:space:]")
        (insert (concat "\n\n" (time-stamp-string) "\n")))
      (setq rsync--process-exit-hook (rsync--make-process-exit-hook (current-buffer)))
      (set-process-sentinel rsync--process #'rsync--run-process-exit-hook))))

(defun rsync-all (&optional dry-run file)
  "Synchronize the current project to all remote hosts.
If DRY-RUN is t, call rsync with the dry-run flag.

If FILE is non-nil, sync only that file. The path specified
by FILE is assumed to be relative to RSYNC-LOCAL-PATH."
  (interactive)
  (message "rsync-all called: dry-run=%s file=%s" (if dry-run "true" "false") (or file "nil"))
  (unless rsync-remote-paths
    (error "No remote paths configured for rsync"))
  (setq rsync--pending-sync nil) ; Reset the pending sync flag
  (dolist (remote-path rsync-remote-paths)
    (condition-case err
        (rsync--run
         remote-path
         (rsync--get-excludes)
         rsync-local-path
         dry-run
         file)
      (error (message "Error during rsync to %s: %s" remote-path (error-message-string err))))))

(defun rsync--select-remote ()
  "Interactively select the remote for synchronization.
REMOTE is the selected remote host."
  (interactive)
  (message "rsync--select-remote called")
  (completing-read "Rsync project to: " rsync-remote-paths nil t))

(defun rsync (&optional dry-run file)
  "Synchronize the current project to a single remote host.
The host is selected interactively by the function
`rsync--select-remote'. If DRY-RUN is t, call rsync with the
dry-run flag.

If FILE is non-nil, sync only that file. The path specified
by FILE is assumed to be relative to RSYNC-LOCAL-PATH."
  (interactive)
  (message "rsync called: dry-run=%s file=%s" (if dry-run "true" "false") (or file "nil"))
  (let ((selected-remote (call-interactively #'rsync--select-remote)))
    (rsync--run selected-remote (rsync--get-excludes) rsync-local-path dry-run file)))

(provide 'rsync-mode)
;;; rsync-mode.el ends here
