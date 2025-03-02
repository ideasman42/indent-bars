;;; indent-bars.el --- highlight indentation with bars -*- lexical-binding: t; -*-
;; Copyright (C) 2023  J.D. Smith

;; Author: J.D. Smith
;; Homepage: https://github.com/jdtsmith/indent-bars
;; Package-Requires: ((emacs "27.1") (compat "29.1.4.1"))
;; Version: 0.0.1
;; Keywords: convenience
;; Prefix: indent-bars
;; Separator: -

;; indent-bars is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; indent-bars is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; indent-bars highlights indentation with configurable font-lock
;; based vertical bars.  The color and appearance (weight, pattern,
;; position within the character, zigzag, etc.) are all configurable.
;; Includes the option for depth-varying colors and highlighting the
;; indentation level of the current line.  Bars span blank lines, by
;; default.  indent-bars works in any mode using fixed, space-based
;; indentation.


;;; Code:
;;;; Requires
(require 'cl-lib)
(require 'color)
(require 'face-remap)
(require 'outline)
(require 'font-lock)
(require 'compat)

;;;; Customization
(defgroup indent-bars nil
  "Highlight indentation bars."
  :group 'basic-faces
  :prefix "indent-bars-")

;;;;; Bar Shape
(defcustom indent-bars-width-frac 0.25
  "The width of the indent bar as a fraction of the character width."
  :type '(float :tag "Width Fraction"
		:match (lambda (_ val) (and val (<= val 1) (>= val 0)))
		:type-error "Fraction must be between 0 and 1")
  :group 'indent-bars)

(defcustom indent-bars-pad-frac 0.1
  "The offset of the bar from the left edge of the character.
A float, the fraction of the character width."
  :type '(float :tag "Offset Fraction"
	  :match (lambda (_ val) (and val (<= val 1) (>= val 0)))
	  :type-error "Fraction must be between 0 and 1")
  :group 'indent-bars)

(defcustom indent-bars-pattern " . . . . ."
  "A pattern specifying the vertical structure of indent bars.
Space signifies blank regions, and any other character signifies
filled regions.  The pattern length is scaled to match the
character height.  Example: \". . \" would specify alternating
filled and blank regions each approximately one-quarter of the
character height.  Note that the non-blank characters need not be
the same (e.g., see `indent-bars-zigzag')."
  :type '(string :tag "Fill Pattern")
  :group 'indent-bars)

(defcustom indent-bars-zigzag nil
  "The zigzag to apply to the bar pattern.
If non-nil, an alternating zigzag offset will be applied to
consecutive groups of identical non-space characters in
`indent-bars-pattern'.  Starting from the top of the pattern,
positive values will zigzag (right, left, right, ..) and negative
values (left, right, left, ...).

Example:

  pattern: \" .**.\"
  width:   0.5
  pad:     0.25
  zigzag: -0.25

would produce a zigzag pattern which differs from the normal
bar pattern as follows:

    |    |            |    |
    | .. | =========> |..  |
    | .. |            |  ..|
    | .. | apply zig- |  ..|
    | .. | zag -0.25  |..  |

Note that the pattern will be truncated at both left and right
boundaries, so (although this is not required) achieving an equal
zigzag left and right requires leaving sufficient padding on each
side of the bar; see `indent-bars-pad-frac' and
`indent-bars-width-frac'."
  :type '(choice
	  (const :tag "No Zigzag" :value nil)
	  (float :value 0.1 :tag "Zigzag Fraction"
		 :match (lambda (_ val) (and val (<= val 1) (>= val -1)))
		 :type-error "Fraction must be between -1 and 1"))
  :group 'indent-bars)

;;;;; Bar Colors
(defcustom indent-bars-color
  '(highlight :face-bg t :blend 0.3)
  "The main indent bar color.
The format is a list of 1 required element, followed by an
optional plist (keyword/value pairs):

  (main_color [:face-bg :blend])

where:

  MAIN_COLOR: Specifies the main indentation bar
    color (required).  It is either a face name symbol, from
    which the foreground color will be used as the primary bar
    color, or an explicit color (a string).

  FACE-BG: A boolean controlling interpretation of the
    MAIN_COLOR face (if configured).  If non-nil, the background
    color of the face will be used as the main bar color instead
    of its foreground.

  BLEND: an optional blend factor, a float between 0 and 1.  If
    non-nil, the main bar color will be computed as a blend
    between MAIN_COLOR and the frame background color,
    notionally:

      BLEND * MAIN_COLOR + (1 - BLEND) * frame-background

    If BLEND is nil or unspecified, no blending is done, and
    MAIN_COLOR is used as-is."
  :type
  '(list (choice :tag "Main Bar Color"
		 color
		 (face :tag "from Face"))
	 (plist :tag "Options"
		:inline t
		:options
		((:face-bg (boolean
			    :tag "Use Face's Background Color"
			    :value t))
		 (:blend (float
			  :tag "Blend Factor"
			  :value 0.5
			  :match (lambda (_ val) (and val (<= val 1) (>= val 0)))
			  :type-error "Factor must be between 0 and 1")))))
  :group 'indent-bars)

(defcustom indent-bars-color-by-depth
  '(:regexp "outline-\\([0-9]+\\)" :blend 1)
  "Configuration for depth-varying indentation bar coloring.
If non-nil, depth-based coloring is performed.  This should be a
plist with keys:

    (:regexp :face-bg :palette :blend)

with:

  REGEXP: A regular expression string used to match against all
    face names.  For the matching faces, the first match group in
    the regex (if any) will be interpreted as a number, and used
    to sort the resulting list of faces.  The foreground color of
    each matching face will then constitute the depth color
    palette (see also PALETTE, which this option overrides).

  FACE-BG: A boolean.  If non-nil, use the background color
    from the faces matching REGEXP for the palette instead of
    their foreground colors.

  PALETTE: An explicit cyclical palette of colors/faces for
    depth-varying bar colors.  Note that REGEXP takes precedence
    over this setting.  The format is a list of faces (symbols)
    or colors (strings) to be used as a color cycle for coloring
    indentations at increasing levels.  Each face can optionally
    be specified as a cons cell (face . 'bg) to specify using
    that face's background color instead of its foreground.

      (face_or_color | (face . 'bg) ...)

    While this list can contain a single element, it makes little
    sense to do so.  The depth palette will be used cyclically,
    i.e. when a bar's indentation depth exceeds the length of the
    palette, colors will be obtained by wrapping around to the
    beginning of the list.

  BLEND: a blend factor (0..1) which controls how palette colors
    are blended with the main color, prior to blending with the
    frame background color (see `indent-bars-color' for
    information on how blend factors are specified).  A nil value
    causes the palette colors to be used as-is.  A unity value
    causes the palette color to be blended directly with the
    background using any blend factor from `indent-bars-color'.

Note that, for this setting to have any effect, one of REGEXP or
PALETTE is required (the former overriding the latter).  If both
are omitted or nil, all bars will have the same color, based on
MAIN_COLOR (aside possibly from the bar at the current
indentation level, if configured; see
`indent-bars-highlight-current-depth')."
  :type '(choice :tag "Depth Palette"
		 (const :tag "No Depth-Coloring" nil)
		 (plist :tag "Depth-Coloring"
			:options
			((:regexp (regexp :tag "Face regexp"))
			 (:face-bg
			  (boolean
			   :value t
			   :tag "Use Matching Face's Background Colors"))
			 (:palette
			  (repeat :tag "Explicit Color/Face List"
				  (choice (color :tag "Color")
					  (face :tag "Foreground from Face")
					  (cons :tag "Background from Face"
						:format "Background from %v"
						face
						(const :format "\n" :value bg)))))
			 (:blend
			  (float :tag "Blend Fraction into Main Color"
				 :value 0.5
				 :match (lambda (_ val)
					  (and val (<= val 1) (>= val 0)))
				 :type-error
				 "Factor must be between 0 and 1")))))
  :group 'indent-bars)

(defcustom indent-bars-highlight-current-depth
  '(:pattern ".")			; solid bar, no color change
  "Current indentation depth bar highlight configuration.
Use this to configure optional highlighting of the bar at the
current line's indentation depth level.

Format:

    nil | (:color :face :face-bg :background :blend
           :width :pad :pattern :zigzag)

If nil, no highlighting will be applied to bars at the current
depth of the line at point.  Otherwise, a plist describes what
highlighting to apply, which can include changes to color and/or
bar pattern.  At least one of :color, :face, :width, :pad,
:pattern, or :zigzag must be set and non-nil for this setting to
take effect.

With COLOR or FACE set, all bars at the current depth will be
highlighted in the appropriate color, either COLOR, or, if FACE
is set, FACE's foreground or background color (the latter if
FACE-BG is non-nil).  If BACKGROUND is set to a color, this will
be used for the background color of the current bar (i.e. not the
stipple color).

If BLEND is provided, it is a blend fraction between 0 and 1 for
blending the highlight color with the existing (depth-based or
main) bar color; see `indent-bars-colors' for its meaning.
BLEND=1 indicates using the full, unblended highlight
color (i.e., the same as omitting BLEND).

If any of WIDTH, PAD, PATTERN, or ZIGZAG are set, the bar pattern
at the current level will be altered as well.  Note that
`indent-bars-width-frac', `indent-bars-pad-frac',
`indent-bars-pattern', and `indent-bars-zigzag' will be used as
defaults for any missing values; see these variables."
  :type '(choice
	  (const :tag "No Current Highlighting" :value nil)
	  (plist :tag "Highlight Current Depth"
		 :options
		 ((:color (color :tag "Highlight Color"))
		  (:face (face :tag "Color from Face"))
		  (:face-bg (boolean :tag "Use Face's Background Color"))
		  (:background (color :tag "Background Color of Current Bar"))
		  (:blend (float :tag "Blend Fraction into Existing Color")
			  :value 0.5
			  :match (lambda (_ val) (and (<= val 1) (>= val 0)))
			  :type-error "Factor must be between 0 and 1")
		  (:width (float :tag "Bar Width"))
		  (:pad (float :tag "Bar Padding (from left)"))
		  (:pattern (string :tag "Fill Pattern"))
		  (:zigzag (float :tag "Zig-Zag")))))
  :group 'indent-bars)

;;;;; Other
(defcustom indent-bars-spacing-override nil
  "Override for default, major-mode based indentation spacing.
Set only if the default guessed spacing is incorrect.  Becomes
buffer-local automatically."
  :local t
  :type '(choice integer (const :tag "Discover automatically" :value nil))
  :group 'indent-bars)

(defcustom indent-bars-display-on-blank-lines t
  "Whether to display bars on blank lines."
  :type 'boolean
  :group 'indent-bars)

;;;; Colors
(defvar indent-bars--main-color nil)
(defvar indent-bars--depth-palette nil)
(defvar indent-bars--current-depth-palette nil
  "Palette for highlighting current depth.
May be nil, a color string or a vector of colors strings.")

(defun indent-bars--blend-colors (c1 c2 fac)
  "Return a fractional color between two colors C1 and C2.
Each is a string color.  The fractional blend point is the
float FAC, with 1.0 matching C1 and 0.0 C2."
  (apply #'color-rgb-to-hex
	 (cl-mapcar (lambda (a b)
		      (+ (* a fac) (* b (- 1.0 fac))))
		    (color-name-to-rgb c1) (color-name-to-rgb c2))))

(defun indent-bars--main-color (&optional tint tint-blend)
  "Calculate the main bar color.
Uses `indent-bars-color' for color and background blend config.
If TINT and TINT-BLEND are passed, first blend the TINT color
into the main color with the requested blend, prior to blending
into the background color."
  (cl-destructuring-bind (main &key face-bg blend) indent-bars-color
    (let ((col (cond ((facep main)
		      (funcall (if face-bg #'face-background #'face-foreground)
			       main))
		     ((color-defined-p main) main))))
      (if (and tint tint-blend (color-defined-p tint))
	  (setq col (indent-bars--blend-colors tint col tint-blend)))
      (if blend
	  (setq col
		(indent-bars--blend-colors
		 col (frame-parameter nil 'background-color) blend)))
      col)))

(defun indent-bars--depth-palette ()
  "Calculate the palette of depth-based colors (a vector).
See `indent-bars-color-by-depth'."
  (when indent-bars-color-by-depth
    (cl-destructuring-bind (&key regexp face-bg palette blend)
	indent-bars-color-by-depth
      (let ((colors
	     (cond
	      (regexp
	       (indent-bars--depth-colors-from-regexp regexp face-bg))
	      (palette
	       (delq nil
		     (cl-loop for el in palette
			      collect (cond
				       ((and (consp el) (facep (car el)))
					(face-background (car el)))
				       ((facep el)
					(face-foreground el))
				       ((color-defined-p el) el)
				       (t nil))))))))
	(vconcat
	 (if blend
	     (mapcar (lambda (c) (indent-bars--main-color c blend)) colors)
	   colors))))))

(defun indent-bars--current-depth-palette ()
  "Colors for highlighting the current depth bar.
A color or palette (vector) of colors is returned, which may be
nil, in which case no special current depth-coloring is used.
See `indent-bars-highlight-current-depth' for
configuration."
  (when indent-bars-highlight-current-depth
    (cl-destructuring-bind (&key color face face-bg blend &allow-other-keys)
	indent-bars-highlight-current-depth
      (when-let ((color
		  (cond
		   ((facep face)
		    (funcall (if face-bg #'face-background #'face-foreground)
			     face))
		   ((and color (color-defined-p color)) color))))
	(if blend
	    (if indent-bars--depth-palette ; blend into normal depth palette
		(vconcat (mapcar (lambda (c)
				   (indent-bars--blend-colors color c blend))
				 indent-bars--depth-palette))
	      (indent-bars--blend-colors color indent-bars--main-color blend))
	  color)))))



(defun indent-bars--depth-colors-from-regexp (regexp &optional face-bg)
  "Return a list of depth colors (strings) for faces matching REGEXP.
The first capture group in REGEXP will be interpreted as a number
and used to sort the list numerically.  A list of the foreground
color of the matching, sorted faces will be returned, unless
FACE-BG is non-nil, in which case the background color is
returned."
  (mapcar (lambda (x) (funcall (if face-bg #'face-background
				 #'face-foreground)
			       (cdr x) nil t))
          (seq-sort-by #'car
		       (lambda (a b) (cond
				      ((not (numberp b)) t)
				      ((not (numberp a)) nil)
				      (t (< a b))))
                       (delq nil
			     (seq-map
			      (lambda (x)
				(let ((n (symbol-name x)))
				  (if (string-match regexp n)
                                      (cons (string-to-number (match-string 1 n))
					    x))))
                              (face-list))))))

(defun indent-bars--get-color (depth  &optional current-highlight)
  "Return the color appropriate for indentation DEPTH.
If CURRENT-HIGHLIGHT is non-nil, return the appropriate highlight
color, if setup (see `indent-bars-highlight-current-depth')."
  (let* ((palette (or (and current-highlight
			   indent-bars--current-depth-palette)
		    indent-bars--depth-palette)))
    (cond
     ((vectorp palette)
      (aref palette (mod (1- depth) (length palette))))
     (palette)  ; single color
     (t indent-bars--main-color))))

;;;; Faces
(defvar indent-bars--faces nil)
(defvar-local indent-bars--remap-face nil)

(defun indent-bars--create-stipple-face (w h rot)
  "Create and set the default `indent-bars-stipple' face.
Create for character size W x H with offset ROT."
  (face-spec-set
   'indent-bars-stipple
   `((t
      (:inherit nil :stipple ,(indent-bars--stipple w h rot))))))

(defun indent-bars--calculate-face-spec (depth)
  "Calculate the face spec for indentation bar at an indentation DEPTH.
DEPTH starts at 1."
  `((t . ( :inherit indent-bars-stipple
	   :foreground ,(indent-bars--get-color depth)))))

(defun indent-bars--create-faces (num &optional redefine)
  "Create bar faces up to depth NUM, redefining them if REDEFINE is non-nil.
Saves the vector of face symbols in variable
`indent-bars--faces'."
  (setq indent-bars--faces
	(vconcat
	 (cl-loop for i from 1 to num
		  for face = (intern (format "indent-bars-%d" i))
		  do
		  (if (and redefine (facep face)) (face-spec-reset-face face))
		  (face-spec-set face (indent-bars--calculate-face-spec i))
		  collect face))))

(defsubst indent-bars--face (depth)
  "Return the bar face for bar DEPTH, creating it if necessary."
  (if (> depth (length indent-bars--faces))
      (indent-bars--create-faces depth))
  (aref indent-bars--faces (1- depth)))

(defvar indent-bars-orig-unfontify-region nil)
(defun indent-bars--unfontify (beg end)
  "Unfontify region between BEG and END.
Removes the display properties in addition to the normal managed
font-lock properties."
  (let ((font-lock-extra-managed-props
         (append '(display) font-lock-extra-managed-props)))
    (funcall indent-bars-orig-unfontify-region beg end)))

;;;; Display
(defvar-local indent-bars-spacing nil)

(defsubst indent-bars--block (n)
  "Create a block of N low-order 1 bits."
  (- (ash 1 n) 1))

(defun indent-bars--stipple-rot (w)
  "Return the stipple rotation for pattern with W for the current window."
  (mod (car (window-edges nil t nil t)) w))

(defun indent-bars--rot (num w n)
  "Shift number NUM of W bits up by N bits, carrying around to the low bits.
N should be strictly less than W and the returned value will fit
within W bits."
  (logand (indent-bars--block w) (logior (ash num n) (ash num (- n w)))))

(defun indent-bars--row-data (w pad rot width-frac)
  "Calculate stipple row data to fit in character of width W.
The width of the pattern of filled pixels is determined by
WIDTH-FRAC.  The pattern itself is shifted up by PAD bits (which
shifts the pattern to the right, for positive values of PAD).
Subsequently, the value is shifted up (with W-bit wrap-around) by
ROT bits, and returned.  ROT is the starting bit offset of a
character within the closest stipple repeat to the left; i.e. if
pixel 1 of the stipple aligns with pixel 1 of the chacter, ROT=0.
ROT should be less than W."
  (let* ((bar-width (max 1 (round (* w width-frac))))
	 (num (indent-bars--rot
	       (ash (indent-bars--block bar-width) pad) w rot)))
    (apply #'unibyte-string
	   (cl-loop for boff = 0 then (+ boff 8) while (< boff w)
		    for nbits = (min 8 (- w boff))
		    collect (ash (logand num
					 (ash (indent-bars--block nbits) boff))
				 (- boff))))))

;; ** Notes on the stipples:
;;
;; indent-bars uses a selectively-revealed stipple pattern with a
;; width equivalent to the (presumed fixed) width of characters to
;; efficiently draw bars.  A stipple pattern is drawn as a fixed
;; repeating bit pattern, with its lowest bits and earlier bytes
;; leftmost.  It is drawn with respect to the *entire frame*, with its
;; first bit aligned with the first (leftmost) frame pixel.  Turning
;; on :stipple for a character merely "opens a window" on that
;; frame-filling, repeating stipple pattern.  Since the pattern starts
;; outside the body (in literally the first frame pixel, typically in
;; the fringe), you must consider the shift between the first pixel of
;; a character and the first pixel of the repeating stipple block at
;; that pixel position or above:
;; 
;;     |<-frame edge |<---buffer/window edge
;;     |<--w-->|<--w-->|<--w-->|     w = pattern width
;;     | marg/fringe |<-chr->|     chr = character width = w
;;             |<-g->|               g = gutter offset of chr start, g<w
;;
;; Or, when the character width exceeds the margin/fringe offset:
;; 
;;     |<-frame edge |<---buffer/window edge
;;     |<--------w-------->|<---------w-------->|
;;     | marg/fringe |<-------chr------->|
;;     |<-----g----->|
;;
;; So g = (mod marg/fringe w).
;; 
;; When the block/zigzag/whatever pattern is made, to align with
;; characters, it must get shifted up (= right) by g bits, with carry
;; over (wrap) around w=(window-font-width) bits (i.e the width of the
;; bitmap).  The byte/bit pattern is first-lowest-leftmost.
;;
;; Note that different window sides will often have different g
;; values, which means the same bitmap cannot work for the buffer in
;; both windows.  So showing the same buffer side by side can lead to
;; mis-alignment in the non-active buffer.
;;
;; Solutions:
;;
;;  - Use window hooks to update the stipple bitmap as focus or
;;    windows change.  So at least the focused buffer looks correct.
;;  - Otherwise, just live with it?
;;  - Suggest using separate frames for this?
;;  - Hide the bars be setting the stipple pattern to 0 in unfocused
;;    windows?  But this isn't great.  The information is useful.
;;  - Could also hide only in non-main window showing the current
;;    buffer, with different g values.  But it will be suprising when
;;    they vanish only when the same buffer is shown twice.
;;  - Provide a helper command to adjust window sizes so g is
;;    preserved (for a given w).  But two *different* buffers, both
;;    side-by-side, make this impossible to work at the same time (if
;;    they have different font sizes).  Maybe that's OK though, if you
;;    are considering the current buffer only.
;;  - Use C-x 4 c (clone-indirect-buffer-other-window).  Probably the
;;    best solution!  But a bug in Emacs <29 means
;;    `face-remapping-alist' is shared between indirect and master
;;    buffers.  Fixed in Emacs 29.

(defun indent-bars--stipple (w h rot
			     &optional width-frac pad-frac pattern zigzag)
  "Calculate stipple bitmap pattern for char width W and height H.
ROT is the number of bits to rotate the pattern around to the
right (with wrap).

Uses configuration variables `indent-bars-width-frac',
`indent-bars-pad-frac', `indent-bars-pattern', and
`indent-bars-zigzag', unless PAD-FRAC, WIDTH-FRAC, PATTERN,
and/or ZIGZAG are set (the latter overriding the config
variables, which see)."
  (let* ((rowbytes (/ (+ w 7) 8))
	 (pattern (or pattern indent-bars-pattern))
	 (pat (if (< h (length pattern)) (substring pattern 0 h) pattern))
	 (plen (length pat))
	 (chunk (/ (float h) plen))
	 (small (floor chunk))
	 (large (ceiling chunk))
	 (pad-frac (or pad-frac indent-bars-pad-frac))
	 (pad (round (* w pad-frac)))
	 (zigzag (or zigzag indent-bars-zigzag))
	 (zz (if zigzag (round (* w zigzag)) 0))
	 (zeroes (make-string rowbytes ?\0))
	 (width-frac (or width-frac indent-bars-width-frac))
	 (dlist (if (and (= plen 1) (not (string= pat " "))) ; solid bar
		    (list (indent-bars--row-data w pad rot width-frac)) ; one row
		  (cl-loop for last-fill-char = nil then x
			   for x across pat
			   for n = small then (if (and (/= x ?\s) (= n small))
						  large
						small)
			   for zoff = zz then (if (and last-fill-char
						       (/= x ?\s)
						       (/= x last-fill-char))
						  (- zoff) zoff)
			   for row = (if (= x ?\s) zeroes
				       (indent-bars--row-data w (+ pad zoff)
							      rot width-frac))
			   append (cl-loop repeat n collect row)))))
    (list w (length dlist) (string-join dlist))))

(defun indent-bars--draw (start end &optional bar-from obj)
  "Set bar text properties from START to END, starting at bar number BAR-FROM.
BAR-FROM is one by default.  If passed, properties are set in
OBJ, otherwise in the buffer.  OBJ is returned."
  (cl-loop for pos = start then (+ pos indent-bars-spacing) while (< pos end)
	   for barnum from (or bar-from 1)
	   do (put-text-property pos (1+ pos)
				 'face (indent-bars--face barnum) obj))
  obj)

(defun indent-bars--display ()
  "Display indentation bars based on line contents."
  (save-excursion
    (goto-char (match-beginning 1))
    (indent-bars--draw (+ (line-beginning-position) indent-bars-spacing) (match-end 1)))
  nil)

;;;; Font Lock
(defvar-local indent-bars--font-lock-keywords nil)
(defvar indent-bars--font-lock-blank-line-keywords nil)

(defvar font-lock-beg) (defvar font-lock-end) ; Dynamic font-lock variables!
(defun indent-bars--extend-blank-line-regions ()
  "Extend the region about to be font-locked to include stretches of blank lines."
  ;; (message "request to extend: %d->%d" font-lock-beg font-lock-end)
  (let ((changed nil) (chars " \n"))
    (goto-char font-lock-beg)
    (when (< (skip-chars-backward chars) 0)
      (unless (bolp) (beginning-of-line 2)) ; spaces at end don't count
      (when (< (point) font-lock-beg)
	(setq changed t font-lock-beg (point))))
    (goto-char font-lock-end)
    (when (> (skip-chars-forward chars) 0)
      (unless (bolp) (beginning-of-line 1))
      (when (> (point) font-lock-end)
	(setq changed t font-lock-end (point))))
    ;; (if changed (message "expanded to %d->%d" font-lock-beg font-lock-end))
    changed))

(defun indent-bars--handle-blank-lines ()
  "Display the appropriate bars on regions of one or more blank-only lines.
Only called by font-lock if `indent-bars-display-on-blank-lines'
is non-nil.  Uses surrounding line indentation to determine
additional bars to display on each line, and uses a string
display property on the final newline if necessary to display the
needed bars.  Blank lines at the beginning or end of the buffer
are not indicated, even if otherwise they would be."
  (let* ((beg (match-beginning 0))
	 (end (match-end 0))
	 ctxbars)
    (when (and (/= end (point-max)) (/= beg (point-min)))
      (save-excursion
	;; (message "BL: %d[%d]->%d[%d]" beg (/ (current-indentation) indent-bars-spacing)
	;; 	 end
	;; 	 (progn
	;; 	   (goto-char end)
	;; 	   (/ (current-indentation) indent-bars-spacing)))
	(goto-char (1- beg)) 		;beg always bol
	(when (> (setq ctxbars
		       (1- (max (/ (current-indentation) indent-bars-spacing)
				(progn
				  (goto-char (1+ end)) ; end always eol
				  (/ (current-indentation) indent-bars-spacing)))))
		 0)
	  (goto-char beg)
	  (while (<= (point) end)
	    (let* ((bp (line-beginning-position))
		   (ep (line-end-position))
		   (len (- ep bp))
		   (nbars (/ (max 0 (1- len)) indent-bars-spacing)))
	      ;; (message "len: %d nbars: %d ctxbars:%d" len nbars ctxbars)
	      ;; Draw "real" bars in existing blank
	      (if (> nbars 0) (indent-bars--draw (+ bp indent-bars-spacing) ep))
	      ;; Add fake bars via display
	      (when (> ctxbars nbars) 
		(let* ((off (- (* (1+ nbars) indent-bars-spacing) len))
		       (nsp (1+ (- (* ctxbars indent-bars-spacing) len)))
		       (s (concat (make-string nsp ?\s) "\n")))
		  (indent-bars--draw off nsp (1+ nbars) s)
		  (put-text-property ep (1+ ep) 'display s)))
	      (beginning-of-line 2)))))
      nil)))

;;;; Current indentation highlight
(defvar-local indent-bars--current-depth 0)
(defvar indent-bars--current-bg-color nil)
(defvar-local indent-bars--current-depth-stipple nil)

(defun indent-bars--set-current-bg-color ()
  "Record the current bar background color."
  (cl-destructuring-bind (&key background &allow-other-keys)
      indent-bars-highlight-current-depth
    (setq indent-bars--current-bg-color background)))

(defun indent-bars--set-current-depth-stipple (&optional w h rot)
  "Set the current depth stipple highlight (if any).
One of the keywords :width, :pad, :pattern, or :zigzag must be
set in `indent-bars-highlight-current-depth' config.  W, H, and
ROT are as in `indent-bars--stipple', and have similar default values."
  (cl-destructuring-bind (&key width pad pattern zigzag &allow-other-keys)
      indent-bars-highlight-current-depth
    (when (or width pad pattern zigzag)
      (let* ((w (or w (window-font-width)))
	     (h (or h (window-font-height)))
	     (rot (or rot (indent-bars--stipple-rot w))))
	(setq indent-bars--current-depth-stipple
	      (indent-bars--stipple w h rot width pad pattern zigzag))))))

(defun indent-bars--highlight-current-depth ()
  "Refresh current indentation depth highlight.
Works by remapping the appropriate indent-bars-N face."
  (let ((depth (/ (current-indentation) indent-bars-spacing)))
    (when (not (= depth indent-bars--current-depth))
      (if indent-bars--remap-face 	; out with the old
	  (face-remap-remove-relative indent-bars--remap-face))
      (setq indent-bars--current-depth depth)
      (when (> depth 0)
	(let ((face (indent-bars--face depth))
	      (hl-col (and indent-bars--current-depth-palette
			   (indent-bars--get-color depth 'highlight)))
	      (hl-bg indent-bars--current-bg-color))
	  (when (or hl-col hl-bg indent-bars--current-depth-stipple)
	    (setq indent-bars--remap-face
		  (apply #'face-remap-add-relative face
		   `(,@(when hl-col `(:foreground ,hl-col))
		     ,@(when hl-bg `(:background ,hl-bg))
		     ,@(when indent-bars--current-depth-stipple
			 `(:stipple ,indent-bars--current-depth-stipple)))))))))))

;;;; Text scaling and window hooks
(defvar-local indent-bars--remap-stipple nil)
(defvar-local indent-bars--gutter-rot 0)
(defun indent-bars--window-change (win)
  "Update the stipple for buffer in window WIN, if selected."
  (when (eq win (selected-window))
    (let* ((w (window-font-width))
	   (rot (indent-bars--stipple-rot w)))
      (when (/= indent-bars--gutter-rot rot)
	(setq indent-bars--gutter-rot rot)
	(indent-bars--resize-stipple w rot)))))

(defun indent-bars--resize-stipple (&optional w rot)
  "Recreate stipple(s) with updated size.
W is the optional `window-font-width' and ROT the bit rotation If
not passed they will be calculated."
  (if indent-bars--remap-stipple
      (face-remap-remove-relative indent-bars--remap-stipple))
  (let* ((w (or w (window-font-width)))
	 (rot (or rot (indent-bars--stipple-rot w)))
	 (h (window-font-height)))
    (setq indent-bars--remap-stipple
	  (face-remap-add-relative
	   'indent-bars-stipple
	   :stipple (indent-bars--stipple w h rot)))
    (when indent-bars--current-depth-stipple
      (indent-bars--set-current-depth-stipple w h rot)
      (setq indent-bars--current-depth 0)
      (indent-bars--highlight-current-depth))))

;;;; Setup and mode
(defun indent-bars--guess-spacing ()
  "Get indentation spacing of current buffer.
Adapted from `highlight-indentation-mode'."
  (cond
   (indent-bars-spacing-override)
   ((and (derived-mode-p 'python-mode) (boundp 'py-indent-offset))
    py-indent-offset)
   ((and (derived-mode-p 'python-mode) (boundp 'python-indent-offset))
    python-indent-offset)
   ((and (derived-mode-p 'ruby-mode) (boundp 'ruby-indent-level))
    ruby-indent-level)
   ((and (derived-mode-p 'scala-mode) (boundp 'scala-indent:step))
    scala-indent:step)
   ((and (derived-mode-p 'scala-mode) (boundp 'scala-mode-indent:step))
    scala-mode-indent:step)
   ((and (or (derived-mode-p 'scss-mode) (derived-mode-p 'css-mode))
	 (boundp 'css-indent-offset))
    css-indent-offset)
   ((and (derived-mode-p 'nxml-mode) (boundp 'nxml-child-indent))
    nxml-child-indent)
   ((and (derived-mode-p 'coffee-mode) (boundp 'coffee-tab-width))
    coffee-tab-width)
   ((and (derived-mode-p 'js-mode) (boundp 'js-indent-level))
    js-indent-level)
   ((and (derived-mode-p 'js2-mode) (boundp 'js2-basic-offset))
    js2-basic-offset)
   ((and (fboundp 'derived-mode-class)
	 (eq (derived-mode-class major-mode) 'sws-mode) (boundp 'sws-tab-width))
    sws-tab-width)
   ((and (derived-mode-p 'web-mode) (boundp 'web-mode-markup-indent-offset))
    web-mode-markup-indent-offset)
   ((and (derived-mode-p 'web-mode) (boundp 'web-mode-html-offset)) ; old var
    web-mode-html-offset)
   ((and (local-variable-p 'c-basic-offset) (boundp 'c-basic-offset))
    c-basic-offset)
   ((and (derived-mode-p 'yaml-mode) (boundp 'yaml-indent-offset))
    yaml-indent-offset)
   ((and (derived-mode-p 'elixir-mode) (boundp 'elixir-smie-indent-basic))
    elixir-smie-indent-basic)
   ((and (boundp 'standard-indent) standard-indent))
   (t 4))) 				; backup

(defun indent-bars--setup-font-lock ()
  "Setup font lock keywords and functions for indent-bars."
  (unless (eq font-lock-unfontify-region-function #'indent-bars--unfontify)
    (setq indent-bars-orig-unfontify-region font-lock-unfontify-region-function))
  (setq-local font-lock-unfontify-region-function #'indent-bars--unfontify)
  (setq indent-bars--font-lock-keywords
	`((,(rx-to-string `(seq bol (group (>= ,(1+ indent-bars-spacing) ?\s)) nonl))
	   (1 (indent-bars--display)))))
  (font-lock-add-keywords nil indent-bars--font-lock-keywords t)
  (if indent-bars-display-on-blank-lines
      (let ((re (rx bol (* (or ?\s ?\t ?\n)) eol)))
	(setq indent-bars--font-lock-blank-line-keywords
	      `((,re (0 (indent-bars--handle-blank-lines)))))
	(font-lock-add-keywords nil indent-bars--font-lock-blank-line-keywords t)
	(add-hook 'font-lock-extend-region-functions
		  #'indent-bars--extend-blank-line-regions 95 t))))

(defun indent-bars-setup ()
  "Setup all face, color, bar size, and indentation info for the current buffer."
  ;; Spacing
  (setq indent-bars-spacing (indent-bars--guess-spacing))

  ;; Colors
  (setq indent-bars--main-color (indent-bars--main-color)
	indent-bars--depth-palette (indent-bars--depth-palette)
	indent-bars--current-depth-palette (indent-bars--current-depth-palette))

  ;; Faces
  (indent-bars--create-stipple-face (frame-char-width) (frame-char-height)
				    (indent-bars--stipple-rot (frame-char-width)))
  (indent-bars--create-faces 9 'reset)	; N.B.: extends as needed

  ;; Resize
  (add-hook 'text-scale-mode-hook #'indent-bars--resize-stipple nil t)
  (indent-bars--resize-stipple)		; just in case

  ;; Window state: selection/size
  (add-hook 'window-state-change-functions #'indent-bars--window-change nil t)

  ;; Font-lock
  (indent-bars--setup-font-lock)
  (font-lock-flush)
  
  ;; Current depth highlight
  (when indent-bars-highlight-current-depth
    (indent-bars--set-current-bg-color)
    (indent-bars--set-current-depth-stipple)
    (add-hook 'post-command-hook #'indent-bars--highlight-current-depth nil t)
    (setq indent-bars--current-depth 0)
    (indent-bars--highlight-current-depth)))

(defun indent-bars-teardown ()
  "Tears down indent-bars."
  (font-lock-remove-keywords nil indent-bars--font-lock-keywords)
  (font-lock-remove-keywords nil indent-bars--font-lock-blank-line-keywords)
  (font-lock-flush)
  (font-lock-ensure)
  (if indent-bars--remap-face
      (face-remap-remove-relative indent-bars--remap-face))
  (setq font-lock-unfontify-region-function indent-bars-orig-unfontify-region)
  (setq indent-bars--depth-palette nil
	indent-bars--faces nil
	indent-bars--remap-face nil
	indent-bars--gutter-rot 0
	indent-bars--current-depth-palette nil
	indent-bars--current-depth-stipple nil
	indent-bars--current-bg-color nil
	indent-bars--current-depth 0)
  (remove-hook 'text-scale-mode-hook #'indent-bars--resize-stipple t)
  (remove-hook 'post-command-hook #'indent-bars--highlight-current-depth t)
  (remove-hook 'font-lock-extend-region-functions
	       #'indent-bars--extend-blank-line-regions t))

(defun indent-bars-reset ()
  "Reset indent-bars config."
  (interactive)
  (indent-bars-teardown)
  (indent-bars-setup))

;;;###autoload
(define-minor-mode indent-bars-mode
  "Indicate indentation with configurable bars."
  :global nil
  :group 'indent-bars
  (if indent-bars-mode
      (indent-bars-setup)
    (indent-bars-teardown)))

(provide 'indent-bars)

;;; indent-bars.el ends here
