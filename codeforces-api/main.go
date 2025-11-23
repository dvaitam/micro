package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	_ "github.com/lib/pq"
	"github.com/segmentio/kafka-go"
)

type problem struct {
	ID                int64  `json:"id"`
	ContestID         string `json:"contest_id"`
	Index             string `json:"index"`
	Title             string `json:"title"`
	Statement         string `json:"statement"`
	ReferenceSolution string `json:"reference_solution,omitempty"`
	Verifier          string `json:"verifier,omitempty"`
}

type submissionRequest struct {
	ContestID string `json:"contest_id"`
	Index     string `json:"index"`
	Lang      string `json:"lang"`
	Code      string `json:"code"`
}

type submissionResponse struct {
	SubmissionID int64  `json:"submission_id"`
	Status       string `json:"status"`
}

type submissionRecord struct {
	ID        int64  `json:"id"`
	ContestID string `json:"contest_id"`
	Index     string `json:"index"`
	Status    string `json:"status"`
	Verdict   string `json:"verdict,omitempty"`
	ExitCode  int    `json:"exit_code,omitempty"`
	Code      string `json:"code,omitempty"`
	Stdout    string `json:"stdout,omitempty"`
	Stderr    string `json:"stderr,omitempty"`
	Response  string `json:"response,omitempty"`
	Timestamp string `json:"timestamp"`
}

type statusMessage struct {
	SubmissionID int64  `json:"submission_id"`
	Status       string `json:"status"`
	Verdict      string `json:"verdict,omitempty"`
	Stdout       string `json:"stdout,omitempty"`
	Stderr       string `json:"stderr,omitempty"`
	ExitCode     *int   `json:"exit_code,omitempty"`
}

type server struct {
	db              *sql.DB
	mysql           *sql.DB
	submissionTopic string
	statusTopic     string
	otpTopic        string
	producer        *kafka.Writer
	otpProducer     *kafka.Writer
	statusReader    *kafka.Reader
	hub             *wsHub
	upgrader        websocket.Upgrader
}

func main() {
	port := getenv("PORT", "8082")
	dbDSN := getenv("DB_DSN", "postgres://postgres:password@localhost:5432/codeforces?sslmode=disable")
	mysqlDSN := getenv("MYSQL_DSN", "root:password@tcp(mysql.default.svc.cluster.local:3306)/micro_auth?parseTime=true")
	brokers := splitAndTrim(getenv("KAFKA_BROKERS", "localhost:9092"))
	submissionTopic := getenv("KAFKA_SUBMISSION_TOPIC", "cf.submissions")
	statusTopic := getenv("KAFKA_STATUS_TOPIC", "cf.submission_status")
	otpTopic := getenv("KAFKA_OTP_TOPIC", "new-registration")

	if err := ensureKafkaTopics(context.Background(), brokers, []string{submissionTopic, statusTopic, otpTopic}); err != nil {
		log.Fatalf("failed to ensure kafka topics: %v", err)
	}

	db, err := sql.Open("postgres", dbDSN)
	if err != nil {
		log.Fatalf("failed to open db: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	if err := db.Ping(); err != nil {
		log.Fatalf("failed to ping db: %v", err)
	}
	if err := ensureSchemas(context.Background(), db); err != nil {
		log.Fatalf("failed to ensure schema: %v", err)
	}

	mysqlDB, err := sql.Open("mysql", mysqlDSN)
	if err != nil {
		log.Fatalf("failed to open mysql: %v", err)
	}
	if err := mysqlDB.Ping(); err != nil {
		log.Fatalf("failed to ping mysql: %v", err)
	}

	producer := &kafka.Writer{
		Addr:                   kafka.TCP(brokers...),
		Topic:                  submissionTopic,
		Balancer:               &kafka.LeastBytes{},
		AllowAutoTopicCreation: true,
	}
	otpProducer := &kafka.Writer{
		Addr:                   kafka.TCP(brokers...),
		Topic:                  otpTopic,
		Balancer:               &kafka.LeastBytes{},
		AllowAutoTopicCreation: true,
	}
	statusReader := kafka.NewReader(kafka.ReaderConfig{
		Brokers:  brokers,
		Topic:    statusTopic,
		GroupID:  "codeforces-api",
		MaxBytes: 10e6,
	})

	s := &server{
		db:              db,
		mysql:           mysqlDB,
		submissionTopic: submissionTopic,
		statusTopic:     statusTopic,
		otpTopic:        otpTopic,
		producer:        producer,
		otpProducer:     otpProducer,
		statusReader:    statusReader,
		hub:             newHub(),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}

	go s.consumeStatusLoop(context.Background())

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/problems", s.handleProblems)
	mux.HandleFunc("/problems/", s.handleProblemByPath)
	mux.HandleFunc("/submissions", s.handleCreateSubmission)
	mux.HandleFunc("/me/submissions", s.handleUserSubmissions)
	mux.HandleFunc("/auth/request-otp", s.handleRequestOTP)
	mux.HandleFunc("/auth/verify-otp", s.handleVerifyOTP)
	mux.HandleFunc("/ws", s.handleWebsocket)
	handler := withCORS(mux)

	log.Printf("codeforces-api listening on :%s", port)
	if err := http.ListenAndServe(":"+port, handler); err != nil {
		log.Fatal(err)
	}
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) handleProblems(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	limit := 20
	if lStr := r.URL.Query().Get("limit"); lStr != "" {
		if l, err := strconv.Atoi(lStr); err == nil && l > 0 && l <= 500 {
			limit = l
		}
	}
	offset := 0
	if oStr := r.URL.Query().Get("offset"); oStr != "" {
		if o, err := strconv.Atoi(oStr); err == nil && o >= 0 {
			offset = o
		}
	}
	rows, err := s.db.Query(`
		SELECT id, contest_id, index_name, COALESCE(title, ''), COALESCE(statement, ''), 
		       COALESCE(reference_solution, ''), COALESCE(verifier, '')
		FROM problems
		ORDER BY contest_id, index_name
		LIMIT $1 OFFSET $2`, limit, offset)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	var probs []problem
	for rows.Next() {
		var p problem
		if err := rows.Scan(&p.ID, &p.ContestID, &p.Index, &p.Title, &p.Statement, &p.ReferenceSolution, &p.Verifier); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		probs = append(probs, p)
	}
	writeJSON(w, http.StatusOK, probs)
}

func (s *server) handleProblemByPath(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/problems/"), "/")
	if len(parts) != 2 {
		http.NotFound(w, r)
		return
	}
	contest := parts[0]
	index := parts[1]
	var p problem
	err := s.db.QueryRow(`
		SELECT id, contest_id, index_name, COALESCE(title, ''), COALESCE(statement, ''), 
		       COALESCE(reference_solution, ''), COALESCE(verifier, '')
		FROM problems
		WHERE contest_id = $1 AND UPPER(index_name) = UPPER($2)
	`, contest, index).Scan(&p.ID, &p.ContestID, &p.Index, &p.Title, &p.Statement, &p.ReferenceSolution, &p.Verifier)
	if errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func (s *server) handleCreateSubmission(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	userID, err := s.authenticate(r)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var req submissionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	if req.ContestID == "" || req.Index == "" || req.Code == "" {
		http.Error(w, "contest_id, index, and code are required", http.StatusBadRequest)
		return
	}
	status := "queued"
	var id int64
	err = s.db.QueryRow(`
		INSERT INTO submissions (contest_id, problem_letter, lang, code, status, user_id)
		VALUES ($1, UPPER($2), $3, $4, $5, $6)
		RETURNING id
	`, req.ContestID, req.Index, req.Lang, req.Code, status, userID).Scan(&id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	msg := statusMessage{
		SubmissionID: id,
		Status:       status,
	}
	if err := s.publishSubmission(msg); err != nil {
		log.Printf("failed to publish submission %d: %v", id, err)
	}

	writeJSON(w, http.StatusAccepted, submissionResponse{
		SubmissionID: id,
		Status:       status,
	})
}

func (s *server) handleUserSubmissions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	userID, err := s.authenticate(r)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	limit := 50
	if lStr := r.URL.Query().Get("limit"); lStr != "" {
		if l, err := strconv.Atoi(lStr); err == nil && l > 0 && l <= 200 {
			limit = l
		}
	}
	offset := 0
	if oStr := r.URL.Query().Get("offset"); oStr != "" {
		if o, err := strconv.Atoi(oStr); err == nil && o >= 0 {
			offset = o
		}
	}
	rows, err := s.db.Query(`
		SELECT id, contest_id, problem_letter,
		       COALESCE(status,''), COALESCE(verdict,''), COALESCE(exit_code,0),
		       COALESCE(code,''), COALESCE(stdout,''), COALESCE(stderr,''), COALESCE(response,''),
		       timestamp
		FROM submissions
		WHERE user_id = $1
		ORDER BY id DESC
		LIMIT $2 OFFSET $3
	`, userID, limit, offset)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	var list []submissionRecord
	for rows.Next() {
		var rec submissionRecord
		var ts time.Time
		if err := rows.Scan(&rec.ID, &rec.ContestID, &rec.Index, &rec.Status, &rec.Verdict, &rec.ExitCode, &rec.Code, &rec.Stdout, &rec.Stderr, &rec.Response, &ts); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		rec.Timestamp = ts.Format(time.RFC3339)
		list = append(list, rec)
	}
	writeJSON(w, http.StatusOK, list)
}
func (s *server) publishSubmission(msg statusMessage) error {
	payload, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return s.producer.WriteMessages(context.Background(), kafka.Message{
		Key:   []byte(strconv.FormatInt(msg.SubmissionID, 10)),
		Value: payload,
	})
}

func (s *server) consumeStatusLoop(ctx context.Context) {
	for {
		m, err := s.statusReader.ReadMessage(ctx)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return
			}
			log.Printf("status consumer error: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}
		var upd statusMessage
		if err := json.Unmarshal(m.Value, &upd); err != nil {
			log.Printf("invalid status message: %v", err)
			continue
		}
		if upd.SubmissionID == 0 {
			continue
		}
		if err := s.applyStatusUpdate(ctx, upd); err != nil {
			log.Printf("failed to apply status %d: %v", upd.SubmissionID, err)
		}
		s.hub.broadcast(upd)
	}
}

func (s *server) applyStatusUpdate(ctx context.Context, upd statusMessage) error {
	var exitCode sql.NullInt32
	if upd.ExitCode != nil {
		exitCode = sql.NullInt32{Int32: int32(*upd.ExitCode), Valid: true}
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE submissions
		SET status = COALESCE($1, status),
		    stdout = COALESCE(NULLIF($2, ''), stdout),
		    stderr = COALESCE(NULLIF($3, ''), stderr),
		    response = COALESCE(NULLIF($4, ''), response),
		    exit_code = COALESCE($5::INT, exit_code),
		    verdict = COALESCE(NULLIF($6, ''), verdict),
		    updated_at = NOW()
		WHERE id = $7
	`, upd.Status, upd.Stdout, upd.Stderr, upd.Verdict, exitCode, upd.Verdict, upd.SubmissionID)
	return err
}

func (s *server) handleWebsocket(w http.ResponseWriter, r *http.Request) {
	subIDStr := r.URL.Query().Get("submissionId")
	if subIDStr == "" {
		http.Error(w, "submissionId is required", http.StatusBadRequest)
		return
	}
	subID, err := strconv.ParseInt(subIDStr, 10, 64)
	if err != nil {
		http.Error(w, "invalid submissionId", http.StatusBadRequest)
		return
	}
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	client := &wsClient{
		submissionID: subID,
		conn:         conn,
		send:         make(chan statusMessage, 4),
		hub:          s.hub,
	}
	s.hub.register(client)
	go client.writePump()
	client.readPump()
}

func (s *server) handleRequestOTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil || payload.Email == "" {
		http.Error(w, "email required", http.StatusBadRequest)
		return
	}
	if err := s.otpProducer.WriteMessages(r.Context(), kafka.Message{
		Key:   []byte(payload.Email),
		Value: []byte(payload.Email),
	}); err != nil {
		http.Error(w, "failed to enqueue otp", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "otp_sent"})
}

func (s *server) handleVerifyOTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil || payload.Email == "" || payload.Code == "" {
		http.Error(w, "email and code required", http.StatusBadRequest)
		return
	}
	ok, err := s.validateOTP(r.Context(), payload.Email, payload.Code)
	if err != nil {
		http.Error(w, "otp validation failed", http.StatusInternalServerError)
		return
	}
	if !ok {
		http.Error(w, "invalid code", http.StatusUnauthorized)
		return
	}
	userID, err := s.ensureUser(r.Context(), payload.Email)
	if err != nil {
		http.Error(w, "failed to create user", http.StatusInternalServerError)
		return
	}
	token, expires, err := s.createSession(r.Context(), userID)
	if err != nil {
		http.Error(w, "failed to create session", http.StatusInternalServerError)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "CF_SESSION",
		Value:    token,
		Path:     "/",
		Expires:  expires,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	writeJSON(w, http.StatusOK, map[string]string{"token": token, "email": payload.Email})
}

func (s *server) validateOTP(ctx context.Context, email, code string) (bool, error) {
	var stored string
	var expires time.Time
	err := s.mysql.QueryRowContext(ctx, `SELECT code, expires_at FROM otp_codes WHERE email = ?`, email).Scan(&stored, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if time.Now().After(expires) {
		return false, nil
	}
	return strings.TrimSpace(stored) == strings.TrimSpace(code), nil
}

func (s *server) ensureUser(ctx context.Context, email string) (int64, error) {
	var id int64
	err := s.db.QueryRowContext(ctx, `SELECT id FROM users WHERE email = $1`, email).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	err = s.db.QueryRowContext(ctx, `INSERT INTO users (email) VALUES ($1) RETURNING id`, email).Scan(&id)
	return id, err
}

func (s *server) createSession(ctx context.Context, userID int64) (string, time.Time, error) {
	token := uuid.NewString()
	exp := time.Now().Add(24 * time.Hour)
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO sessions (token, user_id, expires_at)
		VALUES ($1, $2, $3)
	`, token, userID, exp)
	return token, exp, err
}

func (s *server) authenticate(r *http.Request) (int64, error) {
	var token string
	auth := r.Header.Get("Authorization")
	if strings.HasPrefix(auth, "Bearer ") {
		token = strings.TrimPrefix(auth, "Bearer ")
	}
	if token == "" {
		if c, err := r.Cookie("CF_SESSION"); err == nil {
			token = c.Value
		}
	}
	if token == "" {
		return 0, errors.New("missing token")
	}
	var userID int64
	var expires time.Time
	err := s.db.QueryRow(`
		SELECT user_id, expires_at FROM sessions WHERE token = $1
	`, token).Scan(&userID, &expires)
	if err != nil {
		return 0, err
	}
	if time.Now().After(expires) {
		return 0, errors.New("session expired")
	}
	return userID, nil
}

func ensureSchemas(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS submissions (
			id SERIAL PRIMARY KEY,
			contest_id VARCHAR(20),
			problem_letter VARCHAR(10),
			lang VARCHAR(20),
			code TEXT,
			stdout TEXT,
			stderr TEXT,
			response TEXT,
			exit_code INT,
			timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			user_id INT
		)`); err != nil {
		return err
	}
	ddl := []string{
		`ALTER TABLE submissions ADD COLUMN IF NOT EXISTS status VARCHAR(32) DEFAULT 'queued'`,
		`ALTER TABLE submissions ADD COLUMN IF NOT EXISTS verdict VARCHAR(64)`,
		`ALTER TABLE submissions ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`,
		`ALTER TABLE submissions ADD COLUMN IF NOT EXISTS user_id INT`,
		`CREATE TABLE IF NOT EXISTS users (
			id SERIAL PRIMARY KEY,
			email VARCHAR(255) UNIQUE NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE IF NOT EXISTS sessions (
			token VARCHAR(255) PRIMARY KEY,
			user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			expires_at TIMESTAMP NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE INDEX IF NOT EXISTS idx_submissions_user ON submissions(user_id)`,
	}
	for _, stmt := range ddl {
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			return err
		}
	}
	return nil
}

func ensureKafkaTopics(ctx context.Context, brokers []string, topics []string) error {
	if len(brokers) == 0 || len(topics) == 0 {
		return nil
	}
	conn, err := kafka.DialContext(ctx, "tcp", brokers[0])
	if err != nil {
		return err
	}
	defer conn.Close()

	var configs []kafka.TopicConfig
	for _, t := range topics {
		if strings.TrimSpace(t) == "" {
			continue
		}
		configs = append(configs, kafka.TopicConfig{
			Topic:             t,
			NumPartitions:     1,
			ReplicationFactor: 1,
		})
	}
	if len(configs) == 0 {
		return nil
	}
	return conn.CreateTopics(configs...)
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type,Authorization")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func splitAndTrim(s string) []string {
	parts := strings.Split(s, ",")
	var cleaned []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			cleaned = append(cleaned, p)
		}
	}
	return cleaned
}

type wsHub struct {
	mu      sync.RWMutex
	clients map[int64]map[*wsClient]struct{}
}

func newHub() *wsHub {
	return &wsHub{
		clients: make(map[int64]map[*wsClient]struct{}),
	}
}

func (h *wsHub) register(c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[c.submissionID] == nil {
		h.clients[c.submissionID] = make(map[*wsClient]struct{})
	}
	h.clients[c.submissionID][c] = struct{}{}
}

func (h *wsHub) unregister(c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set, ok := h.clients[c.submissionID]; ok {
		delete(set, c)
		if len(set) == 0 {
			delete(h.clients, c.submissionID)
		}
	}
}

func (h *wsHub) broadcast(msg statusMessage) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	set := h.clients[msg.SubmissionID]
	for c := range set {
		select {
		case c.send <- msg:
		default:
		}
	}
}

type wsClient struct {
	submissionID int64
	conn         *websocket.Conn
	send         chan statusMessage
	hub          *wsHub
}

func (c *wsClient) readPump() {
	defer func() {
		c.hub.unregister(c)
		c.conn.Close()
	}()
	for {
		if _, _, err := c.conn.ReadMessage(); err != nil {
			break
		}
	}
}

func (c *wsClient) writePump() {
	defer func() {
		c.hub.unregister(c)
		c.conn.Close()
	}()
	for msg := range c.send {
		payload, _ := json.Marshal(msg)
		if err := c.conn.WriteMessage(websocket.TextMessage, payload); err != nil {
			return
		}
	}
}
