package main

import (
	bytespkg "bytes"
	"context"
	cryptoRand "crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "github.com/lib/pq"
	"github.com/segmentio/kafka-go"
)

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type request struct {
	Model     string    `json:"model"`
	Messages  []message `json:"messages"`
	MaxTokens int       `json:"max_tokens,omitempty"`
}

type response struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

type problem struct {
	ID        int64
	ContestID string
	Index     string
	Statement string
}

type statusMessage struct {
	SubmissionID int64  `json:"submission_id"`
	Status       string `json:"status"`
	Verdict      string `json:"verdict,omitempty"`
	Stdout       string `json:"stdout,omitempty"`
	Stderr       string `json:"stderr,omitempty"`
	ExitCode     *int   `json:"exit_code,omitempty"`
}

type enqueueRequest struct {
	APIKey       string `json:"api_key,omitempty"`
	Provider     string `json:"provider,omitempty"`
	Model        string `json:"model,omitempty"`
	Lang         string `json:"lang,omitempty"`
	UseResponses bool   `json:"use_responses,omitempty"`
	Count        int    `json:"count,omitempty"`
	Concurrency  int    `json:"concurrency,omitempty"`
	Random       *bool  `json:"random,omitempty"`
	RatingMin    *int   `json:"rating_min,omitempty"`
	RatingMax    *int   `json:"rating_max,omitempty"`
	ContestID    string `json:"contest_id,omitempty"`
	Index        string `json:"index,omitempty"`
	UserID       *int64 `json:"user_id,omitempty"`
}

type enqueueResponse struct {
	JobID  string `json:"job_id"`
	Status string `json:"status"`
	Total  int    `json:"total"`
}

type jobSnapshot struct {
	JobID      string `json:"job_id"`
	Status     string `json:"status"`
	Total      int    `json:"total"`
	Enqueued   int64  `json:"enqueued"`
	Failed     int64  `json:"failed"`
	StartedAt  string `json:"started_at,omitempty"`
	FinishedAt string `json:"finished_at,omitempty"`
	LastError  string `json:"last_error,omitempty"`
}

type jobState struct {
	id         string
	status     atomic.Value
	total      int
	enqueued   atomic.Int64
	failed     atomic.Int64
	startedAt  time.Time
	finishedAt time.Time
	lastError  atomic.Value
	mu         sync.Mutex
}

type server struct {
	db              *sql.DB
	producer        *kafka.Writer
	submissionTopic string
	defaultProvider string
	defaultModel    string
	defaultLang     string
	defaultAPIKey   string
	defaultUseResp  bool
	defaultConc     int
	requestTimeout  time.Duration
	jobsMu          sync.Mutex
	jobs            map[string]*jobState
}

var requestTimeout time.Duration

func main() {
	mode := flag.String("mode", "server", "server or enqueue")
	port := flag.String("port", getenv("PORT", "8083"), "HTTP port (server mode)")
	provider := flag.String("provider", getenv("DEFAULT_PROVIDER", "openrouter"), "Default provider")
	model := flag.String("model", getenv("DEFAULT_MODEL", ""), "Default model")
	lang := flag.String("lang", getenv("DEFAULT_LANG", "go"), "Default language")
	apiKey := flag.String("api-key", getenv("DEFAULT_API_KEY", ""), "Default API key (or use request api_key)")
	useResponses := flag.Bool("use-responses", strings.ToLower(getenv("DEFAULT_USE_RESPONSES", "false")) == "true", "Use responses endpoint when supported")
	count := flag.Int("count", 0, "How many problems to enqueue (enqueue mode)")
	concurrency := flag.Int("concurrency", getenvInt("GENERATOR_CONCURRENCY", 4), "Concurrency for generation")
	requestTimeout = getenvDuration("LLM_TIMEOUT", 120*time.Second)
	flag.Parse()

	dbDSN := getenv("DB_DSN", "postgres://postgres:password@localhost:5432/codeforces?sslmode=disable")
	brokers := splitAndTrim(getenv("KAFKA_BROKERS", "localhost:9092"))
	submissionTopic := getenv("KAFKA_SUBMISSION_TOPIC", "cf.submissions")

	subPartitions := getenvInt("KAFKA_SUBMISSION_PARTITIONS", 1)
	if err := ensureKafkaTopics(context.Background(), brokers, map[string]int{submissionTopic: subPartitions}); err != nil {
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

	producer := &kafka.Writer{
		Addr:                   kafka.TCP(brokers...),
		Topic:                  submissionTopic,
		Balancer:               &kafka.LeastBytes{},
		AllowAutoTopicCreation: true,
	}
	defer producer.Close()

	s := &server{
		db:              db,
		producer:        producer,
		submissionTopic: submissionTopic,
		defaultProvider: *provider,
		defaultModel:    *model,
		defaultLang:     *lang,
		defaultAPIKey:   *apiKey,
		defaultUseResp:  *useResponses,
		defaultConc:     clampInt(*concurrency, 1, 128),
		requestTimeout:  requestTimeout,
		jobs:            make(map[string]*jobState),
	}

	if strings.ToLower(*mode) == "enqueue" {
		req := enqueueRequest{
			APIKey:       *apiKey,
			Provider:     *provider,
			Model:        *model,
			Lang:         *lang,
			UseResponses: *useResponses,
			Count:        *count,
			Concurrency:  *concurrency,
		}
		if err := s.runOnce(context.Background(), req); err != nil {
			log.Fatalf("enqueue failed: %v", err)
		}
		return
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/enqueue", s.handleEnqueue)
	mux.HandleFunc("/jobs/", s.handleJob)
	mux.HandleFunc("/jobs", s.handleListJobs)

	log.Printf("codeforces-generator listening on :%s", *port)
	if err := http.ListenAndServe(":"+*port, withCORS(mux)); err != nil {
		log.Fatal(err)
	}
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) handleEnqueue(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var req enqueueRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	req = s.applyDefaults(req, r.Header.Get("X-API-Key"))
	if err := validateRequest(req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	job := s.newJob(req.Count)
	go s.runJob(context.Background(), job, req)
	writeJSON(w, http.StatusAccepted, enqueueResponse{JobID: job.id, Status: "queued", Total: req.Count})
}

func (s *server) handleJob(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/jobs/")
	if id == "" || id == "/" {
		http.NotFound(w, r)
		return
	}
	job := s.getJob(strings.TrimSpace(id))
	if job == nil {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, job.snapshot())
}

func (s *server) handleListJobs(w http.ResponseWriter, _ *http.Request) {
	s.jobsMu.Lock()
	jobs := make([]jobSnapshot, 0, len(s.jobs))
	for _, job := range s.jobs {
		jobs = append(jobs, job.snapshot())
	}
	s.jobsMu.Unlock()
	writeJSON(w, http.StatusOK, map[string][]jobSnapshot{"jobs": jobs})
}

func (s *server) runOnce(ctx context.Context, req enqueueRequest) error {
	req = s.applyDefaults(req, "")
	if err := validateRequest(req); err != nil {
		return err
	}
	job := s.newJob(req.Count)
	s.runJob(ctx, job, req)
	if job.failed.Load() > 0 {
		return fmt.Errorf("completed with %d failures", job.failed.Load())
	}
	return nil
}

func (s *server) runJob(ctx context.Context, job *jobState, req enqueueRequest) {
	job.setStatus("running")
	job.mu.Lock()
	job.startedAt = time.Now()
	job.mu.Unlock()

	problems, err := loadProblems(ctx, s.db, req)
	if err != nil {
		job.setError(err.Error())
		job.setStatus("failed")
		job.mu.Lock()
		job.finishedAt = time.Now()
		job.mu.Unlock()
		return
	}
	if len(problems) == 0 {
		job.setError("no problems found")
		job.setStatus("failed")
		job.mu.Lock()
		job.finishedAt = time.Now()
		job.mu.Unlock()
		return
	}

	conc := clampInt(req.Concurrency, 1, 128)
	jobs := make(chan problem, conc*2)
	var wg sync.WaitGroup
	for i := 0; i < conc; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for p := range jobs {
				if err := s.processProblem(ctx, req, p); err != nil {
					job.failed.Add(1)
					job.setError(err.Error())
					continue
				}
				job.enqueued.Add(1)
			}
		}()
	}

	for _, p := range problems {
		jobs <- p
	}
	close(jobs)
	wg.Wait()

	job.setStatus("completed")
	job.mu.Lock()
	job.finishedAt = time.Now()
	job.mu.Unlock()
}

func (s *server) processProblem(ctx context.Context, req enqueueRequest, p problem) error {
	prompt := fmt.Sprintf("write a %s solution for %s. Output only the code with no comments, explanation, or additional text.", normalizeLang(req.Lang), latexToPlain(p.Statement))
	resp := sendPrompt(req.Provider, req.Model, req.APIKey, prompt, req.UseResponses, s.requestTimeout)
	if strings.TrimSpace(resp) == "" {
		return errors.New("empty response")
	}
	code := extractCode(resp, normalizeLang(req.Lang))
	if strings.TrimSpace(code) == "" {
		return errors.New("empty code")
	}

	status := "queued"
	var id int64
	var userID sql.NullInt64
	if req.UserID != nil && *req.UserID > 0 {
		userID = sql.NullInt64{Int64: *req.UserID, Valid: true}
	}
	if err := s.db.QueryRowContext(ctx, `
		INSERT INTO submissions (contest_id, problem_letter, lang, code, status, user_id)
		VALUES ($1, UPPER($2), $3, $4, $5, $6)
		RETURNING id
	`, p.ContestID, p.Index, normalizeLang(req.Lang), code, status, userID).Scan(&id); err != nil {
		return err
	}

	msg := statusMessage{SubmissionID: id, Status: status}
	payload, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return s.producer.WriteMessages(ctx, kafka.Message{
		Key:   []byte(strconv.FormatInt(id, 10)),
		Value: payload,
	})
}

func (s *server) applyDefaults(req enqueueRequest, headerKey string) enqueueRequest {
	if req.APIKey == "" {
		req.APIKey = strings.TrimSpace(headerKey)
	}
	if req.APIKey == "" {
		req.APIKey = s.defaultAPIKey
	}
	if req.Provider == "" {
		req.Provider = s.defaultProvider
	}
	if req.Model == "" {
		req.Model = s.defaultModel
	}
	if req.Lang == "" {
		req.Lang = s.defaultLang
	}
	if req.Concurrency <= 0 {
		req.Concurrency = s.defaultConc
	}
	if req.Count <= 0 {
		req.Count = 1
	}
	return req
}

func validateRequest(req enqueueRequest) error {
	if strings.TrimSpace(req.APIKey) == "" {
		return errors.New("api_key is required")
	}
	if strings.TrimSpace(req.Model) == "" {
		return errors.New("model is required")
	}
	if req.Count <= 0 {
		return errors.New("count must be > 0")
	}
	return nil
}

func loadProblems(ctx context.Context, db *sql.DB, req enqueueRequest) ([]problem, error) {
	if req.ContestID != "" && req.Index != "" {
		var p problem
		err := db.QueryRowContext(ctx, `
			SELECT id, contest_id, index_name, statement
			FROM problems
			WHERE contest_id = $1 AND UPPER(index_name) = UPPER($2)
				AND statement IS NOT NULL AND statement <> ''
				AND verifier IS NOT NULL AND verifier <> ''
		`, req.ContestID, req.Index).Scan(&p.ID, &p.ContestID, &p.Index, &p.Statement)
		if err != nil {
			return nil, err
		}
		return []problem{p}, nil
	}

	clauses := []string{"statement IS NOT NULL", "statement <> ''", "verifier IS NOT NULL", "verifier <> ''"}
	args := []interface{}{}
	arg := 1
	if req.RatingMin != nil {
		clauses = append(clauses, fmt.Sprintf("rating >= $%d", arg))
		args = append(args, *req.RatingMin)
		arg++
	}
	if req.RatingMax != nil {
		clauses = append(clauses, fmt.Sprintf("rating <= $%d", arg))
		args = append(args, *req.RatingMax)
		arg++
	}
	where := "WHERE " + strings.Join(clauses, " AND ")
	order := "ORDER BY contest_id, index_name"
	if req.Random == nil || *req.Random {
		order = "ORDER BY random()"
	}
	query := fmt.Sprintf(`
		SELECT id, contest_id, index_name, statement
		FROM problems
		%s
		%s
		LIMIT %d
	`, where, order, req.Count)

	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var problems []problem
	for rows.Next() {
		var p problem
		if err := rows.Scan(&p.ID, &p.ContestID, &p.Index, &p.Statement); err != nil {
			return nil, err
		}
		problems = append(problems, p)
	}
	return problems, rows.Err()
}

func (j *jobState) snapshot() jobSnapshot {
	j.mu.Lock()
	defer j.mu.Unlock()
	start := ""
	finish := ""
	if !j.startedAt.IsZero() {
		start = j.startedAt.Format(time.RFC3339)
	}
	if !j.finishedAt.IsZero() {
		finish = j.finishedAt.Format(time.RFC3339)
	}
	lastErr := ""
	if v := j.lastError.Load(); v != nil {
		lastErr, _ = v.(string)
	}
	status := ""
	if v := j.status.Load(); v != nil {
		status, _ = v.(string)
	}
	return jobSnapshot{
		JobID:      j.id,
		Status:     status,
		Total:      j.total,
		Enqueued:   j.enqueued.Load(),
		Failed:     j.failed.Load(),
		StartedAt:  start,
		FinishedAt: finish,
		LastError:  lastErr,
	}
}

func (j *jobState) setStatus(status string) {
	j.status.Store(status)
}

func (j *jobState) setError(err string) {
	j.lastError.Store(err)
}

func (s *server) newJob(total int) *jobState {
	job := &jobState{id: newJobID(), total: total}
	job.setStatus("queued")
	s.jobsMu.Lock()
	s.jobs[job.id] = job
	s.jobsMu.Unlock()
	return job
}

func (s *server) getJob(id string) *jobState {
	s.jobsMu.Lock()
	job := s.jobs[id]
	s.jobsMu.Unlock()
	return job
}

func newJobID() string {
	buf := make([]byte, 12)
	if _, err := cryptoRand.Read(buf); err != nil {
		r := rand.New(rand.NewSource(time.Now().UnixNano()))
		for i := range buf {
			buf[i] = byte(r.Intn(256))
		}
	}
	return hex.EncodeToString(buf)
}

func sendPrompt(provider, model, apiKey, prompt string, useResponses bool, timeout time.Duration) string {
	prompt = latexToPlain(prompt)

	var body []byte
	var err error
	lowerProvider := strings.ToLower(provider)
	useResp := useResponses && (lowerProvider == "openai" || lowerProvider == "openrouter")

	if lowerProvider == "gemini" || lowerProvider == "vertex" {
		gemReq := map[string]interface{}{
			"contents": []map[string]interface{}{
				{
					"role":  "user",
					"parts": []map[string]string{{"text": prompt}},
				},
			},
		}
		body, err = json.Marshal(gemReq)
	} else if useResp {
		respReq := map[string]interface{}{"model": model, "input": prompt}
		body, err = json.Marshal(respReq)
	} else {
		messages := []message{{Role: "user", Content: prompt}}
		reqBody := request{Model: model, Messages: messages}
		if lowerProvider == "claude" {
			reqBody.MaxTokens = 4096
		}
		body, err = json.Marshal(reqBody)
	}
	if err != nil {
		return ""
	}

	client := &http.Client{Timeout: timeout}
	url := ""
	headers := map[string]string{"Content-Type": "application/json"}

	switch lowerProvider {
	case "openai":
		if useResp {
			url = "https://api.openai.com/v1/responses"
		} else {
			url = "https://api.openai.com/v1/chat/completions"
		}
		headers["Authorization"] = "Bearer " + apiKey
	case "gemini":
		url = "https://generativelanguage.googleapis.com/v1beta/models/" + model + ":generateContent?key=" + apiKey
	case "vertex":
		modelEndpoint := strings.TrimSpace(model)
		if !strings.HasPrefix(modelEndpoint, "http://") && !strings.HasPrefix(modelEndpoint, "https://") {
			modelPath := strings.TrimPrefix(modelEndpoint, "/")
			if !strings.Contains(modelPath, "/") {
				modelPath = "publishers/google/models/" + modelPath
			}
			modelEndpoint = "https://aiplatform.googleapis.com/v1/" + modelPath
		}
		if !strings.Contains(modelEndpoint, ":generateContent") {
			modelEndpoint += ":generateContent"
		}
		if !strings.Contains(modelEndpoint, "key=") {
			if strings.Contains(modelEndpoint, "?") {
				modelEndpoint += "&key=" + apiKey
			} else {
				modelEndpoint += "?key=" + apiKey
			}
		}
		url = modelEndpoint
	case "xai":
		url = "https://api.x.ai/v1/chat/completions"
		headers["Authorization"] = "Bearer " + apiKey
	case "claude":
		url = "https://api.anthropic.com/v1/messages"
		headers["x-api-key"] = apiKey
		headers["anthropic-version"] = "2023-06-01"
	case "deepseek":
		url = "https://api.deepseek.com/v1/chat/completions"
		headers["Authorization"] = "Bearer " + apiKey
	default:
		if useResp {
			url = "https://openrouter.ai/api/v1/responses"
		} else {
			url = "https://openrouter.ai/api/v1/chat/completions"
		}
		headers["Authorization"] = "Bearer " + apiKey
	}

	const maxRetries = 3
	for attempt := 1; attempt <= maxRetries; attempt++ {
		req, err := http.NewRequest("POST", url, bytespkg.NewReader(body))
		if err != nil {
			if attempt == maxRetries {
				return ""
			}
			time.Sleep(time.Second * time.Duration(attempt))
			continue
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}

		resp, err := client.Do(req)
		if err != nil {
			if attempt == maxRetries {
				return ""
			}
			time.Sleep(time.Second * time.Duration(attempt))
			continue
		}
		bodyBytes, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			if attempt == maxRetries {
				return ""
			}
			time.Sleep(time.Second * time.Duration(attempt))
			continue
		}
		if resp.StatusCode != http.StatusOK {
			if attempt == maxRetries {
				return ""
			}
			time.Sleep(time.Second * time.Duration(attempt))
			continue
		}

		if lowerProvider == "gemini" || lowerProvider == "vertex" {
			var gResp struct {
				Candidates []struct {
					Content struct {
						Parts []struct {
							Text string `json:"text"`
						} `json:"parts"`
					} `json:"content"`
				} `json:"candidates"`
			}
			if err = json.Unmarshal(bodyBytes, &gResp); err != nil {
				if attempt == maxRetries {
					return ""
				}
				time.Sleep(time.Second * time.Duration(attempt))
				continue
			}
			if len(gResp.Candidates) == 0 || len(gResp.Candidates[0].Content.Parts) == 0 {
				if attempt == maxRetries {
					return ""
				}
				time.Sleep(time.Second * time.Duration(attempt))
				continue
			}
			return gResp.Candidates[0].Content.Parts[0].Text
		}

		if lowerProvider == "claude" {
			var cResp struct {
				Content []struct {
					Text string `json:"text"`
				} `json:"content"`
			}
			if err = json.Unmarshal(bodyBytes, &cResp); err != nil {
				if attempt == maxRetries {
					return ""
				}
				time.Sleep(time.Second * time.Duration(attempt))
				continue
			}
			if len(cResp.Content) == 0 {
				if attempt == maxRetries {
					return ""
				}
				time.Sleep(time.Second * time.Duration(attempt))
				continue
			}
			return cResp.Content[0].Text
		}

		if useResp {
			var respBody struct {
				OutputText string `json:"output_text"`
			}
			if err = json.Unmarshal(bodyBytes, &respBody); err != nil {
				if attempt == maxRetries {
					return ""
				}
				time.Sleep(time.Second * time.Duration(attempt))
				continue
			}
			if respBody.OutputText == "" {
				if attempt == maxRetries {
					return ""
				}
				time.Sleep(time.Second * time.Duration(attempt))
				continue
			}
			return respBody.OutputText
		}

		var apiResp response
		if err = json.Unmarshal(bodyBytes, &apiResp); err != nil {
			if attempt == maxRetries {
				return ""
			}
			time.Sleep(time.Second * time.Duration(attempt))
			continue
		}
		if len(apiResp.Choices) == 0 {
			if attempt == maxRetries {
				return ""
			}
			time.Sleep(time.Second * time.Duration(attempt))
			continue
		}
		return apiResp.Choices[0].Message.Content
	}

	return ""
}

func extractCode(response, language string) string {
	re := regexp.MustCompile(fmt.Sprintf(`(?s)\x60\x60\x60%s\s*(.*?)\x60\x60\x60`, regexp.QuoteMeta(language)))
	matches := re.FindStringSubmatch(response)
	if len(matches) > 1 {
		return strings.TrimSpace(matches[1])
	}
	re = regexp.MustCompile(`(?s)\x60\x60\x60\s*(.*?)\x60\x60\x60`)
	matches = re.FindStringSubmatch(response)
	if len(matches) > 1 {
		return strings.TrimSpace(matches[1])
	}
	return strings.TrimSpace(response)
}

func latexToPlain(text string) string {
	re := regexp.MustCompile(`\$\$\$(.*?)\$\$\$`)
	return re.ReplaceAllStringFunc(text, func(m string) string {
		sub := re.FindStringSubmatch(m)[1]

		if strings.Contains(sub, `\\begin{array}`) {
			arrRe := regexp.MustCompile(`(?s)\\begin{array}{[^}]*}(.*?)\\end{array}`)
			sub = arrRe.ReplaceAllStringFunc(sub, func(t string) string {
				inner := arrRe.FindStringSubmatch(t)[1]
				inner = strings.ReplaceAll(inner, `\\hline`, "")
				inner = strings.ReplaceAll(inner, `\\\\`, "\n")
				inner = strings.ReplaceAll(inner, `&`, " ")
				textRe := regexp.MustCompile(`\\text{([^{}]*)}`)
				inner = textRe.ReplaceAllString(inner, "$1")
				inner = strings.ReplaceAll(inner, `\\`, "")
				inner = strings.ReplaceAll(inner, "{", "")
				inner = strings.ReplaceAll(inner, "}", "")
				return inner
			})
			return sub
		}

		sub = strings.ReplaceAll(sub, `\left`, "")
		sub = strings.ReplaceAll(sub, `\right`, "")

		replacements := map[string]string{
			`\leq`:   "<=",
			`\le`:    "<=",
			`\geq`:   ">=",
			`\ge`:    ">=",
			`\cdot`:  "*",
			`\times`: "x",
			`\dots`:  "...",
		}
		for old, val := range replacements {
			sub = strings.ReplaceAll(sub, old, val)
		}

		fracRe := regexp.MustCompile(`\\frac{([^{}]+)}{([^{}]+)}`)
		sub = fracRe.ReplaceAllString(sub, "$1/$2")
		sub = strings.ReplaceAll(sub, `\lceil`, "ceil(")
		sub = strings.ReplaceAll(sub, `\rceil`, ")")

		textRe := regexp.MustCompile(`\\text{([^{}]*)}`)
		sub = textRe.ReplaceAllString(sub, "$1")

		sub = strings.ReplaceAll(sub, "\\", "")
		sub = strings.ReplaceAll(sub, "left", "")
		sub = strings.ReplaceAll(sub, "right", "")
		sub = strings.ReplaceAll(sub, "{", "")
		sub = strings.ReplaceAll(sub, "}", "")
		sub = strings.ReplaceAll(sub, " ", "")
		return sub
	})
}

func ensureKafkaTopics(ctx context.Context, brokers []string, topics map[string]int) error {
	if len(brokers) == 0 || len(topics) == 0 {
		return nil
	}
	conn, err := kafka.DialContext(ctx, "tcp", brokers[0])
	if err != nil {
		return err
	}
	defer conn.Close()

	var configs []kafka.TopicConfig
	for topic, partitions := range topics {
		if strings.TrimSpace(topic) == "" {
			continue
		}
		p := clampInt(partitions, 1, 256)
		configs = append(configs, kafka.TopicConfig{
			Topic:             topic,
			NumPartitions:     p,
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
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
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

func getenvInt(key string, def int) int {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func getenvDuration(key string, def time.Duration) time.Duration {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
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

func normalizeLang(lang string) string {
	lang = strings.ToLower(strings.TrimSpace(lang))
	switch lang {
	case "py":
		return "python"
	case "rs":
		return "rust"
	case "cpp":
		return "c++"
	}
	return lang
}

func clampInt(val, min, max int) int {
	if val < min {
		return min
	}
	if val > max {
		return max
	}
	return val
}
