#lang typed/racket
;; Seashell's authentication and communications backend.
;; Copyright (C) 2013-2015 The Seashell Maintainers.
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; See also 'ADDITIONAL TERMS' at the end of the included LICENSE file.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
(require (submod seashell/seashell-config typed)
         seashell/log
         seashell/tunnel/structs)

(provide tunnel-launch)
;; (tunnel-launch user password) -> tunnel?
;; Launches an instance of the Seashell Tunnel backend.
;;
;; Configuration options (see seashell-config.rkt):
;;  host - host to connect to.
;;
;; Expects:
;;  seashell-tunnel should live in the same directory as this file.
;;
;; Arguments:
;;  user - User name.
;;  password - Password.
;;  Target - Target to launch.
;;  args - Arguments.
;;  host - Host to launch on.
;;
;; Returns:
;;  A tunnel? structure, which contains the subprocess?,
;;  and the I/O ports required to communicate with the process.
;;  Standard error is read by the status thread and sent to the logger.
;;
;;  The tunnel either will have been set up OR an exception
;;  would have been raised at the end of this function.
;;
;; Exceptions:
;;  exn:tunnel on tunnel error.
(: tunnel-launch (->* (String String) (#:target (U String False) #:args (U String False) #:host (U String False)) Tunnel))
(define (tunnel-launch user password #:target [target #f] #:args [args #f] #:host [_host #f])
  (define tunnel-custodian (make-custodian))
  (parameterize ([current-custodian tunnel-custodian])
    ;; Randomly select a host
    (define host (if _host _host (first (shuffle (read-config-strings 'host)))))
    ;; Launch the process
    (define-values (process in out error)
      (subprocess #f #f #f
                  (read-config-path 'tunnel-binary)
                  user
                  host
                  (format "~a ~a"
                          (if target target (read-config-path 'seashell-backend-remote))
                          (if args args ""))))
    ;; And the logger thread
    (define status-thread
      (thread
       (lambda ()
         (let loop ()
           (define line (read-line error))
           (when (not (eof-object? line))
             (logf 'debug "tunnel stderr (~a@~a): ~a" user host line)
             (loop)))
         ;; EOF received - die.
         (close-input-port error))))

    ;; Set unbuffered mode for the ports, so nothing funny happens.
    (file-stream-buffer-mode out 'none)

    ;; Write out the authentication details
    (define password-bytes (bytes-append (string->bytes/utf-8 password) (bytes 0)))
    (define password-length (bytes-length password-bytes))

    ;; Format:
    ;;  length - 4 bytes, unsigned integer, LSB order
    ;;  method - 1 byte, 0 for password authentication.
    ;;  password - length bytes
    (write-bytes (integer->integer-bytes password-length 4 #f #f) out)
    (write-byte 0 out)
    (write-bytes password-bytes out)

    ;; Wait on the input port and see what happens.
    (define check (read-byte in))
    (cond
      ;; Case 1 - EOF read.
      [(eof-object? check)
       (subprocess-kill process #t)
       (subprocess-wait process)
       (define status (cast (subprocess-status process) Exact-Nonnegative-Integer))

       (define message (format "Seashell tunnel died with status ~a" status))
       (logf 'warning "~a" message)
       (thread-wait status-thread)
       (custodian-shutdown-all tunnel-custodian)
       (raise (exn:tunnel message (current-continuation-marks)
                          status))]
      ;; Case 2 - Unexpected byte read.  Tunnel will always write ASCII 'O' to output
      ;; before starting two-way data processing.
      [(not (equal? check 79))
       (define message (format "Seashell tunnel wrote bad status byte ~a" check))
       (logf 'warning "~a" message)
       (subprocess-kill process #t)
       (thread-wait status-thread)
       (custodian-shutdown-all tunnel-custodian)
       (raise (exn:tunnel message (current-continuation-marks) #f))]
      ;; Case 3 - All good.
      [(equal? check 79)
       (void)])

    ;; Get remote address.
    (define remote-addr-len (read-byte in))
    (define remote-addr-bytes (if (eof-object? remote-addr-len) #f (read-bytes remote-addr-len in)))

    (cond
      [(or (eof-object? remote-addr-len)
           (eof-object? remote-addr-bytes)
           (false? remote-addr-bytes))
        (subprocess-kill process #t)
        (subprocess-wait process)
        (define status (cast (subprocess-status process) Exact-Nonnegative-Integer))
        (define message "Unexpected EOF from tunnel binary (get remote address).")
        (logf 'warning message)
        (custodian-shutdown-all tunnel-custodian)
        (raise (exn:tunnel message (current-continuation-marks)
                           status))]
      [else
        (logf 'debug "Got remote address: ~a (~a)." (bytes->list remote-addr-bytes) remote-addr-len)])
    ;; All good.
    (tunnel process in out status-thread host tunnel-custodian)))
