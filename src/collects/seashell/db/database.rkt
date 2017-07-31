#lang typed/racket
;; Seashell's SQLite3 + Dexie bindings.
;; Copyright (C) 2013-2017 The Seashell Maintainers.
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

(require typed/json
         typed/db
         typed/db/sqlite3
         (submod seashell/seashell-config typed)
         seashell/log
         seashell/db/support
         seashell/db/changes
         seashell/db/updates
         seashell/utils/uuid)

(provide get-sync-database
         init-sync-database
         clear-sync-database
         DBExpr
         Sync-Database%
         sync-database%)

;; Database Schema:
;;
;; Tables:
;; contents: id, project_id, filename, contents, time
;; files: id, project_id, name, contents_id, flags
;; projects: id, name, settings, last_used

(: true? (All (A) (-> (Option A) Any : #:+ A)))
(define (true? x) x)

(: seashell-sync-database (U False (Instance Sync-Database%)))
(define seashell-sync-database  #f)

(: get-sync-database (-> (Instance Sync-Database%)))
(define (get-sync-database)
  (assert seashell-sync-database))

(: init-sync-database (->* () ((U False SQLite3-Database-Storage)) Void))
(define (init-sync-database [location #f])
  (unless seashell-sync-database
    (define loc (if location location
      (build-path (read-config-path 'seashell) (read-config-path 'database-file))))
    (set! seashell-sync-database (make-object sync-database% loc))
    (init-sync-database-tables)))

(: init-sync-database-tables (-> Void))
(define (init-sync-database-tables)
  (define db (get-sync-database))
  (send db write-transaction (thunk
    (query-exec (send db get-conn) "CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, data TEXT)")
    (query-exec (send db get-conn) "CREATE TABLE IF NOT EXISTS files (id TEXT PRIMARY KEY, data TEXT)")
    (query-exec (send db get-conn) "CREATE TABLE IF NOT EXISTS contents (id TEXT PRIMARY KEY, data TEXT)"))))

(: clear-sync-database (-> Void))
(define (clear-sync-database)
  (when seashell-sync-database
    (set! seashell-sync-database #f)))

(define-type DBExpr (HashTable Symbol JSExpr))

(define-type Sync-Database% (Class
  (init [path SQLite3-Database-Storage])
  [get-conn (-> Connection)]
  [get-path (-> SQLite3-Database-Storage)]
  [subscribe (-> String (-> Void) Void)]
  [unsubscribe (-> String Void)]
  [create-client (->* () (String) String)]
  [write-transaction (All (A) (-> (-> A) A))]
  [read-transaction (All (A) (-> (-> A) A))]
  [current-revision (-> Integer)]
  [fetch (-> String String (Option JSExpr))]
  [fetch-changes (-> Integer String (Listof (Vectorof SQL-Datum)))]
  [apply-create (->* (String String (U String DBExpr)) ((Option String) Boolean) Any)]
  [apply-partial-create (->* (String String (U String DBExpr)) ((Option String)) Any)]
  [apply-update (->* (String String DBExpr) ((Option String) Boolean) Any)]
  [apply-partial-update (->* (String String DBExpr) ((Option String)) Any)]
  [apply-delete (->* (String String) ((Option String) Boolean) Any)]
  [apply-partial-delete (->* (String String) ((Option String)) Any)]
  [apply-partials (->* () (Integer (Option String)) Any)]))

(: sync-database% : Sync-Database%)
(define sync-database%
  (class object%
    (init [path : SQLite3-Database-Storage])

    (: db-path SQLite3-Database-Storage)
    (define db-path path)

    (: database Connection)
    (define database (sqlite-connection path))

    (: subscribers (Listof (Pair String (-> Void))))
    (define subscribers '())

    (super-new)

    (query-exec database "CREATE TABLE IF NOT EXISTS _clients (id TEXT PRIMARY KEY, description TEXT)")
    (query-exec database "INSERT OR IGNORE INTO _clients VALUES ($1, $2)" SERVER_CLIENT_KEY "Server-side Writes")
    (query-exec database "CREATE TABLE IF NOT EXISTS _changes (revision INTEGER PRIMARY KEY AUTOINCREMENT,
                                                               type INTEGER,
                                                               client TEXT,
                                                               target_table TEXT,
                                                               target_key TEXT,
                                                               data TEXT DEFAULT 'false',
                                                               FOREIGN KEY(client) REFERENCES _clients(id))")
    (query-exec database "CREATE TABLE IF NOT EXISTS _partials (client TEXT,
                                                                type INTEGER,
                                                                target_table TEXT,
                                                                target_key text,
                                                                data TEXT DEFAULT 'false',
                                                                FOREIGN KEY(client) REFERENCES _clients(id))")

    (: get-conn (-> Connection))
    (define/public (get-conn)
      database)

    (: get-path (-> SQLite3-Database-Storage))
    (define/public (get-path)
      db-path)

    (: subscribe (-> String (-> Void) Void))
    (define/public (subscribe client cb)
      (set! subscribers (cons (cons client cb)
        (filter-not (lambda ([sub : (Pair String (-> Void))])
          (string=? client (car sub))) subscribers))))

    (: unsubscribe (-> String Void))
    (define/public (unsubscribe client)
      (set! subscribers
        (filter-not (lambda ([sub : (Pair String (-> Void))])
          (string=? client (car sub))) subscribers)))

    (: update-subscribers (-> Void))
    (define/private (update-subscribers)
      (map (lambda ([sub : (Pair String (-> Void))]) ((cdr sub))) subscribers)
      (void))

    (: create-client (->* () (String) String))
    (define/public (create-client [desc ""])
      (define client-id (uuid-generate))
      (query-exec database "INSERT INTO _clients VALUES ($1, $2)" client-id desc)
      client-id)

    (: write-transaction (All (A) (-> (-> A) A)))
    (define/public (write-transaction thunk)
      (define option (if (db-in-transaction?) #f 'immediate))
      (dynamic-wind
        void
        (lambda () (parameterize ([db-in-transaction? #t])
          (call-with-transaction database thunk #:option option)))
        (lambda () (unless (db-in-transaction?)
          (update-subscribers)))))

    (: read-transaction (All (A) (-> (-> A) A)))
    (define/public (read-transaction thunk)
      (define option (if (db-in-transaction?) #f 'deferred))
      (parameterize ([db-in-transaction? #t])
        (call-with-transaction database thunk #:option option)))

    (: current-revision (-> Integer))
    (define/public (current-revision)
      (define result (query-value database "SELECT MAX(revision) FROM _changes"))
      (if (sql-null? result) 0 (assert result exact-integer?)))

    (: fetch (-> String String (Option JSExpr)))
    (define/public (fetch table key)
      (define result (query-maybe-value database (format "SELECT json(data) FROM '~a' WHERE id=$1" table) key))
      (if (string? result)
          (string->jsexpr result)
          #f))

    (: fetch-changes (-> Integer String (Listof (Vectorof SQL-Datum))))
    (define/public (fetch-changes revision client)
      (query-rows database "SELECT type, client, target_table, target_key, data FROM _changes WHERE revision >= $1 AND client != $2" revision client))

    (: apply-create (->* (String String (U String DBExpr)) ((Option String) Boolean) Any))
    (define/public (apply-create table key object [_client #f] [_transaction #t])
      (define data (string-or-jsexpr->string object))
      (define todo (thunk
                    (query-exec database (format "CREATE TABLE IF NOT EXISTS '~a' (id TEXT PRIMARY KEY, data TEXT)" table))
                    (query-exec database (format "INSERT OR REPLACE INTO '~a' (id, data) VALUES ($1, $2)" table) key data)
                    (query-exec database "INSERT INTO _changes (client, type, target_table, target_key, data) VALUES ($1, $2, $3, $4, json($5))"
                                (or _client SERVER_CLIENT_KEY)
                                CREATE
                                table
                                key
                                data)))
      (if _transaction (write-transaction todo) (todo)))

    (: apply-partial-create (->* (String String (U String DBExpr)) ((Option String)) Any))
    (define/public (apply-partial-create table key object [_client #f])
      (define data (string-or-jsexpr->string object))
      (query-exec database "INSERT INTO _partials (client, type, target_table, target_key, data) VALUES ($1, $2, $3, $4, json($5))"
                  (or _client SERVER_CLIENT_KEY)
                  CREATE
                  table
                  key
                  data))

    (: apply-update (->* (String String DBExpr) ((Option String) Boolean) Any))
    (define/public (apply-update table key updates [_client #f] [_transaction #t])
      (define data (string-or-jsexpr->string updates))
      (define todo (thunk
                    (define exists? (query-maybe-value database "SELECT 1 FROM sqlite_master WHERE type = $1 AND name = $2" "table" table))
                    (when exists?
                      (hash-for-each updates
                                     (lambda ([_key : Symbol] [_value : JSExpr])
                                       (define key-path (string-append "$." (symbol->string _key)))
                                       (define update (jsexpr->string _value))
                                       (query-exec database (format "UPDATE ~a SET data = json_set(json(data), $1, json($2)) WHERE id=$3" table) key-path update key)))
                      (query-exec database "INSERT INTO _changes (client, type, target_table, target_key, data) VALUES ($1, $2, $3, $4, json($5))"
                                  (or _client SERVER_CLIENT_KEY)
                                  UPDATE
                                  table
                                  key
                                  data))))
      (if _transaction (write-transaction todo) (todo)))

    (: apply-partial-update (->* (String String DBExpr) ((Option String)) Any))
    (define/public (apply-partial-update table key updates [_client #f])
      (define data (string-or-jsexpr->string updates))
      (query-exec database "INSERT INTO _partials (client, type, target_table, target_key, data) VALUES ($1, $2, $3, $4, json($5))"
                  (or _client SERVER_CLIENT_KEY)
                  UPDATE
                  table
                  key
                  data))
 
    (: apply-delete (->* (String String) ((Option String) Boolean) Any))
    (define/public (apply-delete table key [_client #f] [_transaction #t])
      (logf 'info (format "delete ~a ~a ~a" table key _client))
      (define todo (thunk
                    (define exists? (query-maybe-value database "SELECT 1 FROM sqlite_master WHERE type = $1 AND name = $2" "table" table))
                    (when exists?
                      (query-exec database (format "DELETE FROM ~a WHERE id = $1" table) key)
                      (query-exec database "INSERT INTO _changes (client, type, target_table, target_key) VALUES ($1, $2, $3, $4)"
                                  (or _client SERVER_CLIENT_KEY)
                                  DELETE
                                  table
                                  key))))
      (if _transaction (write-transaction todo) (todo)))

    (: apply-partial-delete (->* (String String) ((Option String)) Any))
    (define/public (apply-partial-delete table key [_client #f])
      (query-exec database "INSERT INTO _partials (client, type, target_table, target_key) VALUES ($1, $2, $3, $4)"
                  (or _client SERVER_CLIENT_KEY)
                  DELETE
                  table
                  key))

    (: apply-partials (->* () (Integer (Option String)) Any))
    (define/public (apply-partials [base 0] [_client #f])
      (define client (or _client SERVER_CLIENT_KEY))
      (write-transaction
       (thunk
        (define changes (map row->change (query-rows database "SELECT type, client, target_table, target_key, json(data) FROM _partials WHERE client = $1" client)))
        (define server-changes (map row->change (query-rows database "SELECT type, client, target_table, target_key, json(data) FROM _changes WHERE revision >= $1" base)))
        (define resolved-changes (resolve-conflicts changes server-changes))
        (display resolved-changes)
        (for ([change resolved-changes])
          (match-define (database-change type client table key data) change)
          (cond
            [(= type CREATE) (apply-create table key data client #f)]
            [(= type UPDATE) (apply-update table key (assert (string->jsexpr data) hash?) client #f)]
            [(= type DELETE) (apply-delete table key client #f)]))
        (query-exec database "DELETE FROM _partials WHERE client = $1" client))))
    ))