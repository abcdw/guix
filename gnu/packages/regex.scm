;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2014 John Darrington
;;; Copyright © 2015 Mark H Weaver <mhw@netris.org>
;;; Copyright © 2016, 2020, 2022 Marius Bakke <marius@gnu.org>
;;; Copyright © 2018, 2019, 2020 Tobias Geerinckx-Rice <me@tobias.gr>
;;; Copyright © 2020 Brett Gilio <brettg@gnu.org>
;;; Copyright © 2024 Zheng Junjie <873216071@qq.com>
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

(define-module (gnu packages regex)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system cmake)
  #:use-module (guix utils)
  #:use-module (gnu packages autotools)
  #:use-module (gnu packages gettext)
  #:use-module (gnu packages check)
  #:use-module (gnu packages cpp))

(define-public re2
   (package
     (name "re2")
     (version "2022-12-01")
     (home-page "https://github.com/google/re2")
     (source (origin
               (method git-fetch)
               (uri (git-reference (url home-page) (commit version)))
               (file-name (git-file-name name version))
               (sha256
                (base32
                 "0g627a5ppyarhf2ph4gyzj89pwbkwfjfajgljzkmjafjmdyxfqs6"))))
     (build-system gnu-build-system)
     (arguments
      (list #:test-target "test"
            ;; There is no configure step, but the Makefile respects a prefix.
            #:make-flags #~(list (string-append "prefix=" #$output)
                                 (string-append "CXX=" #$(cxx-for-target)))
            #:phases
            #~(modify-phases %standard-phases
                (delete 'configure)
                (add-after 'install 'delete-static-library
                  (lambda _
                    ;; No make target for shared-only; delete the static version.
                    (delete-file (string-append #$output "/lib/libre2.a")))))))
     (synopsis "Fast, safe, thread-friendly regular expression engine")
     (description "RE2 is a fast, safe, thread-friendly alternative to
backtracking regular expression engines like those used in PCRE, Perl and
Python.  It is a C++ library.")
     (license license:bsd-3)))

(define-public re2-next
  (package
    (inherit re2)
    (name "re2")
    (version "2024-07-02")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/google/re2")
                    (commit version)))
              (file-name (git-file-name name version))
              (sha256
               (base32
                "11q0kz8b3y5ysn58fr62yhib520f9l3grbn8gxr8x5s9k700vq11"))))
    (build-system cmake-build-system)
    (arguments (list #:configure-flags #~(list "-DBUILD_SHARED_LIBS=ON"
                                               ;; "-DRE2_USE_ICU=ON"
                                               #$@(if (%current-target-system)
                                                      #~("-DRE2_BUILD_TESTING=ON")
                                                      #~()))))
    (native-inputs (list googletest))
    (propagated-inputs (list abseil-cpp))))

(define-public tre
  (package
    (name "tre")
    (version "0.9.0")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/laurikari/tre")
                    (commit (string-append "v" version))))
              (file-name (git-file-name name version))
              (sha256
               (base32
                "1zy91a0jfc5galvd7xrvkn17i3wfiwnv9ikys4qiyjgy7fmk5vz4"))))
    (build-system gnu-build-system)
    (arguments
     `(#:phases
       (modify-phases %standard-phases
         (replace 'bootstrap
           (lambda _
             (invoke "autoreconf" "-vif")))
         (add-before 'check 'install-locales
           (lambda _
             ;; The tests require the availability of the
             ;; 'en_US.ISO-8859-1' locale.
             (setenv "LOCPATH" (getcwd))
             (invoke "localedef" "--no-archive"
                     "--prefix" (getcwd) "-i" "en_US"
                     "-f" "ISO-8859-1" "./en_US.ISO-8859-1"))))))
    (native-inputs
     (list autoconf
           automake
           gettext-minimal ;for autopoint
           libtool))
    (synopsis "Approximate regex matching library and agrep utility")
    (description "Superset of the POSIX regex API, enabling approximate
matching.  Also ships a version of the agrep utility which behaves similar to
grep but features inexact matching.")
    (home-page "https://laurikari.net/tre")
    (license license:bsd-2)))
