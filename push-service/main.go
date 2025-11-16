package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/segmentio/kafka-go"
	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
	apnstoken "github.com/sideshow/apns2/token"
)

type messageEvent struct {
	ConversationID   string   `json:"conversation_id"`
	ConversationName string   `json:"conversation_name"`
	Sender           string   `json:"sender"`
	Text             string   `json:"text"`
	SentAt           string   `json:"sent_at"`
	Participants     []string `json:"participants"`
}

type deviceToken struct {
	Token    string
	Platform string
}

type tokenStore struct {
	db *sql.DB
}

type apnsSender struct {
	client *apns2.Client
	topic  string
}

type service struct {
	reader *kafka.Reader
	tokens *tokenStore
	apns   *apnsSender
}

func main() {
	kafkaURL := strings.TrimSpace(os.Getenv("KAFKA_URL"))
	if kafkaURL == "" {
		kafkaURL = "kafka:9092"
	}
	topic := strings.TrimSpace(os.Getenv("KAFKA_TOPIC"))
	if topic == "" {
		topic = "chat-messages"
	}
	groupID := strings.TrimSpace(os.Getenv("KAFKA_CONSUMER_GROUP"))
	if groupID == "" {
		groupID = "push-service"
	}

	mysqlDSN := strings.TrimSpace(os.Getenv("MYSQL_DSN"))
	if mysqlDSN == "" {
		log.Fatal("MYSQL_DSN must be set for push service")
	}

	db, err := sql.Open("mysql", mysqlDSN)
	if err != nil {
		log.Fatalf("mysql open error: %v", err)
	}
	defer db.Close()
	if err := db.Ping(); err != nil {
		log.Fatalf("mysql ping error: %v", err)
	}

	reader := kafka.NewReader(kafka.ReaderConfig{
		Brokers: []string{kafkaURL},
		Topic:   topic,
		GroupID: groupID,
	})
	defer reader.Close()

	apnsConfig, err := buildAPNSSender()
	if err != nil {
		log.Fatalf("apns setup error: %v", err)
	}

	srv := &service{
		reader: reader,
		tokens: &tokenStore{db: db},
		apns:   apnsConfig,
	}

	log.Printf("Push service listening on topic %s as %s", topic, groupID)
	srv.run()
}

func (s *service) run() {
	for {
		msg, err := s.reader.ReadMessage(context.Background())
		if err != nil {
			log.Printf("kafka read error: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}

		var event messageEvent
		if err := json.Unmarshal(msg.Value, &event); err != nil {
			log.Printf("invalid message event: %v", err)
			continue
		}

		s.processEvent(&event)
	}
}

func (s *service) processEvent(event *messageEvent) {
	recipients := recipientsForEvent(event)
	if len(recipients) == 0 {
		return
	}

	for _, recipient := range recipients {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		tokens, err := s.tokens.TokensForUser(ctx, recipient)
		cancel()
		if err != nil {
			log.Printf("token lookup error for %s: %v", recipient, err)
			continue
		}
		if len(tokens) == 0 {
			log.Printf("no device tokens for %s", recipient)
			continue
		}

		for _, tk := range tokens {
			switch strings.ToLower(tk.Platform) {
			case "ios", "apple", "apns", "":
				if err := s.apns.Send(event, tk.Token); err != nil {
					log.Printf("apns send error token=%s: %v", tk.Token, err)
				}
			case "android":
				sendAndroidPush(event, recipient, tk.Token)
			default:
				log.Printf("unsupported platform %q for token %s", tk.Platform, tk.Token)
			}
		}
	}
}

func (ts *tokenStore) TokensForUser(ctx context.Context, email string) ([]deviceToken, error) {
	rows, err := ts.db.QueryContext(ctx, `
        SELECT device_token, COALESCE(platform, '') FROM device_tokens
        WHERE user_email = ?
    `, email)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tokens []deviceToken
	for rows.Next() {
		var tk deviceToken
		if err := rows.Scan(&tk.Token, &tk.Platform); err != nil {
			return nil, err
		}
		tokens = append(tokens, tk)
	}
	return tokens, rows.Err()
}

func buildAPNSSender() (*apnsSender, error) {
	keyPath := strings.TrimSpace(os.Getenv("APNS_KEY_PATH"))
	keyID := strings.TrimSpace(os.Getenv("APNS_KEY_ID"))
	teamID := strings.TrimSpace(os.Getenv("APNS_TEAM_ID"))
	topic := strings.TrimSpace(os.Getenv("APNS_TOPIC"))
	env := strings.ToLower(strings.TrimSpace(os.Getenv("APNS_ENVIRONMENT")))

	if keyPath == "" || keyID == "" || teamID == "" || topic == "" {
		return nil, fmt.Errorf("APNS configuration is incomplete")
	}

	authKey, err := apnstoken.AuthKeyFromFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("load APNS key: %w", err)
	}

	apnsToken := &apnstoken.Token{
		AuthKey: authKey,
		KeyID:   keyID,
		TeamID:  teamID,
	}

	client := apns2.NewTokenClient(apnsToken)
	useSandbox := env == "development" || env == "sandbox"
	if !useSandbox && env == "" {
		useSandbox = strings.EqualFold(strings.TrimSpace(os.Getenv("APNS_USE_SANDBOX")), "true")
	}

	if useSandbox {
		client = client.Development()
		log.Printf("APNS environment set to development")
	} else {
		client = client.Production()
		log.Printf("APNS environment set to production")
	}

	return &apnsSender{
		client: client,
		topic:  topic,
	}, nil
}

func (a *apnsSender) Send(evt *messageEvent, deviceToken string) error {
	if evt == nil {
		return fmt.Errorf("nil event")
	}

	alert := fmt.Sprintf("%s: %s", evt.Sender, truncate(evt.Text, 140))
	data := payload.NewPayload().
		AlertTitle(evt.ConversationName).
		AlertBody(alert).
		Sound("default").
		Custom("conversation_id", evt.ConversationID).
		Custom("sender", evt.Sender).
		Custom("sent_at", evt.SentAt)

	notification := &apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       a.topic,
		Payload:     data,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	resp, err := a.client.PushWithContext(ctx, notification)
	if err != nil {
		return err
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("apns status %d: %s", resp.StatusCode, resp.Reason)
	}
	return nil
}

func recipientsForEvent(evt *messageEvent) []string {
	if evt == nil {
		return nil
	}
	recipients := make([]string, 0, len(evt.Participants))
	for _, participant := range evt.Participants {
		participant = strings.TrimSpace(participant)
		if participant == "" || participant == evt.Sender {
			continue
		}
		recipients = append(recipients, participant)
	}
	return recipients
}

func sendAndroidPush(evt *messageEvent, recipient, token string) {
	log.Printf("[push][android] skipping real send (no FCM config) conversation=%s recipient=%s token=%s from=%s text=%q",
		evt.ConversationID, recipient, token, evt.Sender, evt.Text)
}

func truncate(text string, max int) string {
	if len(text) <= max {
		return text
	}
	if max <= 3 {
		return text[:max]
	}
	return text[:max-3] + "..."
}
