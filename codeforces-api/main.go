package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	_ "github.com/lib/pq"
	"github.com/segmentio/kafka-go"
)

var jwtSecret = []byte(getenv("JWT_SECRET", "very-secret-key-change-in-prod"))

type Claims struct {
	UserID int64 `json:"user_id"`
	jwt.RegisteredClaims
}

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
	Lang      string `json:"lang,omitempty"`
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

type evaluationRecord struct {
	ID        int64  `json:"id"`
	RunID     string `json:"run_id,omitempty"`
	Provider  string `json:"provider,omitempty"`
	Model     string `json:"model,omitempty"`
	Lang      string `json:"lang,omitempty"`
	ProblemID int64  `json:"problem_id,omitempty"`
	ContestID int    `json:"contest_id,omitempty"`
	Index     string `json:"index,omitempty"`
	Rating    int    `json:"rating,omitempty"`
	Success   bool   `json:"success"`
	Timestamp string `json:"timestamp"`
	Prompt    string `json:"prompt,omitempty"`
	Response  string `json:"response,omitempty"`
	Stdout    string `json:"stdout,omitempty"`
	Stderr    string `json:"stderr,omitempty"`
}

type leaderboardEntry struct {
	RunID     string `json:"run_id"`
	Model     string `json:"model"`
	Lang      string `json:"lang"`
	Rating    int    `json:"rating"`
	Timestamp string `json:"timestamp"`
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

	if err := ensureKafkaTopicsWithRetry(context.Background(), brokers, []string{submissionTopic, statusTopic, otpTopic}, 10, 3*time.Second); err != nil {
		log.Printf("warning: continuing without ensuring kafka topics: %v", err)
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
	mux.HandleFunc("/evaluations", s.handleEvaluations)
	mux.HandleFunc("/leaderboard", s.handleLeaderboard)
	mux.HandleFunc("/model", s.handleModel)
	mux.HandleFunc("/me/submissions", s.handleUserSubmissions)
	mux.HandleFunc("/auth/request-otp", s.handleRequestOTP)
	mux.HandleFunc("/auth/verify-otp", s.handleVerifyOTP)
	mux.HandleFunc("/auth/refresh", s.handleRefreshToken)
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
	contestFilter := strings.TrimSpace(r.URL.Query().Get("contest"))
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

	query := `
		SELECT id, contest_id, index_name, COALESCE(title, ''), COALESCE(statement, ''),
		       COALESCE(reference_solution, ''), COALESCE(verifier, '')
		FROM problems
	`
	var (
		where []string
		args  []interface{}
	)
	if contestFilter != "" {
		where = append(where, fmt.Sprintf("contest_id = $%d", len(args)+1))
		args = append(args, contestFilter)
	}
	if len(where) > 0 {
		query += " WHERE " + strings.Join(where, " AND ")
	}
	query += fmt.Sprintf(" ORDER BY contest_id, index_name LIMIT $%d OFFSET $%d", len(args)+1, len(args)+2)
	args = append(args, limit, offset)

	rows, err := s.db.Query(query, args...)
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
	if r.Method == http.MethodGet {
		s.handleListSubmissions(w, r)
		return
	}
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

// handleListSubmissions returns submissions for a given contest/index for all users.
// This endpoint does not include code/stdout/stderr/response for privacy.
func (s *server) handleListSubmissions(w http.ResponseWriter, r *http.Request) {
	if idStr := strings.TrimSpace(r.URL.Query().Get("id")); idStr != "" {
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil || id <= 0 {
			http.Error(w, "invalid id", http.StatusBadRequest)
			return
		}
		var rec submissionRecord
		var ts time.Time
		err = s.db.QueryRow(`
			SELECT id, contest_id, problem_letter, COALESCE(lang,''),
			       COALESCE(status,''), COALESCE(verdict,''), COALESCE(exit_code,0),
			       COALESCE(code,''), COALESCE(stdout,''), COALESCE(stderr,''), COALESCE(response,''),
			       timestamp
			FROM submissions
			WHERE id = $1
		`, id).Scan(&rec.ID, &rec.ContestID, &rec.Index, &rec.Lang, &rec.Status, &rec.Verdict, &rec.ExitCode, &rec.Code, &rec.Stdout, &rec.Stderr, &rec.Response, &ts)
		if errors.Is(err, sql.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		rec.Timestamp = ts.Format(time.RFC3339)
		writeJSON(w, http.StatusOK, rec)
		return
	}

	contest := strings.TrimSpace(r.URL.Query().Get("contest"))
	index := strings.TrimSpace(r.URL.Query().Get("index"))
	if contest == "" || index == "" {
		http.Error(w, "contest and index are required", http.StatusBadRequest)
		return
	}
	limit := 50
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
		SELECT id, contest_id, problem_letter, lang,
		       COALESCE(status,''), COALESCE(verdict,''), COALESCE(exit_code,0),
		       timestamp
		FROM submissions
		WHERE contest_id = $1 AND UPPER(problem_letter) = UPPER($2)
		ORDER BY id DESC
		LIMIT $3 OFFSET $4
	`, contest, index, limit, offset)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	var list []submissionRecord
	for rows.Next() {
		var rec submissionRecord
		var ts time.Time
		if err := rows.Scan(&rec.ID, &rec.ContestID, &rec.Index, &rec.Lang, &rec.Status, &rec.Verdict, &rec.ExitCode, &ts); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		rec.Timestamp = ts.Format(time.RFC3339)
		// Do not expose code/stdout/stderr/response on this public list.
		rec.Code, rec.Stdout, rec.Stderr, rec.Response = "", "", "", ""
		list = append(list, rec)
	}
	writeJSON(w, http.StatusOK, list)
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
		SELECT id, contest_id, problem_letter, COALESCE(lang,''),
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
		if err := rows.Scan(&rec.ID, &rec.ContestID, &rec.Index, &rec.Lang, &rec.Status, &rec.Verdict, &rec.ExitCode, &rec.Code, &rec.Stdout, &rec.Stderr, &rec.Response, &ts); err != nil {
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
		Email        string `json:"email"`
		Code         string `json:"code"`
		StayLoggedIn bool   `json:"stay_logged_in"`
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

	// Generate Refresh Token (UUID, stored in DB)
	refreshToken, _, err := s.createRefreshToken(r.Context(), userID, payload.StayLoggedIn)
	if err != nil {
		http.Error(w, "failed to create refresh token", http.StatusInternalServerError)
		return
	}

	// Generate Access Token (JWT, stateless)
	accessToken, err := s.createAccessToken(userID)
	if err != nil {
		http.Error(w, "failed to create access token", http.StatusInternalServerError)
		return
	}

	// Set refresh token in HttpOnly cookie (optional, but good practice)
	// Also return it in body for flexibility
	writeJSON(w, http.StatusOK, map[string]string{
		"access_token":  accessToken,
		"refresh_token": refreshToken,
		"email":         payload.Email,
	})
}

func (s *server) handleRefreshToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		RefreshToken string `json:"refresh_token"`
	}
	// Try reading from body first
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil || payload.RefreshToken == "" {
		// Fallback to cookie if implemented/needed
		// for now strict body requirement
		http.Error(w, "refresh_token required", http.StatusBadRequest)
		return
	}

	var userID int64
	var expires time.Time
	err := s.db.QueryRow(`
		SELECT user_id, expires_at FROM sessions WHERE token = $1
	`, payload.RefreshToken).Scan(&userID, &expires)

	if err != nil || time.Now().After(expires) {
		http.Error(w, "invalid or expired refresh token", http.StatusUnauthorized)
		return
	}

	// Generate new Access Token
	accessToken, err := s.createAccessToken(userID)
	if err != nil {
		http.Error(w, "failed to create token", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"access_token": accessToken,
	})
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

// createRefreshToken creates a long-lived opaque token stored in DB
func (s *server) createRefreshToken(ctx context.Context, userID int64, stayLoggedIn bool) (string, time.Time, error) {
	token := uuid.NewString()
	duration := 24 * time.Hour
	if stayLoggedIn {
		duration = 30 * 24 * time.Hour // 30 days
	}
	exp := time.Now().Add(duration)
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO sessions (token, user_id, expires_at)
		VALUES ($1, $2, $3)
	`, token, userID, exp)
	return token, exp, err
}

// createAccessToken creates a short-lived JWT
func (s *server) createAccessToken(userID int64) (string, error) {
	expirationTime := time.Now().Add(15 * time.Minute)
	claims := &Claims{
		UserID: userID,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(expirationTime),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(jwtSecret)
}

func (s *server) authenticate(r *http.Request) (int64, error) {
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return 0, errors.New("missing bearer token")
	}
	tokenStr := strings.TrimPrefix(auth, "Bearer ")

	// Check if it's a JWT
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenStr, claims, func(token *jwt.Token) (interface{}, error) {
		return jwtSecret, nil
	})

	if err == nil && token.Valid {
		return claims.UserID, nil
	}

	// Fallback: Check if it's a legacy session token (UUID) from DB
	// This ensures smooth transition or hybrid support
	var userID int64
	var expires time.Time
	err = s.db.QueryRow(`
		SELECT user_id, expires_at FROM sessions WHERE token = $1
	`, tokenStr).Scan(&userID, &expires)
	if err == nil {
		if time.Now().After(expires) {
			return 0, errors.New("session expired")
		}
		return userID, nil
	}

	return 0, errors.New("invalid token")
}

// handleEvaluations lists evaluations for a problem or returns one by ID.
func (s *server) handleEvaluations(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	if idStr := strings.TrimSpace(r.URL.Query().Get("id")); idStr != "" {
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil || id <= 0 {
			http.Error(w, "invalid id", http.StatusBadRequest)
			return
		}
		var rec evaluationRecord
		var ts time.Time
		var contestID int
		var rating int
		err = s.db.QueryRow(`
			SELECT e.id, COALESCE(e.run_id,''), COALESCE(e.provider,''), COALESCE(e.model,''), COALESCE(e.lang,''),
			       COALESCE(e.problem_id,0), COALESCE(p.contest_id,0), COALESCE(p.index_name,''), COALESCE(p.rating,0),
			       e.success, e.timestamp, COALESCE(e.prompt,''), COALESCE(e.response,''), COALESCE(e.stdout,''), COALESCE(e.stderr,'')
			FROM evaluations e
			LEFT JOIN problems p ON e.problem_id = p.id
			WHERE e.id = $1
		`, id).Scan(&rec.ID, &rec.RunID, &rec.Provider, &rec.Model, &rec.Lang, &rec.ProblemID, &contestID, &rec.Index, &rating, &rec.Success, &ts, &rec.Prompt, &rec.Response, &rec.Stdout, &rec.Stderr)
		if errors.Is(err, sql.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		rec.ContestID = contestID
		rec.Rating = rating
		rec.Timestamp = ts.Format(time.RFC3339)
		writeJSON(w, http.StatusOK, rec)
		return
	}

	contest := strings.TrimSpace(r.URL.Query().Get("contest"))
	index := strings.TrimSpace(r.URL.Query().Get("index"))
	if contest == "" || index == "" {
		http.Error(w, "contest and index are required", http.StatusBadRequest)
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
		SELECT e.id, COALESCE(e.run_id,''), COALESCE(e.provider,''), COALESCE(e.model,''), COALESCE(e.lang,''),
		       COALESCE(e.problem_id,0), COALESCE(p.contest_id,0), COALESCE(p.index_name,''), COALESCE(p.rating,0),
		       e.success, e.timestamp
		FROM evaluations e
		JOIN problems p ON e.problem_id = p.id
		WHERE p.contest_id = $1 AND UPPER(p.index_name) = UPPER($2)
		ORDER BY e.timestamp DESC
		LIMIT $3 OFFSET $4
	`, contest, index, limit, offset)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	var evals []evaluationRecord
	for rows.Next() {
		var rec evaluationRecord
		var ts time.Time
		if err = rows.Scan(&rec.ID, &rec.RunID, &rec.Provider, &rec.Model, &rec.Lang, &rec.ProblemID, &rec.ContestID, &rec.Index, &rec.Rating, &rec.Success, &ts); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		rec.Timestamp = ts.Format(time.RFC3339)
		evals = append(evals, rec)
	}
	writeJSON(w, http.StatusOK, evals)
}

func (s *server) handleLeaderboard(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	limit := 100
	rows, err := s.db.Query(`SELECT run_id, model, lang, rating, timestamp FROM leaderboard ORDER BY rating DESC LIMIT $1`, limit)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	var leaders []leaderboardEntry
	for rows.Next() {
		var l leaderboardEntry
		var ts time.Time
		if err = rows.Scan(&l.RunID, &l.Model, &l.Lang, &l.Rating, &ts); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		l.Timestamp = ts.Format(time.RFC3339)
		leaders = append(leaders, l)
	}

	runID := strings.TrimSpace(r.URL.Query().Get("run"))
	var evals []evaluationRecord
	if runID != "" {
                rows, err = s.db.Query(`
                        SELECT e.id, e.run_id, COALESCE(e.provider,''), COALESCE(e.model,''), COALESCE(e.lang,''),
                               COALESCE(e.problem_id,0), COALESCE(p.contest_id,0), COALESCE(p.index_name,''), COALESCE(p.rating,0),
                               e.success, e.timestamp, COALESCE(e.response,'')
                        FROM evaluations e
                        JOIN problems p ON e.problem_id = p.id
                        WHERE e.run_id = $1
                        ORDER BY e.timestamp DESC
                        LIMIT 200
                `, runID)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		for rows.Next() {
			var rec evaluationRecord
			var ts time.Time
                        if err = rows.Scan(&rec.ID, &rec.RunID, &rec.Provider, &rec.Model, &rec.Lang, &rec.ProblemID, &rec.ContestID, &rec.Index, &rec.Rating, &rec.Success, &ts, &rec.Response); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			rec.Timestamp = ts.Format(time.RFC3339)
			evals = append(evals, rec)
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"leaders": leaders,
		"evals":   evals,
		"run":     runID,
	})
}

// handleModel lists evaluations grouped by model name.
func (s *server) handleModel(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	model := strings.TrimSpace(r.URL.Query().Get("name"))
	if model == "" {
		http.Error(w, "name is required", http.StatusBadRequest)
		return
	}

	limit := 200
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
                SELECT e.id, COALESCE(e.run_id,''), COALESCE(e.provider,''), COALESCE(e.model,''), COALESCE(e.lang,''),
                       COALESCE(e.problem_id,0), COALESCE(p.contest_id,0), COALESCE(p.index_name,''), COALESCE(p.rating,0),
                       e.success, e.timestamp, COALESCE(e.response,'')
                FROM evaluations e
                JOIN problems p ON e.problem_id = p.id
                WHERE LOWER(e.model) = LOWER($1)
                ORDER BY e.timestamp DESC
                LIMIT $2 OFFSET $3
        `, model, limit, offset)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	var evals []evaluationRecord
	for rows.Next() {
		var rec evaluationRecord
		var ts time.Time
		if err = rows.Scan(&rec.ID, &rec.RunID, &rec.Provider, &rec.Model, &rec.Lang, &rec.ProblemID, &rec.ContestID, &rec.Index, &rec.Rating, &rec.Success, &ts, &rec.Response); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		rec.Timestamp = ts.Format(time.RFC3339)
		evals = append(evals, rec)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"model": model,
		"evals": evals,
	})
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

func ensureKafkaTopicsWithRetry(ctx context.Context, brokers []string, topics []string, attempts int, delay time.Duration) error {
	for i := 1; i <= attempts; i++ {
		if err := ensureKafkaTopics(ctx, brokers, topics); err == nil {
			return nil
		} else {
			log.Printf("kafka topics check failed (attempt %d/%d): %v", i, attempts, err)
			if i == attempts {
				return err
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	return nil
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
