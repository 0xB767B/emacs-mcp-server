;;; mcp-server-emacs-tools-ask-user.el --- Ask-user interactive question tool -*- lexical-binding: t; -*-

;;; Commentary:

;; Exposes an MCP tool called "ask-user" that presents one or more
;; multiple-choice questions to the Emacs user via a transient UI and returns
;; the selected answers to the LLM.
;;
;; The tool accepts a `questions' array, each element being an object with a
;; `title' (string) and `options' (string array).  The response is a JSON
;; array of answer strings in the same order as the questions.
;;
;; The tool uses the async (deferred) response pattern so the process filter
;; is never blocked while waiting for the user to answer.  Concurrent calls
;; are serialised through an internal FIFO queue: while one questionnaire is
;; on screen, additional incoming calls are enqueued and dispatched one-by-one
;; as each questionnaire is submitted.
;;
;; Usage (in your Emacs init, after loading mcp-server):
;;
;;   (require 'mcp-server-emacs-tools-ask-user)
;;
;; The tool is registered automatically on require.  Enable it via:
;;
;;   (setq mcp-server-emacs-tools-enabled 'all)
;;   ;; or selectively:
;;   (setq mcp-server-emacs-tools-enabled '(ask-user))

;;; Code:

(require 'transient)
(require 'cl-lib)
(require 'mcp-server-tools)
;; mcp-server-send-tool-result and mcp-server-send-tool-error are defined in
;; mcp-server.el.  We cannot (require 'mcp-server) here because mcp-server.el
;; loads this file, which would create a circular dependency.  Declare the
;; functions so the byte-compiler does not warn about unknown functions.
(declare-function mcp-server-send-tool-result "mcp-server" (client-id request-id text))
(declare-function mcp-server-send-tool-error  "mcp-server" (client-id request-id message))

;;; --------------------------------------------------------------------------
;;; Customisation
;;; --------------------------------------------------------------------------

(defgroup mcp-server-emacs-tools-ask-user nil
  "MCP ask-user tool configuration."
  :group 'mcp-server
  :prefix "mcp-server-emacs-tools-ask-user-")

(defcustom mcp-server-emacs-tools-ask-user-max-input-length 2000
  "Maximum allowed length in characters for question titles and each option.
Inputs exceeding this limit are rejected before the UI is shown."
  :type 'integer
  :group 'mcp-server-emacs-tools-ask-user)

;;; --------------------------------------------------------------------------
;;; Transient UI
;;; --------------------------------------------------------------------------

(cl-defstruct mcp-server-emacs-tools-ask-user--question
  "Structure holding the state of a single question."
  id title choices selected-choice)

(defvar mcp-server-emacs-tools-ask-user--questions nil
  "List of `mcp-server-emacs-tools-ask-user--question' structs for the active session.")

(defvar mcp-server-emacs-tools-ask-user--current-index 0
  "Index of the currently displayed question in the active session.")

(defvar mcp-server-emacs-tools-ask-user--callback nil
  "Function called with the answers vector when the questionnaire is submitted.")

(defun mcp-server-emacs-tools-ask-user--current-question ()
  "Return the currently active question struct."
  (nth mcp-server-emacs-tools-ask-user--current-index
       mcp-server-emacs-tools-ask-user--questions))

(defun mcp-server-emacs-tools-ask-user--question-count ()
  "Return the total number of questions in the active session."
  (length mcp-server-emacs-tools-ask-user--questions))

(defun mcp-server-emacs-tools-ask-user--all-answered-p ()
  "Return non-nil if every question has a selected choice."
  (cl-every (lambda (q)
              (mcp-server-emacs-tools-ask-user--question-selected-choice q))
             mcp-server-emacs-tools-ask-user--questions))

(defun mcp-server-emacs-tools-ask-user--choice-keys (choices)
  "Assign single-character keys to CHOICES.
Returns an alist of (KEY . CHOICE) where KEY is a string like \"1\", \"a\"."
  (let ((keys (append (number-sequence ?1 ?9) (number-sequence ?a ?z)))
        result)
    (cl-mapcar (lambda (choice key)
                 (push (cons (char-to-string key) choice) result))
               choices keys)
    (nreverse result)))

(defun mcp-server-emacs-tools-ask-user--select (choice)
  "Record CHOICE as the answer for the current question.
The transient re-renders automatically because choice suffixes carry
:transient t, which causes transient to re-invoke itself after the
suffix body runs without an explicit transient-setup call."
  (let ((q (mcp-server-emacs-tools-ask-user--current-question)))
    (setf (mcp-server-emacs-tools-ask-user--question-selected-choice q) choice)))

(defun mcp-server-emacs-tools-ask-user--navigate (delta)
  "Move the current question index by DELTA, clamped to valid range.
Navigation suffixes carry :transient t so transient re-invokes
automatically; no explicit transient-setup call is needed."
  (let* ((count (mcp-server-emacs-tools-ask-user--question-count))
         (new   (+ mcp-server-emacs-tools-ask-user--current-index delta)))
    (setq mcp-server-emacs-tools-ask-user--current-index
          (max 0 (min (1- count) new)))))

(defun mcp-server-emacs-tools-ask-user--next ()
  "Move to the next question."
  (interactive)
  (mcp-server-emacs-tools-ask-user--navigate 1))

(defun mcp-server-emacs-tools-ask-user--prev ()
  "Move to the previous question."
  (interactive)
  (mcp-server-emacs-tools-ask-user--navigate -1))

(defun mcp-server-emacs-tools-ask-user--make-choice-suffix (key choice current-answer)
  "Build a transient suffix spec for KEY -> CHOICE, marking it if selected.
The spec includes :transient t so transient re-invokes itself after
selection without needing a manual transient-setup call."
  (let* ((selected (equal choice current-answer))
         (label (if selected
                    (propertize (concat "[x] " choice) 'face 'transient-value)
                  (concat "[ ] " choice))))
    `(,key ,label
           (lambda ()
             (interactive)
             (mcp-server-emacs-tools-ask-user--select ,choice))
           :transient t)))

(defun mcp-server-emacs-tools-ask-user--abort-hook ()
  "Transient-exit-hook handler: clean up if the transient was abandoned.
Only fires on genuine user quits (C-g / transient-quit-*) because:
- Choice and navigation suffixes carry :transient t, so transient
  re-invokes itself without exiting; this hook never fires for them.
- On a normal submit, --submit removes this hook before calling
  transient-quit-all, so this hook is not in the list when transient exits.
The `this-command' check below is a retained safety net."
  (when (and mcp-server-emacs-tools-ask-user--in-flight
             (memq this-command '(transient-quit-one
                                  transient-quit-all
                                  keyboard-quit)))
    (remove-hook 'transient-exit-hook
                 #'mcp-server-emacs-tools-ask-user--abort-hook)
    (let ((cb mcp-server-emacs-tools-ask-user--callback))
      (setq mcp-server-emacs-tools-ask-user--in-flight  nil
            mcp-server-emacs-tools-ask-user--callback   nil)
      (when cb
        (funcall cb nil))
      (mcp-server-emacs-tools-ask-user--dispatch-next))))

(defun mcp-server-emacs-tools-ask-user--submit ()
  "Collect all answers and invoke the registered callback."
  (interactive)
  (when (mcp-server-emacs-tools-ask-user--all-answered-p)
    (let ((answers (vconcat
                    (mapcar #'mcp-server-emacs-tools-ask-user--question-selected-choice
                            mcp-server-emacs-tools-ask-user--questions))))
      ;; Remove the abort hook before quitting so it does not treat a normal
      ;; submit as an abandonment.
      (remove-hook 'transient-exit-hook
                   #'mcp-server-emacs-tools-ask-user--abort-hook)
      (transient-quit-all)
      (when mcp-server-emacs-tools-ask-user--callback
        (funcall mcp-server-emacs-tools-ask-user--callback answers)))))

(defun mcp-server-emacs-tools-ask-user--build-layout (_children)
  "Build the transient layout dynamically from the active question."
  (let* ((idx     mcp-server-emacs-tools-ask-user--current-index)
         (count   (mcp-server-emacs-tools-ask-user--question-count))
         (q       (mcp-server-emacs-tools-ask-user--current-question))
         (choices (mcp-server-emacs-tools-ask-user--question-choices q))
         (answer  (mcp-server-emacs-tools-ask-user--question-selected-choice q))
         (keyed   (mcp-server-emacs-tools-ask-user--choice-keys choices))
         ;; The question title is the heading of the Choices group so it is
         ;; always visible: transient only renders a group heading when the
         ;; group contains at least one interactive suffix, and the Choices
         ;; group always has at least one choice suffix.
         (choices-heading (format "Question %d/%d: %s  [%s]"
                                  (1+ idx) count
                                  (mcp-server-emacs-tools-ask-user--question-title q)
                                  (if answer
                                      (format "answer: %s" answer)
                                    "no answer selected")))
         (choice-specs
          (mapcar (lambda (kv)
                    (mcp-server-emacs-tools-ask-user--make-choice-suffix
                     (car kv) (cdr kv) answer))
                  keyed))
         (nav-specs
           (when (> count 1)
             `(("[" "Previous question" mcp-server-emacs-tools-ask-user--prev :transient t)
               ("]" "Next question"     mcp-server-emacs-tools-ask-user--next :transient t))))
          (submit-specs
           `(("<return>" "Submit all answers"
              mcp-server-emacs-tools-ask-user--submit
              :inapt-if-not mcp-server-emacs-tools-ask-user--all-answered-p))))
    ;; transient-parse-suffixes (plural) maps transient-parse-suffix over the
    ;; list.  It must be called on the GROUP VECTORS, not on individual suffix
    ;; specs: transient--parse-group processes each vector and returns a parsed
    ;; group object.  Passing individual suffix lists here would return raw
    ;; suffix objects wrapped in un-parsed vectors that transient cannot use as
    ;; :setup-children output.  Both transient-parse-suffix (singular) and
    ;; transient-parse-suffixes (plural) are public API per their docstrings.
    (transient-parse-suffixes
     'mcp-server-emacs-tools-ask-user--transient
     (delq nil
           (list
            (apply #'vector choices-heading choice-specs)
            (when nav-specs (apply #'vector "Navigation" nav-specs))
            (apply #'vector "Action" submit-specs))))))

(transient-define-prefix mcp-server-emacs-tools-ask-user--transient ()
  "ask-user transient UI."
  ;; :refresh-suffixes t causes transient--refreshp to be non-nil after every
  ;; suffix invocation.  transient--post-command then calls
  ;; transient--refresh-transient → transient--init-suffixes → setup-children
  ;; → --build-layout, so the layout is rebuilt from fresh state after each
  ;; choice selection or navigation step.  Without this, :transient t on the
  ;; choice/nav suffixes would only call transient--redisplay (re-draw from
  ;; cached suffix objects) rather than re-running --build-layout, making it
  ;; appear that key presses have no effect.
  :refresh-suffixes t
  [:class transient-columns
          :setup-children mcp-server-emacs-tools-ask-user--build-layout])

(defun mcp-server-emacs-tools-ask-user--show (questions callback)
  "Present QUESTIONS to the user via transient UI.
QUESTIONS is a list of `mcp-server-emacs-tools-ask-user--question' structs.
CALLBACK is called with a vector of answer strings when all are submitted,
or with nil if the user abandoned the questionnaire (C-g)."
  (setq mcp-server-emacs-tools-ask-user--questions      questions
        mcp-server-emacs-tools-ask-user--current-index  0
        mcp-server-emacs-tools-ask-user--callback       callback)
  ;; Register the abort hook so a C-g abandonment is handled gracefully.
  (add-hook 'transient-exit-hook
            #'mcp-server-emacs-tools-ask-user--abort-hook)
  (mcp-server-emacs-tools-ask-user--transient))

;;; --------------------------------------------------------------------------
;;; Parallel-call queue
;;; --------------------------------------------------------------------------

(defvar mcp-server-emacs-tools-ask-user--queue nil
  "FIFO queue of pending ask-user calls.
Each entry is a list (CLIENT-ID REQUEST-ID QUESTIONS-LIST).")

(defvar mcp-server-emacs-tools-ask-user--in-flight nil
  "Non-nil while a questionnaire is currently displayed to the user.")

(defun mcp-server-emacs-tools-ask-user--enqueue (client-id request-id questions)
  "Add a call to the end of the queue."
  (setq mcp-server-emacs-tools-ask-user--queue
        (append mcp-server-emacs-tools-ask-user--queue
                (list (list client-id request-id questions)))))

(defun mcp-server-emacs-tools-ask-user--dispatch-next ()
  "If the queue is non-empty and no call is in flight, dispatch the next item."
  (when (and mcp-server-emacs-tools-ask-user--queue
             (not mcp-server-emacs-tools-ask-user--in-flight))
    (let* ((entry      (pop mcp-server-emacs-tools-ask-user--queue))
           (client-id  (nth 0 entry))
           (request-id (nth 1 entry))
           (questions  (nth 2 entry)))
      ;; Set in-flight BEFORE calling --show.  If --show re-enters the
      ;; Lisp event loop synchronously, the flag must already be set to
      ;; prevent a second dispatch from racing in.
      (setq mcp-server-emacs-tools-ask-user--in-flight t)
      (mcp-server-emacs-tools-ask-user--show
       questions
       (lambda (answers)
         ;; This callback and --abort-hook both clear in-flight and call
         ;; dispatch-next.  They are mutually exclusive: --submit removes
         ;; --abort-hook before quitting, and --abort-hook removes itself
         ;; before invoking this callback path.
         (setq mcp-server-emacs-tools-ask-user--in-flight nil)
         (if (null answers)
             (mcp-server-send-tool-error
              client-id request-id "ask-user: cancelled by user")
           ;; json-serialize converts the answers vector to a JSON array
           ;; string, e.g. ["A","Y"].  The LLM receives this as a text
           ;; content item whose text value is that JSON string.
           (mcp-server-send-tool-result
             client-id request-id
             (json-serialize answers)))
         (mcp-server-emacs-tools-ask-user--dispatch-next))))))

;;; --------------------------------------------------------------------------
;;; Input validation
;;; --------------------------------------------------------------------------

(defun mcp-server-emacs-tools-ask-user--validate-string (s field-name)
  "Signal an error if S is not a string or exceeds the max input length.
FIELD-NAME is used in the error message."
  (unless (stringp s)
    (error "ask-user: %s must be a string" field-name))
  (when (> (length s) mcp-server-emacs-tools-ask-user-max-input-length)
    (error "ask-user: %s exceeds maximum length of %d characters"
           field-name mcp-server-emacs-tools-ask-user-max-input-length)))

(defun mcp-server-emacs-tools-ask-user--validate-and-build-questions (raw-questions)
  "Validate RAW-QUESTIONS (a vector or list of alists) and return a list of structs.
Signals an error on any validation failure."
  (let ((qs (cond
             ((vectorp raw-questions) (append raw-questions nil))
             ((listp   raw-questions) raw-questions)
             (t (error "ask-user: questions must be an array")))))
    (unless qs
      (error "ask-user: questions must be a non-empty array"))
    (cl-loop for entry in qs
             for i from 1
             collect
             (let* ((title   (alist-get 'title   entry))
                    (options (alist-get 'options entry))
                    (choices (cond
                              ((vectorp options) (append options nil))
                              ((listp   options) options)
                              (t (error "ask-user: question %d options must be an array" i)))))
               (mcp-server-emacs-tools-ask-user--validate-string
                title (format "question %d title" i))
               (unless choices
                 (error "ask-user: question %d options must be a non-empty array" i))
               (dolist (opt choices)
                 (mcp-server-emacs-tools-ask-user--validate-string
                  opt (format "question %d option" i)))
               (make-mcp-server-emacs-tools-ask-user--question
                :id              (number-to-string i)
                :title           title
                :choices         choices
                :selected-choice nil)))))

;;; --------------------------------------------------------------------------
;;; Tool handler
;;; --------------------------------------------------------------------------

(defun mcp-server-emacs-tools-ask-user--handler (arguments)
  "Handle an ask-user MCP tool call with ARGUMENTS.

ARGUMENTS is an alist with:
  questions - JSON array of objects, each with:
    title   - string, the question to present
    options - JSON array of answer-choice strings

Enqueues the request and returns `mcp-deferred' immediately so the
process filter is not blocked.  The response is a JSON array of answer
strings (one per question) sent from the transient callback once the
user has submitted all answers."
  (let* ((raw-questions (alist-get 'questions arguments))
         (questions     (mcp-server-emacs-tools-ask-user--validate-and-build-questions
                         raw-questions))
         (client-id     mcp-server--current-client-id)
         (request-id    mcp-server--current-request-id))
    (mcp-server-emacs-tools-ask-user--enqueue client-id request-id questions)
    (mcp-server-emacs-tools-ask-user--dispatch-next)
    'mcp-deferred))

;;; --------------------------------------------------------------------------
;;; Self-registration
;;; --------------------------------------------------------------------------

(mcp-server-register-tool
 (make-mcp-server-tool
  :name        "ask-user"
  :title       "Ask User Questions"
  :description
  "Ask the user one or more multiple-choice questions via an interactive Emacs UI.
Use this whenever you need to gather user preferences, clarify ambiguous
instructions, or get decisions on implementation choices.  The user selects
one option per question and the answers are returned as a JSON array of
strings in the same order as the questions.
Concurrent calls are queued and presented one at a time."
  :input-schema
  '((type . "object")
    (properties
     . ((questions
         . ((type . "array")
            (description . "The questions to present to the user")
            (items
             . ((type . "object")
                (properties
                 . ((title
                     . ((type . "string")
                        (description . "The question to present to the user")))
                    (options
                     . ((type . "array")
                        (items . ((type . "string")))
                        (description . "The answer choices to present to the user")))))
                (required . ["title" "options"])))))))
    (required . ["questions"]))
  :function     #'mcp-server-emacs-tools-ask-user--handler
  :annotations  '((readOnlyHint    . :false)
                  (destructiveHint . :false)
                  (idempotentHint  . :false)
                  (openWorldHint   . t))))

(provide 'mcp-server-emacs-tools-ask-user)

;;; mcp-server-emacs-tools-ask-user.el ends here
