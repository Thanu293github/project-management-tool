;;; test-helper.el --- Cask: Test helper  -*- lexical-binding: t; -*-

;; Copyright (C) 2013 Johan Andersson

;; Author: Johan Andersson <johan.rejeep@gmail.com>
;; Maintainer: Johan Andersson <johan.rejeep@gmail.com>
;; URL: http://github.com/cask/cask

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(require 'f)
(require 's)
(require 'ert-async)
(require 'cl-lib)

(defvar cask-test/link-path)
(defvar cask-test/sandbox-path)
(defvar cask-test/fixtures-path)
(defvar cask-test/cvs-repo-path)

(defun cask-same-items (a b)
    "`-same-items?' for A, B."
    (let ((length-a (length a))
          (length-b (length b)))
      (and
       (= length-a length-b)
       (= length-a (length (cl-remove-if-not (lambda (elm) (member elm b)) a))))))

(defconst cask-test/test-path
  (f-parent (f-this-file)))

(defconst cask-test/root-path
  (f-parent cask-test/test-path))

(defconst cask-test/sandbox-path
  (f-expand "sandbox" cask-test/test-path))

(defconst cask-test/fixtures-path
  (f-expand "fixtures" cask-test/root-path))

(defconst cask-test/link-path
  (f-expand "link" cask-test/sandbox-path))

(defvar cask-test/cvs-repo-path nil)

;; Avoid Emacs 23 interupting the tests with:
;;   File bar-autoloads.el changed on disk.  Reread from disk? (yes or no)
(fset 'y-or-n-p (lambda (_) t))
(fset 'yes-or-no-p (lambda (_) t))

(defun cask-test/package-path (bundle package)
  "Return path in BUNDLE to PACKAGE."
  (let ((package-name (apply 'format "%s-%s" package)))
    (f-expand package-name (cask-elpa-path bundle))))

(defun cask-test/package-installed-p (bundle package)
  "Return true if in BUNDLE, PACKAGE is installed.

To be more specific, this function return true if the PACKAGE
directory exists."
  (f-dir? (cask-test/package-path bundle package)))

(defun cask-test/installed-packages (bundle)
  "Return list of all of BUNDLE's installed packages.

The items in the list are on the form (package version)."
  (let ((elpa-dir (cask-elpa-path bundle))
        (package-regex "\\(.+\\)-\\([^\-]+\\)"))
    (when (f-dir? elpa-dir)
      (let ((directories (f--directories elpa-dir (s-matches? package-regex
                                                              (f-filename it)))))
        (mapcar
         (lambda (filename)
           (cdr (s-match package-regex (f-filename filename))))
         (mapcar 'f-filename directories))))))

(defun cask-test/write-forms (forms path)
  "Write FORMS to PATH."
  (if (eq forms 'empty)
      (f-touch path)
    (let ((cask-file-content (s-join "\n" (mapcar 'pp-to-string forms))))
      (f-write-text cask-file-content 'utf-8 path))))

(defmacro cask-test/with-sandbox (&rest body)
  "Run BODY in a sandboxed environment."
  `(f-with-sandbox (list cask-test/sandbox-path
                         cask-test/cvs-repo-path
                         cask-tmp-path)
     (let* ((default-directory cask-test/sandbox-path)
            (cask-tmp-path (f-expand "tmp" cask-test/sandbox-path))
            (cask-tmp-checkout-path (f-expand "checkout" cask-tmp-path))
            (cask-tmp-packages-path (f-expand "packages" cask-tmp-path)))
       (when (f-dir? cask-test/sandbox-path)
         (condition-case err
             (f-delete cask-test/sandbox-path 'force)
           ;; gnupg/S.gpg-agent.ssh dematerializes on github actions
           (file-error
	    (--each (f-entries cask-test/sandbox-path)
	      (ignore-errors (f-delete it 'force))))))
       (f-mkdir cask-test/sandbox-path)
       (f-mkdir cask-test/link-path)
       ,@body)))

(defmacro cask-test/with-bundle (&optional forms &rest body)
  "Write FORMS to sandbox Cask-file and yield BODY.

In BODY, the :packages property has special meaning.  If the
property...

 - is not present, nothing is done
 - is nil, it's asserted that no package is installed
 - is a list of lists of the form (package version), it's
asserted that only those packages are installed"
  (declare (indent 1))
  `(cask-test/with-sandbox
    (let ((cask-source-mapping cask-source-mapping))
      (push (cons 'localhost "http://127.0.0.1:9191/packages/") cask-source-mapping)
      (when ,forms
        (let ((cask-file (f-expand "Cask" cask-test/sandbox-path)))
          (cask-test/write-forms ,forms cask-file)))
      (let ((bundle (cask-setup cask-test/sandbox-path)))
        ,@body
        ,(when (plist-member body :packages)
           `(let ((expected-packages ,(plist-get body :packages))
                  (actual-packages (cask-test/installed-packages bundle)))
              (should (cask-same-items
                       (mapcar 'car expected-packages)
                       (mapcar 'car actual-packages)))
              (dolist (expected-package expected-packages)
                (let ((actual-package (cl-find-if (lambda (elm) (string= (car elm) (car expected-package))) actual-packages)))
                  (let ((actual-package-version (cadr actual-package))
                        (expected-package-version (cadr expected-package)))
                    (when expected-package-version
                      (should (string= actual-package-version expected-package-version))))))))))))

(defun cask-test/install (bundle)
  "Install BUNDLE and then reset the environment."
  (cask-install bundle))

(defun cask-test/run-command (command &rest args)
  "Run COMMAND with ARGS."
  (with-temp-buffer
    (let ((program (executable-find command)))
      (if program
          (let ((exit-code (apply 'call-process (append (list program nil t nil) args))))
            (if (zerop exit-code)
                (buffer-string)
              (error "Running command %s failed with: '%s'"
                     (s-join " " (cons command args))
                     (buffer-string))))
        (error "No such command found %s" command)))))

(defmacro cask-test/with-git-repo (&rest body)
  "Create temporary Git repo and yield BODY."
  `(let* ((cask-test/cvs-repo-path (f-slash (make-temp-file "cask" 'directory)))
          (default-directory cask-test/cvs-repo-path))
     (cask-test/run-command "git" "init" cask-test/cvs-repo-path)
     (cask-test/run-command "git" "remote" "add" "origin" (concat "file://" cask-test/cvs-repo-path))
     (cask-test/run-command "git" "fetch" "origin")
     (cask-test/run-command "git" "config" "user.name" "Bruce Wayne")
     (cask-test/run-command "git" "config" "user.email" "bruce@wayne.com")
     (cl-flet ((git (&rest args)
                 (let ((default-directory cask-test/cvs-repo-path))
                   (apply 'cask-test/run-command (cons "git" args)))))
       ,@body)))

(defun cask-test/link (bundle name fixture-name)
  "Create BUNDLE link with NAME.

The fixture with name FIXTURE-NAME will be copied to
`cask-test/link-path' and will be the link source."
  (let ((from (f-expand fixture-name cask-test/fixtures-path))
        (to cask-test/link-path))
    (unless (f-dir? (f-expand (f-filename from) to))
      (f-copy from (f-slash to)))
    (let ((link-path (f-expand fixture-name cask-test/link-path)))
      (cask-link bundle name link-path)
      link-path)))

(defun should-be-same-dependencies (actual expected)
  "Assert that the dependencies ACTUAL and EXPECTED are same."
  (should
   (cask-same-items
    (mapcar 'cask-dependency-name actual)
    (mapcar 'cask-dependency-name expected)))
  (should
   (cask-same-items
    (mapcar 'cask-dependency-version actual)
    (mapcar 'cask-dependency-version expected))))

(package-initialize)
;;; test-helper.el ends here
