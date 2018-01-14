;;; anki-editor.el --- Create Anki cards in Org-mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2018  Louie Tan

;; Author: Louie Tan <louietanlei@gmail.com>

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distaributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.


(require 'json)
(require 'org-element)


(defconst anki-editor-note-tag "note")
(defconst anki-editor-deck-tag "deck")
(defconst anki-editor-note-type-prop :ANKI_NOTE_TYPE)
(defconst anki-editor-note-tags-prop :ANKI_TAGS)
(defconst anki-editor-note-id-prop :ANKI_NOTE_ID)
(defconst anki-editor-note-failure-reason-prop :ANKI_FAILURE_REASON)
(defconst anki-editor-html-output-buffer-name "*anki-editor html output*")
(defconst anki-editor-anki-connect-listening-address "127.0.0.1")
(defconst anki-editor-anki-connect-listening-port "8765")

;; Commands

;;;###autoload
(defun anki-editor-submit ()
  "Send notes in current buffer to Anki.

For each note heading, if there's no note id in property drawer,
create a note, otherwise, update fields and tags of the existing
note.

If one fails, the failure reason will be set in property drawer
of that heading."
  (interactive)
  (let ((total 0)
        (failed 0))
    (save-excursion
      (goto-char (point-min))
      (let (current-tags current-deck)
        (while (not (= (point) (point-max)))
          (when (org-at-heading-p)
            (setq current-tags (org-get-tags))
            (cond
             ((member anki-editor-deck-tag current-tags) (setq current-deck (nth 4 (org-heading-components))))
             ((member anki-editor-note-tag current-tags) (progn
                                                           (setq total (1+ total))
                                                           (anki-editor--clear-failure-reason)
                                                           (condition-case err
                                                               (anki-editor--process-note-heading current-deck)
                                                             (error (progn
                                                                      (setq failed (1+ failed))
                                                                      (anki-editor--set-failure-reason (error-message-string err)))))))))
          (org-next-visible-heading 1))))
    (message (with-output-to-string
               (princ (format "Submitted %d notes, with %d failed." total failed))
               (when (> failed 0)
                 (princ " Check property drawers for failure reasons."))))))

;;;###autoload
(defun anki-editor-insert-deck (&optional prefix)
  "Insert a deck heading with the same level as current heading.
With prefix, only insert the deck name."
  (interactive "P")
  (message "Fetching decks...")
  (anki-editor--anki-connect-invoke
   "deckNames" 5 nil
   (lambda (result)
     (let (deckname)
       (setq result (append (sort result #'string-lessp) nil)
             deckname (completing-read "Choose a deck: " result))
       (unless prefix (org-insert-heading-respect-content))
       (insert deckname)
       (unless prefix (anki-editor--set-tags-fix anki-editor-deck-tag))))))

;;;###autoload
(defun anki-editor-insert-note ()
  "Insert a note heading that's one level lower to current heading.
The inserted heading will be structured with the property drawer
and subheadings that correspond to the fields of the selected
note type."
  (interactive)
  (message "Fetching note types...")
  (anki-editor--anki-connect-invoke
   "modelNames" 5 nil
   (lambda (note-types)
     (let (note-type note-heading)
       (setq note-types (append (sort note-types #'string-lessp) nil)
             note-type (completing-read "Choose a note type: " note-types))
       (message "Fetching note fields...")
       (anki-editor--anki-connect-invoke
        "modelFieldNames" 5 `((modelName . ,note-type))
        (lambda (fields)
          (setq note-heading (read-from-minibuffer "Enter the heading: " "Item"))
          (org-insert-heading-respect-content)
          (org-do-demote)
          (insert note-heading)
          (anki-editor--set-tags-fix anki-editor-note-tag)
          (org-set-property (substring (symbol-name anki-editor-note-type-prop) 1) note-type)
          (seq-each (lambda (field)
                      (save-excursion
                        (org-insert-heading-respect-content)
                        (org-do-demote)
                        (insert field)))
                    fields)
          (org-next-visible-heading 1)
          (end-of-line)
          (newline-and-indent)))))))

;;;###autoload
(defun anki-editor-export-heading-contents-to-html ()
  "Export the contents of the heading at point to HTML."
  (interactive)
  (let ((tree (org-element-at-point))
        contents)
    (if (or (null tree)
            (not (eq (org-element-type tree) 'headline)))
        (error "No element at point or it's not a heading")

      (setq contents (buffer-substring-no-properties (org-element-property :contents-begin tree)
                                                     (org-element-property :contents-end tree)))
      (when (buffer-live-p (get-buffer anki-editor-html-output-buffer-name))
        (kill-buffer anki-editor-html-output-buffer-name))
      (switch-to-buffer-other-window (get-buffer-create anki-editor-html-output-buffer-name))
      (insert (anki-editor--generate-html contents)))))

;;;###autoload
(defun anki-editor-convert-region-to-html ()
  "Convert and replace region to HTML."
  (interactive)
  (unless (region-active-p) (error "No active region"))
  (insert (anki-editor--generate-html
           (delete-and-extract-region (region-beginning) (region-end)))))

(setq anki-editor--key-map `((,(kbd "C-c a s") . ,#'anki-editor-submit)
                             (,(kbd "C-c a i d") . ,#'anki-editor-insert-deck)
                             (,(kbd "C-c a i n") . ,#'anki-editor-insert-note)
                             (,(kbd "C-c a e") . ,#'anki-editor-export-heading-contents-to-html)))

;;;###autoload
(defun anki-editor-setup-default-keybindings ()
  "Set up the default keybindings."
  (interactive)
  (dolist (map anki-editor--key-map)
    (local-set-key (car map) (cdr map)))
  (message "anki-editor default keybindings have been set"))


;; Core Functions

(defun anki-editor--process-note-heading (deck)
  (unless deck (error "No deck specified"))

  (let (note-elem note)
    (setq note-elem (org-element-at-point)
          note-elem (let ((content (buffer-substring
                                    (org-element-property :begin note-elem)
                                    (org-element-property :end note-elem))))
                      (with-temp-buffer
                        (insert content)
                        (car (org-element-contents (org-element-parse-buffer)))))
          note (anki-editor--heading-to-note note-elem))
    (add-to-list 'note `(deck . ,deck))
    (anki-editor--save-note note)))

(defun anki-editor--save-note (note)
  (if (= (alist-get 'note-id note) -1)
      (anki-editor--create-note note)
    (anki-editor--update-note note)))

(defun anki-editor--create-note (note)
  (let* ((response (anki-editor--anki-connect-invoke
                    "addNote" 5 `((note . ,(anki-editor--anki-connect-map-note note)))))
         (result (alist-get 'result response))
         (err (alist-get 'error response)))
    (if result
        (org-set-property (substring (symbol-name anki-editor-note-id-prop) 1)
                          (format "%d" (alist-get 'result response)))
      (error (or err "Sorry, the operation was unsuccessful and detailed information is unavailable.")))))

(defun anki-editor--update-note (note)
  "Update fields and tags of a note."
  (let* ((response (anki-editor--anki-connect-invoke
                    "updateNoteFields" 5 `((note . ,(anki-editor--anki-connect-map-note note)))))
         (err (alist-get 'error response)))
    (when err (error err))
    ;; TODO: Update tags
    ))

(defun anki-editor--set-failure-reason (reason)
  (org-set-property (substring (symbol-name anki-editor-note-failure-reason-prop) 1) reason))

(defun anki-editor--clear-failure-reason ()
  (org-delete-property (substring (symbol-name anki-editor-note-failure-reason-prop) 1)))

(defun anki-editor--heading-to-note (heading)
  (let (note-id note-type tags fields)
    (setq note-id (org-element-property anki-editor-note-id-prop heading)
          note-type (org-element-property anki-editor-note-type-prop heading)
          tags (org-element-property anki-editor-note-tags-prop heading)
          fields (mapcar #'anki-editor--heading-to-note-field (anki-editor--get-subheadings heading)))

    (unless note-type (error "Missing note type"))
    (unless fields (error "Missing fields"))

    `((note-id . ,(string-to-number (or note-id "-1")))
      (note-type . ,note-type)
      (tags . ,(and tags (split-string tags " ")))
      (fields . ,fields))))

(defun anki-editor--get-subheadings (heading)
  (org-element-map (org-element-contents heading)
      'headline 'identity nil nil 'headline))

(defun anki-editor--heading-to-note-field (heading)
  (let ((field-name (substring-no-properties
                     (org-element-property
                      :raw-value
                      heading)))
        (contents (org-element-contents heading)))
    `(,field-name . ,(anki-editor--generate-html
                      (org-element-interpret-data contents)))))

(defun anki-editor--generate-html (org-content)
  (with-temp-buffer
    (insert org-content)
    (setq anki-editor--replacement-records nil)
    (anki-editor--replace-latex)
    (anki-editor--buffer-to-html)
    (anki-editor--translate-latex)
    (buffer-substring-no-properties (point-min) (point-max))))

;; Transformers

(defun anki-editor--buffer-to-html ()
  (when (> (buffer-size) 0)
    (save-mark-and-excursion
     (mark-whole-buffer)
     (org-html-convert-region-to-html))))

(defun anki-editor--replace-latex ()
  (let (object type memo)
    (while (setq object (org-element-map
                            (org-element-parse-buffer)
                            '(latex-fragment latex-environment) 'identity nil t))

      (setq type (org-element-type object)
            memo (anki-editor--replace-node object
                                            (lambda (original)
                                              (anki-editor--hash type
                                                                 original))))
      (add-to-list 'anki-editor--replacement-records
                   `(,(cdr memo) . ((type . ,type)
                                    (original . ,(car memo))))))))

(setq anki-editor--anki-latex-syntax-map
      `((,(format "^%s" (regexp-quote "$$")) . "[$$]")
        (,(format "%s$" (regexp-quote "$$")) . "[/$$]")
        (,(format "^%s" (regexp-quote "$")) . "[$]")
        (,(format "%s$" (regexp-quote "$")) . "[/$]")
        (,(format "^%s" (regexp-quote "\\(")) . "[$]")
        (,(format "%s$" (regexp-quote "\\)")) . "[/$]")
        (,(format "^%s" (regexp-quote "\\[")) . "[$$]")
        (,(format "%s$" (regexp-quote "\\]")) . "[/$$]")))

(defun anki-editor--wrap-latex (content)
  (format "[latex]%s[/latex]" content))

(defun anki-editor--convert-latex-fragment (frag)
  (let ((copy frag))
    (dolist (map anki-editor--anki-latex-syntax-map)
      (setq frag (replace-regexp-in-string (car map) (cdr map) frag t t)))
    (if (equal copy frag)
        (anki-editor--wrap-latex frag)
      frag)))

(defun anki-editor--translate-latex ()
  (let (ele-data translated)
    (dolist (record anki-editor--replacement-records)
      (setq ele-data (cdr record))
      (goto-char (point-min))
      (when (search-forward (car record) nil t)
        (pcase (alist-get 'type ele-data)
          ('latex-fragment (replace-match (anki-editor--convert-latex-fragment (alist-get 'original ele-data)) t t))
          ('latex-environment (replace-match (anki-editor--wrap-latex (alist-get 'original ele-data)) t t)))
        (add-to-list 'translated record)))
    (setq anki-editor--replacement-records (cl-set-difference anki-editor--replacement-records translated))))

;; Utilities

(defun anki-editor--hash (type text)
  (sha1 (format "%s %s" (symbol-name type) text)))

(defun anki-editor--set-tags-fix (tags)
  (org-set-tags-to tags)
  (org-fix-tags-on-the-fly))

(defun anki-editor--replace-node (node replacer)
  (let* ((begin (org-element-property :begin node))
         (end (- (org-element-property :end node) (org-element-property :post-blank node)))
         (original (delete-and-extract-region begin end))
         (replacement (funcall replacer original)))
    (goto-char begin)
    (insert replacement)
    (cons original replacement)))

;; anki-connect

;; FIXME: behavior changed, callers need to be updated
(defun anki-editor--anki-connect-invoke (action version &optional params)
  (let* ((data `(("action" . ,action)
                 ("version" . ,version)))
         (request-body (json-encode
                        (if params
                            (add-to-list 'data `("params" . ,params))
                          data)))
         (request-tempfile (make-temp-file "emacs-anki-editor")))

    (with-temp-file request-tempfile
      (setq buffer-file-coding-system 'utf-8)
      (set-buffer-multibyte t)
      (insert request-body))

    (let* ((raw-resp (shell-command-to-string
                      (format "curl %s:%s --silent -X POST --data-binary @%s"
                              anki-editor-anki-connect-listening-address
                              anki-editor-anki-connect-listening-port
                              request-tempfile)))
           resp error)
      (when (file-exists-p request-tempfile) (delete-file request-tempfile))
      (condition-case err
          (setq resp (json-read-from-string raw-resp)
                error (alist-get 'error resp))
        (error (setq error
                     (format "Unexpected error communicating with anki-connect: %s, the response was %s"
                             (error-message-string err)
                             (prin1-to-string raw-resp)))))
      `((result . ,(alist-get 'result resp))
        (error . ,error)))))

(defun anki-editor--anki-connect-map-note (note)
  `(("id" . ,(alist-get 'note-id note))
    ("deckName" . ,(alist-get 'deck note))
    ("modelName" . ,(alist-get 'note-type note))
    ("fields" . ,(alist-get 'fields note))
    ;; Convert tags to a vector since empty list is identical to nil
    ;; which will become None in Python, but anki-connect requires it
    ;; to be type of list.
    ("tags" . ,(vconcat (alist-get 'tags note)))))

(defun anki-editor--anki-connect-heading-to-note (heading)
  (anki-editor--anki-connect-map-note
   (anki-editor--heading-to-note heading)))

(provide 'anki-editor)

;;; anki-editor.el ends here
