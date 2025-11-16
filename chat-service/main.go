package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/gorilla/websocket"
	"github.com/redis/go-redis/v9"
)

type server struct {
	db       *sql.DB
	redis    *redis.Client
	messages *messageServiceClient
	upgrader websocket.Upgrader

	mu      sync.RWMutex
	clients map[string]*client
}

type client struct {
	email     string
	conn      *websocket.Conn
	send      chan []byte
	closeOnce sync.Once
}

type incomingMessage struct {
	Type           string `json:"type"`
	ConversationID string `json:"conversation_id,omitempty"`
	Text           string `json:"text,omitempty"`
}

type chatMessage struct {
	Type             string               `json:"type"`
	ConversationID   string               `json:"conversation_id,omitempty"`
	ConversationName string               `json:"conversation_name,omitempty"`
	From             string               `json:"from,omitempty"`
	Text             string               `json:"text,omitempty"`
	SentAt           string               `json:"sent_at,omitempty"`
	Participants     []string             `json:"participants,omitempty"`
	Conversation     *conversationSummary `json:"conversation,omitempty"`
}

func main() {
	mysqlDSN := os.Getenv("MYSQL_DSN")
	redisAddr := os.Getenv("REDIS_ADDR")
	messageSvcURL := os.Getenv("MESSAGE_SERVICE_URL")
	if mysqlDSN == "" {
		log.Fatal("MYSQL_DSN must be set")
	}
	if redisAddr == "" {
		log.Fatal("REDIS_ADDR must be set")
	}
	if messageSvcURL == "" {
		log.Fatal("MESSAGE_SERVICE_URL must be set")
	}

	db, err := sql.Open("mysql", mysqlDSN)
	if err != nil {
		log.Fatalf("mysql connection error: %v", err)
	}
	if err := db.Ping(); err != nil {
		log.Fatalf("mysql ping error: %v", err)
	}

	rdb := redis.NewClient(&redis.Options{
		Addr: redisAddr,
	})
	ctx := context.Background()
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("redis connection error: %v", err)
	}

	messageClient, err := newMessageServiceClient(messageSvcURL)
	if err != nil {
		log.Fatalf("message service client error: %v", err)
	}

	srv := &server{
		db:       db,
		redis:    rdb,
		messages: messageClient,
		upgrader: websocket.Upgrader{
			ReadBufferSize:  1024,
			WriteBufferSize: 1024,
			CheckOrigin: func(r *http.Request) bool {
				return true
			},
		},
		clients: make(map[string]*client),
	}

	go srv.consumeRedis(ctx)

	http.HandleFunc("/ws", srv.handleWebsocket)

	log.Println("Chat service listening on :8083")
	if err := http.ListenAndServe(":8083", nil); err != nil {
		log.Fatal(err)
	}
}

func (s *server) handleWebsocket(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimSpace(r.URL.Query().Get("token"))
	if token == "" {
		http.Error(w, "Missing token", http.StatusUnauthorized)
		return
	}

	email, err := s.validateSession(token)
	if err != nil {
		http.Error(w, "Invalid session", http.StatusUnauthorized)
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("websocket upgrade error: %v", err)
		return
	}

	cl := &client{
		email: email,
		conn:  conn,
		send:  make(chan []byte, 32),
	}

	s.addClient(email, cl)

	go cl.writeLoop()
	s.readLoop(cl)

	if removed := s.removeClient(email, cl); removed {
		s.broadcastPresence()
	}
}

func (s *server) validateSession(token string) (string, error) {
	var email string
	var expires time.Time
	err := s.db.QueryRow(
		"SELECT email, expires_at FROM sessions WHERE token = ?",
		token,
	).Scan(&email, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return "", errors.New("session not found")
	}
	if err != nil {
		return "", err
	}
	if time.Now().After(expires) {
		return "", errors.New("session expired")
	}
	return email, nil
}

func (s *server) addClient(email string, cl *client) {
	var previous *client

	s.mu.Lock()
	if existing, ok := s.clients[email]; ok {
		previous = existing
	}
	s.clients[email] = cl
	s.mu.Unlock()

	if previous != nil {
		previous.close()
	}
	s.broadcastPresence()
}

func (s *server) removeClient(email string, cl *client) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	current, ok := s.clients[email]
	if !ok || current != cl {
		return false
	}
	delete(s.clients, email)
	return true
}

func (s *server) broadcastPresence() {
	s.mu.RLock()
	users := make([]string, 0, len(s.clients))
	for email := range s.clients {
		users = append(users, email)
	}
	s.mu.RUnlock()

	sort.Strings(users)

	payload := map[string]interface{}{
		"type":  "presence",
		"users": users,
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}

	s.mu.RLock()
	clients := make([]*client, 0, len(s.clients))
	for _, cl := range s.clients {
		clients = append(clients, cl)
	}
	s.mu.RUnlock()

	for _, cl := range clients {
		cl.sendMessage(data)
	}
}

func (s *server) readLoop(cl *client) {
	defer cl.close()

	cl.conn.SetReadLimit(4096)
	cl.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	cl.conn.SetPongHandler(func(string) error {
		cl.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	backgroundCtx := context.Background()

	for {
		_, message, err := cl.conn.ReadMessage()
		if err != nil {
			if !websocket.IsCloseError(err, websocket.CloseNormalClosure) {
				log.Printf("read error for %s: %v", cl.email, err)
			}
			break
		}

		var incoming incomingMessage
		if err := json.Unmarshal(message, &incoming); err != nil {
			sendError(cl, "Invalid payload")
			continue
		}

		switch incoming.Type {
		case "message":
			conversationID := strings.TrimSpace(incoming.ConversationID)
			text := strings.TrimSpace(incoming.Text)
			if conversationID == "" || text == "" {
				sendError(cl, "Conversation and message text are required")
				continue
			}

			ctx, cancel := context.WithTimeout(backgroundCtx, 5*time.Second)
			stored, err := s.messages.CreateMessage(ctx, conversationID, cl.email, text)
			cancel()
			if err != nil {
				log.Printf("store message error: %v", err)
				sendError(cl, "Unable to store message")
				continue
			}

			event := redisEvent{
				Type:             "message",
				Participants:     stored.Participants,
				ConversationID:   stored.ConversationID,
				ConversationName: stored.ConversationName,
				From:             stored.Sender,
				Text:             stored.Text,
				SentAt:           stored.SentAt,
			}
			if err := s.publishEvent(backgroundCtx, &event); err != nil {
				log.Printf("redis publish error: %v", err)
				sendError(cl, "Unable to deliver message")
			}

		case "conversation":
			conversationID := strings.TrimSpace(incoming.ConversationID)
			if conversationID == "" {
				sendError(cl, "Conversation id is required")
				continue
			}

			ctx, cancel := context.WithTimeout(backgroundCtx, 5*time.Second)
			conv, err := s.messages.GetConversation(ctx, conversationID)
			cancel()
			if err != nil {
				log.Printf("load conversation error: %v", err)
				sendError(cl, "Unable to load conversation")
				continue
			}
			if !contains(conv.Participants, cl.email) {
				sendError(cl, "You are not part of this conversation")
				continue
			}

			event := redisEvent{
				Type:           "conversation",
				Participants:   conv.Participants,
				ConversationID: conv.ID,
				Conversation:   conv,
			}
			if err := s.publishEvent(backgroundCtx, &event); err != nil {
				log.Printf("redis publish error: %v", err)
				sendError(cl, "Unable to share conversation")
			}

		default:
			sendError(cl, "Unsupported message type")
		}
	}
}

func (s *server) consumeRedis(ctx context.Context) {
	pubsub := s.redis.Subscribe(ctx, "chat:messages")
	defer pubsub.Close()

	for msg := range pubsub.Channel() {
		var event redisEvent
		if err := json.Unmarshal([]byte(msg.Payload), &event); err != nil {
			log.Printf("invalid chat event: %v", err)
			continue
		}

		clientPayload := chatMessage{
			Type:             event.Type,
			ConversationID:   event.ConversationID,
			ConversationName: event.ConversationName,
			From:             event.From,
			Text:             event.Text,
			SentAt:           event.SentAt,
			Conversation:     event.Conversation,
		}

		data, err := json.Marshal(clientPayload)
		if err != nil {
			log.Printf("marshal error: %v", err)
			continue
		}

		for _, email := range event.Participants {
			s.sendTo(strings.TrimSpace(email), data)
		}
	}
}

func (s *server) publishEvent(ctx context.Context, event *redisEvent) error {
	data, err := json.Marshal(event)
	if err != nil {
		return err
	}
	return s.redis.Publish(ctx, "chat:messages", data).Err()
}

func (s *server) sendTo(email string, data []byte) {
	if email == "" {
		return
	}
	s.mu.RLock()
	cl, ok := s.clients[email]
	s.mu.RUnlock()
	if !ok {
		return
	}
	cl.sendMessage(data)
}

type redisEvent struct {
	Type             string               `json:"type"`
	Participants     []string             `json:"participants"`
	ConversationID   string               `json:"conversation_id,omitempty"`
	ConversationName string               `json:"conversation_name,omitempty"`
	From             string               `json:"from,omitempty"`
	Text             string               `json:"text,omitempty"`
	SentAt           string               `json:"sent_at,omitempty"`
	Conversation     *conversationSummary `json:"conversation,omitempty"`
}

type conversationSummary struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Participants   []string `json:"participants"`
	LastActivityAt string   `json:"last_activity_at"`
	CreatedBy      string   `json:"created_by,omitempty"`
}

type messageResponse struct {
	ID               string   `json:"id"`
	ConversationID   string   `json:"conversation_id"`
	ConversationName string   `json:"conversation_name"`
	Sender           string   `json:"sender"`
	Text             string   `json:"text"`
	SentAt           string   `json:"sent_at"`
	Participants     []string `json:"participants"`
}

type messageServiceClient struct {
	baseURL string
	client  *http.Client
}

func newMessageServiceClient(baseURL string) (*messageServiceClient, error) {
	baseURL = strings.TrimSpace(baseURL)
	if baseURL == "" {
		return nil, fmt.Errorf("message service url is empty")
	}
	baseURL = strings.TrimRight(baseURL, "/")
	return &messageServiceClient{
		baseURL: baseURL,
		client: &http.Client{
			Timeout: 5 * time.Second,
		},
	}, nil
}

func (m *messageServiceClient) GetConversation(ctx context.Context, id string) (*conversationSummary, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/conversations/%s", m.baseURL, id), nil)
	if err != nil {
		return nil, err
	}

	resp, err := m.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("message service conversation status %d", resp.StatusCode)
	}

	var payload struct {
		ID             string   `json:"id"`
		Name           string   `json:"name"`
		Participants   []string `json:"participants"`
		LastActivityAt string   `json:"last_activity_at"`
		CreatedBy      string   `json:"created_by"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}

	return &conversationSummary{
		ID:             payload.ID,
		Name:           payload.Name,
		Participants:   payload.Participants,
		LastActivityAt: payload.LastActivityAt,
		CreatedBy:      payload.CreatedBy,
	}, nil
}

func (m *messageServiceClient) CreateMessage(ctx context.Context, conversationID, sender, text string) (*messageResponse, error) {
	payload := map[string]string{
		"sender": sender,
		"text":   text,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("%s/conversations/%s/messages", m.baseURL, conversationID), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := m.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		return nil, fmt.Errorf("message service create message status %d", resp.StatusCode)
	}

	var result messageResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	return &result, nil
}

func contains(list []string, item string) bool {
	for _, v := range list {
		if v == item {
			return true
		}
	}
	return false
}

func (cl *client) writeLoop() {
	ticker := time.NewTicker(45 * time.Second)
	defer func() {
		ticker.Stop()
		cl.close()
	}()

	for {
		select {
		case msg, ok := <-cl.send:
			if !ok {
				cl.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := cl.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		case <-ticker.C:
			if err := cl.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (cl *client) sendMessage(data []byte) {
	select {
	case cl.send <- data:
	default:
		cl.close()
	}
}

func (cl *client) close() {
	cl.closeOnce.Do(func() {
		close(cl.send)
		cl.conn.Close()
	})
}

func sendError(cl *client, message string) {
	resp := map[string]string{
		"type":  "error",
		"error": message,
	}
	data, err := json.Marshal(resp)
	if err != nil {
		return
	}
	cl.sendMessage(data)
}
