# Free-Text Answer Input for ask-user Tool

**Date:** 2026-06-21
**Status:** Approved for implementation

## Summary

Extend the `ask-user` transient UI so the user can type a custom answer for any
question when none of the presented options fit. The feature is always available
on every question; no LLM-side opt-in is required.

## User Experience

Inside the choices group, a new `!` suffix always appears last:

```
Question 1/2: Preferred language?  [no answer selected]
1  [ ] Elisp
2  [ ] Python
3  [ ] Rust
!  [ ] Other...
```

Pressing `!` opens a minibuffer prompt:

```
Your answer: _
```

If the user previously entered a free-text answer for this question it is
pre-filled so they can edit rather than retype. An empty submission (bare RET)
is a no-op — the previous answer, if any, is preserved. `C-g` in the minibuffer
is also a no-op (existing answer preserved, transient remains live).

After entry the transient re-renders (`:transient t`) and the suffix label
reflects the entered text:

```
!  [x] Other: something custom
```

The heading also reflects it:

```
Question 1/2: Preferred language?  [answer: something custom]
```

Submit (`<return>`) works identically — the custom string is returned as the
answer for that question, indistinguishable from a predefined choice from the
LLM's perspective.

## Architecture

### No data-model changes

`selected-choice` in `mcp-server-emacs-tools-ask-user--question` already holds
an arbitrary string. A free-text answer is stored there identically to a
predefined choice. The question struct is unchanged.

### Key assignment

`!` is hardcoded outside the `1–9` / `a–z` auto-assigned range.
`--choice-keys` requires no changes.

### New function: `mcp-server-emacs-tools-ask-user--read-free-text`

```elisp
(defun mcp-server-emacs-tools-ask-user--read-free-text ()
  "Prompt the user to type a free-text answer for the current question.
Pre-fills any previously entered custom answer as the initial input.
An empty submission is treated as a no-op. C-g is also a no-op."
  (interactive)
  (let* ((q       (mcp-server-emacs-tools-ask-user--current-question))
         (current (mcp-server-emacs-tools-ask-user--question-selected-choice q))
         (choices (mcp-server-emacs-tools-ask-user--question-choices q))
         (initial (when (and current (not (member current choices))) current))
         (answer  (condition-case nil
                      (read-string "Your answer: " initial)
                    (quit nil))))
    (when (and answer (not (string= answer "")))
      (setf (mcp-server-emacs-tools-ask-user--question-selected-choice q) answer))))
```

`read-string` runs in the minibuffer while transient remains live. Because the
suffix carries `:transient t`, transient re-invokes `--build-layout` after the
body returns.

### Changes to `--build-layout`

After building `choice-specs`, compute one additional suffix spec for "Other...":

```elisp
(other-spec
 (let* ((q        (mcp-server-emacs-tools-ask-user--current-question))
        (answer   (mcp-server-emacs-tools-ask-user--question-selected-choice q))
        (choices  (mcp-server-emacs-tools-ask-user--question-choices q))
        (custom-p (and answer (not (member answer choices))))
        (label    (if custom-p
                      (propertize (concat "[x] Other: " answer) 'face 'transient-value)
                    "[ ] Other...")))
   `("!" ,label mcp-server-emacs-tools-ask-user--read-free-text :transient t)))
```

Append it to `choice-specs` before constructing the choices group vector:

```elisp
(apply #'vector choices-heading (append choice-specs (list other-spec)))
```

### MCP schema

No changes. The LLM receives the custom string as a plain answer, identical to
any predefined choice. `max-input-length` is not enforced on minibuffer input
(the user typed it themselves).

## Error Handling

- Empty minibuffer submission → no-op, previous answer preserved.
- `C-g` in minibuffer → `condition-case` catches `quit`, treats as no-op;
  transient remains live with previous answer intact.

## Testing

Four new `ert` tests in `test/unit/test-mcp-ask-user.el`:

1. **`--read-free-text` stores answer:** Mock `read-string` to return
   `"custom text"`, call `--read-free-text`, assert `selected-choice` is
   `"custom text"` and `choices` list is unchanged.

2. **`--read-free-text` empty submission is no-op:** Pre-set `selected-choice`
   to `"previous"`, mock `read-string` to return `""`, call
   `--read-free-text`, assert `selected-choice` is still `"previous"`.

3. **`--read-free-text` C-g is no-op:** Pre-set `selected-choice` to
   `"previous"`, mock `read-string` to signal `quit`, call
   `--read-free-text`, assert `selected-choice` is still `"previous"`.

4. **`--build-layout` includes `!` suffix with correct label:** Two sub-cases:
   - No custom answer active → label is `"[ ] Other..."`.
   - `selected-choice` set to a value not in `choices` → label is
     `"[x] Other: <value>"` with `transient-value` face.

## Files Changed

- `tools/mcp-server-emacs-tools-ask-user.el` — new `--read-free-text`
  function, updated `--build-layout`
- `test/unit/test-mcp-ask-user.el` — 4 new tests
