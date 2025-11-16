package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"fmt"
	"log"
	"math/big"
	"os"
	"time"

	_ "github.com/go-sql-driver/mysql"
	mailgun "github.com/mailgun/mailgun-go/v4"
	"github.com/segmentio/kafka-go"
)

const otpTTL = 3 * time.Minute

func main() {
	kafkaURL := os.Getenv("KAFKA_URL")
	mgDomain := os.Getenv("MAILGUN_DOMAIN")
	mgAPIKey := os.Getenv("MAILGUN_API_KEY")
	mysqlDSN := os.Getenv("MYSQL_DSN")

	if kafkaURL == "" || mgDomain == "" || mgAPIKey == "" {
		log.Fatal("KAFKA_URL, MAILGUN_DOMAIN, and MAILGUN_API_KEY must be set")
	}
	if mysqlDSN == "" {
		log.Fatal("MYSQL_DSN must be set for OTP storage")
	}

	db, err := sql.Open("mysql", mysqlDSN)
	if err != nil {
		log.Fatalf("mysql connection error: %v", err)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		log.Fatalf("mysql ping error: %v", err)
	}

	if err := ensureSchema(db); err != nil {
		log.Fatalf("schema setup error: %v", err)
	}

	mg := mailgun.NewMailgun(mgDomain, mgAPIKey)

	reader := kafka.NewReader(kafka.ReaderConfig{
		Brokers: []string{kafkaURL},
		Topic:   "new-registration",
		GroupID: "email-worker-group",
	})
	defer reader.Close()

	log.Println("Email worker listening to Kafka...")

	for {
		msg, err := reader.ReadMessage(context.Background())
		if err != nil {
			log.Println("Error reading Kafka:", err)
			continue
		}

		email := string(msg.Value)
		if email == "" {
			continue
		}
		log.Printf("Generating OTP for %s", email)

		otp, err := generateOTP()
		if err != nil {
			log.Printf("otp generation error: %v", err)
			continue
		}

		if err := storeOTP(db, email, otp); err != nil {
			log.Printf("failed to store otp for %s: %v", email, err)
			continue
		}

		message := mg.NewMessage(
			"auth@"+mgDomain,
			"Your login code",
			fmt.Sprintf("Your one-time password is %s. It is valid for 3 minutes.", otp),
			email,
		)

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		_, _, err = mg.Send(ctx, message)
		cancel()
		if err != nil {
			log.Printf("Mailgun send error for %s: %v", email, err)
			continue
		}
		log.Printf("OTP email sent to %s", email)
	}
}

func ensureSchema(db *sql.DB) error {
	query := `
		CREATE TABLE IF NOT EXISTS otp_codes (
			email VARCHAR(255) NOT NULL PRIMARY KEY,
			code VARCHAR(12) NOT NULL,
			expires_at DATETIME NOT NULL,
			created_at DATETIME NOT NULL
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
	`
	_, err := db.Exec(query)
	return err
}

func storeOTP(db *sql.DB, email, code string) error {
	now := time.Now()
	expires := now.Add(otpTTL)
	_, err := db.Exec(`
		INSERT INTO otp_codes (email, code, expires_at, created_at)
		VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE
			code = VALUES(code),
			expires_at = VALUES(expires_at),
			created_at = VALUES(created_at)
	`, email, code, expires, now)
	return err
}

func generateOTP() (string, error) {
	max := big.NewInt(1000000)
	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}
