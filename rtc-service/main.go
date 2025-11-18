package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

type server struct {
	mu         sync.Mutex
	sessions   map[string]*session
	sessionTTL time.Duration

	turnSecret string
	turnTTL    time.Duration
	turnURLs   []string
}

type session struct {
	ID             string                    `json:"id"`
	ConversationID string                    `json:"conversation_id,omitempty"`
	Initiator      string                    `json:"initiator"`
	CreatedAt      time.Time                 `json:"created_at"`
	ExpiresAt      time.Time                 `json:"expires_at"`
	Offer          *sdpPayload               `json:"offer,omitempty"`
	Answer         *sdpPayload               `json:"answer,omitempty"`
	Candidates     map[string][]iceCandidate `json:"candidates,omitempty"`
}

type sdpPayload struct {
	Type  string    `json:"type"`
	SDP   string    `json:"sdp"`
	From  string    `json:"from"`
	SetAt time.Time `json:"set_at"`
}

type iceCandidate struct {
	Candidate     string    `json:"candidate"`
	SDPMid        string    `json:"sdp_mid,omitempty"`
	SDPMLineIndex *uint16   `json:"sdp_m_line_index,omitempty"`
	From          string    `json:"from"`
	AddedAt       time.Time `json:"added_at"`
}

type createSessionRequest struct {
	ConversationID string `json:"conversation_id"`
	Initiator      string `json:"initiator"`
}

type sdpRequest struct {
	Type string `json:"type"`
	SDP  string `json:"sdp"`
	From string `json:"from"`
}

type candidateRequest struct {
	Candidate     string  `json:"candidate"`
	SDPMid        string  `json:"sdp_mid,omitempty"`
	SDPMLineIndex *uint16 `json:"sdp_m_line_index,omitempty"`
	From          string  `json:"from"`
}

type turnCredentials struct {
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
	TTLSeconds int      `json:"ttl_seconds"`
	URLs       []string `json:"urls"`
}

var (
	errSessionNotFound = errors.New("session not found")
	errSessionExpired  = errors.New("session expired")
)

func main() {
	cfg := loadConfig()

	srv := &server{
		sessions:   make(map[string]*session),
		sessionTTL: cfg.sessionTTL,
		turnSecret: cfg.turnSecret,
		turnTTL:    cfg.turnTTL,
		turnURLs:   cfg.turnURLs,
	}

	go srv.cleanupExpiredSessions()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealth)
	mux.HandleFunc("/sessions", srv.handleSessions)
	mux.HandleFunc("/sessions/", srv.handleSessionResource)

	log.Printf("rtc-service listening on :%s", cfg.port)
	handler := logRequest(corsMiddleware(cfg.cors, mux))
	if err := http.ListenAndServe(":"+cfg.port, handler); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

type config struct {
	port       string
	sessionTTL time.Duration
	turnSecret string
	turnTTL    time.Duration
	turnURLs   []string
	cors       corsConfig
}

func loadConfig() config {
	port := strings.TrimSpace(os.Getenv("SERVICE_PORT"))
	if port == "" {
		port = "8085"
	}

	sessionTTL := durationFromEnv("SESSION_TTL_SECONDS", 15*time.Minute)
	turnSecret := strings.TrimSpace(os.Getenv("TURN_SHARED_SECRET"))
	turnTTL := durationFromEnv("TURN_CREDENTIAL_TTL", 10*time.Minute)
	turnURLs := parseCSVEnv("TURN_SERVER_URLS")
	if len(turnURLs) == 0 {
		turnURLs = []string{"turn:turn-server:3478?transport=udp", "turn:turn-server:3478?transport=tcp"}
	}

	corsAllowed := strings.TrimSpace(os.Getenv("CORS_ALLOWED_ORIGINS"))

	return config{
		port:       port,
		sessionTTL: sessionTTL,
		turnSecret: turnSecret,
		turnTTL:    turnTTL,
		turnURLs:   turnURLs,
		cors:       newCORSConfig(corsAllowed),
	}
}

func durationFromEnv(key string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	secs, err := strconv.Atoi(raw)
	if err != nil || secs <= 0 {
		log.Printf("invalid %s=%q, using fallback %s", key, raw, fallback)
		return fallback
	}
	return time.Duration(secs) * time.Second
}

func parseCSVEnv(key string) []string {
	return parseCSVList(strings.TrimSpace(os.Getenv(key)))
}

func parseCSVList(raw string) []string {
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	cleaned := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			cleaned = append(cleaned, p)
		}
	}
	return cleaned
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *server) handleSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}

	var req createSessionRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	req.ConversationID = strings.TrimSpace(req.ConversationID)
	req.Initiator = strings.TrimSpace(req.Initiator)
	if req.Initiator == "" {
		writeError(w, http.StatusBadRequest, "initiator is required")
		return
	}

	sess := s.createSession(req.ConversationID, req.Initiator)
	resp := map[string]any{
		"session": sess,
	}
	resp["turn"] = s.buildTurnCredentials(req.Initiator)

	writeJSON(w, http.StatusCreated, resp)
}

func (s *server) handleSessionResource(w http.ResponseWriter, r *http.Request) {
	tail := strings.TrimPrefix(r.URL.Path, "/sessions/")
	if tail == "" {
		http.NotFound(w, r)
		return
	}
	parts := strings.Split(tail, "/")
	id := parts[0]
	if id == "" {
		http.NotFound(w, r)
		return
	}

	var subresource string
	if len(parts) > 1 {
		subresource = parts[1]
	}
	if len(parts) > 2 {
		http.NotFound(w, r)
		return
	}

	switch subresource {
	case "":
		s.handleSession(w, r, id)
	case "offer":
		s.handleOffer(w, r, id)
	case "answer":
		s.handleAnswer(w, r, id)
	case "candidates":
		s.handleCandidate(w, r, id)
	default:
		http.NotFound(w, r)
	}
}

func (s *server) handleSession(w http.ResponseWriter, r *http.Request, id string) {
	switch r.Method {
	case http.MethodGet:
		participant := strings.TrimSpace(r.URL.Query().Get("participant"))
		sess, err := s.fetchSession(id)
		if err != nil {
			handleSessionError(w, err)
			return
		}
		resp := map[string]any{"session": sess}
		if participant != "" {
			resp["turn"] = s.buildTurnCredentials(participant)
		}
		writeJSON(w, http.StatusOK, resp)
	case http.MethodDelete:
		s.deleteSession(id)
		w.WriteHeader(http.StatusNoContent)
	default:
		methodNotAllowed(w, http.MethodGet, http.MethodDelete)
	}
}

func (s *server) handleOffer(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPut {
		methodNotAllowed(w, http.MethodPut)
		return
	}

	sess, err := s.applySDP(id, r.Body, "offer", func(sess *session, payload *sdpPayload) {
		sess.Offer = payload
	})
	if err != nil {
		handleSessionError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"session": sess})
}

func (s *server) handleAnswer(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPut {
		methodNotAllowed(w, http.MethodPut)
		return
	}

	sess, err := s.applySDP(id, r.Body, "answer", func(sess *session, payload *sdpPayload) {
		sess.Answer = payload
	})
	if err != nil {
		handleSessionError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"session": sess})
}

func (s *server) handleCandidate(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}

	var req candidateRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Candidate = strings.TrimSpace(req.Candidate)
	req.From = strings.TrimSpace(req.From)
	if req.Candidate == "" {
		writeError(w, http.StatusBadRequest, "candidate is required")
		return
	}
	if req.From == "" {
		writeError(w, http.StatusBadRequest, "from is required")
		return
	}

	sess, err := s.addCandidate(id, &req)
	if err != nil {
		handleSessionError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"session": sess})
}

func (s *server) createSession(conversationID, initiator string) *session {
	now := time.Now().UTC()
	sess := &session{
		ID:             uuid.NewString(),
		ConversationID: conversationID,
		Initiator:      initiator,
		CreatedAt:      now,
		ExpiresAt:      now.Add(s.sessionTTL),
	}

	s.mu.Lock()
	s.sessions[sess.ID] = sess
	s.mu.Unlock()

	return cloneSession(sess)
}

func (s *server) fetchSession(id string) (*session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	sess, ok := s.sessions[id]
	if !ok {
		return nil, errSessionNotFound
	}
	if time.Now().After(sess.ExpiresAt) {
		delete(s.sessions, id)
		return nil, errSessionExpired
	}

	return cloneSession(sess), nil
}

func (s *server) deleteSession(id string) {
	s.mu.Lock()
	delete(s.sessions, id)
	s.mu.Unlock()
}

func (s *server) applySDP(id string, body io.Reader, defaultType string, assign func(*session, *sdpPayload)) (*session, error) {
	var req sdpRequest
	if err := decodeJSON(body, &req); err != nil {
		return nil, err
	}
	req.SDP = strings.TrimSpace(req.SDP)
	req.From = strings.TrimSpace(req.From)
	if req.SDP == "" {
		return nil, errors.New("sdp is required")
	}
	if req.From == "" {
		return nil, errors.New("from is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	sess, ok := s.sessions[id]
	if !ok {
		return nil, errSessionNotFound
	}
	if time.Now().After(sess.ExpiresAt) {
		delete(s.sessions, id)
		return nil, errSessionExpired
	}

	payload := &sdpPayload{
		Type:  defaultValue(strings.TrimSpace(req.Type), defaultType),
		SDP:   req.SDP,
		From:  req.From,
		SetAt: time.Now().UTC(),
	}
	assign(sess, payload)
	sess.ExpiresAt = time.Now().Add(s.sessionTTL)

	return cloneSession(sess), nil
}

func (s *server) addCandidate(id string, req *candidateRequest) (*session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	sess, ok := s.sessions[id]
	if !ok {
		return nil, errSessionNotFound
	}
	if time.Now().After(sess.ExpiresAt) {
		delete(s.sessions, id)
		return nil, errSessionExpired
	}

	if sess.Candidates == nil {
		sess.Candidates = make(map[string][]iceCandidate)
	}
	candidate := iceCandidate{
		Candidate:     req.Candidate,
		SDPMid:        req.SDPMid,
		SDPMLineIndex: req.SDPMLineIndex,
		From:          req.From,
		AddedAt:       time.Now().UTC(),
	}
	sess.Candidates[req.From] = append(sess.Candidates[req.From], candidate)
	sess.ExpiresAt = time.Now().Add(s.sessionTTL)

	return cloneSession(sess), nil
}

func (s *server) cleanupExpiredSessions() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		now := time.Now()
		s.mu.Lock()
		for id, sess := range s.sessions {
			if now.After(sess.ExpiresAt) {
				delete(s.sessions, id)
			}
		}
		s.mu.Unlock()
	}
}

func (s *server) buildTurnCredentials(identity string) turnCredentials {
	identity = strings.TrimSpace(identity)
	creds := turnCredentials{
		TTLSeconds: int(s.turnTTL.Seconds()),
		URLs:       append([]string(nil), s.turnURLs...),
	}
	if identity == "" || s.turnSecret == "" {
		return creds
	}

	expiry := time.Now().Add(s.turnTTL).Unix()
	username := strconv.FormatInt(expiry, 10) + ":" + identity
	mac := hmac.New(sha1.New, []byte(s.turnSecret))
	mac.Write([]byte(username))

	creds.Username = username
	creds.Credential = base64.StdEncoding.EncodeToString(mac.Sum(nil))
	return creds
}

func defaultValue(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func handleSessionError(w http.ResponseWriter, err error) {
	switch err {
	case errSessionNotFound:
		writeError(w, http.StatusNotFound, err.Error())
	case errSessionExpired:
		writeError(w, http.StatusGone, err.Error())
	default:
		writeError(w, http.StatusBadRequest, err.Error())
	}
}

func methodNotAllowed(w http.ResponseWriter, allowed ...string) {
	w.Header().Set("Allow", strings.Join(allowed, ", "))
	w.WriteHeader(http.StatusMethodNotAllowed)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("failed to encode response: %v", err)
	}
}

func decodeJSON(body io.Reader, v any) error {
	dec := json.NewDecoder(body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	return nil
}

func cloneSession(src *session) *session {
	if src == nil {
		return nil
	}
	clone := *src
	if src.Offer != nil {
		offer := *src.Offer
		clone.Offer = &offer
	}
	if src.Answer != nil {
		answer := *src.Answer
		clone.Answer = &answer
	}
	if len(src.Candidates) > 0 {
		clone.Candidates = make(map[string][]iceCandidate, len(src.Candidates))
		for k, v := range src.Candidates {
			candidates := make([]iceCandidate, len(v))
			copy(candidates, v)
			clone.Candidates[k] = candidates
		}
	} else {
		clone.Candidates = nil
	}
	return &clone
}

type loggingResponseWriter struct {
	http.ResponseWriter
	status int
}

func (lrw *loggingResponseWriter) WriteHeader(statusCode int) {
	lrw.status = statusCode
	lrw.ResponseWriter.WriteHeader(statusCode)
}

func logRequest(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lrw := &loggingResponseWriter{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(lrw, r)
		duration := time.Since(start).Round(time.Millisecond)
		log.Printf("%s %s -> %d (%s)", r.Method, r.URL.Path, lrw.status, duration)
	})
}

type corsConfig struct {
	allowAny  bool
	originSet map[string]struct{}
}

func newCORSConfig(raw string) corsConfig {
	cfg := corsConfig{}
	origins := parseCSVList(raw)
	if len(origins) == 0 {
		origins = []string{
			"http://localhost:5173",
			"http://127.0.0.1:5173",
		}
	}
	for _, origin := range origins {
		if origin == "*" {
			cfg.allowAny = true
			cfg.originSet = nil
			return cfg
		}
		if cfg.originSet == nil {
			cfg.originSet = make(map[string]struct{})
		}
		cfg.originSet[origin] = struct{}{}
	}
	return cfg
}

func (c corsConfig) isAllowed(origin string) bool {
	if origin == "" {
		return false
	}
	if c.allowAny {
		return true
	}
	if len(c.originSet) == 0 {
		return false
	}
	_, ok := c.originSet[origin]
	return ok
}

func corsMiddleware(cfg corsConfig, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowed := origin == "" || cfg.isAllowed(origin)
		requestedHeaders := strings.TrimSpace(r.Header.Get("Access-Control-Request-Headers"))
		if origin != "" && allowed {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			allowHeaders := []string{"Content-Type", "Authorization"}
			if requestedHeaders != "" {
				allowHeaders = append(allowHeaders, requestedHeaders)
			} else {
				allowHeaders = append(allowHeaders, "X-Requested-With")
			}
			w.Header().Set("Access-Control-Allow-Headers", strings.Join(uniqueStrings(allowHeaders), ", "))
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		}

		if r.Method == http.MethodOptions {
			if allowed {
				w.WriteHeader(http.StatusNoContent)
			} else {
				http.Error(w, "origin not allowed", http.StatusForbidden)
			}
			return
		}

		if origin != "" && !allowed {
			http.Error(w, "origin not allowed", http.StatusForbidden)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		key := strings.ToLower(value)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, value)
	}
	return result
}
