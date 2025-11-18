package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/google/uuid"
	redis "github.com/redis/go-redis/v9"
	"github.com/segmentio/kafka-go"
)

var (
	db               *sql.DB
	writer           *kafka.Writer
	messageSvc       *messageServiceClient
	jwtSecret        []byte
	redisClient      *redis.Client
	allowedOrigins   []string
	allowedOriginSet map[string]struct{}
	allowAnyOrigin   bool
)

type session struct {
	Token     string
	Email     string
	ExpiresAt time.Time
}

type deviceTokenPayload struct {
	DeviceToken string `json:"device_token"`
	Platform    string `json:"platform,omitempty"`
}

func main() {
	kafkaURL := os.Getenv("KAFKA_URL")
	mysqlDSN := os.Getenv("MYSQL_DSN")
	messageSvcURL := os.Getenv("MESSAGE_SERVICE_URL")
	jwtSecretValue := strings.TrimSpace(os.Getenv("JWT_SECRET"))
	if jwtSecretValue != "" {
		jwtSecret = []byte(jwtSecretValue)
	} else {
		log.Println("JWT_SECRET is not set; JWT access tokens will be disabled")
	}
	if kafkaURL == "" {
		log.Fatal("KAFKA_URL must be set")
	}
	if mysqlDSN == "" {
		log.Fatal("MYSQL_DSN must be set")
	}
	if messageSvcURL == "" {
		log.Fatal("MESSAGE_SERVICE_URL must be set")
	}

	redisAddr := strings.TrimSpace(os.Getenv("REDIS_ADDR"))
	if redisAddr == "" {
		redisAddr = "redis:6379"
	}

	var err error
	db, err = sql.Open("mysql", mysqlDSN)
	if err != nil {
		log.Fatalf("mysql connection error: %v", err)
	}
	db.SetMaxIdleConns(5)
	db.SetMaxOpenConns(10)
	if err := db.Ping(); err != nil {
		log.Fatalf("mysql ping error: %v", err)
	}

	if err := ensureSchema(); err != nil {
		log.Fatalf("schema setup error: %v", err)
	}

	redisClient = redis.NewClient(&redis.Options{
		Addr: redisAddr,
	})
	if err := redisClient.Ping(context.Background()).Err(); err != nil {
		log.Fatalf("redis connection error: %v", err)
	}

	writer = &kafka.Writer{
		Addr:     kafka.TCP(kafkaURL),
		Topic:    "new-registration",
		Balancer: &kafka.LeastBytes{},
	}

	messageSvc = newMessageServiceClient(messageSvcURL)
	configureAllowedOrigins()

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleHealth)
	mux.HandleFunc("/api/request-otp", handleAPIRequestOTP)
	mux.HandleFunc("/api/verify-otp", handleAPIVerifyOTP)
	mux.HandleFunc("/api/conversations", handleAPIConversations)
	mux.HandleFunc("/api/conversations/", handleAPIConversationResource)
	mux.HandleFunc("/api/device", handleRegisterDevice)
	mux.HandleFunc("/api/device/associate", handleAssociateDevice)
	mux.HandleFunc("/api/session", handleAPISession)
	mux.HandleFunc("/api/users", handleAPIUsers)
	mux.HandleFunc("/api/users/all", handleAPIUsersAll)
	mux.HandleFunc("/api/profile", handleAPIProfile)
	mux.HandleFunc("/api/profile/photo", handleAPIProfilePhoto)
	mux.HandleFunc("/api/users/photo", handleAPIUserPhoto)

	fmt.Println("Registration API running on :8080")
	log.Fatal(http.ListenAndServe(":8080", corsMiddleware(mux)))
}

func ensureSchema() error {
	createOTPs := `
        CREATE TABLE IF NOT EXISTS otp_codes (
            email VARCHAR(255) NOT NULL PRIMARY KEY,
            code VARCHAR(12) NOT NULL,
            expires_at DATETIME NOT NULL,
            created_at DATETIME NOT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    `
	if _, err := db.Exec(createOTPs); err != nil {
		return err
	}

	createSessions := `
        CREATE TABLE IF NOT EXISTS sessions (
            token VARCHAR(64) NOT NULL PRIMARY KEY,
            email VARCHAR(255) NOT NULL,
            expires_at DATETIME NOT NULL,
            created_at DATETIME NOT NULL,
            INDEX idx_session_email (email)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    `
	if _, err := db.Exec(createSessions); err != nil {
		return err
	}

	createDeviceTokens := `
        CREATE TABLE IF NOT EXISTS device_tokens (
            device_token VARCHAR(255) NOT NULL PRIMARY KEY,
            platform VARCHAR(32) DEFAULT NULL,
            user_email VARCHAR(255) DEFAULT NULL,
            created_at DATETIME NOT NULL,
            updated_at DATETIME NOT NULL,
            INDEX idx_device_user_email (user_email)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    `
	if _, err := db.Exec(createDeviceTokens); err != nil {
		return err
	}

	createProfiles := `
        CREATE TABLE IF NOT EXISTS user_profiles (
            email VARCHAR(255) NOT NULL PRIMARY KEY,
            name VARCHAR(255) NOT NULL DEFAULT '',
            avatar LONGBLOB NULL,
            avatar_content_type VARCHAR(64) DEFAULT NULL,
            updated_at DATETIME NOT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    `
	if _, err := db.Exec(createProfiles); err != nil {
		return err
	}

	createConversationAvatars := `
        CREATE TABLE IF NOT EXISTS conversation_avatars (
            conversation_id VARCHAR(64) NOT NULL PRIMARY KEY,
            avatar LONGBLOB NULL,
            avatar_content_type VARCHAR(64) DEFAULT NULL,
            updated_at DATETIME NOT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    `
	if _, err := db.Exec(createConversationAvatars); err != nil {
		return err
	}

	return nil
}

func handleAPISession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	sess, err := getSessionFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	response := map[string]interface{}{
		"email": sess.Email,
		"token": sess.Token,
	}

	if len(jwtSecret) > 0 {
		if jwtToken, err := generateJWT(sess.Email, sess.ExpiresAt); err == nil {
			expiresIn := sess.ExpiresAt.Unix() - time.Now().Unix()
			if expiresIn < 0 {
				expiresIn = 0
			}
			response["access_token"] = jwtToken
			response["token_type"] = "Bearer"
			response["expires_in"] = expiresIn
		} else {
			log.Printf("jwt generation error: %v", err)
		}
	}

	writeJSON(w, http.StatusOK, response)
}

func handleRegisterDevice(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	defer r.Body.Close()
	var payload deviceTokenPayload
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json payload"})
		return
	}

	token := strings.TrimSpace(payload.DeviceToken)
	if token == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "device_token is required"})
		return
	}

	platform := strings.ToLower(strings.TrimSpace(payload.Platform))
	now := time.Now()

	_, err := db.Exec(
		`INSERT INTO device_tokens (device_token, platform, created_at, updated_at)
         VALUES (?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE platform = VALUES(platform), updated_at = VALUES(updated_at)`,
		token, platform, now, now,
	)
	if err != nil {
		log.Printf("register device token error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to register device"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func handleAssociateDevice(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	sess, err := getSessionFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	defer r.Body.Close()
	var payload deviceTokenPayload
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json payload"})
		return
	}

	token := strings.TrimSpace(payload.DeviceToken)
	if token == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "device_token is required"})
		return
	}

	now := time.Now()

	res, err := db.Exec(
		`UPDATE device_tokens
         SET user_email = ?, updated_at = ?
         WHERE device_token = ?`,
		sess.Email, now, token,
	)
	if err != nil {
		log.Printf("associate device token update error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to associate device"})
		return
	}

	rows, err := res.RowsAffected()
	if err != nil {
		log.Printf("associate device token rows affected error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to associate device"})
		return
	}

	if rows == 0 {
		_, err = db.Exec(
			`INSERT INTO device_tokens (device_token, user_email, created_at, updated_at)
             VALUES (?, ?, ?, ?)
             ON DUPLICATE KEY UPDATE user_email = VALUES(user_email), updated_at = VALUES(updated_at)`,
			token, sess.Email, now, now,
		)
		if err != nil {
			log.Printf("associate device token insert error: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to associate device"})
			return
		}
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ok",
		"message": "Chat API ready",
	})
}

func handleAPIRequestOTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	defer r.Body.Close()
	var payload struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json payload"})
		return
	}

	email := strings.TrimSpace(payload.Email)
	if email == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "email is required"})
		return
	}

	msg := kafka.Message{Value: []byte(email)}
	if err := writer.WriteMessages(r.Context(), msg); err != nil {
		log.Printf("Kafka write error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to queue otp"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func handleAPIVerifyOTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	defer r.Body.Close()
	var payload struct {
		Email string `json:"email"`
		OTP   string `json:"otp"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json payload"})
		return
	}

	email := strings.TrimSpace(payload.Email)
	code := strings.TrimSpace(payload.OTP)
	if email == "" || code == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "email and otp are required"})
		return
	}

	if err := verifyOTP(email, code); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	token, expiresAt, err := createSession(email)
	if err != nil {
		log.Printf("session creation error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to create session"})
		return
	}

	if len(jwtSecret) == 0 {
		log.Printf("jwt secret is not configured; cannot issue access_token")
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "jwt not configured"})
		return
	}

	jwtToken, err := generateJWT(email, expiresAt)
	if err != nil {
		log.Printf("jwt generation error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to issue access token"})
		return
	}

	expiresIn := expiresAt.Unix() - time.Now().Unix()
	if expiresIn < 0 {
		expiresIn = 0
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"email":         email,
		"session_token": token,
		"access_token":  jwtToken,
		"token_type":    "Bearer",
		"expires_in":    expiresIn,
	})
}

func handleAPIProfile(w http.ResponseWriter, r *http.Request) {
	sess, err := getSessionFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	switch r.Method {
	case http.MethodGet:
		var (
			name              string
			avatarContentType sql.NullString
		)

		err := db.QueryRow(
			"SELECT name, avatar_content_type FROM user_profiles WHERE email = ?",
			sess.Email,
		).Scan(&name, &avatarContentType)
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, http.StatusOK, map[string]interface{}{
				"email": sess.Email,
				"name":  "",
			})
			return
		}
		if err != nil {
			log.Printf("load profile error: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to load profile"})
			return
		}

		writeJSON(w, http.StatusOK, map[string]interface{}{
			"email": sess.Email,
			"name":  name,
		})

	case http.MethodPost:
		defer r.Body.Close()
		var payload struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json payload"})
			return
		}

		name := strings.TrimSpace(payload.Name)
		now := time.Now()

		_, err := db.Exec(`
            INSERT INTO user_profiles (email, name, updated_at)
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE name = VALUES(name), updated_at = VALUES(updated_at)
        `, sess.Email, name, now)
		if err != nil {
			log.Printf("upsert profile error: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to save profile"})
			return
		}

		writeJSON(w, http.StatusOK, map[string]interface{}{
			"email": sess.Email,
			"name":  name,
		})

	default:
		w.Header().Set("Allow", "GET, POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func handleAPIProfilePhoto(w http.ResponseWriter, r *http.Request) {
	sess, err := getSessionFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	switch r.Method {
	case http.MethodGet:
		var (
			data        []byte
			contentType sql.NullString
			name        sql.NullString
			lastUpdated time.Time
		)

		err := db.QueryRow(
			"SELECT avatar, avatar_content_type, name, updated_at FROM user_profiles WHERE email = ?",
			sess.Email,
		).Scan(&data, &contentType, &name, &lastUpdated)
		if errors.Is(err, sql.ErrNoRows) || len(data) == 0 {
			http.NotFound(w, r)
			return
		}
		if err != nil {
			log.Printf("load avatar error: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to load avatar"})
			return
		}

		ct := contentType.String
		if ct == "" {
			ct = "image/jpeg"
		}
		w.Header().Set("Content-Type", ct)
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write(data); err != nil {
			log.Printf("write avatar error: %v", err)
		}

	case http.MethodPost:
		defer r.Body.Close()

		body, err := io.ReadAll(io.LimitReader(r.Body, 5*1024*1024))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unable to read body"})
			return
		}
		if len(body) == 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "empty body"})
			return
		}

		contentType := strings.TrimSpace(r.Header.Get("Content-Type"))
		if contentType == "" {
			contentType = "image/jpeg"
		}

		now := time.Now()
		_, err = db.Exec(`
            INSERT INTO user_profiles (email, avatar, avatar_content_type, updated_at)
            VALUES (?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE avatar = VALUES(avatar), avatar_content_type = VALUES(avatar_content_type), updated_at = VALUES(updated_at)
        `, sess.Email, body, contentType, now)
		if err != nil {
			log.Printf("update avatar error: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to save avatar"})
			return
		}

		w.WriteHeader(http.StatusNoContent)

	default:
		w.Header().Set("Allow", "GET, POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func handleAPIUserPhoto(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	if _, err := getSessionFromRequest(r); err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	email := strings.TrimSpace(r.URL.Query().Get("email"))
	if email == "" {
		http.NotFound(w, r)
		return
	}

	var (
		data        []byte
		contentType sql.NullString
	)

	err := db.QueryRow(
		"SELECT avatar, avatar_content_type FROM user_profiles WHERE email = ?",
		email,
	).Scan(&data, &contentType)
	if errors.Is(err, sql.ErrNoRows) || len(data) == 0 {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Printf("load avatar for %s error: %v", email, err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to load avatar"})
		return
	}

	ct := strings.TrimSpace(contentType.String)
	if ct == "" {
		ct = "image/jpeg"
	}
	w.Header().Set("Content-Type", ct)
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write(data); err != nil {
		log.Printf("write avatar for %s error: %v", email, err)
	}
}

func handleAPIUsersAll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	if _, err := getSessionFromRequest(r); err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	q := strings.TrimSpace(r.URL.Query().Get("q"))
	like := "%" + q + "%"

	query := `
        SELECT s.email, COALESCE(p.name, ''), p.avatar
        FROM sessions s
        LEFT JOIN user_profiles p ON p.email = s.email
        GROUP BY s.email, p.name, p.avatar
    `
	args := []interface{}{}
	if q != "" {
		query = `
            SELECT s.email, COALESCE(p.name, ''), p.avatar
            FROM sessions s
            LEFT JOIN user_profiles p ON p.email = s.email
            WHERE s.email LIKE ? OR p.name LIKE ?
            GROUP BY s.email, p.name, p.avatar
        `
		args = append(args, like, like)
	}

	rows, err := db.Query(query, args...)
	if err != nil {
		log.Printf("list users error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to load users"})
		return
	}
	defer rows.Close()

	type userSummary struct {
		Email     string `json:"email"`
		Name      string `json:"name"`
		HasAvatar bool   `json:"has_avatar"`
	}

	users := make([]userSummary, 0, 64)
	for rows.Next() {
		var (
			email  string
			name   string
			avatar []byte
		)
		if err := rows.Scan(&email, &name, &avatar); err != nil {
			log.Printf("scan users error: %v", err)
			continue
		}
		users = append(users, userSummary{
			Email:     email,
			Name:      strings.TrimSpace(name),
			HasAvatar: len(avatar) > 0,
		})
	}
	if err := rows.Err(); err != nil {
		log.Printf("iterate users error: %v", err)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"users": users})
}

func handleAPIConversations(w http.ResponseWriter, r *http.Request) {
	sess, err := getSessionFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	switch r.Method {
	case http.MethodGet:
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		conversations, err := messageSvc.ListConversations(ctx, sess.Email)
		cancel()
		if err != nil {
			log.Printf("list conversations error: %v", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to load conversations"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"conversations": conversations})

	case http.MethodPost:
		var payload struct {
			Name         string   `json:"name"`
			Participants []string `json:"participants"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json payload"})
			return
		}
		defer r.Body.Close()

		participants := uniqueNonEmpty(payload.Participants)
		if !contains(participants, sess.Email) {
			participants = append(participants, sess.Email)
		}
		if len(participants) < 2 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "select at least one other participant"})
			return
		}

		normalizedTarget := normalizeParticipantEmails(participants)

		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		existing, err := messageSvc.ListConversations(ctx, sess.Email)
		cancel()
		if err != nil {
			log.Printf("list conversations for match error: %v", err)
		} else {
			for _, conv := range existing {
				if participantsMatch(conv.Participants, normalizedTarget) {
					writeJSON(w, http.StatusOK, map[string]interface{}{"conversation": conv, "reused": true})
					return
				}
			}
		}

		ctx, cancel = context.WithTimeout(r.Context(), 5*time.Second)
		conversation, err := messageSvc.CreateConversation(ctx, sess.Email, payload.Name, participants)
		cancel()
		if err != nil {
			log.Printf("create conversation error: %v", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to create conversation"})
			return
		}
		writeJSON(w, http.StatusCreated, map[string]interface{}{"conversation": conversation})

	default:
		w.Header().Set("Allow", "GET, POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func handleAPIConversationResource(w http.ResponseWriter, r *http.Request) {
	sess, err := getSessionFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/api/conversations/")
	if path == "" {
		http.NotFound(w, r)
		return
	}
	parts := strings.Split(path, "/")
	conversationID := parts[0]
	if conversationID == "" {
		http.NotFound(w, r)
		return
	}

	if len(parts) == 2 && parts[1] == "photo" {
		handleAPIConversationPhoto(w, r, conversationID)
		return
	}
	if len(parts) == 1 {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		conversation, err := messageSvc.GetConversation(ctx, conversationID)
		cancel()
		if err != nil {
			if errors.Is(err, errNotFound) {
				http.NotFound(w, r)
				return
			}
			log.Printf("get conversation error: %v", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to load conversation"})
			return
		}
		if !contains(conversation.Participants, sess.Email) {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"conversation": conversation})
		return
	}

	if len(parts) == 2 && parts[1] == "messages" {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		conversation, err := messageSvc.GetConversation(ctx, conversationID)
		cancel()
		if err != nil {
			if errors.Is(err, errNotFound) {
				http.NotFound(w, r)
				return
			}
			log.Printf("conversation lookup error: %v", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to load conversation"})
			return
		}
		if !contains(conversation.Participants, sess.Email) {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}

		switch r.Method {
		case http.MethodGet:
			limit := 0
			if limitParam := strings.TrimSpace(r.URL.Query().Get("limit")); limitParam != "" {
				if parsed, err := strconv.Atoi(limitParam); err == nil && parsed > 0 && parsed <= 1000 {
					limit = parsed
				}
			}

			ctx, cancel = context.WithTimeout(r.Context(), 5*time.Second)
			var messages []messageView
			if limit > 0 {
				messages, err = messageSvc.ListMessagesWithLimit(ctx, conversationID, limit)
			} else {
				messages, err = messageSvc.ListMessages(ctx, conversationID)
			}
			cancel()
			if err != nil {
				log.Printf("list messages error: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to load messages"})
				return
			}
			writeJSON(w, http.StatusOK, map[string]interface{}{
				"conversation_id": conversationID,
				"messages":        messages,
			})
			return

		case http.MethodPost:
			var payload struct {
				Text string `json:"text"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json payload"})
				return
			}
			defer r.Body.Close()

			text := strings.TrimSpace(payload.Text)
			if text == "" {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "text is required"})
				return
			}

			ctx, cancel = context.WithTimeout(r.Context(), 5*time.Second)
			msg, err := messageSvc.CreateMessage(ctx, conversationID, sess.Email, text)
			cancel()
			if err != nil {
				log.Printf("create message error: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to send message"})
				return
			}

			// Broadcast chat event to websocket server via Redis so all
			// connected clients receive this message in real time.
			if redisClient != nil {
				event := &chatRedisEvent{
					Type:             "message",
					Participants:     msg.Participants,
					ConversationID:   msg.ConversationID,
					ConversationName: msg.Name,
					From:             msg.Sender,
					Text:             msg.Text,
					SentAt:           msg.SentAt,
				}
				if err := publishChatEvent(context.Background(), event); err != nil {
					log.Printf("redis publish error: %v", err)
				}
			}

			writeJSON(w, http.StatusCreated, map[string]interface{}{"message": msg})
			return

		default:
			w.Header().Set("Allow", "GET, POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
	}

	w.WriteHeader(http.StatusNotFound)
}

func verifyOTP(email, code string) error {
	var storedCode string
	var expires time.Time
	err := db.QueryRow(
		"SELECT code, expires_at FROM otp_codes WHERE email = ?",
		email,
	).Scan(&storedCode, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return errors.New("OTP not found or expired")
	}
	if err != nil {
		log.Printf("query otp error: %v", err)
		return errors.New("Unable to verify OTP")
	}

	if time.Now().After(expires) {
		if _, delErr := db.Exec("DELETE FROM otp_codes WHERE email = ?", email); delErr != nil {
			log.Printf("failed to remove expired otp: %v", delErr)
		}
		return errors.New("OTP expired, request a new one")
	}
	if subtle.ConstantTimeCompare([]byte(code), []byte(storedCode)) != 1 {
		return errors.New("Invalid OTP code")
	}

	if _, err := db.Exec("DELETE FROM otp_codes WHERE email = ?", email); err != nil {
		log.Printf("failed to delete otp: %v", err)
	}
	return nil
}

func createSession(email string) (string, time.Time, error) {
	token := uuid.NewString()
	now := time.Now()
	// Extend session lifetime to 90 days for long-lived mobile and web sessions.
	expires := now.Add(90 * 24 * time.Hour)

	if _, err := db.Exec(
		"INSERT INTO sessions (token, email, expires_at, created_at) VALUES (?, ?, ?, ?)",
		token, email, expires, now,
	); err != nil {
		return "", time.Time{}, err
	}
	return token, expires, nil
}

func getSessionFromRequest(r *http.Request) (*session, error) {
	token := ""

	if cookie, err := r.Cookie("session_token"); err == nil {
		token = strings.TrimSpace(cookie.Value)
	}

	if token == "" {
		authHeader := strings.TrimSpace(r.Header.Get("Authorization"))
		if authHeader != "" {
			if strings.HasPrefix(strings.ToLower(authHeader), "bearer ") {
				token = strings.TrimSpace(authHeader[len("bearer "):])
			}
		}
	}

	if token == "" {
		return nil, errors.New("missing session token")
	}

	var sess session
	err := db.QueryRow(
		"SELECT token, email, expires_at FROM sessions WHERE token = ?",
		token,
	).Scan(&sess.Token, &sess.Email, &sess.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		// Fall back to validating as a JWT if configured.
		if len(jwtSecret) > 0 {
			email, exp, jwtErr := parseJWT(token)
			if jwtErr != nil {
				return nil, jwtErr
			}
			if time.Now().After(exp) {
				return nil, errors.New("session expired")
			}
			return &session{
				Token:     token,
				Email:     email,
				ExpiresAt: exp,
			}, nil
		}
		return nil, errors.New("session not found")
	}
	if err != nil {
		return nil, err
	}
	if time.Now().After(sess.ExpiresAt) {
		go func(token string) {
			if _, deleteErr := db.Exec("DELETE FROM sessions WHERE token = ?", token); deleteErr != nil {
				log.Printf("session cleanup error: %v", deleteErr)
			}
		}(token)
		return nil, errors.New("session expired")
	}
	return &sess, nil
}

type jwtClaims struct {
	Sub   string `json:"sub"`
	Exp   int64  `json:"exp"`
	Iat   int64  `json:"iat"`
	Scope string `json:"scope,omitempty"`
}

func generateJWT(email string, expiresAt time.Time) (string, error) {
	if len(jwtSecret) == 0 {
		return "", errors.New("jwt secret not configured")
	}

	header := map[string]string{
		"alg": "HS256",
		"typ": "JWT",
	}
	headerJSON, err := json.Marshal(header)
	if err != nil {
		return "", err
	}

	now := time.Now()
	claims := jwtClaims{
		Sub: email,
		Exp: expiresAt.Unix(),
		Iat: now.Unix(),
	}
	payloadJSON, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}

	enc := base64.RawURLEncoding
	unsigned := enc.EncodeToString(headerJSON) + "." + enc.EncodeToString(payloadJSON)

	mac := hmac.New(sha256.New, jwtSecret)
	if _, err := mac.Write([]byte(unsigned)); err != nil {
		return "", err
	}
	signature := mac.Sum(nil)

	token := unsigned + "." + enc.EncodeToString(signature)
	return token, nil
}

func parseJWT(token string) (string, time.Time, error) {
	if len(jwtSecret) == 0 {
		return "", time.Time{}, errors.New("jwt secret not configured")
	}

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", time.Time{}, errors.New("invalid jwt format")
	}

	enc := base64.RawURLEncoding

	headerBytes, err := enc.DecodeString(parts[0])
	if err != nil {
		return "", time.Time{}, errors.New("invalid jwt header encoding")
	}
	var header map[string]interface{}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return "", time.Time{}, errors.New("invalid jwt header")
	}
	alg, _ := header["alg"].(string)
	if alg != "HS256" {
		return "", time.Time{}, errors.New("unsupported jwt alg")
	}

	signature, err := enc.DecodeString(parts[2])
	if err != nil {
		return "", time.Time{}, errors.New("invalid jwt signature encoding")
	}

	unsigned := parts[0] + "." + parts[1]
	mac := hmac.New(sha256.New, jwtSecret)
	if _, err := mac.Write([]byte(unsigned)); err != nil {
		return "", time.Time{}, err
	}
	expectedSig := mac.Sum(nil)
	if !hmac.Equal(expectedSig, signature) {
		return "", time.Time{}, errors.New("invalid jwt signature")
	}

	payloadBytes, err := enc.DecodeString(parts[1])
	if err != nil {
		return "", time.Time{}, errors.New("invalid jwt payload encoding")
	}

	var claims jwtClaims
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return "", time.Time{}, errors.New("invalid jwt claims")
	}

	if claims.Sub == "" {
		return "", time.Time{}, errors.New("jwt missing subject")
	}
	if claims.Exp == 0 {
		return "", time.Time{}, errors.New("jwt missing exp")
	}

	expiresAt := time.Unix(claims.Exp, 0)
	return claims.Sub, expiresAt, nil
}

func configureAllowedOrigins() {
	raw := strings.TrimSpace(os.Getenv("CORS_ALLOWED_ORIGINS"))
	if raw == "" {
		allowedOrigins = []string{"http://localhost:5173", "http://127.0.0.1:5173"}
	} else {
		parts := strings.Split(raw, ",")
		for _, part := range parts {
			origin := strings.TrimSpace(part)
			if origin == "" {
				continue
			}
			if origin == "*" {
				allowAnyOrigin = true
				allowedOrigins = nil
				allowedOriginSet = nil
				return
			}
			allowedOrigins = append(allowedOrigins, origin)
		}
	}
	allowedOriginSet = make(map[string]struct{}, len(allowedOrigins))
	for _, origin := range allowedOrigins {
		allowedOriginSet[origin] = struct{}{}
	}
}

func isOriginAllowed(origin string) bool {
	if allowAnyOrigin {
		return true
	}
	if len(allowedOriginSet) == 0 {
		return false
	}
	_, ok := allowedOriginSet[origin]
	return ok
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && isOriginAllowed(origin) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
		} else if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func urlQuery(s string) string {
	return url.QueryEscape(s)
}

func writeJSON(w http.ResponseWriter, status int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if payload != nil {
		if err := json.NewEncoder(w).Encode(payload); err != nil {
			log.Printf("json encode error: %v", err)
		}
	}
}

type conversationView struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Participants   []string `json:"participants"`
	LastActivityAt string   `json:"last_activity_at"`
	IsGroup        bool     `json:"is_group"`
}

type messageView struct {
	ID     string `json:"id"`
	Sender string `json:"sender"`
	Text   string `json:"text"`
	SentAt string `json:"sent_at"`
}

type createdMessage struct {
	ID             string   `json:"id"`
	ConversationID string   `json:"conversation_id"`
	Sender         string   `json:"sender"`
	Text           string   `json:"text"`
	SentAt         string   `json:"sent_at"`
	Participants   []string `json:"participants,omitempty"`
	Name           string   `json:"conversation_name,omitempty"`
}

type chatRedisEvent struct {
	Type             string            `json:"type"`
	Participants     []string          `json:"participants"`
	ConversationID   string            `json:"conversation_id,omitempty"`
	ConversationName string            `json:"conversation_name,omitempty"`
	From             string            `json:"from,omitempty"`
	Text             string            `json:"text,omitempty"`
	SentAt           string            `json:"sent_at,omitempty"`
	Conversation     *conversationView `json:"conversation,omitempty"`
}

var errNotFound = errors.New("not found")

type messageServiceClient struct {
	baseURL string
	http    *http.Client
}

func newMessageServiceClient(baseURL string) *messageServiceClient {
	return &messageServiceClient{
		baseURL: strings.TrimRight(strings.TrimSpace(baseURL), "/"),
		http: &http.Client{
			Timeout: 5 * time.Second,
		},
	}
}

// loadConversationForUser reuses the existing APIConversation logic to
// ensure the current user is allowed to access the conversation.
func loadConversationForUser(w http.ResponseWriter, r *http.Request, conversationID, email string) (*conversationSummary, error) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	conv, err := messageSvc.GetConversation(ctx, conversationID)
	if err != nil {
		if errors.Is(err, errNotFound) {
			http.NotFound(w, r)
			return nil, err
		}
		log.Printf("conversation lookup error: %v", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to load conversation"})
		return nil, err
	}
	if !contains(conv.Participants, email) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return nil, errors.New("forbidden")
	}
	return conv, nil
}

func publishChatEvent(ctx context.Context, event *chatRedisEvent) error {
	if redisClient == nil || event == nil {
		return nil
	}
	data, err := json.Marshal(event)
	if err != nil {
		return err
	}
	return redisClient.Publish(ctx, "chat:messages", data).Err()
}

func handleAPIUsers(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	if _, err := getSessionFromRequest(r); err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	emailsParam := strings.TrimSpace(r.URL.Query().Get("emails"))
	if emailsParam == "" {
		writeJSON(w, http.StatusOK, map[string]interface{}{"users": []interface{}{}})
		return
	}
	rawEmails := strings.Split(emailsParam, ",")

	seen := make(map[string]struct{}, len(rawEmails))
	emails := make([]string, 0, len(rawEmails))
	for _, e := range rawEmails {
		email := strings.TrimSpace(e)
		if email == "" {
			continue
		}
		if _, ok := seen[email]; ok {
			continue
		}
		seen[email] = struct{}{}
		emails = append(emails, email)
	}

	type userSummary struct {
		Email     string `json:"email"`
		Name      string `json:"name"`
		HasAvatar bool   `json:"has_avatar"`
	}

	users := make([]userSummary, 0, len(emails))
	for _, email := range emails {
		var (
			name   sql.NullString
			avatar []byte
		)
		err := db.QueryRow(
			"SELECT name, avatar FROM user_profiles WHERE email = ?",
			email,
		).Scan(&name, &avatar)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			log.Printf("load user profile for %s error: %v", email, err)
			continue
		}
		users = append(users, userSummary{
			Email:     email,
			Name:      strings.TrimSpace(name.String),
			HasAvatar: len(avatar) > 0,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"users": users})
}

func (m *messageServiceClient) ListConversations(ctx context.Context, email string) ([]conversationView, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/conversations?user=%s", m.baseURL, url.QueryEscape(email)), nil)
	if err != nil {
		return nil, err
	}

	resp, err := m.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, decodeMessageServiceError(resp)
	}

	var payload struct {
		Conversations []conversationView `json:"conversations"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	return payload.Conversations, nil
}

func (m *messageServiceClient) CreateConversation(ctx context.Context, createdBy, name string, participants []string) (*conversationView, error) {
	body := map[string]interface{}{
		"name":         name,
		"participants": participants,
		"created_by":   createdBy,
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("%s/conversations", m.baseURL), bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := m.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		return nil, decodeMessageServiceError(resp)
	}

	var conv conversationView
	if err := json.NewDecoder(resp.Body).Decode(&conv); err != nil {
		return nil, err
	}
	return &conv, nil
}

func (m *messageServiceClient) GetConversation(ctx context.Context, id string) (*conversationSummary, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/conversations/%s", m.baseURL, id), nil)
	if err != nil {
		return nil, err
	}
	resp, err := m.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, decodeMessageServiceError(resp)
	}

	var conv conversationSummary
	if err := json.NewDecoder(resp.Body).Decode(&conv); err != nil {
		return nil, err
	}
	return &conv, nil
}

func (m *messageServiceClient) ListMessages(ctx context.Context, id string) ([]messageView, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/conversations/%s/messages", m.baseURL, id), nil)
	if err != nil {
		return nil, err
	}
	resp, err := m.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, decodeMessageServiceError(resp)
	}

	var payload struct {
		Messages []messageView `json:"messages"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	return payload.Messages, nil
}

func (m *messageServiceClient) ListMessagesWithLimit(ctx context.Context, id string, limit int) ([]messageView, error) {
	url := fmt.Sprintf("%s/conversations/%s/messages", m.baseURL, id)
	if limit > 0 {
		url = fmt.Sprintf("%s?limit=%d", url, limit)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := m.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, decodeMessageServiceError(resp)
	}

	var payload struct {
		Messages []messageView `json:"messages"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	return payload.Messages, nil
}

func (m *messageServiceClient) CreateMessage(ctx context.Context, conversationID, sender, text string) (*createdMessage, error) {
	body := map[string]string{
		"sender": sender,
		"text":   text,
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("%s/conversations/%s/messages", m.baseURL, conversationID), bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := m.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		return nil, decodeMessageServiceError(resp)
	}

	var msg createdMessage
	if err := json.NewDecoder(resp.Body).Decode(&msg); err != nil {
		return nil, err
	}
	return &msg, nil
}

type conversationSummary struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Participants   []string `json:"participants"`
	LastActivityAt string   `json:"last_activity_at"`
	CreatedBy      string   `json:"created_by"`
}

func decodeMessageServiceError(resp *http.Response) error {
	body, _ := io.ReadAll(resp.Body)
	msg := strings.TrimSpace(string(body))
	if resp.StatusCode == http.StatusNotFound {
		return errNotFound
	}
	if msg == "" {
		msg = http.StatusText(resp.StatusCode)
	}
	return fmt.Errorf("message service status %d: %s", resp.StatusCode, msg)
}

func uniqueNonEmpty(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, v := range values {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		if _, exists := seen[v]; exists {
			continue
		}
		seen[v] = struct{}{}
		result = append(result, v)
	}
	return result
}

func contains(list []string, target string) bool {
	for _, v := range list {
		if v == target {
			return true
		}
	}
	return false
}

func normalizeParticipantEmails(list []string) []string {
	normalized := make([]string, 0, len(list))
	seen := make(map[string]struct{}, len(list))
	for _, value := range list {
		email := strings.ToLower(strings.TrimSpace(value))
		if email == "" {
			continue
		}
		if _, exists := seen[email]; exists {
			continue
		}
		seen[email] = struct{}{}
		normalized = append(normalized, email)
	}
	sort.Strings(normalized)
	return normalized
}

func participantsMatch(participants []string, normalizedTarget []string) bool {
	if len(normalizedTarget) == 0 {
		return false
	}
	normalizedParticipants := normalizeParticipantEmails(participants)
	if len(normalizedParticipants) != len(normalizedTarget) {
		return false
	}
	for i := range normalizedParticipants {
		if normalizedParticipants[i] != normalizedTarget[i] {
			return false
		}
	}
	return true
}
