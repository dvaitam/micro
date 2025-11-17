package main

import (
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

func handleAPIConversationPhoto(w http.ResponseWriter, r *http.Request, conversationID string) {
	sess, err := getSessionFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	switch r.Method {
	case http.MethodGet:
		// Anyone in the conversation can view the photo.
		conv, err := loadConversationForUser(r, conversationID, sess.Email)
		if err != nil {
			return
		}
		_ = conv

		var (
			data        []byte
			contentType sql.NullString
		)

		err = db.QueryRow(
			"SELECT avatar, avatar_content_type FROM conversation_avatars WHERE conversation_id = ?",
			conversationID,
		).Scan(&data, &contentType)
		if errors.Is(err, sql.ErrNoRows) || len(data) == 0 {
			http.NotFound(w, r)
			return
		}
		if err != nil {
			log.Printf("load conversation avatar %s error: %v", conversationID, err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to load conversation avatar"})
			return
		}

		ct := strings.TrimSpace(contentType.String)
		if ct == "" {
			ct = "image/jpeg"
		}
		w.Header().Set("Content-Type", ct)
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write(data); err != nil {
			log.Printf("write conversation avatar %s error: %v", conversationID, err)
		}

	case http.MethodPost:
		// Only participants may update the conversation photo.
		conv, err := loadConversationForUser(r, conversationID, sess.Email)
		if err != nil {
			return
		}
		if !contains(conv.Participants, sess.Email) {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}

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
            INSERT INTO conversation_avatars (conversation_id, avatar, avatar_content_type, updated_at)
            VALUES (?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE avatar = VALUES(avatar), avatar_content_type = VALUES(avatar_content_type), updated_at = VALUES(updated_at)
        `, conversationID, body, contentType, now)
		if err != nil {
			log.Printf("update conversation avatar %s error: %v", conversationID, err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to save conversation avatar"})
			return
		}

		w.WriteHeader(http.StatusNoContent)

	default:
		w.Header().Set("Allow", "GET, POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

