package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/gocql/gocql"
	"github.com/segmentio/kafka-go"
)

type server struct {
	session     *gocql.Session
	kafkaWriter *kafka.Writer
}

type conversation struct {
	ID             gocql.UUID
	Name           string
	Participants   []string
	CreatedAt      time.Time
	CreatedBy      string
	LastActivityAt time.Time
	LastMessage    string
	LastMessageAt  time.Time
	LastSender     string
}

type message struct {
	ID        gocql.UUID
	Sender    string
	Body      string
	SentAt    time.Time
	CreatedAt time.Time
}

type messageEvent struct {
	ConversationID   string   `json:"conversation_id"`
	ConversationName string   `json:"conversation_name"`
	Sender           string   `json:"sender"`
	Text             string   `json:"text"`
	SentAt           string   `json:"sent_at"`
	Participants     []string `json:"participants"`
}

func main() {
	hostsEnv := strings.TrimSpace(os.Getenv("CASSANDRA_HOSTS"))
	if hostsEnv == "" {
		hostsEnv = "cassandra"
	}
	hosts := strings.Split(hostsEnv, ",")
	for i := range hosts {
		hosts[i] = strings.TrimSpace(hosts[i])
	}

	keyspace := strings.TrimSpace(os.Getenv("CASSANDRA_KEYSPACE"))
	if keyspace == "" {
		keyspace = "chat_data"
	}
	if err := ensureKeyspace(hosts, keyspace); err != nil {
		log.Fatalf("unable to ensure keyspace: %v", err)
	}

	cluster := gocql.NewCluster(hosts...)
	cluster.Timeout = 10 * time.Second
	cluster.ConnectTimeout = 10 * time.Second
	cluster.Keyspace = keyspace
	cluster.Consistency = gocql.Quorum

	session, err := cluster.CreateSession()
	if err != nil {
		log.Fatalf("failed to connect to cassandra keyspace %q: %v", keyspace, err)
	}
	defer session.Close()

	if err := ensureSchema(session); err != nil {
		log.Fatalf("unable to ensure schema: %v", err)
	}

	kafkaURL := strings.TrimSpace(os.Getenv("KAFKA_URL"))
	if kafkaURL == "" {
		kafkaURL = "kafka:9092"
	}
	messageTopic := strings.TrimSpace(os.Getenv("MESSAGE_EVENTS_TOPIC"))
	if messageTopic == "" {
		messageTopic = "chat-messages"
	}
	kafkaWriter := newMessageWriter(kafkaURL, messageTopic)
	defer kafkaWriter.Close()

	srv := &server{
		session:     session,
		kafkaWriter: kafkaWriter,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealth)
	mux.HandleFunc("/conversations", srv.handleConversations)
	mux.HandleFunc("/conversations/", srv.handleConversationResource)

	port := strings.TrimSpace(os.Getenv("SERVICE_PORT"))
	if port == "" {
		port = "8084"
	}

	log.Printf("message-service listening on :%s", port)
	if err := http.ListenAndServe(":"+port, logRequest(mux)); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func ensureKeyspace(hosts []string, keyspace string) error {
	cluster := gocql.NewCluster(hosts...)
	cluster.Timeout = 10 * time.Second
	cluster.ConnectTimeout = 10 * time.Second

	session, err := cluster.CreateSession()
	if err != nil {
		return fmt.Errorf("connect to cluster: %w", err)
	}
	defer session.Close()

	cql := fmt.Sprintf(`CREATE KEYSPACE IF NOT EXISTS %s WITH replication = {'class': 'SimpleStrategy', 'replication_factor': '1'}`, keyspace)
	return session.Query(cql).Exec()
}

func ensureSchema(session *gocql.Session) error {
	statements := []string{
		`CREATE TABLE IF NOT EXISTS conversations (
			conversation_id uuid,
			name text,
			participants set<text>,
			created_at timestamp,
			created_by text,
			last_activity_at timestamp,
			PRIMARY KEY (conversation_id)
		)`,
		`CREATE TABLE IF NOT EXISTS conversations_by_user (
			user_email text,
			conversation_id uuid,
			name text,
			participants set<text>,
			last_activity_at timestamp,
			PRIMARY KEY (user_email, conversation_id)
		)`,
		`CREATE TABLE IF NOT EXISTS messages (
			conversation_id uuid,
			sent_at timestamp,
			message_id uuid,
			sender text,
			body text,
			PRIMARY KEY ((conversation_id), sent_at, message_id)
		) WITH CLUSTERING ORDER BY (sent_at ASC, message_id ASC)`,
		`CREATE TABLE IF NOT EXISTS conversation_message_counts (
			conversation_id uuid,
			total_messages counter,
			PRIMARY KEY (conversation_id)
		)`,
		`CREATE TABLE IF NOT EXISTS conversation_reads (
			user_email text,
			conversation_id uuid,
			read_count bigint,
			last_read_at timestamp,
			PRIMARY KEY (user_email, conversation_id)
		)`,
	}

	for _, stmt := range statements {
		if err := session.Query(stmt).Exec(); err != nil {
			return fmt.Errorf("ensure schema: %w", err)
		}
	}

	alterStatements := []string{
		`ALTER TABLE conversations ADD last_message text`,
		`ALTER TABLE conversations ADD last_message_at timestamp`,
		`ALTER TABLE conversations ADD last_sender text`,
		`ALTER TABLE conversations_by_user ADD last_message text`,
		`ALTER TABLE conversations_by_user ADD last_message_at timestamp`,
		`ALTER TABLE conversations_by_user ADD last_sender text`,
	}
	for _, stmt := range alterStatements {
		if err := session.Query(stmt).Exec(); err != nil {
			if !isAlreadyExistsError(err) {
				return fmt.Errorf("ensure schema alter: %w", err)
			}
		}
	}
	return nil
}

func newMessageWriter(broker, topic string) *kafka.Writer {
	return kafka.NewWriter(kafka.WriterConfig{
		Brokers:  []string{broker},
		Topic:    topic,
		Balancer: &kafka.LeastBytes{},
	})
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if err := s.session.Query("SELECT now() FROM system.local").Exec(); err != nil {
		http.Error(w, "cassandra unavailable", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *server) handleConversations(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.listConversations(w, r)
	case http.MethodPost:
		s.createConversation(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *server) handleConversationResource(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/conversations/")
	if path == "" {
		http.NotFound(w, r)
		return
	}
	parts := strings.Split(path, "/")
	idStr := parts[0]
	conversationID, err := gocql.ParseUUID(idStr)
	if err != nil {
		http.Error(w, "invalid conversation id", http.StatusBadRequest)
		return
	}

	if len(parts) == 1 {
		switch r.Method {
		case http.MethodGet:
			s.getConversation(w, r, conversationID)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
		return
	}

	if len(parts) == 2 && parts[1] == "messages" {
		switch r.Method {
		case http.MethodGet:
			s.listMessages(w, r, conversationID)
		case http.MethodPost:
			s.createMessage(w, r, conversationID)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
		return
	}

	if len(parts) == 2 && parts[1] == "read" {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		s.handleConversationRead(w, r, conversationID)
		return
	}

	http.NotFound(w, r)
}

func (s *server) listConversations(w http.ResponseWriter, r *http.Request) {
	user := strings.TrimSpace(r.URL.Query().Get("user"))
	if user == "" {
		http.Error(w, "user query param required", http.StatusBadRequest)
		return
	}

	iter := s.session.Query(`SELECT conversation_id, name, participants, last_activity_at, last_message, last_message_at, last_sender FROM conversations_by_user WHERE user_email = ?`, user).Iter()
	var (
		id            gocql.UUID
		name          string
		participants  []string
		lastActivity  time.Time
		lastMessage   string
		lastMessageAt time.Time
		lastSender    string
	)

	conversations := make([]conversation, 0, 16)

	for iter.Scan(&id, &name, &participants, &lastActivity, &lastMessage, &lastMessageAt, &lastSender) {
		conversations = append(conversations, conversation{
			ID:             id,
			Name:           name,
			Participants:   copyAndSort(participants),
			LastActivityAt: lastActivity,
			LastMessage:    lastMessage,
			LastMessageAt:  lastMessageAt,
			LastSender:     lastSender,
		})
	}
	if err := iter.Close(); err != nil {
		http.Error(w, "unable to query conversations", http.StatusInternalServerError)
		return
	}

	sort.Slice(conversations, func(i, j int) bool {
		return conversations[i].LastActivityAt.After(conversations[j].LastActivityAt)
	})

	resp := make([]map[string]interface{}, 0, len(conversations))
	for _, c := range conversations {
		isGroup := isGroupConversation(c.Name, c.Participants)
		unread := s.calculateUnread(user, c.ID)
		resp = append(resp, map[string]interface{}{
			"id":               c.ID.String(),
			"name":             c.Name,
			"participants":     c.Participants,
			"last_activity_at": c.LastActivityAt.UTC().Format(time.RFC3339),
			"is_group":         isGroup,
			"last_message":     strings.TrimSpace(c.LastMessage),
			"last_message_at":  formatTime(c.LastMessageAt),
			"last_sender":      c.LastSender,
			"unread_count":     unread,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"conversations": resp})
}

func (s *server) createConversation(w http.ResponseWriter, r *http.Request) {
	var payload struct {
		Name         string   `json:"name"`
		Participants []string `json:"participants"`
		CreatedBy    string   `json:"created_by"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		http.Error(w, "invalid json payload", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	participants := uniqueNonEmpty(payload.Participants)
	if len(participants) == 0 {
		http.Error(w, "participants required", http.StatusBadRequest)
		return
	}
	if payload.CreatedBy == "" {
		http.Error(w, "created_by required", http.StatusBadRequest)
		return
	}
	if !contains(participants, payload.CreatedBy) {
		participants = append(participants, payload.CreatedBy)
	}

	now := time.Now().UTC()
	conversationID := gocql.TimeUUID()
	name := strings.TrimSpace(payload.Name)
	if name == "" {
		name = buildConversationName(participants, payload.CreatedBy)
	}

	setParticipants := make(map[string]struct{}, len(participants))
	for _, p := range participants {
		setParticipants[p] = struct{}{}
	}

	if err := s.session.Query(
		`INSERT INTO conversations (conversation_id, name, participants, created_at, created_by, last_activity_at) VALUES (?, ?, ?, ?, ?, ?)`,
		conversationID, name, setParticipants, now, payload.CreatedBy, now,
	).Exec(); err != nil {
		http.Error(w, "unable to create conversation", http.StatusInternalServerError)
		return
	}

	for _, participant := range participants {
		if err := s.session.Query(
			`INSERT INTO conversations_by_user (user_email, conversation_id, name, participants, last_activity_at) VALUES (?, ?, ?, ?, ?)`,
			participant, conversationID, name, setParticipants, now,
		).Exec(); err != nil {
			http.Error(w, "unable to map conversation to user", http.StatusInternalServerError)
			return
		}
	}

	resp := map[string]interface{}{
		"id":               conversationID.String(),
		"name":             name,
		"participants":     participants,
		"created_by":       payload.CreatedBy,
		"created_at":       now.Format(time.RFC3339),
		"last_activity_at": now.Format(time.RFC3339),
	}
	writeJSON(w, http.StatusCreated, resp)
}

func (s *server) getConversation(w http.ResponseWriter, r *http.Request, id gocql.UUID) {
	var (
		name         string
		participants []string
		createdAt    time.Time
		createdBy    string
		lastActivity time.Time
	)

	err := s.session.Query(
		`SELECT name, participants, created_at, created_by, last_activity_at FROM conversations WHERE conversation_id = ?`,
		id,
	).Consistency(gocql.Quorum).Scan(&name, &participants, &createdAt, &createdBy, &lastActivity)

	if errors.Is(err, gocql.ErrNotFound) {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("get conversation %s error: %v", id, err)
		http.Error(w, "unable to load conversation", http.StatusInternalServerError)
		return
	}

	sortedParticipants := copyAndSort(participants)
	resp := map[string]interface{}{
		"id":               id.String(),
		"name":             name,
		"participants":     sortedParticipants,
		"created_by":       createdBy,
		"created_at":       createdAt.UTC().Format(time.RFC3339),
		"last_activity_at": lastActivity.UTC().Format(time.RFC3339),
		"is_group":         isGroupConversation(name, sortedParticipants),
	}

	writeJSON(w, http.StatusOK, resp)
}

func (s *server) listMessages(w http.ResponseWriter, r *http.Request, id gocql.UUID) {
	limit := 200
	if limitParam := strings.TrimSpace(r.URL.Query().Get("limit")); limitParam != "" {
		if parsed, err := strconv.Atoi(limitParam); err == nil && parsed > 0 && parsed <= 1000 {
			limit = parsed
		}
	}
	reader := strings.TrimSpace(r.URL.Query().Get("reader"))

	iter := s.session.Query(
		`SELECT sent_at, message_id, sender, body FROM messages WHERE conversation_id = ? LIMIT ?`,
		id, limit,
	).Iter()

	var (
		sentAt    time.Time
		messageID gocql.UUID
		sender    string
		body      string
	)

	messages := make([]map[string]interface{}, 0, limit)
	for iter.Scan(&sentAt, &messageID, &sender, &body) {
		messages = append(messages, map[string]interface{}{
			"id":      messageID.String(),
			"sender":  sender,
			"text":    body,
			"sent_at": sentAt.UTC().Format(time.RFC3339),
		})
	}
	if err := iter.Close(); err != nil {
		http.Error(w, "unable to load messages", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"conversation_id": id.String(),
		"messages":        messages,
	})

	if reader != "" {
		if err := s.markConversationRead(reader, id, -1); err != nil {
			log.Printf("mark conversation read for %s/%s failed: %v", reader, id, err)
		}
	}
}

func (s *server) handleConversationRead(w http.ResponseWriter, r *http.Request, id gocql.UUID) {
	var payload struct {
		User string `json:"user"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		http.Error(w, "invalid json payload", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	payload.User = strings.TrimSpace(payload.User)
	if payload.User == "" {
		http.Error(w, "user is required", http.StatusBadRequest)
		return
	}
	if !s.userInConversation(payload.User, id) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if err := s.markConversationRead(payload.User, id, -1); err != nil {
		log.Printf("mark conversation read error: %v", err)
		http.Error(w, "unable to mark conversation read", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) createMessage(w http.ResponseWriter, r *http.Request, conversationID gocql.UUID) {
	var payload struct {
		Sender string `json:"sender"`
		Text   string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		http.Error(w, "invalid json payload", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	payload.Sender = strings.TrimSpace(payload.Sender)
	payload.Text = strings.TrimSpace(payload.Text)

	if payload.Sender == "" || payload.Text == "" {
		http.Error(w, "sender and text are required", http.StatusBadRequest)
		return
	}

	conv, err := s.loadConversation(conversationID)
	if err != nil {
		if errors.Is(err, gocql.ErrNotFound) {
			http.Error(w, "conversation not found", http.StatusNotFound)
		} else {
			log.Printf("create message load conversation %s error: %v", conversationID, err)
			http.Error(w, "unable to load conversation", http.StatusInternalServerError)
		}
		return
	}
	if !contains(conv.Participants, payload.Sender) {
		http.Error(w, "sender not in conversation", http.StatusForbidden)
		return
	}

	now := time.Now().UTC()
	messageID := gocql.TimeUUID()

	if err := s.session.Query(
		`INSERT INTO messages (conversation_id, sent_at, message_id, sender, body) VALUES (?, ?, ?, ?, ?)`,
		conversationID, now, messageID, payload.Sender, payload.Text,
	).Exec(); err != nil {
		log.Printf("store message insert error for conversation %s: %v", conversationID, err)
		http.Error(w, "unable to store message", http.StatusInternalServerError)
		return
	}

	// update denormalized tables with latest activity
	setParticipants := make(map[string]struct{}, len(conv.Participants))
	for _, participant := range conv.Participants {
		setParticipants[participant] = struct{}{}
		if err := s.session.Query(
			`UPDATE conversations_by_user SET last_activity_at = ?, last_message = ?, last_message_at = ?, last_sender = ? WHERE user_email = ? AND conversation_id = ?`,
			now, payload.Text, now, payload.Sender, participant, conversationID,
		).Exec(); err != nil {
			log.Printf("warn: update conversations_by_user for %s failed: %v", participant, err)
		}
	}
	if err := s.session.Query(
		`UPDATE conversations SET last_activity_at = ?, last_message = ?, last_message_at = ?, last_sender = ? WHERE conversation_id = ?`,
		now, payload.Text, now, payload.Sender, conversationID,
	).Exec(); err != nil {
		log.Printf("warn: update conversations last_activity failed: %v", err)
	}

	total, err := s.incrementConversationMessageCount(conversationID)
	if err != nil {
		log.Printf("warn: increment conversation counter failed: %v", err)
	}
	if err := s.markConversationRead(payload.Sender, conversationID, total); err != nil {
		log.Printf("warn: mark sender read failed: %v", err)
	}

	resp := map[string]interface{}{
		"id":                messageID.String(),
		"conversation_id":   conversationID.String(),
		"sender":            payload.Sender,
		"text":              payload.Text,
		"sent_at":           now.Format(time.RFC3339),
		"participants":      conv.Participants,
		"conversation_name": conv.Name,
	}

	event := &messageEvent{
		ConversationID:   conversationID.String(),
		ConversationName: conv.Name,
		Sender:           payload.Sender,
		Text:             payload.Text,
		SentAt:           now.Format(time.RFC3339),
		Participants:     conv.Participants,
	}
	s.publishMessageEvent(event)

	writeJSON(w, http.StatusCreated, resp)
}

func (s *server) loadConversation(id gocql.UUID) (*conversation, error) {
	var (
		name         string
		participants []string
		createdAt    time.Time
		createdBy    string
		lastActivity time.Time
	)

	err := s.session.Query(
		`SELECT name, participants, created_at, created_by, last_activity_at FROM conversations WHERE conversation_id = ?`,
		id,
	).Consistency(gocql.Quorum).Scan(&name, &participants, &createdAt, &createdBy, &lastActivity)
	if err != nil {
		log.Printf("load conversation %s error: %v", id, err)
		return nil, err
	}

	return &conversation{
		ID:             id,
		Name:           name,
		Participants:   copyAndSort(participants),
		CreatedAt:      createdAt,
		CreatedBy:      createdBy,
		LastActivityAt: lastActivity,
	}, nil
}

func (s *server) publishMessageEvent(event *messageEvent) {
	if s.kafkaWriter == nil || event == nil {
		return
	}
	data, err := json.Marshal(event)
	if err != nil {
		log.Printf("kafka event marshal error: %v", err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.kafkaWriter.WriteMessages(ctx, kafka.Message{Value: data}); err != nil {
		log.Printf("kafka write error: %v", err)
	}
}

func copyAndSort(values []string) []string {
	out := append([]string(nil), values...)
	sort.Strings(out)
	return out
}

func isAlreadyExistsError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "already exists") || strings.Contains(msg, "existing column") || strings.Contains(msg, "invalid column name")
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

func contains(list []string, value string) bool {
	for _, v := range list {
		if v == value {
			return true
		}
	}
	return false
}

func buildConversationName(participants []string, createdBy string) string {
	if len(participants) == 2 {
		return ""
	}
	if len(participants) <= 3 {
		return strings.Join(participants, ", ")
	}
	return fmt.Sprintf("Group of %d", len(participants))
}

func writeJSON(w http.ResponseWriter, status int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if payload != nil {
		if err := json.NewEncoder(w).Encode(payload); err != nil {
			log.Printf("failed to encode json: %v", err)
		}
	}
}

func (s *server) userInConversation(user string, conversationID gocql.UUID) bool {
	if user == "" {
		return false
	}
	var id gocql.UUID
	err := s.session.Query(
		`SELECT conversation_id FROM conversations_by_user WHERE user_email = ? AND conversation_id = ?`,
		user, conversationID,
	).Scan(&id)
	if errors.Is(err, gocql.ErrNotFound) {
		return false
	}
	if err != nil {
		log.Printf("userInConversation lookup error: %v", err)
		return false
	}
	return true
}

func (s *server) getConversationTotalMessages(conversationID gocql.UUID) (int64, error) {
	var total int64
	err := s.session.Query(
		`SELECT total_messages FROM conversation_message_counts WHERE conversation_id = ?`,
		conversationID,
	).Scan(&total)
	if errors.Is(err, gocql.ErrNotFound) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return total, nil
}

func (s *server) incrementConversationMessageCount(conversationID gocql.UUID) (int64, error) {
	if err := s.session.Query(
		`UPDATE conversation_message_counts SET total_messages = total_messages + 1 WHERE conversation_id = ?`,
		conversationID,
	).Exec(); err != nil {
		return 0, err
	}
	return s.getConversationTotalMessages(conversationID)
}

func (s *server) getConversationReadCount(user string, conversationID gocql.UUID) (int64, error) {
	var readCount int64
	err := s.session.Query(
		`SELECT read_count FROM conversation_reads WHERE user_email = ? AND conversation_id = ?`,
		user, conversationID,
	).Scan(&readCount)
	if errors.Is(err, gocql.ErrNotFound) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return readCount, nil
}

func (s *server) markConversationRead(user string, conversationID gocql.UUID, total int64) error {
	if user == "" {
		return errors.New("user required")
	}
	if total < 0 {
		var err error
		total, err = s.getConversationTotalMessages(conversationID)
		if err != nil {
			return err
		}
	}
	now := time.Now().UTC()
	return s.session.Query(
		`INSERT INTO conversation_reads (user_email, conversation_id, read_count, last_read_at) VALUES (?, ?, ?, ?)`,
		user, conversationID, total, now,
	).Exec()
}

func (s *server) calculateUnread(user string, conversationID gocql.UUID) int {
	total, err := s.getConversationTotalMessages(conversationID)
	if err != nil {
		log.Printf("get total messages for %s error: %v", conversationID, err)
		return 0
	}
	read, err := s.getConversationReadCount(user, conversationID)
	if err != nil {
		log.Printf("get read messages for %s/%s error: %v", user, conversationID, err)
		return 0
	}
	diff := total - read
	if diff < 0 {
		diff = 0
	}
	if diff > int64(math.MaxInt32) {
		return math.MaxInt32
	}
	return int(diff)
}

func formatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func isGroupConversation(name string, participants []string) bool {
	// Self-chat is never a group.
	if len(participants) <= 1 {
		return false
	}
	// More than two participants is always a group.
	if len(participants) > 2 {
		return true
	}
	// At this point, there are exactly two participants.
	trimmedName := strings.TrimSpace(name)
	if trimmedName == "" {
		return false
	}
	// If the name matches one of the participant emails, treat as a
	// regular one-to-one conversation.
	for _, p := range participants {
		if trimmedName == p {
			return false
		}
	}
	// Otherwise, a custom name for a 2-person conversation indicates a group.
	return true
}

func logRequest(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		duration := time.Since(start)
		log.Printf("%s %s %s", r.Method, r.URL.Path, duration)
	})
}
