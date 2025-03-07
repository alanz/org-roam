;;; org-roam.el --- Roam Research replica with Org-mode -*- coding: utf-8; lexical-binding: t -*-

;; Copyright © 2020 Jethro Kuan <jethrokuan95@gmail.com>

;; Author: Jethro Kuan <jethrokuan95@gmail.com>
;; URL: https://github.com/jethrokuan/org-roam
;; Keywords: org-mode, roam, convenience
;; Version: 0.1.2
;; Package-Requires: ((emacs "26.1") (dash "2.13") (f "0.17.2") (s "1.12.0") (org "9.0") (emacsql "3.0.0") (emacsql-sqlite "1.0.0"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; This library is an attempt at injecting Roam functionality into Org-mode.
;; This is achieved primarily through building caches for forward links,
;; backward links, and file titles.
;;
;;
;;; Code:

(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'dash)
(require 's)
(require 'f)
(require 'cl-lib)
(require 'org-roam-db)
(require 'org-roam-utils)
(require 'xml)

;;; Customizations
(defgroup org-roam nil
  "Roam Research replica in Org-mode."
  :group 'org
  :prefix "org-roam-"
  :link '(url-link :tag "Github" "https://github.com/jethrokuan/org-roam")
  :link '(url-link :tag "Online Manual" "https://org-roam.readthedocs.io/"))

(defgroup org-roam-faces nil
  "Faces used by Org-Roam."
  :group 'org-roam
  :group 'faces)

(defcustom org-roam-new-file-directory nil
  "Path to where new Org-roam files are created.
If nil, default to the org-roam-directory (preferred)."
  :type 'directory
  :group 'org-roam)

(defcustom org-roam-buffer-position 'right
  "Position of `org-roam' buffer.
Valid values are
 * left,
 * right."
  :type '(choice (const left)
                 (const right))
  :group 'org-roam)

(defcustom org-roam-link-title-format "%s"
  "The format string used when inserting org-roam links that use their title."
  :type 'string
  :group 'org-roam)

(defcustom org-roam-filename-noconfirm t
  "Whether to prompt for confirmation of filename for new files.
If nil, always ask for filename."
  :type 'boolean
  :group 'org-roam)

(defcustom org-roam-buffer-width 0.33 "Width of `org-roam' buffer."
  :type 'number
  :group 'org-roam)

(defcustom org-roam-buffer "*org-roam*"
  "Org-roam buffer name."
  :type 'string
  :group 'org-roam)

(defcustom org-roam-encrypt-files nil
  "Whether to encrypt new files. If true, create files with .org.gpg extension."
  :type 'boolean
  :group 'org-roam)

(defcustom org-roam-graph-viewer (executable-find "firefox")
  "Path to executable for viewing SVG."
  :type 'string
  :group 'org-roam)

(defcustom org-roam-graphviz-executable (executable-find "dot")
  "Path to graphviz executable."
  :type 'string
  :group 'org-roam)

(defcustom org-roam-graph-max-title-length 100
  "Maximum length of titles in Graphviz graph nodes."
  :type 'number
  :group 'org-roam)

(defcustom org-roam-graph-node-shape "ellipse"
  "Shape of Graphviz nodes."
  :type 'string
  :group 'org-roam)

;;; Dynamic variables
(defvar org-roam--current-buffer nil
  "Currently displayed file in `org-roam' buffer.")

(defvar org-roam-last-window nil
  "Last window `org-roam' was called from.")

;;; Utilities
(defun org-roam--list-files (dir)
  "Return all Org-roam files located within DIR, at any nesting level.
Ignores hidden files and directories."
  (if (file-exists-p dir)
      (let ((files (directory-files dir t "." t))
            (dir-ignore-regexp (concat "\\(?:"
                                       "\\."
                                       "\\|\\.\\."
                                       "\\)$"))
            result)
        (dolist (file files)
          (cond
           ((file-directory-p file)
            (when (not (string-match dir-ignore-regexp file))
              (setq result (append (org-roam--list-files file) result))))
           ((and (file-readable-p file)
                 (org-roam--org-file-p file))
            (setq result (cons (file-truename file) result)))))
        result)))

(defun org-roam--extract-links (&optional file-path)
  "Extracts all link items within the current buffer.
Link items are of the form:

    [file-from file-to properties]

This is the format that emacsql expects when inserting into the database.
FILE-FROM is typically the buffer file path, but this may not exist, for example
in temp buffers. In cases where this occurs, we do know the file path, and pass
it as FILE-PATH."
  (let ((file-path (or file-path
                       (file-truename (buffer-file-name (current-buffer))))))
    (org-element-map (org-element-parse-buffer) 'link
      (lambda (link)
        (let ((type (org-element-property :type link))
              (path (org-element-property :path link))
              (start (org-element-property :begin link)))
          (when (and (string= type "file")
                     (org-roam--org-file-p path))
            (goto-char start)
            (let* ((element (org-element-at-point))
                   (begin (or (org-element-property :content-begin element)
                              (org-element-property :begin element)))
                   (content (or (org-element-property :raw-value element)
                                (buffer-substring
                                 begin
                                 (or (org-element-property :content-end element)
                                     (org-element-property :end element)))))
                   (content (string-trim content)))
              (vector file-path
                      (file-truename (expand-file-name path (file-name-directory file-path)))
                      (list :content content :point begin)))))))))

(defun org-roam--extract-global-props (props)
  "Extract PROPS from the current org buffer.
The search terminates when the first property is encountered."
  (let ((buf (org-element-parse-buffer))
        res)
    (dolist (prop props)
      (let ((p (org-element-map buf 'keyword
                 (lambda (kw)
                   (when (string= (org-element-property :key kw) prop)
                     (org-element-property :value kw)))
                 :first-match t)))
        (push (cons prop p) res)))
    res))

(defun org-roam--extract-titles ()
  "Extract the titles from current buffer.
Titles are obtained via the #+TITLE property, or aliases
specified via the #+ROAM_ALIAS property."
  (let* ((props (org-roam--extract-global-props '("TITLE" "ROAM_ALIAS")))
         (aliases (cdr (assoc "ROAM_ALIAS" props)))
         (title (cdr (assoc "TITLE" props)))
         (alias-list (org-roam--aliases-str-to-list aliases)))
    (if title
        (cons title alias-list)
      alias-list)))

(defun org-roam--extract-ref ()
  "Extract the ref from current buffer."
  (cdr (assoc "ROAM_KEY" (org-roam--extract-global-props '("ROAM_KEY")))))

(defun org-roam--db-insert-links (links)
  "Insert LINK into the org-roam cache."
  (org-roam-sql
   [:insert :into file-links
    :values $v1]
   links))

(defun org-roam--db-insert-titles (file titles)
  "Insert TITLES into the org-roam-cache."
  (org-roam-sql
   [:insert :into titles
    :values $v1]
   (list (vector file titles))))

(defun org-roam--db-insert-ref (file ref)
  "Insert REF into the Org-roam cache."
  (org-roam-sql
   [:insert :into refs
    :values $v1]
   (list (vector ref file))))

(defun org-roam--db-clear ()
  "Clears all entries in the caches."
  (interactive)
  (when (file-exists-p (org-roam--get-db))
    (org-roam-sql [:delete :from files])
    (org-roam-sql [:delete :from titles])
    (org-roam-sql [:delete :from file-links])
    (org-roam-sql [:delete :from files])
    (org-roam-sql [:delete :from refs])))

(defun org-roam--db-clear-file (&optional filepath)
  "Remove any related links to the file at FILEPATH.
This is equivalent to removing the node from the graph."
  (let* ((path (or filepath
                   (buffer-file-name (current-buffer))))
         (file (file-truename path)))
    (org-roam-sql [:delete :from files
                   :where (= file $s1)]
                  file)
    (org-roam-sql [:delete :from file-links
                   :where (= file-from $s1)]
                  file)
    (org-roam-sql [:delete :from titles
                   :where (= file $s1)]
                  file)
    (org-roam-sql [:delete :from refs
                   :where (= file $s1)]
                  file)))

(defun org-roam--get-current-files ()
  "Return a hash of file to buffer string hash."
  (let* ((current-files (org-roam-sql [:select * :from files]))
         (ht (make-hash-table :test #'equal)))
    (dolist (row current-files)
      (puthash (car row) (cadr row) ht))
    ht))

(defun org-roam--db-initialized-p ()
  "Whether the cache has been initialized."
  (and (file-exists-p (org-roam--get-db))
       (> (caar (org-roam-sql [:select (funcall count) :from titles]))
          0)))

(defun org-roam--db-ensure-built ()
  "Ensures that org-roam cache is built."
  (unless (org-roam--db-initialized-p)
    (error "[Org-roam] your cache isn't built yet! Please run org-roam-build-cache.")))

(defun org-roam--db-get-titles (file)
  "Return the titles of FILE from the cache."
  (caar (org-roam-sql [:select [titles] :from titles
                       :where (= file $s1)]
                      file
                      :limit 1)))

(defun org-roam--list-all-files ()
  "Return a list of all org-roam files within `org-roam-directory'."
  (org-roam--list-files (file-truename org-roam-directory)))

(defun org-roam--new-file-path (id &optional absolute)
  "The file path for a new Org-roam file, with identifier ID.
If ABSOLUTE, return an absolute file-path. Else, return a relative file-path."
  (let ((absolute-file-path (file-truename
                             (expand-file-name
                              (if org-roam-encrypt-files
                                  (concat id ".org.gpg")
                                (concat id ".org"))
                              (or org-roam-new-file-directory
                                  org-roam-directory)))))
    (if absolute
        absolute-file-path
      (file-relative-name absolute-file-path
                          (file-truename org-roam-directory)))))

(defun org-roam--path-to-slug (path)
  "Return a slug from PATH."
  (-> path
      (file-relative-name (file-truename org-roam-directory))
      (file-name-sans-extension)))

(defun org-roam--get-title-or-slug (path)
  "Convert `PATH' to the file title, if it exists. Else, return the path."
  (or (car (org-roam--db-get-titles path))
      (org-roam--path-to-slug path)))

(defun org-roam--title-to-slug (title)
  "Convert TITLE to a filename-suitable slug."
  (cl-flet ((replace (title pair)
                     (replace-regexp-in-string (car pair) (cdr pair) title)))
    (let* ((pairs `(("[^[:alnum:][:digit:]]" . "_")  ;; convert anything not alphanumeric
                    ("__*" . "_")  ;; remove sequential underscores
                    ("^_" . "")  ;; remove starting underscore
                    ("_$" . "")))  ;; remove ending underscore
           (slug (-reduce-from #'replace title pairs)))
      (s-downcase slug))))

(defun org-roam--file-name-timestamp-title (title)
  "Return a file name (without extension) for new files.

It uses TITLE and the current timestamp to form a unique title."
  (let ((timestamp (format-time-string "%Y%m%d%H%M%S" (current-time)))
        (slug (org-roam--title-to-slug title)))
    (format "%s_%s" timestamp slug)))

;;; Creating org-roam files
(defvar org-roam-templates
  (list (list "default" (list :file #'org-roam--file-name-timestamp-title
                              :content "#+TITLE: ${title}")))
  "Templates to insert for new files in org-roam.")

(defun org-roam--get-template (&optional template-key)
  "Return an Org-roam template. TEMPLATE-KEY is used to get a template."
  (unless org-roam-templates
    (user-error "No templates defined"))
  (if template-key
      (cadr (assoc template-key org-roam-templates))
    (if (= (length org-roam-templates) 1)
        (cadar org-roam-templates)
      (cadr (assoc (completing-read "Template: " org-roam-templates)
                   org-roam-templates)))))

(defun org-roam--make-new-file (&optional info)
  (let ((template (org-roam--get-template (cdr (assoc 'template info))))
        (title (or (cdr (assoc 'title info))
                   (completing-read "Title: " nil)))
        file-name-fn file-path)
    (fset 'file-name-fn (plist-get template :file))
    (setq file-path (org-roam--new-file-path (file-name-fn title) t))
    (push (cons 'slug (org-roam--title-to-slug title)) info)
    (unless (file-exists-p file-path)
      (org-roam--touch-file file-path)
      (write-region
       (s-format (plist-get template :content)
                 'aget
                 info)
       nil file-path nil))
    (org-roam--db-update-file file-path)
    file-path))

;;; Inserting org-roam links
(defun org-roam-insert (prefix)
  "Find an org-roam file, and insert a relative org link to it at point.
If PREFIX, downcase the title before insertion."
  (interactive "P")
  (let* ((region (and (region-active-p)
                      ;; following may lose active region, so save it
                      (cons (region-beginning) (region-end))))
         (region-text (when region
                        (buffer-substring-no-properties
                         (car region) (cdr region))))
         (completions (org-roam--get-title-path-completions))
         (title (completing-read "File: " completions nil nil region-text))
         (region-or-title (or region-text title))
         (absolute-file-path (or (cdr (assoc title completions))
                                 (org-roam--make-new-file (list (cons 'title title)))))
         (current-file-path (-> (or (buffer-base-buffer)
                                    (current-buffer))
                                (buffer-file-name)
                                (file-truename)
                                (file-name-directory))))
    (when region ;; Remove previously selected text.
      (goto-char (car region))
      (delete-char (- (cdr region) (car region))))
    (insert (format "[[%s][%s]]"
                    (concat "file:" (file-relative-name absolute-file-path
                                                        current-file-path))
                    (format org-roam-link-title-format (if prefix
                                                           (downcase region-or-title)
                                                         region-or-title))))))

;;; Finding org-roam files
(defun org-roam--get-title-path-completions ()
  "Return a list of cons pairs for titles to absolute path of Org-roam files."
  (let* ((rows (org-roam-sql [:select [file titles] :from titles]))
         res)
    (dolist (row rows)
      (let ((file-path (car row))
            (titles (cadr row)))
        (if titles
            (dolist (title titles)
              (push (cons title file-path) res))
          (push (cons (org-roam--path-to-slug file-path)
                      file-path) res))))
    res))

(defun org-roam--get-ref-path-completions ()
  "Return a list of cons pairs for titles to absolute path of Org-roam files."
  (let ((rows (org-roam-sql [:select [ref file] :from refs])))
    (mapcar (lambda (row)
              (cons (car row)
                    (cadr row))) rows)))

(defun org-roam-find-ref (&optional info)
  "Find and open an org-roam file from a ref.
INFO is an alist containing additional information."
  (interactive)
  (let* ((completions (org-roam--get-ref-path-completions))
         (ref (or (cdr (assoc 'ref info))
                  (completing-read "Ref: " (org-roam--get-ref-path-completions))))
         (file-path (cdr (assoc ref completions))))
    (if file-path
        (find-file file-path)
      (find-file (org-roam--make-new-file info)))))

(defun org-roam-find-file ()
  "Find and open an org-roam file."
  (interactive)
  (let* ((completions (org-roam--get-title-path-completions))
         (title-or-slug (completing-read "File: " completions))
         (absolute-file-path (or (cdr (assoc title-or-slug completions))
                                 (org-roam--make-new-file (list (cons 'title title-or-slug))))))
    (find-file absolute-file-path)))

(defun org-roam--get-roam-buffers ()
  "Return a list of buffers that are org-roam files."
  (--filter (and (with-current-buffer it (derived-mode-p 'org-mode))
                 (buffer-file-name it)
                 (org-roam--org-roam-file-p (buffer-file-name it)))
            (buffer-list)))

(defun org-roam-switch-to-buffer ()
  "Switch to an existing org-roam buffer."
  (interactive)
  (let* ((roam-buffers (org-roam--get-roam-buffers))
         (names-and-buffers (mapcar (lambda (buffer)
                                      (cons (or (org-roam--get-title-or-slug
                                                 (buffer-file-name buffer))
                                                (buffer-name buffer))
                                            buffer))
                                    roam-buffers)))
    (unless roam-buffers
      (user-error "No roam buffers."))
    (when-let ((name (completing-read "Choose a buffer: " names-and-buffers)))
      (switch-to-buffer (cdr (assoc name names-and-buffers))))))

;;; Building the org-roam cache
(defun org-roam-build-cache ()
  "Build the cache for `org-roam-directory'."
  (interactive)
  (org-roam-db) ;; To initialize the database, no-op if already initialized
  (let* ((org-roam-files (org-roam--list-files org-roam-directory))
         (current-files (org-roam--get-current-files))
         (time (current-time))
         all-files all-links all-titles all-refs)
    (dolist (file org-roam-files)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((contents-hash (secure-hash 'sha1 (current-buffer))))
          (unless (string= (gethash file current-files)
                           contents-hash)
            (org-roam--db-clear-file file)
            (setq all-files
                  (cons (vector file contents-hash time) all-files))
            (when-let (links (org-roam--extract-links file))
              (setq all-links (append links all-links)))
            (let ((titles (org-roam--extract-titles)))
              (setq all-titles (cons (vector file titles) all-titles)))
            (when-let ((ref (org-roam--extract-ref)))
              (setq all-refs (cons (vector ref file) all-refs))))
          (remhash file current-files))))
    (dolist (file (hash-table-keys current-files))
      ;; These files are no longer around, remove from cache...
      (org-roam--db-clear-file file))
    (when all-files
      (org-roam-sql
       [:insert :into files
        :values $v1]
       all-files))
    (when all-links
      (org-roam-sql
       [:insert :into file-links
        :values $v1]
       all-links))
    (when all-titles
      (org-roam-sql
       [:insert :into titles
        :values $v1]
       all-titles))
    (when all-refs
      (org-roam-sql
       [:insert :into refs
        :values $v1]
       all-refs))
    (let ((stats (list :files (length all-files)
                       :links (length all-links)
                       :titles (length all-titles)
                       :refs (length all-refs)
                       :deleted (length (hash-table-keys current-files)))))
      (message (format "files: %s, links: %s, titles: %s, refs: %s, deleted: %s"
                       (plist-get stats :files)
                       (plist-get stats :links)
                       (plist-get stats :titles)
                       (plist-get stats :refs)
                       (plist-get stats :deleted)))
      stats)))

(defun org-roam--db-update-titles ()
  "Update the title of the current buffer into the cache."
  (let ((file (file-truename (buffer-file-name (current-buffer)))))
    (org-roam-sql [:delete :from titles
                   :where (= file $s1)]
                  file)
    (org-roam--db-insert-titles file (org-roam--extract-titles))))

(defun org-roam--db-update-refs ()
  "Update the ref of the current buffer into the cache."
  (let ((file (file-truename (buffer-file-name (current-buffer)))))
    (org-roam-sql [:delete :from refs
                   :where (= file $s1)]
                  file)
    (when-let ((ref (org-roam--extract-ref)))
      (org-roam--db-insert-ref file ref))))

(defun org-roam--update-cache-links ()
  "Update the file links of the current buffer in the cache."
  (let ((file (file-truename (buffer-file-name (current-buffer)))))
    (org-roam-sql [:delete :from file-links
                   :where (= file-from $s1)]
                  file)
    (when-let ((links (org-roam--extract-links)))
      (org-roam--db-insert-links links))))

(defun org-roam--db-update-file (&optional file-path)
  "Update org-roam caches for the FILE-PATH."
  (let (buf)
    (if file-path
        (setq buf (find-file-noselect file-path))
      (setq buf (current-buffer)))
    (with-current-buffer buf
      (save-excursion
        (org-roam--db-update-titles)
        (org-roam--db-update-refs)
        (org-roam--update-cache-links)
        (org-roam--maybe-update-buffer :redisplay t)))))

;;; Org-roam daily notes
(defun org-roam--file-for-time (time)
  "Create and find file for TIME."
  (let* ((org-roam-templates (list (list "daily" (list :file (lambda (title) title)
                                                       :content "#+TITLE: ${title}")))))
    (org-roam--make-new-file (list (cons 'title (format-time-string "%Y-%m-%d" time))
                                   (cons 'template "daily")))))

(defun org-roam-today ()
  "Create and find file for today."
  (interactive)
  (let ((path (org-roam--file-for-time (current-time))))
    (org-roam--find-file path)))

(defun org-roam-tomorrow ()
  "Create and find the file for tomorrow."
  (interactive)
  (let ((path (org-roam--file-for-time (time-add 86400 (current-time)))))
    (org-roam--find-file path)))

(defun org-roam-date ()
  "Create the file for any date using the calendar."
  (interactive)
  (let ((time (org-read-date nil 'to-time nil "Date:  ")))
    (let ((path (org-roam--file-for-time time)))
      (org-roam--find-file path))))


;;; Org-roam Buffer
(define-derived-mode org-roam-backlinks-mode org-mode "Backlinks"
  "Major mode for the org-roam backlinks buffer

Bindings:
\\{org-roam-backlinks-mode-map}")

(define-key org-roam-backlinks-mode-map [mouse-1] 'org-roam-open-at-point)
(define-key org-roam-backlinks-mode-map (kbd "RET") 'org-roam-open-at-point)

(defun org-roam-open-at-point ()
  "Open a link at point.

When point is on an org-roam link, open the link in the org-roam window.

When point is on the org-roam preview text, open the link in the org-roam
window, and navigate to the point.

If item at point is not org-roam specific, default to Org behaviour."
  (interactive)
  (let ((context (org-element-context)))
    (catch 'ret
      ;; Org-roam link
      (when (and (eq (org-element-type context) 'link)
                 (string= "file" (org-element-property :type context))
                 (org-roam--org-roam-file-p (file-truename (org-element-property :path context))))
        (org-roam--find-file (org-element-property :path context))
        (org-show-context)
        (throw 'ret t))
      ;; Org-roam preview text
      (when-let ((file-from (get-text-property (point) 'file-from))
                 (p (get-text-property (point) 'file-from-point)))
        (org-roam--find-file file-from)
        (goto-char p)
        (org-show-context)
        (throw 'ret t))
      ;; Default to default org behaviour
      (org-open-at-point))))

(defun org-roam--find-file (file)
  "Open FILE in the window `org-roam' was called from."
  (if (and org-roam-last-window (window-valid-p org-roam-last-window))
      (progn (with-selected-window org-roam-last-window
               (find-file file))
             (select-window org-roam-last-window))
    (find-file file)))

(defun org-roam--get-backlinks (file)
  (org-roam-sql [:select [file-from, file-to, properties] :from file-links
                 :where (= file-to $s1)]
                file))

(defun org-roam-update (file-path)
  "Show the backlinks for given org file for file at `FILE-PATH'."
  (org-roam--db-ensure-built)
  (let* ((source-org-roam-directory org-roam-directory))
    (let ((buffer-title (org-roam--get-title-or-slug file-path)))
      (with-current-buffer org-roam-buffer
        ;; When dir-locals.el is used to override org-roam-directory,
        ;; org-roam-buffer may have a different local org-roam-directory.
        (let ((org-roam-directory source-org-roam-directory))
          ;; Locally overwrite the file opening function to re-use the
          ;; last window org-roam was called from
          (setq-local
           org-link-frame-setup
           (cons '(file . org-roam--find-file) org-link-frame-setup))
          (let ((inhibit-read-only t))
            (erase-buffer)
            (when (not (eq major-mode 'org-roam-backlinks-mode))
              (org-roam-backlinks-mode))
            (make-local-variable 'org-return-follows-link)
            (setq org-return-follows-link t)
            (insert
             (propertize buffer-title 'font-lock-face 'org-document-title))
            (if-let* ((backlinks (org-roam--get-backlinks file-path))
                      (grouped-backlinks (--group-by (nth 0 it) backlinks)))
                (progn
                  (insert (format "\n\n* %d Backlinks\n"
                                  (length backlinks)))
                  (dolist (group grouped-backlinks)
                    (let ((file-from (car group))
                          (bls (cdr group)))
                      (insert (format "** [[file:%s][%s]]\n"
                                      file-from
                                      (org-roam--get-title-or-slug file-from)))
                      (dolist (backlink bls)
                        (pcase-let ((`(,file-from ,file-to ,props) backlink))
                          (insert (propertize
                                   (s-trim (s-replace "\n" " "
                                                      (plist-get props :content)))
                                   'font-lock-face 'org-block
                                   'help-echo "mouse-1: visit backlinked note"
                                   'file-from file-from
                                   'file-from-point (plist-get props :point)))
                          (insert "\n\n"))))))
              (insert "\n\n* No backlinks!")))
          (read-only-mode 1))))))

;;; Graph
(defun org-roam--build-graph ()
  "Build the Graphviz string.
The Org-roam database titles table is read, to obtain the list of titles.
The file-links table is then read to obtain all directed links, and formatted
into a digraph."
  (org-roam--db-ensure-built)
  (with-temp-buffer
	  (insert "digraph {\n")
    (let ((rows (org-roam-sql [:select [file titles] :from titles])))
      (dolist (row rows)
        (let* ((file (xml-escape-string (car row)))
               (title (or (caadr row)
                          (org-roam--path-to-slug file)))
               (shortened-title (s-truncate org-roam-graph-max-title-length title)))
          (insert
		       (format "  \"%s\" [label=\"%s\", shape=%s, URL=\"org-protocol://roam-file?file=%s\", tooltip=\"%s\"];\n"
                   file
				           (xml-escape-string shortened-title)
				           org-roam-graph-node-shape
				           file
				           (xml-escape-string title))))))
    (let ((link-rows (org-roam-sql [:select :distinct [file-to file-from] :from file-links])))
      (dolist (row link-rows)
        (insert (format "  \"%s\" -> \"%s\";\n"
                        (xml-escape-string (car row))
						            (xml-escape-string (cadr row))))))
	  (insert "}")
	  (buffer-string)))

(defun org-roam-show-graph ()
  "Displays the generated Org-roam graph using `org-roam-graph-viewer'."
  (interactive)
  (declare (indent 0))
  (unless org-roam-graphviz-executable
    (setq org-roam-graphviz-executable (executable-find "dot")))
  (unless org-roam-graphviz-executable
    (user-error "Can't find graphviz executable. Please check if it is in your path"))
  (let ((temp-dot (expand-file-name "graph.dot" temporary-file-directory))
        (temp-graph (expand-file-name "graph.svg" temporary-file-directory))
        (graph (org-roam--build-graph)))
    (with-temp-file temp-dot
      (insert graph))
    (call-process org-roam-graphviz-executable nil 0 nil temp-dot "-Tsvg" "-o" temp-graph)
    (if (and org-roam-graph-viewer (executable-find org-roam-graph-viewer))
	      (call-process org-roam-graph-viewer nil 0 nil temp-graph)
      (view-file temp-graph))))

;;; Org-roam minor mode
(cl-defun org-roam--maybe-update-buffer (&key redisplay)
  "Reconstructs `org-roam-buffer'.
This needs to be quick or infrequent, because this is run at
`post-command-hook'."
  (let ((buffer (window-buffer)))
    (when (and (or redisplay
                   (not (eq org-roam--current-buffer buffer)))
               (eq 'visible (org-roam--current-visibility))
               (buffer-local-value 'buffer-file-truename buffer))
      (setq org-roam--current-buffer buffer)
      (org-roam-update (expand-file-name
                        (buffer-local-value 'buffer-file-truename buffer))))))

(defface org-roam-link
  '((t :inherit org-link))
  "Face for org-roam link."
  :group 'org-roam-faces)

(defun org-roam--roam-link-face (path)
  "Conditional face for org file links.
Applies `org-roam-link-face' if PATH correponds to a Roam file."
  (if (org-roam--org-roam-file-p path)
      'org-roam-link
    'org-link))

(defun org-roam--find-file-hook-function ()
  "Called by `find-file-hook' when `org-roam-mode' is on."
  (when (org-roam--org-roam-file-p)
    (setq org-roam-last-window (get-buffer-window))
    (add-hook 'post-command-hook #'org-roam--maybe-update-buffer nil t)
    (add-hook 'after-save-hook #'org-roam--db-update-file nil t)
    (org-roam--setup-file-links)
    (org-roam--maybe-update-buffer :redisplay nil)))

(defun org-roam--setup-file-links ()
  "Set up `file:' Org links with org-roam-link-face."
  (unless (version< org-version "9.2")
    (org-link-set-parameters "file" :face 'org-roam--roam-link-face)))

(defun org-roam--teardown-file-links ()
  "Teardown the setup done by Org-roam on file links.
This sets `file:' Org links to have the org-link face."
  (unless (version< org-version "9.2")
    (org-link-set-parameters "file" :face 'org-link)))

(defvar org-roam-mode-map
  (make-sparse-keymap)
  "Keymap for org-roam commands.")

(defun org-roam--delete-file-advice (file &optional _trash)
  "Advice for maintaining cache consistency during file deletes."
  (when (and (not (auto-save-file-name-p file))
             (org-roam--org-roam-file-p file))
    (org-roam--db-clear-file (file-truename file))))

(defun org-roam--rename-file-advice (file new-file &rest args)
  "Rename backlinks of FILE to refer to NEW-FILE."
  (when (and (not (auto-save-file-name-p file))
             (not (auto-save-file-name-p new-file))
             (org-roam--org-roam-file-p new-file))
    (org-roam--db-ensure-built)
    (let* ((files-to-rename (org-roam-sql [:select :distinct [file-from]
                                           :from file-links
                                           :where (= file-to $s1)]
                                          file))
           (path (file-truename file))
           (new-path (file-truename new-file))
           (slug (org-roam--get-title-or-slug file))
           (old-title (format org-roam-link-title-format slug))
           (new-slug (or (car (org-roam--db-get-titles path))
                         (org-roam--path-to-slug new-path)))
           (new-title (format org-roam-link-title-format new-slug)))
      (org-roam--db-clear-file file)
      (dolist (file-from files-to-rename)
        (let* ((file-from (car file-from))
               (file-from (if (string-equal (file-truename file-from)
                                            path)
                              new-path
                            file-from))
               (file-dir (file-name-directory file-from))
               (relative-path (file-relative-name new-path file-dir))
               (old-relative-path (file-relative-name path file-dir))
               (slug-regex (regexp-quote (format "[[file:%s][%s]]" old-relative-path old-title)))
               (named-regex (concat
                             (regexp-quote (format "[[file:%s][" old-relative-path))
                             "\\(.*\\)"
                             (regexp-quote "]]"))))
          (with-temp-file file-from
            (insert-file-contents file-from)
            (while (re-search-forward slug-regex nil t)
              (replace-match (format "[[file:%s][%s]]" relative-path new-title)))
            (goto-char (point-min))
            (while (re-search-forward named-regex nil t)
              (replace-match (format "[[file:%s][\\1]]" relative-path))))
          (org-roam--db-update-file file-from)))
      (org-roam--db-update-file new-path))))

;;;###autoload
(define-minor-mode org-roam-mode
  "Minor mode for Org-roam.

When called interactively, toggle `org-roam-mode'. with prefix ARG, enable `org-roam-mode'
if ARG is positive, otherwise disable it.

When called from Lisp, enable `org-roam-mode' if ARG is omitted, nil, or positive.
If ARG is `toggle', toggle `org-roam-mode'. Otherwise, behave as if called interactively."
  :lighter " Org-Roam"
  :keymap  org-roam-mode-map
  :group 'org-roam
  :require 'org-roam
  :global t
  (cond
   (org-roam-mode
    (org-roam-build-cache)
    (add-hook 'find-file-hook #'org-roam--find-file-hook-function)
    (add-hook 'kill-emacs-hook #'org-roam--db-close-all)
    (advice-add 'rename-file :after #'org-roam--rename-file-advice)
    (advice-add 'delete-file :before #'org-roam--delete-file-advice))
   (t
    (remove-hook 'find-file-hook #'org-roam--find-file-hook-function)
    (remove-hook 'kill-emacs-hook #'org-roam--db-close-all)
    (advice-remove 'rename-file #'org-roam--rename-file-advice)
    (advice-remove 'delete-file #'org-roam--delete-file-advice)
    (org-roam--db-close-all)
    ;; Disable local hooks for all org-roam buffers
    (dolist (buf (org-roam--get-roam-buffers))
      (with-current-buffer buf
        (org-roam--teardown-file-links)
        (remove-hook 'post-command-hook #'org-roam--maybe-update-buffer t)
        (remove-hook 'after-save-hook #'org-roam--db-update-file t))))))

;;; Show/hide the org-roam buffer
(define-inline org-roam--current-visibility ()
  "Return whether the current visibility state of the org-roam buffer.
Valid states are 'visible, 'exists and 'none."
  (declare (side-effect-free t))
  (inline-quote
   (cond
    ((get-buffer-window org-roam-buffer) 'visible)
    ((get-buffer org-roam-buffer) 'exists)
    (t 'none))))

(defun org-roam--set-width (width)
  "Set the width of the org-roam buffer to `WIDTH'."
  (unless (one-window-p)
    (let ((window-size-fixed)
          (w (max width window-min-width)))
      (cond
       ((> (window-width) w)
        (shrink-window-horizontally  (- (window-width) w)))
       ((< (window-width) w)
        (enlarge-window-horizontally (- w (window-width))))))))

(defun org-roam--setup-buffer ()
  "Setup the `org-roam' buffer at the `org-roam-buffer-position'."
  (let ((window (get-buffer-window)))
    (-> (get-buffer-create org-roam-buffer)
        (display-buffer-in-side-window
         `((side . ,org-roam-buffer-position)))
        (select-window))
    (org-roam--set-width
     (round (* (frame-width)
               org-roam-buffer-width)))
    (select-window window)))

(defun org-roam ()
  "Pops up the window `org-roam-buffer' accordingly."
  (interactive)
  (setq org-roam-last-window (get-buffer-window))
  (pcase (org-roam--current-visibility)
    ('visible (delete-window (get-buffer-window org-roam-buffer)))
    ('exists (org-roam--setup-buffer))
    ('none (org-roam--setup-buffer))))

;;; -
(provide 'org-roam)
;;; org-roam.el ends here

;; Local Variables:
;; outline-regexp: ";;;+ "
;; End:
