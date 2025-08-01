;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2013-2017, 2019-2021, 2025 Ludovic Courtès <ludo@gnu.org>
;;; Copyright © 2020 Tobias Geerinckx-Rice <me@tobias.gr>
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

(define-module (guix scripts archive)
  #:use-module (guix utils)
  #:use-module (guix combinators)
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module ((guix serialization)
                #:select (fold-archive restore-file))
  #:use-module (guix store)
  #:use-module ((guix status) #:select (with-status-verbosity))
  #:use-module (guix packages)
  #:use-module (guix derivations)
  #:use-module (guix monads)
  #:use-module (guix ui)
  #:use-module (guix pki)
  #:use-module (gcrypt common)
  #:use-module (gcrypt pk-crypto)
  #:use-module (guix scripts)
  #:use-module (guix scripts build)
  #:use-module (gnu packages)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-37)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:export (guix-archive
            options->derivations+files))


;;;
;;; Command-line options.
;;;

(define %default-options
  ;; Alist of default option values.
  `((system . ,(%current-system))
    (substitutes? . #t)
    (offload? . #t)
    (graft? . #t)
    (print-build-trace? . #t)
    (print-extended-build-trace? . #t)
    (multiplexed-build-output? . #t)
    (verbosity . 3)
    (debug . 0)))

(define (show-help)
  (display (G_ "Usage: guix archive [OPTION]... PACKAGE...
Export/import one or more packages from/to the store.\n"))
  (display (G_ "
      --export           export the specified files/packages to stdout"))
  (display (G_ "
  -r, --recursive        combined with '--export', include dependencies"))
  (display (G_ "
      --import           import from the archive passed on stdin"))
  (display (G_ "
      --missing          print the files from stdin that are missing"))
  (display (G_ "
  -x, --extract=DIR      extract the archive on stdin to DIR"))
  (display (G_ "
  -t, --list             list the files in the archive on stdin"))
  (newline)
  (display (G_ "
      --generate-key[=PARAMETERS]
                         generate a key pair with the given parameters"))
  (display (G_ "
      --authorize        authorize imports signed by the public key on stdin"))
  (newline)
  (display (G_ "
  -e, --expression=EXPR  build the package or derivation EXPR evaluates to"))
  (display (G_ "
  -S, --source           build the packages' source derivations"))
  (display (G_ "
  -v, --verbosity=LEVEL  use the given verbosity LEVEL"))

  (newline)
  (show-build-options-help)
  (newline)
  (show-cross-build-options-help)
  (newline)
  (show-native-build-options-help)

  (newline)
  (display (G_ "
  -h, --help             display this help and exit"))
  (display (G_ "
  -V, --version          display version information and exit"))
  (newline)
  (show-bug-report-information))

(define %key-generation-parameters
  ;; Default key generation parameters.  We prefer Ed25519, but it was
  ;; introduced in libgcrypt 1.6.0.
  (if (version>? (gcrypt-version) "1.6.0")
      "(genkey (ecdsa (curve Ed25519) (flags rfc6979)))"
      "(genkey (rsa (nbits 4:4096)))"))

(define %options
  ;; Specifications of the command-line options.
  (cons* (option '(#\h "help") #f #f
                 (lambda args
                   (leave-on-EPIPE (show-help))
                   (exit 0)))
         (option '(#\V "version") #f #f
                 (lambda args
                   (show-version-and-exit "guix archive")))
         (option '("export") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'export #t result)))
         (option '(#\r "recursive") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'export-recursive? #t result)))
         (option '("import") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'import #t result)))
         (option '("missing") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'missing #t result)))
         (option '("extract" #\x) #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'extract arg result)))
         (option '("list" #\t) #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'list #t result)))
         (option '("generate-key") #f #t
                 (lambda (opt name arg result)
                   (catch 'gcry-error
                     (lambda ()
                       ;; XXX: Curve25519 was actually introduced in
                       ;; libgcrypt 1.6.0.
                       (let ((params
                              (string->canonical-sexp
                               (or arg %key-generation-parameters))))
                         (alist-cons 'generate-key params result)))
                     (lambda (key proc err)
                       (leave (G_ "invalid key generation parameters: ~a: ~a~%")
                              (error-source err)
                              (error-string err))))))
         (option '("authorize") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'authorize #t result)))

         (option '(#\S "source") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'source? #t result)))
         (option '(#\e "expression") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'expression arg result)))
         (option '(#\v "verbosity") #t #f
                 (lambda (opt name arg result)
                   (let ((level (string->number* arg)))
                     (alist-cons 'verbosity level
                                 (alist-delete 'verbosity result)))))
         (option '(#\n "dry-run") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'dry-run? #t result)))

         (append %standard-build-options
                 %standard-cross-build-options
                 %standard-native-build-options)))

(define (derivation-from-expression store str package-derivation
                                    system source?)
  "Read/eval STR and return the corresponding derivation path for SYSTEM.
When SOURCE? is true and STR evaluates to a package, return the derivation of
the package source; otherwise, use PACKAGE-DERIVATION to compute the
derivation of a package."
  (match (read/eval str)
    ((? package? p)
     (if source?
         (let ((source (package-source p)))
           (if source
               (package-source-derivation store source)
               (leave (G_ "package `~a' has no source~%")
                      (package-name p))))
         (package-derivation store p system)))
    ((? procedure? proc)
     (run-with-store store
       (mbegin %store-monad
         (set-guile-for-build (default-guile))
         (proc)) #:system system))))

(define (options->derivations+files store opts)
  "Given OPTS, the result of 'args-fold', return a list of derivations to
build and a list of store files to transfer."
  (define package->derivation
    (match (assoc-ref opts 'target)
      (#f package-derivation)
      (triplet
       (cut package-cross-derivation <> <> triplet <>))))

  (define src? (assoc-ref opts 'source?))
  (define sys  (assoc-ref opts 'system))

  (fold2 (lambda (arg derivations files)
           (match arg
             (('expression . str)
              (let ((drv (derivation-from-expression store str
                                                     package->derivation
                                                     sys src?)))
                (values (cons drv derivations)
                        (cons (derivation->output-path drv) files))))
             (('argument . (? store-path? file))
              (values derivations (cons file files)))
             (('argument . (? string? spec))
              (let-values (((p output)
                            (specification->package+output spec)))
                (if src?
                    (let* ((s   (package-source p))
                           (drv (package-source-derivation store s)))
                      (values (cons drv derivations)
                              (cons (derivation->output-path drv)
                                    files)))
                    (let ((drv (package->derivation store p sys)))
                      (values (cons drv derivations)
                              (cons (derivation->output-path drv output)
                                    files))))))
             (_
              (values derivations files))))
         '()
         '()
         opts))


;;;
;;; Entry point.
;;;

(define (export-from-store store opts)
  "Export the packages or derivations specified in OPTS from STORE.  Write the
resulting archive to the standard output port."
  (let-values (((drv files)
                (options->derivations+files store opts)))
    (when (null? files)
      (warning (G_ "no arguments specified; creating an empty archive~%")))

    (if (build-derivations store drv)
        (export-paths store files (current-output-port)
                      #:recursive? (assoc-ref opts 'export-recursive?))
        (leave (G_ "unable to export the given packages~%")))))

(define (generate-key-pair parameters)
  "Generate a key pair with PARAMETERS, a canonical sexp, and store it in the
right place."
  (when (or (file-exists? %public-key-file)
            (file-exists? %private-key-file))
    (leave (G_ "key pair exists under '~a'; remove it first~%")
           (dirname %public-key-file)))

  (format (current-error-port)
          (G_ "Please wait while gathering entropy to generate the key pair;
this may take time...~%"))

  (let* ((pair   (catch 'gcry-error
                   (lambda ()
                     (generate-key parameters))
                   (lambda (key proc err)
                     (leave (G_ "key generation failed: ~a: ~a~%")
                            (error-source err)
                            (error-string err)))))
         (public (find-sexp-token pair 'public-key))
         (secret (find-sexp-token pair 'private-key)))
    ;; Create the following files as #o400.
    (umask #o266)

    (mkdir-p (dirname %public-key-file))
    (with-atomic-file-output %public-key-file
      (lambda (port)
        (display (canonical-sexp->string public) port)))
    (with-atomic-file-output %private-key-file
      (lambda (port)
        (display (canonical-sexp->string secret) port)))

    ;; Make the public key readable by everyone.
    (chmod %public-key-file #o444)))

(define (authorize-key)
  "Authorize imports signed by the public key passed as an advanced sexp on
the input port."
  (define (read-key)
    (catch 'gcry-error
      (lambda ()
        (string->canonical-sexp (read-string (current-input-port))))
      (lambda (key proc err)
        (leave (G_ "failed to read public key: ~a: ~a~%")
               (error-source err) (error-string err)))))

  ;; Warn about potentially volatile ACLs, but continue: system reconfiguration
  ;; might not be possible without (newly-authorized) substitutes.
  (let ((stat (false-if-exception (lstat %acl-file))))
    (when (and stat (eq? 'symlink (stat:type (lstat %acl-file))))
      (warning (G_ "replacing symbolic link ~a with a regular file~%")
               %acl-file)
      (when (string-prefix? (%store-prefix) (readlink %acl-file))
        (display-hint (G_ "On Guix System, add all @code{authorized-keys} to the
@code{guix-service-type} service of your @code{operating-system} instead.")))))

  (let ((key (read-key))
        (acl (current-acl)))
    (unless (eq? 'public-key (canonical-sexp-nth-data key 0))
      (leave (G_ "s-expression does not denote a public key~%")))

    ;; Add KEY to the ACL and write that.
    (let ((acl (public-keys->acl (cons key (acl->public-keys acl)))))
      (mkdir-p (dirname %acl-file))
      (with-atomic-file-output %acl-file
        (cut write-acl acl <>))
      (chmod %acl-file #o644))))

(define (list-contents port)
  "Read a nar from PORT and print the list of files it contains to the current
output port."
  (define (consume-input port size)
    (let ((bv (make-bytevector 32768)))
      (let loop ((total size))
        (unless (zero? total)
          (let ((n (get-bytevector-n! port bv 0
                                      (min total (bytevector-length bv)))))
            (loop (- total n)))))))

  (fold-archive (lambda (file type content result)
                  (match type
                    ('directory
                     (format #t "D ~a~%" file))
                    ('directory-complete
                     #t)
                    ('symlink
                     (format #t "S ~a -> ~a~%" file content))
                    ((or 'regular 'executable)
                     (match content
                       ((input . size)
                        (format #t "~a ~60a ~10h B~%"
                                (if (eq? type 'executable)
                                    "x" "r")
                                file size)
                        (consume-input input size))))))
                #t
                port
                ""))


;;;
;;; Entry point.
;;;

(define-command (guix-archive . args)
  (category plumbing)
  (synopsis "manipulate, export, and import normalized archives (nars)")

  (define (lines port)
    ;; Return lines read from PORT.
    (let loop ((line   (read-line port))
               (result '()))
      (if (eof-object? line)
          (reverse result)
          (loop (read-line port)
                (cons line result)))))

  (with-error-handling
    (let ((opts (parse-command-line args %options (list %default-options))))
      (parameterize ((%graft? (assoc-ref opts 'graft?)))
        (cond ((assoc-ref opts 'generate-key)
               =>
               generate-key-pair)
              ((assoc-ref opts 'authorize)
               (authorize-key))
              (else
               (with-status-verbosity (assoc-ref opts 'verbosity)
                 (with-store store
                   (set-build-options-from-command-line store opts)
                   (with-build-handler
                       (build-notifier #:use-substitutes?
                                       (assoc-ref opts 'substitutes?)
                                       #:verbosity
                                       (assoc-ref opts 'verbosity)
                                       #:dry-run?
                                       (assoc-ref opts 'dry-run?))
                     (cond ((assoc-ref opts 'export)
                            (export-from-store store opts))
                           ((assoc-ref opts 'import)
                            (import-paths store (current-input-port)))
                           ((assoc-ref opts 'missing)
                            (let* ((files   (lines (current-input-port)))
                                   (missing (remove (cut valid-path? store <>)
                                                    files)))
                              (format #t "~{~a~%~}" missing)))
                           ((assoc-ref opts 'list)
                            (list-contents (current-input-port)))
                           ((assoc-ref opts 'extract)
                            =>
                            (lambda (target)
                              (restore-file (current-input-port) target)))
                           (else
                            (leave
                             (G_ "either '--export' or '--import' \
must be specified~%")))))))))))))
