package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/gorilla/websocket"
	"golang.org/x/crypto/ssh"
)

type jwtClaims struct {
	Sub string `json:"sub"`
	Exp int64  `json:"exp"`
}

var (
	db          *sql.DB
	jwtSecret   []byte
	encKey      []byte
	connTTL     time.Duration
	activeMu    = &sync.Mutex{}
	activeConns = map[string]*activeConn{}
)

type activeConn struct {
	client   *ssh.Client
	lastUsed time.Time
	ttl      time.Duration
}

func main() {
	mysqlDSN := os.Getenv("MYSQL_DSN")
	if mysqlDSN == "" {
		log.Fatal("MYSQL_DSN must be set")
	}

	jwtVal := strings.TrimSpace(os.Getenv("JWT_SECRET"))
	if jwtVal == "" {
		log.Fatal("JWT_SECRET must be set for auth")
	}
	jwtSecret = []byte(jwtVal)

	keyB64 := strings.TrimSpace(os.Getenv("SSH_ENCRYPTION_KEY"))
	if keyB64 == "" {
		log.Fatal("SSH_ENCRYPTION_KEY must be set (32-byte key base64)")
	}
	keyRaw, err := base64.StdEncoding.DecodeString(keyB64)
	if err != nil || (len(keyRaw) != 32) {
		log.Fatal("SSH_ENCRYPTION_KEY must be base64 for 32 bytes (AES-256)")
	}
	encKey = keyRaw

	d, err := sql.Open("mysql", mysqlDSN)
	if err != nil {
		log.Fatalf("mysql open error: %v", err)
	}
	if err := d.Ping(); err != nil {
		log.Fatalf("mysql ping error: %v", err)
	}
	db = d

	if err := ensureSchema(); err != nil {
		log.Fatalf("schema error: %v", err)
	}

	// Configure connection TTL
	if v := strings.TrimSpace(os.Getenv("SSH_CONN_TTL_SECONDS")); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
			connTTL = time.Duration(secs) * time.Second
		}
	}
	if connTTL == 0 {
		connTTL = 5 * time.Minute
	}

	// Start janitor
	go sweepExpired()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealth)
	mux.HandleFunc("/api/ssh/connections", withAuth(handleConnections))
	mux.HandleFunc("/api/ssh/connections/", withAuth(handleConnectionByID))
	mux.HandleFunc("/api/ssh/commands", withAuth(handleCommandHistory))
	mux.HandleFunc("/api/ssh/run", withAuth(handleRunCommand))
	mux.HandleFunc("/api/ssh/live", withAuth(handleLiveConnections))
	mux.HandleFunc("/api/ssh/live/ws", withAuth(handleLiveWS))
	mux.HandleFunc("/api/ssh/live/", withAuth(handleLiveDelete))
	// Trackpad/control input over WebSocket
	mux.HandleFunc("/api/ssh/control/ws", withAuth(handleControlWS))
	mux.HandleFunc("/api/health/ws", handleHealthWS)
	mux.HandleFunc("/api/ssh/stream", withAuth(handleStreamCommand))

	port := strings.TrimSpace(os.Getenv("SERVICE_PORT"))
	if port == "" {
		port = "8086"
	}
	log.Printf("SSH service listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, corsMiddleware(mux)))
}

func ensureSchema() error {
	q := `
    CREATE TABLE IF NOT EXISTS ssh_connections (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        owner_email VARCHAR(255) NOT NULL,
        name VARCHAR(255) NOT NULL DEFAULT '',
        host VARCHAR(255) NOT NULL,
        port INT NOT NULL DEFAULT 22,
        username VARCHAR(255) NOT NULL,
        password_enc VARBINARY(4096) NULL,
        private_key_enc LONGBLOB NULL,
        passphrase_enc VARBINARY(4096) NULL,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        INDEX idx_owner_email (owner_email)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;`
	if _, err := db.Exec(q); err != nil {
		return err
	}
	q = `
    CREATE TABLE IF NOT EXISTS ssh_command_history (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        owner_email VARCHAR(255) NOT NULL,
        command TEXT NOT NULL,
        command_hash CHAR(64) NOT NULL,
        created_at DATETIME NOT NULL,
        last_used_at DATETIME NOT NULL,
        UNIQUE KEY uniq_owner_command (owner_email, command_hash),
        INDEX idx_owner_last_used (owner_email, last_used_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;`
	_, err := db.Exec(q)
	return err
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Middleware to authenticate via Bearer JWT issued by registration-api
func withAuth(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authz := strings.TrimSpace(r.Header.Get("Authorization"))
		token := ""
		if strings.HasPrefix(strings.ToLower(authz), "bearer ") {
			token = strings.TrimSpace(authz[len("bearer "):])
		}
		if token == "" {
			// Allow access_token via query for WebSocket where custom headers are not supported
			token = strings.TrimSpace(r.URL.Query().Get("access_token"))
		}
		if token == "" {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		email, exp, err := parseJWT(token)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		if time.Now().Unix() >= exp.Unix() {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "session expired"})
			return
		}
		next(w, r, email)
	}
}

func parseJWT(token string) (string, time.Time, error) {
	// very small, compatible with registration-api format
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", time.Time{}, errors.New("invalid jwt format")
	}
	headerB, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return "", time.Time{}, errors.New("invalid header")
	}
	var hdr map[string]any
	if err := json.Unmarshal(headerB, &hdr); err != nil {
		return "", time.Time{}, errors.New("invalid header json")
	}
	alg, _ := hdr["alg"].(string)
	if strings.ToUpper(alg) != "HS256" {
		return "", time.Time{}, errors.New("unsupported alg")
	}
	mac := hmac.New(sha256.New, jwtSecret)
	mac.Write([]byte(parts[0]))
	mac.Write([]byte{'.'})
	mac.Write([]byte(parts[1]))
	sig := mac.Sum(nil)
	gotSig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return "", time.Time{}, errors.New("invalid sig")
	}
	if !hmac.Equal(sig, gotSig) {
		return "", time.Time{}, errors.New("bad sig")
	}
	payloadB, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", time.Time{}, errors.New("invalid payload")
	}
	var c jwtClaims
	if err := json.Unmarshal(payloadB, &c); err != nil {
		return "", time.Time{}, errors.New("invalid claims")
	}
	if c.Sub == "" || c.Exp == 0 {
		return "", time.Time{}, errors.New("missing claims")
	}
	return c.Sub, time.Unix(c.Exp, 0), nil
}

func corsMiddleware(next http.Handler) http.Handler {
	allowed := strings.Split(strings.TrimSpace(os.Getenv("CORS_ALLOWED_ORIGINS")), ",")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" {
			// Allow any if no explicit list set
			if len(allowed) == 1 && allowed[0] == "" {
				w.Header().Set("Access-Control-Allow-Origin", origin)
			} else {
				for _, a := range allowed {
					if strings.TrimSpace(a) == origin {
						w.Header().Set("Access-Control-Allow-Origin", origin)
						break
					}
				}
			}
			w.Header().Set("Vary", "Origin")
		}
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization,Content-Type")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type sshConnection struct {
	ID        int64     `json:"id"`
	Name      string    `json:"name"`
	Host      string    `json:"host"`
	Port      int       `json:"port"`
	Username  string    `json:"username"`
	HasPass   bool      `json:"has_password"`
	HasKey    bool      `json:"has_private_key"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

func handleConnections(w http.ResponseWriter, r *http.Request, email string) {
	switch r.Method {
	case http.MethodGet:
		rows, err := db.Query(`SELECT id, name, host, port, username, password_enc IS NOT NULL, private_key_enc IS NOT NULL, created_at, updated_at FROM ssh_connections WHERE owner_email = ? ORDER BY id DESC`, email)
		if err != nil {
			log.Printf("list error: %v", err)
			writeJSON(w, 500, map[string]string{"error": "query error"})
			return
		}
		defer rows.Close()
		var list []sshConnection
		for rows.Next() {
			var it sshConnection
			var hasPass, hasKey bool
			if err := rows.Scan(&it.ID, &it.Name, &it.Host, &it.Port, &it.Username, &hasPass, &hasKey, &it.CreatedAt, &it.UpdatedAt); err != nil {
				log.Printf("scan: %v", err)
				continue
			}
			it.HasPass = hasPass
			it.HasKey = hasKey
			list = append(list, it)
		}
		writeJSON(w, 200, map[string]interface{}{"connections": list})
	case http.MethodPost:
		var payload struct {
			Name       string `json:"name"`
			Host       string `json:"host"`
			Port       int    `json:"port"`
			Username   string `json:"username"`
			Password   string `json:"password"`
			PrivateKey string `json:"private_key"`
			Passphrase string `json:"passphrase"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSON(w, 400, map[string]string{"error": "invalid json"})
			return
		}
		if payload.Port == 0 {
			payload.Port = 22
		}
		if payload.Host == "" || payload.Username == "" {
			writeJSON(w, 400, map[string]string{"error": "host and username required"})
			return
		}
		if strings.TrimSpace(payload.Password) == "" && strings.TrimSpace(payload.PrivateKey) == "" {
			writeJSON(w, 400, map[string]string{"error": "password or private_key required"})
			return
		}
		now := time.Now()
		var passEnc, keyEnc, phrEnc []byte
		var err error
		if strings.TrimSpace(payload.Password) != "" {
			passEnc, err = seal([]byte(payload.Password))
			if err != nil {
				writeJSON(w, 500, map[string]string{"error": "encryption error"})
				return
			}
		}
		if strings.TrimSpace(payload.PrivateKey) != "" {
			keyEnc, err = seal([]byte(payload.PrivateKey))
			if err != nil {
				writeJSON(w, 500, map[string]string{"error": "encryption error"})
				return
			}
		}
		if strings.TrimSpace(payload.Passphrase) != "" {
			phrEnc, err = seal([]byte(payload.Passphrase))
			if err != nil {
				writeJSON(w, 500, map[string]string{"error": "encryption error"})
				return
			}
		}
		res, err := db.Exec(`INSERT INTO ssh_connections (owner_email, name, host, port, username, password_enc, private_key_enc, passphrase_enc, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)`,
			email, strings.TrimSpace(payload.Name), payload.Host, payload.Port, payload.Username, nullIfEmpty(passEnc), nullIfEmpty(keyEnc), nullIfEmpty(phrEnc), now, now)
		if err != nil {
			log.Printf("insert error: %v", err)
			writeJSON(w, 500, map[string]string{"error": "insert error"})
			return
		}
		id, _ := res.LastInsertId()
		writeJSON(w, 201, map[string]interface{}{"id": id})
	default:
		w.Header().Set("Allow", "GET,POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func handleConnectionByID(w http.ResponseWriter, r *http.Request, email string) {
	idStr := strings.TrimPrefix(r.URL.Path, "/api/ssh/connections/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": "invalid id"})
		return
	}
	switch r.Method {
	case http.MethodGet:
		var it sshConnection
		var hasPass, hasKey bool
		err := db.QueryRow(`SELECT id, name, host, port, username, password_enc IS NOT NULL, private_key_enc IS NOT NULL, created_at, updated_at FROM ssh_connections WHERE id=? AND owner_email=?`, id, email).
			Scan(&it.ID, &it.Name, &it.Host, &it.Port, &it.Username, &hasPass, &hasKey, &it.CreatedAt, &it.UpdatedAt)
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, 404, map[string]string{"error": "not found"})
			return
		}
		if err != nil {
			writeJSON(w, 500, map[string]string{"error": "query error"})
			return
		}
		it.HasPass = hasPass
		it.HasKey = hasKey
		writeJSON(w, 200, it)
	case http.MethodPut:
		var payload struct {
			Name       *string `json:"name"`
			Host       *string `json:"host"`
			Port       *int    `json:"port"`
			Username   *string `json:"username"`
			Password   *string `json:"password"`
			PrivateKey *string `json:"private_key"`
			Passphrase *string `json:"passphrase"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSON(w, 400, map[string]string{"error": "invalid json"})
			return
		}
		// Load existing to ensure ownership
		var exists int
		if err := db.QueryRow(`SELECT 1 FROM ssh_connections WHERE id=? AND owner_email=?`, id, email).Scan(&exists); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeJSON(w, 404, map[string]string{"error": "not found"})
				return
			}
			writeJSON(w, 500, map[string]string{"error": "query error"})
			return
		}
		b := strings.Builder{}
		args := []interface{}{}
		b.WriteString("UPDATE ssh_connections SET ")
		setAny := false
		if payload.Name != nil {
			b.WriteString("name=?,")
			args = append(args, strings.TrimSpace(*payload.Name))
			setAny = true
		}
		if payload.Host != nil {
			b.WriteString("host=?,")
			args = append(args, strings.TrimSpace(*payload.Host))
			setAny = true
		}
		if payload.Port != nil {
			b.WriteString("port=?,")
			args = append(args, *payload.Port)
			setAny = true
		}
		if payload.Username != nil {
			b.WriteString("username=?,")
			args = append(args, strings.TrimSpace(*payload.Username))
			setAny = true
		}
		if payload.Password != nil {
			if strings.TrimSpace(*payload.Password) == "" {
				b.WriteString("password_enc=NULL,")
				setAny = true
			} else {
				enc, err := seal([]byte(*payload.Password))
				if err != nil {
					writeJSON(w, 500, map[string]string{"error": "encryption error"})
					return
				}
				b.WriteString("password_enc=?,")
				args = append(args, enc)
				setAny = true
			}
		}
		if payload.PrivateKey != nil {
			if strings.TrimSpace(*payload.PrivateKey) == "" {
				b.WriteString("private_key_enc=NULL,")
				setAny = true
			} else {
				enc, err := seal([]byte(*payload.PrivateKey))
				if err != nil {
					writeJSON(w, 500, map[string]string{"error": "encryption error"})
					return
				}
				b.WriteString("private_key_enc=?,")
				args = append(args, enc)
				setAny = true
			}
		}
		if payload.Passphrase != nil {
			if strings.TrimSpace(*payload.Passphrase) == "" {
				b.WriteString("passphrase_enc=NULL,")
				setAny = true
			} else {
				enc, err := seal([]byte(*payload.Passphrase))
				if err != nil {
					writeJSON(w, 500, map[string]string{"error": "encryption error"})
					return
				}
				b.WriteString("passphrase_enc=?,")
				args = append(args, enc)
				setAny = true
			}
		}
		b.WriteString("updated_at=? WHERE id=? AND owner_email=?")
		args = append(args, time.Now(), id, email)
		if !setAny {
			writeJSON(w, 400, map[string]string{"error": "no fields to update"})
			return
		}
		if _, err := db.Exec(b.String(), args...); err != nil {
			writeJSON(w, 500, map[string]string{"error": "update error"})
			return
		}
		writeJSON(w, 200, map[string]string{"status": "ok"})
	case http.MethodDelete:
		if _, err := db.Exec(`DELETE FROM ssh_connections WHERE id=? AND owner_email=?`, id, email); err != nil {
			writeJSON(w, 500, map[string]string{"error": "delete error"})
			return
		}
		writeJSON(w, 200, map[string]string{"status": "ok"})
	default:
		w.Header().Set("Allow", "GET,PUT,DELETE")
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func handleRunCommand(w http.ResponseWriter, r *http.Request, email string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		ConnectionID int64  `json:"connection_id"`
		Command      string `json:"command"`
		TimeoutSec   int    `json:"timeout_seconds"`
		KeepaliveSec int    `json:"keepalive_seconds"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeJSON(w, 400, map[string]string{"error": "invalid json"})
		return
	}
	if payload.ConnectionID == 0 || strings.TrimSpace(payload.Command) == "" {
		writeJSON(w, 400, map[string]string{"error": "connection_id and command required"})
		return
	}
	if len(payload.Command) > 4096 {
		writeJSON(w, 400, map[string]string{"error": "command too long"})
		return
	}
	if payload.TimeoutSec <= 0 {
		payload.TimeoutSec = 30
	}
	if payload.KeepaliveSec < 0 {
		payload.KeepaliveSec = 0
	}
	recordCommandHistory(email, payload.Command)

	// Load connection and secrets
	var host, username string
	var port int
	var passEnc, keyEnc, phrEnc []byte
	err := db.QueryRow(`SELECT host, port, username, password_enc, private_key_enc, passphrase_enc FROM ssh_connections WHERE id=? AND owner_email=?`, payload.ConnectionID, email).
		Scan(&host, &port, &username, &passEnc, &keyEnc, &phrEnc)
	if errors.Is(err, sql.ErrNoRows) {
		writeJSON(w, 404, map[string]string{"error": "not found"})
		return
	}
	if err != nil {
		writeJSON(w, 500, map[string]string{"error": "query error"})
		return
	}

	var auths []ssh.AuthMethod
	if len(keyEnc) > 0 {
		keyPem, err := openSeal(keyEnc)
		if err != nil {
			writeJSON(w, 500, map[string]string{"error": "decrypt key error"})
			return
		}
		var signer ssh.Signer
		if len(phrEnc) > 0 {
			passphrase, err := openSeal(phrEnc)
			if err != nil {
				writeJSON(w, 500, map[string]string{"error": "decrypt passphrase error"})
				return
			}
			signer, err = ssh.ParsePrivateKeyWithPassphrase(keyPem, passphrase)
			if err != nil {
				writeJSON(w, 400, map[string]string{"error": "invalid private key or passphrase"})
				return
			}
		} else {
			signer, err = ssh.ParsePrivateKey(keyPem)
			if err != nil {
				writeJSON(w, 400, map[string]string{"error": "invalid private key"})
				return
			}
		}
		auths = append(auths, ssh.PublicKeys(signer))
	}
	if len(passEnc) > 0 {
		pw, err := openSeal(passEnc)
		if err != nil {
			writeJSON(w, 500, map[string]string{"error": "decrypt password error"})
			return
		}
		auths = append(auths, ssh.Password(string(pw)))
	}
	if len(auths) == 0 {
		writeJSON(w, 400, map[string]string{"error": "no credentials configured"})
		return
	}

	cfg := &ssh.ClientConfig{
		User:            username,
		Auth:            auths,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(), // consider known_hosts in production
		Timeout:         time.Duration(payload.TimeoutSec) * time.Second,
	}
	// Use or create a cached connection
	ttl := connTTL
	if payload.KeepaliveSec > 0 {
		ttl = time.Duration(payload.KeepaliveSec) * time.Second
	}
	client, reused, err := getOrDialClient(email, payload.ConnectionID, fmt.Sprintf("%s:%d", host, port), cfg, ttl, time.Duration(payload.TimeoutSec)*time.Second)
	if err != nil {
		writeJSON(w, 502, map[string]string{"error": "ssh dial failed"})
		return
	}
	go broadcastLive(email)

	session, err := client.NewSession()
	if err != nil {
		writeJSON(w, 500, map[string]string{"error": "ssh session failed"})
		return
	}
	defer session.Close()

	stdout, err := session.CombinedOutput(payload.Command)
	exit := 0
	if err != nil {
		// Try to extract exit status
		var ee *ssh.ExitError
		if errors.As(err, &ee) {
			exit = ee.ExitStatus()
		} else {
			exit = 255
		}
	}
	// Return output as UTF-8 string; remote may include binary
	writeJSON(w, 200, map[string]interface{}{
		"output":      string(stdout),
		"exit_status": exit,
		"reused":      reused,
	})
}

// WebSocket: run command and stream stdout/stderr as it arrives.
func handleStreamCommand(w http.ResponseWriter, r *http.Request, email string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	// Query: id, cmd, keepalive_seconds, timeout_seconds
	q := r.URL.Query()
	id, _ := strconv.ParseInt(q.Get("id"), 10, 64)
	cmd := strings.TrimSpace(q.Get("cmd"))
	keepalive, _ := strconv.Atoi(q.Get("keepalive_seconds"))
	timeout, _ := strconv.Atoi(q.Get("timeout_seconds"))
	if id == 0 || cmd == "" {
		http.Error(w, "missing id/cmd", 400)
		return
	}
	if timeout <= 0 {
		timeout = 60
	}
	recordCommandHistory(email, cmd)

	var host, username string
	var port int
	var passEnc, keyEnc, phrEnc []byte
	err := db.QueryRow(`SELECT host, port, username, password_enc, private_key_enc, passphrase_enc FROM ssh_connections WHERE id=? AND owner_email=?`, id, email).
		Scan(&host, &port, &username, &passEnc, &keyEnc, &phrEnc)
	if err != nil {
		http.Error(w, "not found", 404)
		return
	}

	var auths []ssh.AuthMethod
	if len(keyEnc) > 0 {
		keyPem, err := openSeal(keyEnc)
		if err != nil {
			http.Error(w, "key decrypt", 500)
			return
		}
		var signer ssh.Signer
		if len(phrEnc) > 0 {
			pw, _ := openSeal(phrEnc)
			signer, err = ssh.ParsePrivateKeyWithPassphrase(keyPem, pw)
		} else {
			signer, err = ssh.ParsePrivateKey(keyPem)
		}
		if err != nil {
			http.Error(w, "bad key", 400)
			return
		}
		auths = append(auths, ssh.PublicKeys(signer))
	}
	if len(passEnc) > 0 {
		pw, err := openSeal(passEnc)
		if err != nil {
			http.Error(w, "pw decrypt", 500)
			return
		}
		auths = append(auths, ssh.Password(string(pw)))
	}
	if len(auths) == 0 {
		http.Error(w, "no credentials", 400)
		return
	}

	cfg := &ssh.ClientConfig{User: username, Auth: auths, HostKeyCallback: ssh.InsecureIgnoreHostKey(), Timeout: time.Duration(timeout) * time.Second}
	ttl := connTTL
	if keepalive > 0 {
		ttl = time.Duration(keepalive) * time.Second
	}
	client, _, err := getOrDialClient(email, id, fmt.Sprintf("%s:%d", host, port), cfg, ttl, time.Duration(timeout)*time.Second)
	if err != nil {
		http.Error(w, "dial failed", 502)
		return
	}
	go broadcastLive(email)

	upgrader := websocket.Upgrader{CheckOrigin: wsOriginChecker}
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer c.Close()

	session, err := client.NewSession()
	if err != nil {
		c.WriteMessage(websocket.TextMessage, []byte("ERR: session failed"))
		return
	}
	defer session.Close()
	stdout, _ := session.StdoutPipe()
	stderr, _ := session.StderrPipe()
	if err := session.Start(cmd); err != nil {
		c.WriteMessage(websocket.TextMessage, []byte("ERR: start failed"))
		return
	}

	done := make(chan struct{}, 1)
	go func() { io.Copy(wsWriter{c}, stdout); done <- struct{}{} }()
	go func() { io.Copy(wsWriter{c}, stderr); done <- struct{}{} }()

	// Wait for both streams and command exit
	_ = session.Wait()
	<-done
	<-done
	_ = c.WriteMessage(websocket.TextMessage, []byte("__CMD_DONE__"))
}

func handleCommandHistory(w http.ResponseWriter, r *http.Request, email string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	limit := 50
	if lStr := strings.TrimSpace(r.URL.Query().Get("limit")); lStr != "" {
		if l, err := strconv.Atoi(lStr); err == nil && l > 0 && l <= 200 {
			limit = l
		}
	}
	rows, err := db.Query(`SELECT command FROM ssh_command_history WHERE owner_email=? ORDER BY last_used_at DESC LIMIT ?`, email, limit)
	if err != nil {
		writeJSON(w, 500, map[string]string{"error": "query error"})
		return
	}
	defer rows.Close()
	cmds := []string{}
	for rows.Next() {
		var cmd string
		if err := rows.Scan(&cmd); err != nil {
			writeJSON(w, 500, map[string]string{"error": "scan error"})
			return
		}
		cmds = append(cmds, cmd)
	}
	writeJSON(w, 200, map[string]interface{}{"commands": cmds})
}

func recordCommandHistory(email, cmd string) {
	trimmed := strings.TrimSpace(cmd)
	if trimmed == "" || email == "" {
		return
	}
	sum := sha256.Sum256([]byte(trimmed))
	hash := fmt.Sprintf("%x", sum[:])
	now := time.Now()
	_, err := db.Exec(
		`INSERT INTO ssh_command_history (owner_email, command, command_hash, created_at, last_used_at)
         VALUES (?, ?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE last_used_at=VALUES(last_used_at)`,
		email, trimmed, hash, now, now,
	)
	if err != nil {
		log.Printf("command history insert failed: %v", err)
	}
}

type wsWriter struct{ c *websocket.Conn }

func (w wsWriter) Write(p []byte) (int, error) {
	return len(p), w.c.WriteMessage(websocket.TextMessage, p)
}

// wsOriginChecker allows WS only from configured origins (or all if unset).
func wsOriginChecker(r *http.Request) bool {
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	// Allow non-browser or same-origin requests with no Origin header
	if origin == "" {
		return true
	}
	allowed := strings.Split(strings.TrimSpace(os.Getenv("CORS_ALLOWED_ORIGINS")), ",")
	if len(allowed) == 1 && strings.TrimSpace(allowed[0]) == "" {
		return true
	}
	for _, a := range allowed {
		if strings.TrimSpace(a) == origin {
			return true
		}
	}
	return false
}

// handleHealthWS upgrades to WebSocket and sends a simple probe message.
func handleHealthWS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	upgrader := websocket.Upgrader{CheckOrigin: wsOriginChecker}
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer c.Close()
	_ = c.WriteMessage(websocket.TextMessage, []byte("ws-ok"))
}

// Live connections WebSocket
var (
	subsMu      = &sync.Mutex{}
	subscribers = map[string]map[*websocket.Conn]struct{}{}
)

func handleLiveWS(w http.ResponseWriter, r *http.Request, email string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	upgrader := websocket.Upgrader{CheckOrigin: wsOriginChecker}
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	// Register
	subsMu.Lock()
	if subscribers[email] == nil {
		subscribers[email] = make(map[*websocket.Conn]struct{})
	}
	subscribers[email][c] = struct{}{}
	subsMu.Unlock()
	// Ensure cleanup on close
	defer func() {
		subsMu.Lock()
		delete(subscribers[email], c)
		if len(subscribers[email]) == 0 {
			delete(subscribers, email)
		}
		subsMu.Unlock()
		_ = c.Close()
	}()
	// Send initial snapshot
	sendLive(email, c)
	// Keep connection open; read loop to detect close
	c.SetReadLimit(512)
	c.SetReadDeadline(time.Now().Add(60 * time.Second))
	c.SetPongHandler(func(string) error { c.SetReadDeadline(time.Now().Add(60 * time.Second)); return nil })
	for {
		if _, _, err := c.ReadMessage(); err != nil {
			break
		}
	}
}

// handleControlWS maintains a WS to receive control events (e.g., trackpad/click)
// and forwards them to the SSH target as short commands.
// Query params: id (connection id, required), keepalive_seconds, timeout_seconds
// Messages from client (text):
//
//	{"type":"move","dx":int,"dy":int}
//	{"type":"click","button":1|2}
func handleControlWS(w http.ResponseWriter, r *http.Request, email string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	q := r.URL.Query()
	id, _ := strconv.ParseInt(q.Get("id"), 10, 64)
	if id == 0 {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	keepalive, _ := strconv.Atoi(q.Get("keepalive_seconds"))
	timeout, _ := strconv.Atoi(q.Get("timeout_seconds"))
	if timeout <= 0 {
		timeout = 30
	}

	// Load connection and secrets
	var host, username string
	var port int
	var passEnc, keyEnc, phrEnc []byte
	err := db.QueryRow(`SELECT host, port, username, password_enc, private_key_enc, passphrase_enc FROM ssh_connections WHERE id=? AND owner_email=?`, id, email).
		Scan(&host, &port, &username, &passEnc, &keyEnc, &phrEnc)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	var auths []ssh.AuthMethod
	if len(keyEnc) > 0 {
		keyPem, err := openSeal(keyEnc)
		if err != nil {
			http.Error(w, "key decrypt", 500)
			return
		}
		var signer ssh.Signer
		if len(phrEnc) > 0 {
			pw, _ := openSeal(phrEnc)
			signer, err = ssh.ParsePrivateKeyWithPassphrase(keyPem, pw)
		} else {
			signer, err = ssh.ParsePrivateKey(keyPem)
		}
		if err != nil {
			http.Error(w, "bad key", 400)
			return
		}
		auths = append(auths, ssh.PublicKeys(signer))
	}
	if len(passEnc) > 0 {
		pw, err := openSeal(passEnc)
		if err != nil {
			http.Error(w, "pw decrypt", 500)
			return
		}
		auths = append(auths, ssh.Password(string(pw)))
	}
	if len(auths) == 0 {
		http.Error(w, "no credentials", 400)
		return
	}

	cfg := &ssh.ClientConfig{User: username, Auth: auths, HostKeyCallback: ssh.InsecureIgnoreHostKey(), Timeout: time.Duration(timeout) * time.Second}
	ttl := connTTL
	if keepalive > 0 {
		ttl = time.Duration(keepalive) * time.Second
	}
	client, _, err := getOrDialClient(email, id, fmt.Sprintf("%s:%d", host, port), cfg, ttl, time.Duration(timeout)*time.Second)
	if err != nil {
		http.Error(w, "dial failed", 502)
		return
	}
	go broadcastLive(email)

	upgrader := websocket.Upgrader{CheckOrigin: wsOriginChecker}
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer c.Close()

	type ctrlMsg struct {
		Type   string `json:"type"`
		DX     int    `json:"dx"`
		DY     int    `json:"dy"`
		Button int    `json:"button"`
	}

	// Simple helper to run a short command and ignore output
	runShort := func(cmd string) {
		session, err := client.NewSession()
		if err != nil {
			_ = c.WriteMessage(websocket.TextMessage, []byte("ERR: session"))
			return
		}
		defer session.Close()
		// We don't stream; just execute and ignore errors (best-effort)
		_, _ = session.CombinedOutput(cmd)
	}

	// Read loop
	for {
		mt, data, err := c.ReadMessage()
		if err != nil {
			break
		}
		if mt != websocket.TextMessage && mt != websocket.BinaryMessage {
			continue
		}
		// Expect JSON text; ignore binary for now
		var m ctrlMsg
		if err := json.Unmarshal(data, &m); err != nil {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(m.Type)) {
		case "move":
			// Compose echo
			cmd := fmt.Sprintf("echo \"M, %d,%d\" > /dev/ttyAMA0", m.DX, m.DY)
			runShort(cmd)
		case "click":
			if m.Button != 1 && m.Button != 2 {
				m.Button = 1
			}
			cmd := fmt.Sprintf("echo \"C, %d\" > /dev/ttyAMA0", m.Button)
			runShort(cmd)
		default:
			// ignore
		}
	}
}

type liveEntry struct {
	ID        int64     `json:"id"`
	LastUsed  time.Time `json:"last_used"`
	ExpiresAt time.Time `json:"expires_at"`
}

func snapshotLive(email string) []liveEntry {
	prefix := email + "#"
	now := time.Now()
	activeMu.Lock()
	out := make([]liveEntry, 0)
	for k, ac := range activeConns {
		if strings.HasPrefix(k, prefix) {
			parts := strings.Split(k, "#")
			if len(parts) == 2 {
				if id, err := strconv.ParseInt(parts[1], 10, 64); err == nil {
					e := liveEntry{ID: id, LastUsed: ac.lastUsed, ExpiresAt: ac.lastUsed.Add(ac.ttl)}
					if e.ExpiresAt.After(now) {
						out = append(out, e)
					}
				}
			}
		}
	}
	activeMu.Unlock()
	return out
}

func sendLive(email string, c *websocket.Conn) {
	payload := map[string]any{"type": "live", "live": snapshotLive(email)}
	b, _ := json.Marshal(payload)
	_ = c.WriteMessage(websocket.TextMessage, b)
}

func broadcastLive(email string) {
	subsMu.Lock()
	conns := make([]*websocket.Conn, 0, len(subscribers[email]))
	for conn := range subscribers[email] {
		conns = append(conns, conn)
	}
	subsMu.Unlock()
	if len(conns) == 0 {
		return
	}
	payload := map[string]any{"type": "live", "live": snapshotLive(email)}
	b, _ := json.Marshal(payload)
	for _, c := range conns {
		if err := c.WriteMessage(websocket.TextMessage, b); err != nil {
			subsMu.Lock()
			delete(subscribers[email], c)
			subsMu.Unlock()
			_ = c.Close()
		}
	}
}

func nullIfEmpty(b []byte) interface{} {
	if len(b) == 0 {
		return nil
	}
	return b
}

func seal(plain []byte) ([]byte, error) {
	block, err := aes.NewCipher(encKey)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	out := aead.Seal(nil, nonce, plain, nil)
	// store as nonce|ciphertext base64
	buf := make([]byte, 0, len(nonce)+len(out))
	buf = append(buf, nonce...)
	buf = append(buf, out...)
	enc := make([]byte, base64.StdEncoding.EncodedLen(len(buf)))
	base64.StdEncoding.Encode(enc, buf)
	return enc, nil
}

func openSeal(b64 []byte) ([]byte, error) {
	raw := make([]byte, base64.StdEncoding.DecodedLen(len(b64)))
	n, err := base64.StdEncoding.Decode(raw, b64)
	if err != nil {
		return nil, err
	}
	raw = raw[:n]
	block, err := aes.NewCipher(encKey)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(raw) < aead.NonceSize() {
		return nil, errors.New("ciphertext too short")
	}
	nonce, ct := raw[:aead.NonceSize()], raw[aead.NonceSize():]
	return aead.Open(nil, nonce, ct, nil)
}

func writeJSON(w http.ResponseWriter, status int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

// Connection cache helpers
func keyFor(email string, id int64) string { return fmt.Sprintf("%s#%d", email, id) }

func getOrDialClient(email string, id int64, addr string, cfg *ssh.ClientConfig, ttl time.Duration, connTimeout time.Duration) (*ssh.Client, bool, error) {
	key := keyFor(email, id)
	now := time.Now()
	activeMu.Lock()
	if ac, ok := activeConns[key]; ok {
		if now.Sub(ac.lastUsed) < ac.ttl {
			ac.lastUsed = now
			cli := ac.client
			activeMu.Unlock()
			return cli, true, nil
		}
		// expired
		_ = ac.client.Close()
		delete(activeConns, key)
	}
	activeMu.Unlock()
	// Dial outside lock
	cli, err := dialSSH(addr, cfg, connTimeout)
	if err != nil {
		return nil, false, err
	}
	activeMu.Lock()
	activeConns[key] = &activeConn{client: cli, lastUsed: now, ttl: ttl}
	activeMu.Unlock()
	return cli, false, nil
}

// dialSSH performs TCP dial with timeout and completes SSH handshake.
func dialSSH(addr string, cfg *ssh.ClientConfig, timeout time.Duration) (*ssh.Client, error) {
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return nil, err
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, addr, cfg)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	return ssh.NewClient(c, chans, reqs), nil
}

func sweepExpired() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		activeMu.Lock()
		for k, ac := range activeConns {
			if now.Sub(ac.lastUsed) >= ac.ttl {
				_ = ac.client.Close()
				delete(activeConns, k)
			}
		}
		activeMu.Unlock()
	}
}

func handleLiveConnections(w http.ResponseWriter, r *http.Request, email string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	type liveEntry struct {
		ID        int64     `json:"id"`
		LastUsed  time.Time `json:"last_used"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	out := []liveEntry{}
	prefix := email + "#"
	now := time.Now()
	activeMu.Lock()
	for k, ac := range activeConns {
		if strings.HasPrefix(k, prefix) {
			// parse id from key
			parts := strings.Split(k, "#")
			if len(parts) != 2 {
				continue
			}
			if id, err := strconv.ParseInt(parts[1], 10, 64); err == nil {
				out = append(out, liveEntry{ID: id, LastUsed: ac.lastUsed, ExpiresAt: ac.lastUsed.Add(ac.ttl)})
			}
		}
	}
	activeMu.Unlock()
	// Filter out any already expired due to race
	filtered := out[:0]
	for _, e := range out {
		if e.ExpiresAt.After(now) {
			filtered = append(filtered, e)
		}
	}
	writeJSON(w, 200, map[string]any{"live": filtered})
}

// Disconnect a live connection: DELETE /api/ssh/live/{id}
func handleLiveDelete(w http.ResponseWriter, r *http.Request, email string) {
	if r.Method != http.MethodDelete {
		w.Header().Set("Allow", "DELETE")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	idStr := strings.TrimPrefix(r.URL.Path, "/api/ssh/live/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		writeJSON(w, 400, map[string]string{"error": "invalid id"})
		return
	}
	key := keyFor(email, id)
	activeMu.Lock()
	if ac, ok := activeConns[key]; ok {
		_ = ac.client.Close()
		delete(activeConns, key)
	}
	activeMu.Unlock()
	go broadcastLive(email)
	writeJSON(w, 200, map[string]string{"status": "disconnected"})
}
