package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	_ "github.com/lib/pq"
	"github.com/segmentio/kafka-go"
)

type statusMessage struct {
	SubmissionID int64  `json:"submission_id"`
	Status       string `json:"status"`
	Verdict      string `json:"verdict,omitempty"`
	Stdout       string `json:"stdout,omitempty"`
	Stderr       string `json:"stderr,omitempty"`
	ExitCode     *int   `json:"exit_code,omitempty"`
}

type submission struct {
	ID        int64
	ContestID string
	Index     string
	Lang      string
	Code      string
}

type problem struct {
	Verifier string
}

func main() {
	dbDSN := getenv("DB_DSN", "postgres://postgres:password@localhost:5432/codeforces?sslmode=disable")
	brokers := splitAndTrim(getenv("KAFKA_BROKERS", "localhost:9092"))
	submissionTopic := getenv("KAFKA_SUBMISSION_TOPIC", "cf.submissions")
	statusTopic := getenv("KAFKA_STATUS_TOPIC", "cf.submission_status")
	streamTests := strings.ToLower(getenv("STREAM_TEST_PROGRESS", "true")) == "true"

	if err := ensureKafkaTopics(context.Background(), brokers, []string{submissionTopic, statusTopic}); err != nil {
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
	if err := ensureSchema(context.Background(), db); err != nil {
		log.Fatalf("failed to ensure schema: %v", err)
	}

	reader := kafka.NewReader(kafka.ReaderConfig{
		Brokers:  brokers,
		Topic:    submissionTopic,
		GroupID:  "codeforces-worker",
		MaxBytes: 10e6,
	})
	producer := &kafka.Writer{
		Addr:                   kafka.TCP(brokers...),
		Topic:                  statusTopic,
		Balancer:               &kafka.LeastBytes{},
		AllowAutoTopicCreation: true,
	}
	defer reader.Close()
	defer producer.Close()

	log.Printf("codeforces-worker consuming %s, producing %s", submissionTopic, statusTopic)
	for {
		msg, err := reader.ReadMessage(context.Background())
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return
			}
			log.Printf("read error: %v", err)
			time.Sleep(time.Second)
			continue
		}
		var subMsg statusMessage
		if err := json.Unmarshal(msg.Value, &subMsg); err != nil {
			log.Printf("discarding invalid submission payload: %v", err)
			continue
		}
		if subMsg.SubmissionID == 0 {
			log.Printf("missing submission_id in payload")
			continue
		}
		go func(id int64) {
			if err := handleSubmission(context.Background(), db, producer, id, streamTests); err != nil {
				log.Printf("submission %d failed: %v", id, err)
				status := statusMessage{SubmissionID: id, Status: "failed", Verdict: err.Error()}
				_ = publishStatus(context.Background(), producer, status)
			}
		}(subMsg.SubmissionID)
	}
}

func handleSubmission(ctx context.Context, db *sql.DB, producer *kafka.Writer, id int64, streamTests bool) error {
	sub, err := loadSubmission(ctx, db, id)
	if err != nil {
		return err
	}
	prob, err := loadProblem(ctx, db, sub.ContestID, sub.Index)
	if err != nil {
		return err
	}
	startStatus := statusMessage{SubmissionID: id, Status: "processing"}
	if err := publishStatus(ctx, producer, startStatus); err != nil {
		log.Printf("warn: failed to send processing status for %d: %v", id, err)
	}

	res := runVerification(ctx, sub, prob, producer, streamTests)
	return publishStatus(ctx, producer, res)
}

func publishStatus(ctx context.Context, producer *kafka.Writer, msg statusMessage) error {
	payload, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return producer.WriteMessages(ctx, kafka.Message{
		Key:   []byte(strconv.FormatInt(msg.SubmissionID, 10)),
		Value: payload,
	})
}

func loadSubmission(ctx context.Context, db *sql.DB, id int64) (*submission, error) {
	var sub submission
	err := db.QueryRowContext(ctx, `
		SELECT id, contest_id, problem_letter, COALESCE(lang,''), COALESCE(code,'')
		FROM submissions
		WHERE id = $1
	`, id).Scan(&sub.ID, &sub.ContestID, &sub.Index, &sub.Lang, &sub.Code)
	if err != nil {
		return nil, err
	}
	return &sub, nil
}

func loadProblem(ctx context.Context, db *sql.DB, contest, index string) (*problem, error) {
	var p problem
	err := db.QueryRowContext(ctx, `
		SELECT COALESCE(verifier, '')
		FROM problems
		WHERE contest_id = $1 AND UPPER(index_name) = UPPER($2)
	`, contest, index).Scan(&p.Verifier)
	if err != nil {
		return nil, err
	}
	return &p, nil
}

func runVerification(ctx context.Context, sub *submission, prob *problem, producer *kafka.Writer, stream bool) statusMessage {
	if strings.TrimSpace(sub.Code) == "" {
		return statusMessage{SubmissionID: sub.ID, Status: "failed", Verdict: "empty code"}
	}
	tmpDir, err := os.MkdirTemp("", "cf-worker-*")
	if err != nil {
		return statusMessage{SubmissionID: sub.ID, Status: "failed", Verdict: "mktemp failed: " + err.Error()}
	}
	defer os.RemoveAll(tmpDir)

	// Write submission source.
	srcPath := filepath.Join(tmpDir, submissionFilename(sub.Lang))
	if err := os.WriteFile(srcPath, []byte(sub.Code), 0o644); err != nil {
		return statusMessage{SubmissionID: sub.ID, Status: "failed", Verdict: "write source failed: " + err.Error()}
	}

	candidateBin, err := buildCandidate(sub.Lang, srcPath, tmpDir)
	if err != nil {
		return statusMessage{SubmissionID: sub.ID, Status: "failed", Verdict: "compile failed: " + err.Error()}
	}

	// Special-case 1A: run tests directly so we can stream per-test status.
	if strings.TrimSpace(sub.ContestID) == "1" && strings.EqualFold(sub.Index, "A") {
		return verify1A(ctx, sub, candidateBin, producer, stream)
	}

	// Write and build verifier.
	verifierPath := filepath.Join(tmpDir, "verifierA.go")
	if err := os.WriteFile(verifierPath, []byte(prob.Verifier), 0o644); err != nil {
		return statusMessage{SubmissionID: sub.ID, Status: "failed", Verdict: "write verifier failed: " + err.Error()}
	}
	verifierBin := filepath.Join(tmpDir, "verifier.bin")
	buildCmd := exec.Command("go", "build", "-o", verifierBin, verifierPath)
	buildCmd.Stdout = &bytes.Buffer{}
	var verifierStderr bytes.Buffer
	buildCmd.Stderr = &verifierStderr
	if err := buildCmd.Run(); err != nil {
		return statusMessage{
			SubmissionID: sub.ID,
			Status:       "failed",
			Verdict:      "verifier build failed",
			Stderr:       verifierStderr.String(),
		}
	}

	// Run verifier.
	var outBuf, errBuf bytes.Buffer
	run := exec.Command(verifierBin, candidateBin)
	run.Stdout = &outBuf
	run.Stderr = &errBuf
	run.Dir = tmpDir
	if err := run.Run(); err != nil {
		exitCode := exitCode(err)
		return statusMessage{
			SubmissionID: sub.ID,
			Status:       "completed",
			Verdict:      "wrong answer",
			Stdout:       outBuf.String(),
			Stderr:       errBuf.String(),
			ExitCode:     &exitCode,
		}
	}

	exitCode := 0
	return statusMessage{
		SubmissionID: sub.ID,
		Status:       "completed",
		Verdict:      "accepted",
		Stdout:       outBuf.String(),
		Stderr:       errBuf.String(),
		ExitCode:     &exitCode,
	}
}

func verify1A(ctx context.Context, sub *submission, candidateBin string, producer *kafka.Writer, stream bool) statusMessage {
	tests := make([]struct{ n, m, a int64 }, 0, 120)
	seedCases := []struct{ n, m, a int64 }{
		{6, 6, 4},
		{1, 1, 1},
		{1, 2, 3},
		{1_000_000_000, 1, 1_000_000_000},
		{1_000_000_000, 1_000_000_000, 1_000_000_000},
		{999_999_937, 999_999_929, 2},
		{100, 25, 7},
		{25, 100, 7},
		{99999999, 1234567, 89},
		{33, 44, 5},
		{44, 33, 5},
		{100000, 99999, 17},
	}
	tests = append(tests, seedCases...)
	// Generate additional cases to exceed 100 entries.
	for i := int64(0); len(tests) < 110; i++ {
		n := 1 + (i*37)%1_000_000_000
		m := 1 + (i*91)%1_000_000_000
		a := 1 + (i*53)%999_999_900
		if a == 0 {
			a = 1
		}
		tests = append(tests, struct{ n, m, a int64 }{n, m, a})
	}

	for i, t := range tests {
		expected := tilesNeeded(t.n, t.m, t.a)
		if stream && producer != nil {
			_ = publishStatus(ctx, producer, statusMessage{
				SubmissionID: sub.ID,
				Status:       "running",
				Verdict:      fmt.Sprintf("test %d/%d", i+1, len(tests)),
			})
		}

		cmd := exec.Command(candidateBin)
		cmd.Stdin = bytes.NewBufferString(fmt.Sprintf("%d %d %d\n", t.n, t.m, t.a))
		var outBuf, errBuf bytes.Buffer
		cmd.Stdout = &outBuf
		cmd.Stderr = &errBuf
		if err := cmd.Run(); err != nil {
			exit := exitCode(err)
			return statusMessage{
				SubmissionID: sub.ID,
				Status:       "completed",
				Verdict:      fmt.Sprintf("runtime error on test %d", i+1),
				Stdout:       outBuf.String(),
				Stderr:       errBuf.String(),
				ExitCode:     &exit,
			}
		}
		var got int64
		outStr := strings.TrimSpace(outBuf.String())
		fmt.Sscan(outStr, &got)
		if got != expected {
			exit := 0
			return statusMessage{
				SubmissionID: sub.ID,
				Status:       "completed",
				Verdict:      fmt.Sprintf("wrong answer on test %d: expected %d got %s", i+1, expected, outStr),
				Stdout:       outBuf.String(),
				Stderr:       errBuf.String(),
				ExitCode:     &exit,
			}
		}
	}

	exit := 0
	return statusMessage{
		SubmissionID: sub.ID,
		Status:       "completed",
		Verdict:      "accepted",
		Stdout:       fmt.Sprintf("Passed %d tests", len(tests)),
		ExitCode:     &exit,
	}
}

func buildCandidate(lang, srcPath, tmpDir string) (string, error) {
	lang = strings.ToLower(strings.TrimSpace(lang))
	switch lang {
	case "go", "golang":
		bin := filepath.Join(tmpDir, "candidate_go.bin")
		cmd := exec.Command("go", "build", "-o", bin, srcPath)
		cmd.Dir = tmpDir
		cmd.Env = append(os.Environ(),
			"GO111MODULE=off",
			"GOWORK=off",
			"GOPATH="+filepath.Join(tmpDir, "gopath"),
		)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			return "", errors.New(strings.TrimSpace(stderr.String()))
		}
		return bin, nil
	case "cpp", "c++", "cc", "cxx":
		bin := filepath.Join(tmpDir, "candidate_cpp.bin")
		cmd := exec.Command("g++", "-std=c++17", "-O2", "-pipe", "-static", "-s", srcPath, "-o", bin)
		cmd.Dir = tmpDir
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			return "", errors.New(strings.TrimSpace(stderr.String()))
		}
		return bin, nil
	case "py", "python", "python3":
		// Make script executable with shebang.
		data, err := os.ReadFile(srcPath)
		if err != nil {
			return "", err
		}
		if !bytes.HasPrefix(data, []byte("#!")) {
			data = append([]byte("#!/usr/bin/env python3\n"), data...)
			if err := os.WriteFile(srcPath, data, 0o755); err != nil {
				return "", err
			}
		} else {
			_ = os.Chmod(srcPath, 0o755)
		}
		return srcPath, nil
	default:
		return "", errors.New("unsupported lang: " + lang)
	}
}

func submissionFilename(lang string) string {
	switch strings.ToLower(strings.TrimSpace(lang)) {
	case "go", "golang":
		return "main.go"
	case "cpp", "c++", "cc", "cxx":
		return "main.cpp"
	case "py", "python", "python3":
		return "main.py"
	case "rs", "rust":
		return "main.rs"
	default:
		return "main.txt"
	}
}

func tilesNeeded(n, m, a int64) int64 {
	rows := (n + a - 1) / a
	cols := (m + a - 1) / a
	return rows * cols
}

func exitCode(err error) int {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return -1
}

func ensureSchema(ctx context.Context, db *sql.DB) error {
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
			timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		)`); err != nil {
		return err
	}
	ddl := []string{
		`ALTER TABLE submissions ADD COLUMN IF NOT EXISTS status VARCHAR(32) DEFAULT 'queued'`,
		`ALTER TABLE submissions ADD COLUMN IF NOT EXISTS verdict VARCHAR(64)`,
		`ALTER TABLE submissions ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`,
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
