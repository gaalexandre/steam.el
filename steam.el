;;; steam.el --- Organize and launch Steam games

;; Copyright (C) 2015-- Erik Sjöstrand
;; MIT License

;; Author: Erik Sjöstrand
;; URL: http://github.com/Kungsgeten/steam.el
;; Version: 1.00
;; Keywords: games
;; Package-Requires: ((cl-lib "0.5"))

;;; Commentary:

;; Launch games in your Steam library from Emacs.  First set your `steam-username':
;;
;; (setq steam-username "your_username")
;;
;; Then use `steam-launch' to play a game! You can also insert your steam
;; library into an org-mode file, in order to organize your games, and launch
;; them from there.  Run either `steam-insert-org-text' or
;; `steam-insert-org-images' (if you want the logotypes for the games in your
;; org file). The logotypes will be saved locally (see variable `steam-logo-dir'
;; into a folder relative to the org-file.

;;; Code:

(eval-when-compile
  (defvar url-http-codes)
  (defvar url-http-end-of-headers))

(require 'url)
(require 'xml)
(require 'cl-lib)

(declare-function org-current-level "org")

(defvar steam-games nil "An XML file of the user's games on Steam.")
(defvar steam-username nil "The Steam username.")
(defvar steam-logo-dir "steamlogos" "The dir where logos will be downloaded, relative to the org-file.")

(defun steam-check-xml-response (xml)
  "Check XML from steam for errors, return an error message if an error was detected, else nil."
  (let ((error-node (xml-get-children xml 'error))
	(games-node (xml-get-children xml 'games)))
    (cond
     (error-node
      (format "Recieved response: '%s', are you sure your profile is public?"
	       (car (last (car error-node)))))
      ((not games-node) "Could not find games tag in response")
      (t nil))))

(defun steam-get-xml ()
  "Downloads the user's games as XML."
  (with-current-buffer
      (url-retrieve-synchronously (format "http://steamcommunity.com/id/%s/games?tab=all&xml=1"
                                          (url-hexify-string steam-username)))
    (goto-char url-http-end-of-headers)
    (let*
	((response (car (xml-parse-region (point) (point-max))))
	 (error-detected (steam-check-xml-response response)))
      (if (not error-detected)
	  (progn
	    (message "Retrieved games successfully")
	    (car (xml-get-children response 'games)))
	(message error-detected)
	nil))))

(defun steam-game-attribute (game attribute)
  "From GAME, read an XML ATTRIBUTE."
  (cl-caddar (xml-get-children game attribute)))

(defun steam-get-games ()
  "Download steam games as XML and update `steam-games'."
  (interactive)
  (setq steam-games (xml-get-children (steam-get-xml) 'game)))

(defun steam-launch-id (id)
  "Launch game with ID in Steam client."
  (start-process "Steam"
                 nil
                 (cl-case system-type
                   ('windows-nt "explorer")
                   ('gnu/linux "steam")
                   ('darwin "open"))
                 (format "steam://rungameid/%s" id)))

;;;###autoload
(defun steam-launch ()
  "Launch a game in your Steam library."
  (interactive)
  (unless steam-games (steam-get-games))
  (let* ((games (mapcar
                 (lambda (game)
                   (cons (steam-game-attribute game 'name)
                         (steam-game-attribute game 'appID)))
                 steam-games))
         (game (cdr (assoc (completing-read "Game: " games)
                           games))))
    (when game (steam-launch-id game))))

(defun steam--insert-org (desc-format-func &optional prefix-format-func suffix-format-func)
  "Insert steam game links in current `org-mode' buffer.
Entries already existing in the buffer will not be duplicated.

The description of each link is generated by DESC-FORMAT-FUNC.
A prefix before the link can be generated by PREFIX-FORMAT-FUNC.
A suffix after the link can be generated by SUFFIX-FORMAT-FUNC.
These functions should take a single argument; the game id."
  (unless steam-games (steam-get-games))
  (unless prefix-format-func (setq prefix-format-func (lambda (x) "")))
  (unless suffix-format-func (setq suffix-format-func (lambda (x) "")))
  (let ((new-games
         (cl-mapcan (lambda (game)
                      (let ((org-link-action
                             (format "elisp:(steam-launch-id %s)"
                                     (steam-game-attribute game 'appID))))
                        (unless (save-excursion
                                  (goto-char (point-min))
                                  (search-forward org-link-action nil t))
                          (list (format "%s %s[[%s][%s]]%s\n"
                                        (make-string (1+ (or (org-current-level) 0)) ?*)
                                        (funcall prefix-format-func game)
                                        org-link-action
                                        (funcall desc-format-func game)
                                        (funcall suffix-format-func game))))))
                    steam-games)))
    (insert (apply #'concat new-games))))

;;;###autoload
(defun steam-insert-org-text ()
  "Insert each Steam game as an org heading.
The heading contains the game's name and a link to execute the game.
Entries already existing in the buffer will not be duplicated."
  (interactive)
  (steam--insert-org
   (lambda (game) (steam-game-attribute game 'name))))

;;;###autoload
(defun steam-insert-org-images ()
  "Insert each Steam game as an org heading.
The heading contains an image of the game's logo and a link to execute the game.
Entries already existing in the buffer will not be duplicated."
  (interactive)
  (steam--insert-org
   (lambda (game) (steam-game-attribute game 'name))
   (lambda (game) (format "[[file:%s]] " (steam-download-logo game)))))

(defun steam-download-logo (game)
  "Download the logo image of GAME into `steam-logo-dir' folder."
  (let ((link (steam-game-attribute game 'logo))
        (filename (concat steam-logo-dir "/img" (steam-game-attribute game 'appID) ".jpg")))
    (unless (file-exists-p filename)
      (url-retrieve
       link
       (lambda (status filename buffer)
         ;; Write current buffer to FILENAME
         ;; and update inline images in BUFFER
         (let ((err (plist-get status :error)))
           (if err (error
                    "\"%s\" %s" link
                    (downcase (nth 2 (assq (nth 2 err) url-http-codes))))))
         (delete-region
          (point-min)
          (progn
            (re-search-forward "\n\n" nil 'move)
            (point)))
         (let ((coding-system-for-write 'no-conversion))
           (write-region nil nil filename nil nil nil nil)))
       (list
        (expand-file-name filename)
        (current-buffer))
       nil t)
      (sleep-for 0 100))
    filename))

(defun steam-id-at-point ()
  "Get steam game id of link at point, if any."
  (or (when (org-in-regexp org-bracket-link-regexp 1)
        (let ((link (match-string-no-properties 1)))
          (when (string-match "elisp:(steam-launch-id \\([0-9]+\\))"
                              link)
            (match-string-no-properties 1 link))))
      (error "No Steam link at point")))

;;;###autoload
(defun steam-browse-at-point ()
  "Open the Steam store for the Steam org link at point."
  (interactive)
  (browse-url (concat "https://store.steampowered.com/app/"
                      (steam-id-at-point))))

(provide 'steam)
;;; steam.el ends here
