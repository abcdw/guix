;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2024, 2025 Giacomo Leidi <goodoldpaul@autistici.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu tests containers)
  #:use-module (gnu)
  #:use-module (gnu tests)
  #:use-module (guix build-system trivial)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages containers)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages guile-xyz)
  #:use-module (gnu services)
  #:use-module (gnu services containers)
  #:use-module (gnu services desktop)
  #:use-module (gnu services dbus)
  #:use-module (gnu services networking)
  #:use-module (gnu system)
  #:use-module (gnu system accounts)
  #:use-module (gnu system vm)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix monads)
  #:use-module (guix packages)
  #:use-module (guix profiles)
  #:use-module ((guix scripts pack) #:prefix pack:)
  #:use-module (guix store)
  #:export (%test-rootless-podman))


(define %rootless-podman-os
  (simple-operating-system
   (service rootless-podman-service-type
            (rootless-podman-configuration
             (subgids
              (list (subid-range (name "dummy"))))
             (subuids
              (list (subid-range (name "dummy"))))))

   (service dhcpcd-service-type)
   (service dbus-root-service-type)
   (service polkit-service-type)
   (service elogind-service-type)

   (simple-service 'accounts
                   account-service-type
                   (list (user-account
                          (name "dummy")
                          (group "users")
                          (supplementary-groups '("wheel" "netdev" "cgroup"
                                                  "audio" "video")))))))

(define (run-rootless-podman-test oci-tarball)

  (define os
    (marionette-operating-system
     (operating-system-with-gc-roots
      %rootless-podman-os
      (list oci-tarball))
     #:imported-modules '((gnu services herd)
                          (guix combinators))))

  (define vm
    (virtual-machine
     (operating-system os)
     (volatile? #f)
     (memory-size 1024)
     (disk-image-size (* 3000 (expt 2 20)))
     (port-forwardings '())))

  (define test
    (with-imported-modules '((gnu build marionette)
                             (gnu services herd))
      #~(begin
          (use-modules (srfi srfi-11) (srfi srfi-64)
                       (gnu build marionette))

          (define marionette
            ;; Relax timeout to accommodate older systems and
            ;; allow for pulling the image.
            (make-marionette (list #$vm) #:timeout 60))
          (define out-dir "/tmp")

          (test-runner-current (system-test-runner #$output))
          (test-begin "rootless-podman")
          (marionette-eval
           '(begin
              (use-modules (gnu services herd))
              (wait-for-service 'file-system-/sys/fs/cgroup))
           marionette)

          (test-assert "services started successfully and /sys/fs/cgroup has correct permissions"
            (begin
              (define (run-test)
                (marionette-eval
                 `(begin
                    (use-modules (ice-9 popen)
                                 (ice-9 match)
                                 (ice-9 rdelim))

                    (define (read-lines file-or-port)
                      (define (loop-lines port)
                        (let loop ((lines '()))
                          (match (read-line port)
                            ((? eof-object?)
                             (reverse lines))
                            (line
                             (loop (cons line lines))))))

                      (if (port? file-or-port)
                          (loop-lines file-or-port)
                          (call-with-input-file file-or-port
                            loop-lines)))

                    (define slurp
                      (lambda args
                        (let* ((port (apply open-pipe* OPEN_READ args))
                               (output (read-lines port))
                               (status (close-pipe port)))
                          output)))
                    (let* ((bash
                            ,(string-append #$bash "/bin/bash"))
                           (response1
                            (slurp bash "-c"
                                   (string-append "ls -la /sys/fs/cgroup | "
                                                  "grep -E ' \\./?$' | awk '{ print $4 }'")))
                           (response2 (slurp bash "-c"
                                             (string-append "ls -l /sys/fs/cgroup/cgroup"
                                                            ".{procs,subtree_control,threads} | "
                                                            "awk '{ print $4 }' | sort -u"))))
                      (list (string-join response1 "\n") (string-join response2 "\n"))))
                 marionette))
              ;; Allow services to come up on slower machines
              (let loop ((attempts 0))
                (if (= attempts 60)
                    (error "Services didn't come up after more than 60 seconds")
                    (if (equal? '("cgroup" "cgroup")
                                (run-test))
                        #t
                        (begin
                          (sleep 1)
                          (format #t "Services didn't come up yet, retrying with attempt ~a~%"
                                  (+ 1 attempts))
                          (loop (+ 1 attempts))))))))

          (test-equal "/sys/fs/cgroup/cgroup.subtree_control content is sound"
            (list "cpu" "cpuset" "io" "memory" "pids")
            (marionette-eval
             `(begin
                (use-modules (srfi srfi-1)
                             (ice-9 popen)
                             (ice-9 match)
                             (ice-9 rdelim))

                (define (read-lines file-or-port)
                  (define (loop-lines port)
                    (let loop ((lines '()))
                      (match (read-line port)
                        ((? eof-object?)
                         (reverse lines))
                        (line
                         (loop (cons line lines))))))

                  (if (port? file-or-port)
                      (loop-lines file-or-port)
                      (call-with-input-file file-or-port
                        loop-lines)))

                (define slurp
                  (lambda args
                    (let* ((port (apply open-pipe* OPEN_READ args))
                           (output (read-lines port))
                           (status (close-pipe port)))
                      output)))
                (let* ((response1 (slurp
                                   ,(string-append #$coreutils "/bin/cat")
                                   "/sys/fs/cgroup/cgroup.subtree_control")))
                  (sort-list (string-split (first response1) #\space) string<?)))
             marionette))

          (test-equal "Load oci image and run it (unprivileged)"
            '("hello world" "hi!" "JSON!" #o1777)
            (marionette-eval
             `(begin
                (use-modules (srfi srfi-1)
                             (ice-9 popen)
                             (ice-9 match)
                             (ice-9 rdelim))

                (define (wait-for-file file)
                  ;; Wait until FILE shows up.
                  (let loop ((i 60))
                    (cond ((file-exists? file)
                           #t)
                          ((zero? i)
                           (error "file didn't show up" file))
                          (else
                           (pk 'wait-for-file file)
                           (sleep 1)
                           (loop (- i 1))))))

                (define (read-lines file-or-port)
                  (define (loop-lines port)
                    (let loop ((lines '()))
                      (match (read-line port)
                        ((? eof-object?)
                         (reverse lines))
                        (line
                         (loop (cons line lines))))))

                  (if (port? file-or-port)
                      (loop-lines file-or-port)
                      (call-with-input-file file-or-port
                        loop-lines)))

                (define slurp
                  (lambda args
                    (let* ((port (apply open-pipe* OPEN_READ
                                        (list "sh" "-l" "-c"
                                              (string-join
                                               args
                                               " "))))
                           (output (read-lines port))
                           (status (close-pipe port)))
                      output)))

                (match (primitive-fork)
                  (0
                   (dynamic-wind
                     (const #f)
                     (lambda ()
                       (setgid (passwd:gid (getpwnam "dummy")))
                       (setuid (passwd:uid (getpw "dummy")))

                       (let* ((loaded (slurp ,(string-append #$podman
                                                             "/bin/podman")
                                             "load" "-i"
                                             ,#$oci-tarball))
                              (repository&tag "localhost/guile-guest:latest")
                              (response1 (slurp
                                          ,(string-append #$podman "/bin/podman")
                                          "run" "--pull" "never"
                                          "--entrypoint" "bin/Guile"
                                          repository&tag
                                          "/aa.scm"))
                              (response2 (slurp ;default entry point
                                          ,(string-append #$podman "/bin/podman")
                                          "run" "--pull" "never" repository&tag
                                          "-c" "'(display \"hi!\")'"))

                              ;; Check whether (json) is in $GUILE_LOAD_PATH.
                              (response3 (slurp ;default entry point + environment
                                          ,(string-append #$podman "/bin/podman")
                                          "run" "--pull" "never" repository&tag
                                          "-c" "'(use-modules (json))
  (display (json-string->scm (scm->json-string \"JSON!\")))'"))

                              ;; Check whether /tmp exists.
                              (response4 (slurp
                                          ,(string-append #$podman "/bin/podman")
                                          "run" "--pull" "never" repository&tag "-c"
                                          "'(display (stat:perms (lstat \"/tmp\")))'")))
                         (call-with-output-file (string-append ,out-dir "/response1")
                           (lambda (port)
                             (display (string-join response1 " ") port)))
                         (call-with-output-file (string-append ,out-dir "/response2")
                           (lambda (port)
                             (display (string-join response2 " ") port)))
                         (call-with-output-file (string-append ,out-dir "/response3")
                           (lambda (port)
                             (display (string-join response3 " ") port)))
                         (call-with-output-file (string-append ,out-dir "/response4")
                           (lambda (port)
                             (display (string-join response4 " ") port)))))
                     (lambda ()
                       (primitive-exit 127))))
                  (pid
                   (cdr (waitpid pid))))
                (wait-for-file (string-append ,out-dir "/response4"))
                (append
                 (slurp "cat" (string-append ,out-dir "/response1"))
                 (slurp "cat" (string-append ,out-dir "/response2"))
                 (slurp "cat" (string-append ,out-dir "/response3"))
                 (map string->number (slurp "cat" (string-append ,out-dir "/response4")))))
             marionette))

          (test-end))))

  (gexp->derivation "rootless-podman-test" test))

(define (build-tarball&run-rootless-podman-test)
  (mlet* %store-monad
      ((_ (set-grafting #f))
       (guile (set-guile-for-build (default-guile)))
       (guest-script-package ->
        (package
          (name "guest-script")
          (version "0")
          (source #f)
          (build-system trivial-build-system)
          (arguments `(#:guile ,guile-3.0
                       #:builder
                       (let ((out (assoc-ref %outputs "out")))
                         (mkdir out)
                         (call-with-output-file (string-append out "/a.scm")
                           (lambda (port)
                             (display "(display \"hello world\n\")" port)))
                         #t)))
          (synopsis "Display hello world using Guile")
          (description "This package displays the text \"hello world\" on the
standard output device and then enters a new line.")
          (home-page #f)
          (license license:public-domain)))
       (profile (profile-derivation (packages->manifest
                                     (list guile-3.0 guile-json-3
                                           guest-script-package))
                                    #:hooks '()
                                    #:locales? #f))
       (tarball (pack:docker-image
                 "docker-pack" profile
                 #:symlinks '(("/bin/Guile" -> "bin/guile")
                              ("aa.scm" -> "a.scm"))
                 #:extra-options
                 '(#:image-tag "guile-guest")
                 #:entry-point "bin/guile"
                 #:localstatedir? #t)))
    (run-rootless-podman-test tarball)))

(define %test-rootless-podman
  (system-test
   (name "rootless-podman")
   (description "Test rootless Podman service.")
   (value (build-tarball&run-rootless-podman-test))))
