;;; Part of lyqi, a major emacs mode derived from LilyPond-Mode,
;;; for quick note insertion while editing GNU LilyPond music scores.
;;; 
;;; (c) copyright 2009 Nicolas Sceaux <nicolas.sceaux@free.fr>
;;; See http://nicolas.sceaux.free.fr/lilypond/

(eval-when-compile (require 'cl))
(require 'eieio)
(require 'lyqi-pitchnames)

;;;
;;; regex and match utilities
;;;

;; for XEmacs21 compatibility
(if (not (fboundp 'match-string-no-properties))
    (defalias 'match-string-no-properties 'match-string))

(defun lyqi:join (join-string strings)
  "Returns a concatenation of all strings elements, with join-string between elements"
  (apply 'concat 
	 (car strings) 
	 (mapcar (lambda (str) (concat join-string str))
		 (cdr strings))))

(defun lyqi:sort-string-by-length (string-list)
  "Sort the given string list by decreasing string length."
  (nreverse 
   (sort string-list
	 (lambda (str1 str2)
	   (or (< (length str1) (length str2))
	       (and (= (length str1) (length str2))
		    (string< str1 str2)))))))

(defun lyqi:forward-match ()
  (forward-char (- (match-end 0) (match-beginning 0))))

;;;
;;; LilyPond syntax (language dependent)
;;;
(defclass lyqi:lilypond-syntax ()
  ((parse-tree :initform nil
               :accessor lyqi:parse-tree)
   ;; parsing data
   (pitch-data            :initarg :pitch-data)
   (pitch-regex           :initarg :pitch-regex)
   (octave-regex          :initarg :octave-regex)
   (note-regex            :initarg :note-regex)
   (rest-skip-regex       :initarg :rest-skip-regex)
   (duration-data         :initarg :duration-data)
   (duration-length-regex :initarg :duration-length-regex)
   (duration-regex        :initarg :duration-regex)))

(defun lyqi:make-lilypond-syntax (&optional language)
  (let* ((pitch-data (case language
                       ((italiano francais) lyqi:+italian-pitchnames+)
                       ((english) lyqi:+english-pitchnames+)
                       ((deutsch) lyqi:+german-pitchnames+)
                       (t lyqi:+dutch-pitchnames+)))
         (pitch-regex (format "\\(%s\\)" 
                              (lyqi:join "\\|" (lyqi:sort-string-by-length
                                                (mapcar 'car pitch-data)))))
         (octave-regex "\\('+\\|,+\\)")
         (note-regex (format "%s%s?\\([^a-zA-Z]\\|$\\)" pitch-regex octave-regex))
         (rest-skip-regex "\\(r\\|R\\|s\\|q\\|\\\\skip\\)\\([^a-zA-Z]\\|$\\)")
         (duration-data '(("4" . 2)
                          ("8" . 3)
                          ("32" . 5)
                          ("64" . 6)
                          ("128" . 7) 
                          ("16" . 4)
                          ("256" . 8)
                          ("2" . 1)
                          ("1" . 0)
                          ("\\breve" . -1)
                          ("\\longa" . -2)
                          ("\\maxima" . -3)))
         (duration-length-regex
          (format "\\(%s\\)"
                  (lyqi:join "\\|" (mapcar 'regexp-quote
                                           (lyqi:sort-string-by-length
                                            (mapcar 'car duration-data))))))
         (duration-regex (format "%s\\.*\\(\\*[0-9]+\\(/[0-9]+\\)?\\)?"
                                 duration-length-regex)))
    (make-instance 'lyqi:lilypond-syntax
                   :pitch-data             pitch-data
                   :pitch-regex            pitch-regex
                   :octave-regex           octave-regex
                   :note-regex             note-regex
                   :rest-skip-regex        rest-skip-regex
                   :duration-data          duration-data
                   :duration-length-regex  duration-length-regex
                   :duration-regex         duration-regex)))

(defvar lyqi:*lilypond-syntax* nil)

;;;
;;; Lexemes
;;;

(defclass lyqi:parser-symbol ()
  ((marker :initform nil
           :initarg :marker
           :accessor lyqi:marker)
   (size :initform nil
         :initarg :size
         :accessor lyqi:size)
   (children :initarg :children
             :initform nil
             :accessor lyqi:children-of)))

(defclass lyqi:lexeme (lyqi:parser-symbol) ())

(defclass lyqi:verbatim-lexeme (lyqi:lexeme) ())

(defclass lyqi:note-lexeme (lyqi:lexeme)
  ((pitch :initarg :pitch)
   (alteration :initarg :alteration
               :initform 0)
   (octave-modifier :initarg :octave-modifier
                    :initform 0)))

(defclass lyqi:rest-skip-etc-lexeme (lyqi:lexeme) ())
(defclass lyqi:rest-lexeme (lyqi:rest-skip-etc-lexeme) ())
(defclass lyqi:mm-rest-lexeme (lyqi:rest-skip-etc-lexeme) ())
(defclass lyqi:space-lexeme (lyqi:rest-skip-etc-lexeme) ())
(defclass lyqi:skip-lexeme (lyqi:rest-skip-etc-lexeme) ())
(defclass lyqi:chord-repetition-lexeme (lyqi:rest-skip-etc-lexeme) ())

(defclass lyqi:chord-start-lexeme (lyqi:lexeme) ())
(defclass lyqi:chord-end-lexeme (lyqi:lexeme) ())

(defclass lyqi:base-duration-lexeme (lyqi:lexeme) ())
(defclass lyqi:duration-lexeme (lyqi:base-duration-lexeme)
  ((length      :initarg :length
                :initform nil)
   (dot-count   :initarg :dot-count
                :initform 0)
   (numerator   :initarg :numerator
                :initform 1)
   (denominator :initarg :denominator
                :initform 1)))
(defclass lyqi:no-duration-lexeme (lyqi:base-duration-lexeme) ())

;;; forms
(defclass lyqi:form (lyqi:parser-symbol) ())
(defclass lyqi:verbatim-form (lyqi:form) ())
(defclass lyqi:music-form (lyqi:form)
  ((duration :initarg :duration
             :initform nil
             :accessor lyqi:duration-of)))

(defclass lyqi:simple-note-form (lyqi:music-form)
  ((rest :initarg :rest
         :initform nil)))
(defclass lyqi:rest-skip-etc-form (lyqi:music-form) ())
(defclass lyqi:chord-form (lyqi:music-form) ())
(defclass lyqi:chord-end-form (lyqi:music-form) ())
(defclass lyqi:incomplete-chord-form (lyqi:form) ())

(defclass lyqi:line-comment-form (lyqi:form) ())

;;;
;;; Lexer
;;;

;;; lexer states
(defclass lyqi:lexer-state () ())
(defclass lyqi:lexer-toplevel-state (lyqi:lexer-state) ())
(defvar lyqi:*lexer-toplevel-state* (make-instance 'lyqi:lexer-toplevel-state))

(defclass lyqi:lexer-duration?-state (lyqi:lexer-state) ())
(defvar lyqi:*lexer-duration?-state* (make-instance 'lyqi:lexer-duration?-state))

(defclass lyqi:lexer-note-duration?-state (lyqi:lexer-state) ())
(defvar lyqi:*lexer-note-duration?-state* (make-instance 'lyqi:lexer-note-duration?-state))
(defclass lyqi:lexer-note-rest?-state (lyqi:lexer-state) ())
(defvar lyqi:*lexer-note-rest?-state* (make-instance 'lyqi:lexer-note-rest?-state))

(defclass lyqi:lexer-incomplete-chord-state (lyqi:lexer-state) ())
(defvar lyqi:*lexer-incomplete-chord-state* (make-instance 'lyqi:lexer-incomplete-chord-state))

(defclass lyqi:lexer-line-comment-state (lyqi:lexer-state) ())
(defvar lyqi:*lexer-line-comment-state* (make-instance 'lyqi:lexer-line-comment-state))

;;; lex/parse functions
(defun lyqi:parse (syntax &optional end-position)
  "Return a list of form lists, built by parsing, line by line,
from current point up to `end-position' (or end of buffer).  The
list of form list is in reverse order, that is the parse list
corresponding to the last line of buffer is found first."
  (loop with end-position = (or end-position (point-max))
        with result = nil
        for (forms state) = (lyqi:parse-line syntax) then (lyqi:parse-line syntax state)
        do (push forms result)
        do (forward-line 1) ;; go to next-line
        if (>= (point) end-position) return result))

(defun lyqi:parse-line (syntax &optional state)
  "Return a form list, built by parsing current buffer starting
from current point up to the end of the current line."
  (loop with end-point = (point-at-eol)
        for finished = nil then (>= (point) end-point)
        for (new-state form non-reduced-lexemes next-form-class continue)
        = (lyqi:lex (or state lyqi:*lexer-toplevel-state*) syntax nil nil)
        then (lyqi:lex new-state syntax non-reduced-lexemes next-form-class)
        if form collect form into result
        while continue
        finally return (values result new-state)))
  

(defgeneric lyqi:lex (lexer-state syntax non-reduced-lexemes next-form-class)
  "If a lexeme can be found after point, return five values:
- the new lexer state;
- a form of type `next-form-class', or NIL if lexemes do not reduce yet;
- a list of lexemes, not yet reduced (possibly NIL);
- the class name of the next form (to be used when lexemes are reduced);
- NIL if the end of line is reached, T otherwise.
Advance point at the end of the returned lexeme.")

;;;
;;; Top level
;;;
(defmethod lyqi:lex ((lexer lyqi:lexer-toplevel-state)
                     syntax non-reduced-lexemes next-form-class)
  "Lexing in {toplevel} state
EOL : reduce all lexemes into a verbatim form
note -> note lexeme, {note-duration?} state
rest | mm-rest | skip | spacer | chord-repetition -> rest-skip-etc lexeme, {duration?} state
'<' -> chord-start lexeme, {incomplete-chord} state
% ... EOL -> line comment form, {toplevel} state
<other things> -> verbatim lexeme, {toplevel} state"
  (labels ((reduce-lexemes ()
            (when non-reduced-lexemes
              (let* ((last-lexeme (first non-reduced-lexemes))
                     (verbatim-lexemes (nreverse non-reduced-lexemes))
                     (marker (lyqi:marker (first verbatim-lexemes)))
                     (size (- (+ (lyqi:marker last-lexeme)
                                 (lyqi:size last-lexeme))
                              marker)))
                (make-instance 'lyqi:verbatim-form
                               :marker marker
                               :size size
                               :children verbatim-lexemes)))))
    (lyqi:skip-whitespace)
    (cond ((eolp)
           ;; at end of line, reduce remaining lexemes
           (values lyqi:*lexer-toplevel-state* (reduce-lexemes) nil nil nil))
          ;; a note
          ((looking-at (slot-value syntax 'note-regex))
           (values lyqi:*lexer-note-duration?-state*
                   (reduce-lexemes)
                   (list (lyqi:lex-note syntax))
                   'lyqi:simple-note-form
                   t))
          ;; rest, mm-rest, skip or spacer
          ((looking-at (slot-value syntax 'rest-skip-regex))
           (values lyqi:*lexer-duration?-state*
                   (reduce-lexemes)
                   (list (lyqi:lex-rest-skip-etc syntax))
                   'lyqi:rest-skip-etc-form
                   t))
          ;; a chord start: '<'
          ((looking-at "<\\([^<]\\|$\\)")
           (let ((marker (point-marker)))
             (forward-char 1)
             (values lyqi:*lexer-incomplete-chord-state*
                     (reduce-lexemes)
                     (list (make-instance 'lyqi:chord-start-lexeme
                                          :marker marker
                                          :size (- (point) marker)))
                     'lyqi:chord-form
                     t)))
          ;; a line comment
          ((looking-at "%[^{}].*$")
           (let ((marker (point-marker)))
             (lyqi:forward-match)
             (values lyqi:*lexer-toplevel-state*
                     (make-instance 'lyqi:line-comment-form
                                    :marker marker
                                    :size (- (point) marker))
                     nil
                     nil
                     t)))
          ;; other top level expressions are treated as verbatim
          (t
           (values lyqi:*lexer-toplevel-state*
                   nil
                   (cons (lyqi:lex-verbatim syntax) non-reduced-lexemes)
                   'lyqi:verbatim-form
                   t)))))

(defmethod lyqi:lex ((lexer lyqi:lexer-duration?-state)
                     syntax non-reduced-lexemes next-form-class)
      "Lexing in duration?-state:
duration | no-duration -> toplevel-state"
  (let* ((duration-lexeme (lyqi:lex-duration syntax))
         (all-lexemes (nreverse (cons duration-lexeme non-reduced-lexemes)))
         (first-lexeme (first all-lexemes))
         (marker (lyqi:marker first-lexeme))
         (size (- (+ (lyqi:marker duration-lexeme)
                     (lyqi:size duration-lexeme))
                  marker)))
    (values lyqi:*lexer-toplevel-state*
            (make-instance next-form-class
                           :marker marker
                           :size size
                           :children all-lexemes
                           :duration duration-lexeme)
            nil
            nil
            t)))

(defmethod lyqi:lex ((lexer lyqi:lexer-note-duration?-state)
                     syntax non-reduced-lexemes next-form-class)
  (values lyqi:*lexer-note-rest?-state*
          nil
          (cons (lyqi:lex-duration syntax) non-reduced-lexemes)
          next-form-class
          t))

(defmethod lyqi:lex ((lexer lyqi:lexer-note-rest?-state)
                     syntax non-reduced-lexemes next-form-class)
  (lyqi:skip-whitespace)
  (let* ((duration (first non-reduced-lexemes))
         (marker (point-marker))
         (rest-lexeme (when (looking-at "\\\\rest")
                        (lyqi:forward-match)
                        (make-instance 'lyqi:verbatim-lexeme
                                       :marker marker
                                       :size (- (point) marker))))
         (all-lexemes (nreverse (if rest-lexeme
                                    (cons rest-lexeme non-reduced-lexemes)
                                    non-reduced-lexemes)))
         (last-lexeme (or rest-lexeme duration))
         (first-lexeme (first all-lexemes))
         (first-marker (lyqi:marker first-lexeme))
         (size (- (+ (lyqi:marker last-lexeme)
                     (lyqi:size last-lexeme))
                  first-marker)))
    (values lyqi:*lexer-toplevel-state*
            (make-instance next-form-class
                           :marker first-marker
                           :size size
                           :children all-lexemes
                           :duration duration
                           :rest (not (not rest-lexeme)))
            nil
            nil
            t)))

(defmethod lyqi:lex ((lexer lyqi:lexer-incomplete-chord-state)
                     syntax non-reduced-lexemes next-form-class)
  "Lexing in incomplete-chord-state:
 '>' -> duration?-state
 note | other tokens -> incomplete-chord-state"
  (lyqi:skip-whitespace)
  (cond ((eolp)
         ;; at end of line, reduce remaining lexemes
         (let* ((children (nreverse non-reduced-lexemes))
                (marker (lyqi:marker (first children))))
           (values lyqi:*lexer-incomplete-chord-state*
                   (make-instance 'lyqi:incomplete-chord-form
                                  :marker marker
                                  :size (- (point) marker)
                                  :children children)
                   nil
                   nil
                   nil)))
        ;; a note
        ((looking-at (slot-value syntax 'note-regex)) 
         (values lyqi:*lexer-incomplete-chord-state*
                 nil
                 (cons (lyqi:lex-note syntax) non-reduced-lexemes)
                 next-form-class
                 t))
        ;; a chord end: '>'
        ((eql (char-after) ?\>)
         (let ((marker (point-marker)))
           (forward-char 1)
           (values lyqi:*lexer-duration?-state*
                   nil
                   (cons (make-instance 'lyqi:chord-end-lexeme
                                        :marker marker
                                        :size (- (point) marker))
                         non-reduced-lexemes)
                   (or next-form-class 'lyqi:chord-end-form)
                   t)))
        ;; something else
        (t
         (values lyqi:*lexer-incomplete-chord-state*
                 nil
                 (cons (lyqi:lex-verbatim syntax "[^ >]+") non-reduced-lexemes)
                 next-form-class
                 t))))

;;;
;;; specific lexing functions
;;;

(defun lyqi:skip-whitespace ()
  (when (looking-at "\\s-+")
    (lyqi:forward-match)))

(defun lyqi:lex-verbatim (syntax &optional verbatim-regex)
  (let ((marker (point-marker)))
    (looking-at (or verbatim-regex "\\S-+"))
    (lyqi:forward-match)
    (make-instance 'lyqi:verbatim-lexeme
                           :marker marker
                           :size (- (point) marker))))

(defun lyqi:lex-note (syntax)
  (let ((pitch 0)
        (alteration 0)
        (octave-modifier 0)
        (marker (point-marker)))
    (when (looking-at (slot-value syntax 'pitch-regex))
      ;; pitch and alteration
      (let ((pitch-data (assoc (match-string-no-properties 0)
                               (slot-value syntax 'pitch-data))))
        (setf pitch (second pitch-data))
        (setf alteration (third pitch-data)))
      (lyqi:forward-match)
      ;; octave
      (when (looking-at (slot-value syntax 'octave-regex))
        (setf octave-modifier (* (if (eql (char-after) ?\,) -1 1)
                                 (- (match-end 0) (match-beginning 0))))
        (lyqi:forward-match)))
    (make-instance 'lyqi:note-lexeme
                   :pitch pitch
                   :alteration alteration
                   :octave-modifier octave-modifier
                   :marker marker
                   :size (- (point) marker))))

(defun lyqi:lex-rest-skip-etc (syntax)
  (let* ((marker (point-marker))
         (size 1))
    (make-instance (cond ((looking-at "r")
                          (forward-char 1)
                          'lyqi:rest-lexeme)
                         ((looking-at "R")
                          (forward-char 1)
                          'lyqi:mm-rest-lexeme)
                         ((looking-at "s")
                          (forward-char 1)
                          'lyqi:space-lexeme)
                         ((looking-at "q")
                          (forward-char 1)
                          'lyqi:chord-repetition-lexeme)
                         ((looking-at "\\\\skip")
                          (lyqi:forward-match)
                          (setf size (- (point) marker))
                          (lyqi:skip-whitespace)
                          'lyqi:skip-lexeme))
                   :marker marker :size size)))

(defun lyqi:lex-duration (syntax)
  (if (or (eolp)
          (not (looking-at (slot-value syntax 'duration-regex))))
      ;; implicit duration
      (make-instance 'lyqi:no-duration-lexeme
                     :marker (point-marker)
                     :size 0)
      ;; explicit duration
      (let ((length 2)
            (dot-count 0)
            (num 1)
            (den 1)
            (marker (point-marker)))
        (when (looking-at (slot-value syntax 'duration-length-regex))
          ;; length
          (setf length (cdr (assoc (match-string-no-properties 0)
                                   (slot-value syntax 'duration-data))))
          (lyqi:forward-match)
          ;; dots
          (when (and (not (eolp))
                     (looking-at "\\.+"))
            (setf dot-count (- (match-end 0) (match-beginning 0)))
            (lyqi:forward-match))
          ;; numerator
          (when (and (not (eolp))
                     (looking-at "\\*\\([0-9]+\\)"))
            (setf num (string-to-number (match-string-no-properties 1)))
            (lyqi:forward-match)
            ;; denominator
            (when (and (not (eolp))
                       (looking-at "/\\([0-9]+\\)"))
              (setf den (string-to-number (match-string-no-properties 1)))
              (lyqi:forward-match))))
        (make-instance 'lyqi:duration-lexeme
                       :length length
                       :dot-count dot-count
                       :numerator num
                       :denominator den
                       :marker marker
                       :size (- (point) marker)))))

(provide 'lyqi-syntax)