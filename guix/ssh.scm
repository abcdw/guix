;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2016-2021, 2023-2025 Ludovic Courtès <ludo@gnu.org>
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

(define-module (guix ssh)
  #:use-module (guix store)
  #:use-module (guix inferior)
  #:use-module (guix i18n)
  #:use-module ((guix diagnostics)
                #:select (info &fix-hint formatted-message))
  #:use-module ((guix progress)
                #:select (progress-bar
                          erase-current-line current-terminal-columns))
  #:use-module (gcrypt pk-crypto)
  #:use-module (ssh session)
  #:use-module (ssh auth)
  #:use-module (ssh key)
  #:use-module (ssh channel)
  #:use-module (ssh popen)
  #:use-module (ssh session)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-35)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 vlist)
  #:export (open-ssh-session
            authenticate-server*

            remote-inferior
            remote-daemon-channel
            connect-to-remote-daemon
            remote-system
            remote-authorize-signing-key
            send-files
            retrieve-files
            retrieve-files*
            remote-store-host

            report-guile-error))

;;; Commentary:
;;;
;;; This module provides tools to support communication with remote stores
;;; over SSH, using Guile-SSH.
;;;
;;; Code:

(define %compression
  "zlib@openssh.com,zlib")

(define (host-key->type+key host-key)
  "Destructure HOST-KEY, an OpenSSH host key string, and return two values:
its key type as a symbol, and the actual base64-encoded string."
  (define (type->symbol type)
    (and (string-prefix? "ssh-" type)
         (string->symbol (string-drop type 4))))

  (match (string-tokenize host-key)
    ((type key x)
     (values (type->symbol type) key))
    ((type key)
     (values (type->symbol type) key))))

(define (authenticate-server* session key)
  "Make sure the server for SESSION has the given KEY, where KEY is a string
such as \"ssh-ed25519 AAAAC3Nz… root@example.org\".  Raise an exception if the
actual key does not match."
  (let-values (((server)   (get-server-public-key session))
               ((type key) (host-key->type+key key)))
    (unless (and (or (not (get-key-type server))
                     (eq? (get-key-type server) type))
                 (string=? (public-key->string server) key))
      ;; Key mismatch: something's wrong.  XXX: It could be that the server
      ;; provided its Ed25519 key when we where expecting its RSA key.  XXX:
      ;; Guile-SSH 0.10.1 doesn't know about ed25519 keys and 'get-key-type'
      ;; returns #f in that case.
      (raise (formatted-message (G_ "server at '~a' returned host key \
'~a' of type '~a' instead of '~a' of type '~a'~%")
                                (session-get session 'host)
                                (public-key->string server)
                                (get-key-type server)
                                key type)))))

(define* (open-ssh-session host #:key user port identity
                           host-key
                           (compression %compression)
                           (timeout 3600)
                           (connection-timeout 10)
                           (strict-host-key-check? #t))
  "Open an SSH session for HOST and return it.  IDENTITY specifies the file
name of a private key to use for authenticating with the host.  When USER,
PORT, or IDENTITY are #f, use default values or whatever '~/.ssh/config'
specifies; otherwise use them.

When HOST-KEY is true, it must be a string like \"ssh-ed25519 AAAAC3Nz…
root@example.org\"; the server is authenticated and an error is raised if its
host key is different from HOST-KEY.

Error out if connection establishment takes more than CONNECTION-TIMEOUT
seconds.  Install TIMEOUT as the maximum time in seconds after which a read or
write operation on a channel of the returned session is considered as failing.

If STRICT-HOST-KEY-CHECK? is #f, strict host key checking is turned off for
the new session.

Throw an error on failure."
  (let ((session (make-session #:user user
                               #:identity identity
                               #:host host
                               #:port port
                               #:timeout connection-timeout
                               ;; #:log-verbosity 'protocol

                               ;; Prevent libssh from reading
                               ;; ~/.ssh/known_hosts when the caller provides
                               ;; a HOST-KEY to match against.
                               #:knownhosts (and host-key "/dev/null")

                               ;; We need lightweight compression when
                               ;; exchanging full archives.
                               #:compression compression
                               #:compression-level 3

                               ;; Speed up RPCs by creating sockets with
                               ;; TCP_NODELAY.
                               #:nodelay #t
                               #:stricthostkeycheck strict-host-key-check?)))

    ;; Honor ~/.ssh/config.
    (session-parse-config! session)

    (match (connect! session)
      ('ok
       (if host-key
           ;; Make sure the server's key is what we expect.
           (authenticate-server* session host-key)

           ;; Authenticate against ~/.ssh/known_hosts.
           (when strict-host-key-check?
             (match (authenticate-server session)
               ('ok #f)
               (reason
                (raise (formatted-message (G_ "failed to authenticate \
server at '~a': ~a")
                                          (session-get session 'host)
                                          reason))))))

       ;; Use public key authentication, via the SSH agent if it's available.
       (match (userauth-public-key/auto! session)
         ('success
          (session-set! session 'timeout timeout)
          session)
         ('again
          (raise (formatted-message (G_ "timeout while connecting \
to SSH server at '~a'")
                                    (session-get session 'host))))
         (x
          (match (userauth-gssapi! session)
            ('success
             (session-set! session 'timeout timeout)
             session)
            (x
             (disconnect! session)
             (raise (condition
                     (&message
                      (message (format #f (G_ "SSH authentication failed for '~a@~a': ~a~%")
                                       (session-get session 'user) host
                                       (get-error session)))))))))))
      (x
       ;; Connection failed or timeout expired.
       (raise (formatted-message (G_ "SSH connection to '~a' port ~a failed: ~a~%")
                                 host (or port 22) (get-error session)))))))

(define* (remote-inferior session #:optional become-command)
  "Return a remote inferior for the given SESSION.  If BECOME-COMMAND is
given, use that to invoke the remote Guile REPL."
  (let* ((repl-command (append (or become-command '())
                               '("guix" "repl" "-t" "machine")))
         (pipe (apply open-remote-pipe* session OPEN_BOTH repl-command)))
    (when (eof-object? (peek-char pipe))
      (let ((status (channel-get-exit-status pipe)))
        (close-port pipe)
        (raise (formatted-message (G_ "remote command '~{~a~^ ~}' failed \
with status ~a")
                                  repl-command status))))
    (port->inferior pipe)))

(define* (inferior-remote-eval exp session #:optional become-command)
  "Evaluate EXP in a new inferior running in SESSION, and close the inferior
right away.  If BECOME-COMMAND is given, use that to invoke the remote Guile
REPL."
  (let ((inferior (remote-inferior session become-command)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (inferior-eval exp inferior))
      (lambda ()
        ;; Close INFERIOR right away to prevent finalization from happening in
        ;; another thread at the wrong time (see
        ;; <https://bugs.gnu.org/26976>.)
        (close-inferior inferior)))))

(define (remote-run exp session)
  "Run EXP in a new process in SESSION and return a remote pipe.

Unlike 'inferior-remote-eval', this is used for side effects and may
communicate over stdout/stdin as it sees fit.  EXP is typically a loop that
processes data from stdin and/or sends data to stdout.  The assumption is that
EXP never returns or calls 'primitive-exit' when it's done."
  (define pipe
    (open-remote-pipe* session OPEN_BOTH
                       "guix" "repl" "-t" "machine"))

  (match (read pipe)
    (('repl-version _ ...)
     #t)
    ((? eof-object?)
     (close-port pipe)
     (raise (formatted-message
             (G_ "failed to start 'guix repl' on '~a'")
             (session-get session 'host)))))

  ;; Disable buffering so 'guix repl' does not read more than what's really
  ;; sent to itself.
  (write '(setvbuf (current-input-port) 'none) pipe)
  (force-output pipe)

  ;; Read the reply and subsequent newline.
  (read pipe) (get-u8 pipe)

  (write exp pipe)
  (force-output pipe)

  ;; From now on, we stop following the inferior protocol.
  pipe)

(define* (remote-daemon-channel session
                                #:optional
                                (socket-name
                                 "/var/guix/daemon-socket/socket"))
  "Return an input/output port (an SSH channel) to the daemon at SESSION."
  (define redirect
    ;; Code run in SESSION to redirect the remote process' stdin/stdout to the
    ;; daemon's socket, à la socat.  The SSH protocol supports forwarding to
    ;; Unix-domain sockets but libssh doesn't have an API for that, hence this
    ;; hack.
    `(begin
       (use-modules (ice-9 match) (rnrs io ports)
                    (rnrs bytevectors))

       (define connect-to-daemon
         ;; XXX: 'connect-to-daemon' used to be private and before that it
         ;; didn't even exist, hence these shenanigans.
         (let ((connect-to-daemon
                (false-if-exception (module-ref (resolve-module '(guix store))
                                                'connect-to-daemon))))
           (lambda (uri)
             (if connect-to-daemon
                 (connect-to-daemon uri)
                 (let ((sock (socket AF_UNIX SOCK_STREAM 0)))
                   (connect sock AF_UNIX ,socket-name)
                   sock)))))

       ;; Use 'connect-to-daemon' to honor GUIX_DAEMON_SOCKET.
       (let ((sock    (connect-to-daemon (or (getenv "GUIX_DAEMON_SOCKET")
                                             ,socket-name)))
             (stdin   (current-input-port))
             (stdout  (current-output-port))
             (select* (lambda (read write except)
                        ;; This is a workaround for
                        ;; <https://bugs.gnu.org/30365> in Guile < 2.2.4:
                        ;; since 'select' sometimes returns non-empty sets for
                        ;; no good reason, call 'select' a second time with a
                        ;; zero timeout to filter out incorrect replies.
                        (match (select read write except)
                          ((read write except)
                           (select read write except 0))))))
         (setvbuf stdout 'none)

         ;; Use buffered ports so that 'get-bytevector-some' returns up to the
         ;; whole buffer like read(2) would--see <https://bugs.gnu.org/30066>.
         (setvbuf stdin 'block 65536)
         (setvbuf sock 'block 65536)

         (let loop ()
           (match (select* (list stdin sock) '() '())
             ((reads () ())
              (when (memq stdin reads)
                (match (get-bytevector-some stdin)
                  ((? eof-object?)
                   (primitive-exit 0))
                  (bv
                   (put-bytevector sock bv)
                   (force-output sock))))
              (when (memq sock reads)
                (match (get-bytevector-some sock)
                  ((? eof-object?)
                   (primitive-exit 0))
                  (bv
                   (put-bytevector stdout bv))))
              (loop))
             (_
              (primitive-exit 1)))))))

  (remote-run redirect session))

(define* (connect-to-remote-daemon session
                                   #:optional
                                   (socket-name
                                    "/var/guix/daemon-socket/socket"))
  "Connect to the remote build daemon listening on SOCKET-NAME over SESSION,
an SSH session.  Return a <store-connection> object."
  (guard (c ((store-connection-error? c)
             ;; Raise a more focused error condition.
             (raise (formatted-message
                     (G_ "failed to connect over SSH to daemon at '~a', socket ~a")
                     (session-get session 'host)
                     socket-name))))
    (open-connection #:port (remote-daemon-channel session socket-name))))

(define (store-import-channel session)
  "Return an output port to which archives to be exported to SESSION's store
can be written."
  ;; Using the 'import-paths' RPC on a remote store would be slow because it
  ;; makes a round trip every time 32 KiB have been transferred.  This
  ;; procedure instead opens a separate channel to use the remote
  ;; 'import-paths' procedure, which consumes all the data in a single round
  ;; trip.  This optimizes the successful case at the expense of error
  ;; conditions: errors can only be reported once all the input has been
  ;; consumed.
  (define import
    `(begin
       (use-modules (guix) (srfi srfi-34)
                    (rnrs io ports) (rnrs bytevectors))

       (define (consume-input port)
         (let ((bv (make-bytevector 32768)))
           (let loop ()
             (let ((n (get-bytevector-n! port bv 0
                                         (bytevector-length bv))))
               (unless (eof-object? n)
                 (loop))))))

       ;; Upon completion, write an sexp that denotes the status.
       (write
        (catch #t
          (lambda ()
            (guard (c ((nix-protocol-error? c)
                       ;; Consume all the input since the only time we can
                       ;; report the error is after everything has been
                       ;; consumed.
                       (consume-input (current-input-port))
                       (list 'protocol-error (nix-protocol-error-message c))))
              (with-store store
                (write '(importing))              ;we're ready
                (force-output)

                (setvbuf (current-input-port) 'none)

                ;; If 'guix-daemon' is running with '--debug', a lot of
                ;; debugging info goes to 'current-build-output-port' (stderr
                ;; by default).  However, since nobody's reading it, this
                ;; could lead to a deadlock.  Thus, disable debugging output.
                (set-build-options store #:verbosity 0)

                (import-paths store (current-input-port))

                '(success))))
          (lambda args
            (cons 'error args))))
       (primitive-exit 0)))

  (remote-run import session))

(define* (store-export-channel session files
                               #:key recursive?)
  "Return an input port from which an export of FILES from SESSION's store can
be read.  When RECURSIVE? is true, the closure of FILES is exported."
  ;; Same as above: this is more efficient than calling 'export-paths' on a
  ;; remote store.
  (define export
    `(begin
       (use-modules (guix) (srfi srfi-1)
                    (srfi srfi-26) (srfi srfi-34))

       (guard (c ((nix-connection-error? c)
                  (write `(connection-error ,(nix-connection-error-file c)
                                            ,(nix-connection-error-code c)))
                  (primitive-exit 1))
                 ((nix-protocol-error? c)
                  (write `(protocol-error ,(nix-protocol-error-status c)
                                          ,(nix-protocol-error-message c)))
                  (primitive-exit 2))
                 (else
                  (write `(exception))
                  (primitive-exit 3)))
         (with-store store
           (let* ((files ',files)
                  (invalid (remove (cut valid-path? store <>)
                                   files)))
             (unless (null? invalid)
               (write `(invalid-items ,invalid))
               (exit 1))

             ;; TODO: When RECURSIVE? is true, we could send the list of store
             ;; items in the closure so that the other end can filter out
             ;; those it already has.

             (write '(exporting))                 ;we're ready
             (force-output)

             (setvbuf (current-output-port) 'none)
             (export-paths store files (current-output-port)
                           #:recursive? ,recursive?)
             (primitive-exit 0))))))

  (remote-run export session))

(define (remote-system session)
  "Return the system type as expected by Nix, usually ARCHITECTURE-KERNEL, of
the machine on the other end of SESSION."
  (inferior-remote-eval '(begin (use-modules (guix utils)) (%current-system))
                        session))

(define* (remote-authorize-signing-key key session #:optional become-command)
  "Send KEY, a canonical sexp containing a public key, over SESSION and add it
to the system ACL file if it has not yet been authorized."
  (inferior-remote-eval
   `(begin
      (use-modules (guix build utils)
                   (guix pki)
                   (guix utils)
                   (gcrypt pk-crypto)
                   (srfi srfi-26))

      (define acl (current-acl))
      (define key (string->canonical-sexp ,(canonical-sexp->string key)))

      (unless (authorized-key? key)
        (let ((acl (public-keys->acl (cons key (acl->public-keys acl)))))
          (mkdir-p (dirname %acl-file))
          (with-atomic-file-output %acl-file
            (cut write-acl acl <>))
          (chmod %acl-file #o644))))
   session
   become-command))

(define (prepare-to-send store host log-port items)
  "Notify the user that we're about to send ITEMS to HOST.  Return three
values allowing 'notify-send-progress' to track the state of this transfer."
  (let* ((count (length items))
         (sizes (fold (lambda (item result)
                        (vhash-cons item
                                    (path-info-nar-size
                                     (query-path-info store item))
                                    result))
                      vlist-null
                      items))
         (total  (vlist-fold (lambda (pair result)
                               (match pair
                                 ((_ . size) (+ size result))))
                             0
                             sizes)))
    (info (N_ "sending ~a store item (~h MiB) to '~a'...~%"
              "sending ~a store items (~h MiB) to '~a'...~%" count)
          count
          (inexact->exact (round (/ total (expt 2. 20))))
          host)

    (values log-port sizes total 0)))

(define (notify-transfer-progress item port sizes total sent)
  "Notify the user that we've already transferred SENT bytes out of TOTAL.
Use SIZES to determine the size of ITEM, which is about to be sent."
  (define (display-bar %)
    (erase-current-line port)
    (format port "~3@a% ~a"
            (inexact->exact (round %))
            (progress-bar % (- (max (current-terminal-columns) 5) 5)))
    (force-output port))

  (unless (zero? total)
    (let ((% (* 100. (/ sent total))))
      (match (vhash-assoc item sizes)
        (#f
         (display-bar %)
         (values port sizes total sent))
        ((_ . size)
         (display-bar %)
         (values port sizes total (+ sent size)))))))

(define (notify-transfer-completion port . args)
  "Notify the user that the transfer has completed."
  (apply notify-transfer-progress "" port args) ;display the 100% progress bar
  (erase-current-line port)
  (force-output port))

(define* (send-files local files remote
                     #:key
                     recursive?
                     (log-port (current-error-port)))
  "Send the subset of FILES from LOCAL (a local store) that's missing to
REMOTE, a remote store.  When RECURSIVE? is true, send the closure of FILES.
Return the list of store items actually sent."
  ;; Compute the subset of FILES missing on SESSION and send them.
  (let* ((files   (if recursive? (requisites local files) files))
         (session (channel-get-session (store-connection-socket remote)))
         (missing (inferior-remote-eval
                   `(begin
                      (use-modules (guix)
                                   (srfi srfi-1) (srfi srfi-26))

                      (with-store store
                        (remove (cut valid-path? store <>)
                                ',files)))
                   session))
         (port    (store-import-channel session))
         (host    (session-get session 'host)))
    ;; Make sure everything alright on the remote side.
    (match (read port)
      (('importing)
       #t)
      (sexp
       (handle-import/export-channel-error sexp remote)))

    ;; Send MISSING in topological order.
    (let ((tty? (isatty? log-port)))
      (export-paths local missing port
                    #:start (cut prepare-to-send local host log-port <>)
                    #:progress (if tty? notify-transfer-progress (const #f))
                    #:finish (if tty? notify-transfer-completion (const #f))))

    ;; Tell the remote process that we're done.  (In theory the end-of-archive
    ;; mark of 'export-paths' would be enough, but in practice it's not.)
    (channel-send-eof port)

    ;; Wait for completion of the remote process and read the status sexp from
    ;; PORT.  Wait for the exit status only when 'read' completed; otherwise,
    ;; we might wait forever if the other end is stuck.
    (let* ((result (false-if-exception (read port)))
           (status (and result
                        (zero? (channel-get-exit-status port)))))
      (close-port port)
      (match result
        (('success . _)
         missing)
        (('protocol-error message)
         (raise (condition
                 (&store-protocol-error (message message) (status 42)))))
        (('error key args ...)
         (raise (condition
                 (&store-protocol-error
                  (message (call-with-output-string
                             (lambda (port)
                               (print-exception port #f key args))))
                  (status 43)))))
        (_
         (raise (condition
                 (&store-protocol-error
                  (message "unknown error while sending files over SSH")
                  (status 44)))))))))

(define (remote-store-session remote)
  "Return the SSH channel beneath REMOTE, a remote store as returned by
'connect-to-remote-daemon', or #f."
  (channel-get-session (store-connection-socket remote)))

(define (remote-store-host remote)
  "Return the name of the host REMOTE is connected to, where REMOTE is a
remote store as returned by 'connect-to-remote-daemon'."
  (match (remote-store-session remote)
    (#f #f)
    ((? session? session)
     (session-get session 'host))))

(define* (file-retrieval-port files remote
                              #:key recursive?)
  "Return an input port from which to retrieve FILES (a list of store items)
from REMOTE, along with the number of items to retrieve (lower than or equal
to the length of FILES.)"
  (values (store-export-channel (remote-store-session remote) files
                                #:recursive? recursive?)
          (length files)))            ;XXX: inaccurate when RECURSIVE? is true

(define-syntax raise-error
  (syntax-rules (=>)
    ((_ fmt args ... (=> hint-fmt hint-args ...))
     (raise (condition
             (&message
              (message (format #f fmt args ...)))
             (&fix-hint
              (hint (format #f hint-fmt hint-args ...))))))
    ((_ fmt args ...)
     (raise (condition
             (&message
              (message (format #f fmt args ...))))))))

(define (handle-import/export-channel-error sexp remote)
  "Report an error corresponding to SEXP, the EOF object or an sexp read from
REMOTE."
  (match sexp
    ((? eof-object?)
     (report-guile-error (remote-store-host remote)))
    (('connection-error file code . _)
     (raise-error (G_ "failed to connect to '~A' on remote host '~A': ~a")
                  file (remote-store-host remote) (strerror code)))
    (('invalid-items items . _)
     (raise-error (N_ "no such item on remote host '~A':~{ ~a~}"
                      "no such items on remote host '~A':~{ ~a~}"
                      (length items))
                  (remote-store-host remote) items))
    (('protocol-error status message . _)
     (raise-error (G_ "protocol error on remote host '~A': ~a")
                  (remote-store-host remote) message))
    (_
     (raise-error (G_ "failed to retrieve store items from '~a'")
                  (remote-store-host remote)))))

(define* (retrieve-files* files remote
                          #:key recursive? (log-port (current-error-port))
                          (import (const #f)))
  "Pass IMPORT an input port from which to read the sequence of FILES coming
from REMOTE.  When RECURSIVE? is true, retrieve the closure of FILES."
  (let-values (((port count)
                (file-retrieval-port files remote
                                     #:recursive? recursive?)))
    (match (read port)                            ;read the initial status
      (('exporting)
       (format #t (N_ "retrieving ~a store item from '~a'...~%"
                      "retrieving ~a store items from '~a'...~%" count)
               count (remote-store-host remote))

       (dynamic-wind
         (const #t)
         (lambda ()
           (import port))
         (lambda ()
           (close-port port))))
      (sexp
       (handle-import/export-channel-error sexp remote)))))

(define* (retrieve-files local files remote
                         #:key recursive? (log-port (current-error-port)))
  "Retrieve FILES from REMOTE and import them using the 'import-paths' RPC on
LOCAL.  When RECURSIVE? is true, retrieve the closure of FILES."
  (retrieve-files* (remove (cut valid-path? local <>) files)
                   remote
                   #:recursive? recursive?
                   #:log-port log-port
                   #:import (lambda (port)
                              (import-paths local port))))


;;;
;;; Error reporting.
;;;

(define (report-guile-error host)
  (raise-error (G_ "failed to start Guile on remote host '~A'") host
               (=> (G_ "Make sure @command{guile} can be found in
@code{$PATH} on the remote host.  Run @command{ssh ~A guile --version} to
check.")
                   host)))

(define (report-inferior-exception exception host)
  "Report EXCEPTION, an &inferior-exception that occurred on HOST."
  (raise-error (G_ "exception occurred on remote host '~A': ~s")
               host (inferior-exception-arguments exception)))

;;; ssh.scm ends here
