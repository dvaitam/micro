package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "github.com/go-sql-driver/mysql"
	_ "github.com/lib/pq"
)

type config struct {
	apiBase         string
	postgresDSN     string
	mysqlDSN        string
	users           int
	workers         int
	problemsPerSec  int
	interval        time.Duration
	duration        time.Duration
	problemLimit    int
	lang            string
	codePath        string
	emailPrefix     string
	emailDomain     string
	otpWait         time.Duration
	otpPollInterval time.Duration
	requestTimeout  time.Duration
	statsInterval   time.Duration
	seed            int64
	keepRefreshing  bool
}

type problem struct {
	contestID string
	index     string
}

type user struct {
	email        string
	accessToken  string
	refreshToken string
	mu           sync.Mutex
}

type stats struct {
	attempts     int64
	successes    int64
	failures     int64
	unauthorized int64
	refreshes    int64
	latencyNanos int64
}

type submissionJob struct {
	problem problem
	user    *user
}

type requestOTPBody struct {
	Email string `json:"email"`
}

type verifyOTPBody struct {
	Email string `json:"email"`
	Code  string `json:"code"`
}

type verifyOTPResp struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

type refreshBody struct {
	RefreshToken string `json:"refresh_token"`
}

type refreshResp struct {
	AccessToken string `json:"access_token"`
}

type submissionBody struct {
	ContestID string `json:"contest_id"`
	Index     string `json:"index"`
	Lang      string `json:"lang"`
	Code      string `json:"code"`
}

func main() {
	cfg := config{}
	flag.StringVar(&cfg.apiBase, "api-base", "http://localhost:8082", "Base URL for codeforces-api")
	flag.StringVar(&cfg.postgresDSN, "postgres-dsn", "postgres://postgres:sFW4fa93yBoHK0JX1BPf7FOrBz0eK6Mg8qkfnDCJ7CiRTQWLbpTDDKdrc4zYlysU@10.111.18.154:5432/codeforces?sslmode=require", "Postgres DSN for problems DB")
	flag.StringVar(&cfg.mysqlDSN, "mysql-dsn", os.Getenv("MYSQL_DSN"), "MySQL DSN for OTP lookup (defaults to MYSQL_DSN env)")
	flag.IntVar(&cfg.users, "users", 10, "Number of users to register/login")
	flag.IntVar(&cfg.workers, "workers", 0, "Number of concurrent submission workers (0 = users)")
	flag.IntVar(&cfg.problemsPerSec, "problems-per-second", 1, "Target submissions per second")
	flag.DurationVar(&cfg.interval, "interval", 2*time.Second, "Dispatch interval for submissions")
	flag.DurationVar(&cfg.duration, "duration", 0, "How long to run (0 = until interrupted)")
	flag.IntVar(&cfg.problemLimit, "problem-limit", 200, "How many problems to sample from Postgres")
	flag.StringVar(&cfg.lang, "lang", "go", "Language for submissions")
	flag.StringVar(&cfg.codePath, "code-path", "", "Optional path to source code to submit")
	flag.StringVar(&cfg.emailPrefix, "email-prefix", "loadtest", "Email prefix for generated users")
	flag.StringVar(&cfg.emailDomain, "email-domain", "example.com", "Email domain for generated users")
	flag.DurationVar(&cfg.otpWait, "otp-wait", 30*time.Second, "Max time to wait for OTP")
	flag.DurationVar(&cfg.otpPollInterval, "otp-poll-interval", 250*time.Millisecond, "Polling interval for OTP lookup")
	flag.DurationVar(&cfg.requestTimeout, "request-timeout", 15*time.Second, "HTTP request timeout")
	flag.DurationVar(&cfg.statsInterval, "stats-interval", 10*time.Second, "How often to print stats")
	flag.Int64Var(&cfg.seed, "seed", time.Now().UnixNano(), "Random seed")
	flag.BoolVar(&cfg.keepRefreshing, "refresh-on-401", true, "Refresh tokens when submissions get 401")
	flag.Parse()

	if cfg.mysqlDSN == "" {
		fatalf("mysql-dsn is required (or set MYSQL_DSN)")
	}
	if cfg.users <= 0 {
		fatalf("users must be > 0")
	}
	if cfg.problemsPerSec <= 0 {
		fatalf("problems-per-second must be > 0")
	}
	if cfg.interval <= 0 {
		fatalf("interval must be > 0")
	}
	if cfg.workers <= 0 {
		cfg.workers = cfg.users
	}

	code := defaultCode()
	if cfg.codePath != "" {
		data, err := os.ReadFile(cfg.codePath)
		if err != nil {
			fatalf("read code-path: %v", err)
		}
		code = string(data)
		if strings.TrimSpace(code) == "" {
			fatalf("code-path was empty")
		}
	}

	rand.Seed(cfg.seed)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	postgresDB, err := sql.Open("postgres", cfg.postgresDSN)
	if err != nil {
		fatalf("postgres connect: %v", err)
	}
	defer postgresDB.Close()
	if err := postgresDB.Ping(); err != nil {
		fatalf("postgres ping: %v", err)
	}

	mysqlDB, err := sql.Open("mysql", cfg.mysqlDSN)
	if err != nil {
		fatalf("mysql connect: %v", err)
	}
	defer mysqlDB.Close()
	if err := mysqlDB.Ping(); err != nil {
		fatalf("mysql ping: %v", err)
	}

	problems, err := loadProblems(ctx, postgresDB, cfg.problemLimit)
	if err != nil {
		fatalf("load problems: %v", err)
	}
	if len(problems) == 0 {
		fatalf("no problems found in postgres")
	}

	client := &http.Client{Timeout: cfg.requestTimeout}

	users, err := registerUsers(ctx, client, mysqlDB, cfg, cfg.users)
	if err != nil {
		fatalf("register users: %v", err)
	}

	jobs := make(chan submissionJob, cfg.workers*4)
	var wg sync.WaitGroup
	stats := &stats{}

	for i := 0; i < cfg.workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range jobs {
				sendSubmission(ctx, client, cfg, job, code, stats)
			}
		}()
	}

	statsCtx, statsCancel := context.WithCancel(ctx)
	go printStats(statsCtx, stats, cfg.statsInterval)

	dispatchCtx := ctx
	if cfg.duration > 0 {
		var cancel context.CancelFunc
		dispatchCtx, cancel = context.WithTimeout(ctx, cfg.duration)
		defer cancel()
	}

	dispatchSubmissions(dispatchCtx, jobs, users, problems, cfg)
	close(jobs)
	wg.Wait()
	statsCancel()

	printFinalStats(stats)
}

func loadProblems(ctx context.Context, db *sql.DB, limit int) ([]problem, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := db.QueryContext(ctx, `
		SELECT contest_id, index_name
		FROM problems
		ORDER BY random()
		LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var problems []problem
	for rows.Next() {
		var p problem
		if err := rows.Scan(&p.contestID, &p.index); err != nil {
			return nil, err
		}
		problems = append(problems, p)
	}
	return problems, rows.Err()
}

func registerUsers(ctx context.Context, client *http.Client, mysqlDB *sql.DB, cfg config, count int) ([]*user, error) {
	users := make([]*user, 0, count)
	for i := 0; i < count; i++ {
		email := fmt.Sprintf("%s+%d-%d@%s", cfg.emailPrefix, time.Now().UnixNano(), i, cfg.emailDomain)
		if err := requestOTP(ctx, client, cfg.apiBase, email); err != nil {
			return nil, err
		}
		code, err := waitForOTP(ctx, mysqlDB, email, cfg.otpWait, cfg.otpPollInterval)
		if err != nil {
			return nil, err
		}
		access, refresh, err := verifyOTP(ctx, client, cfg.apiBase, email, code)
		if err != nil {
			return nil, err
		}
		users = append(users, &user{email: email, accessToken: access, refreshToken: refresh})
	}
	return users, nil
}

func requestOTP(ctx context.Context, client *http.Client, baseURL, email string) error {
	payload := requestOTPBody{Email: email}
	return doJSONRequest(ctx, client, http.MethodPost, baseURL+"/auth/request-otp", payload, nil, nil)
}

func waitForOTP(ctx context.Context, db *sql.DB, email string, wait, poll time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()
	var code string
	for {
		err := db.QueryRowContext(ctx, `SELECT code FROM otp_codes WHERE email = ?`, email).Scan(&code)
		if err == nil && strings.TrimSpace(code) != "" {
			return code, nil
		}
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return "", err
		}
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("otp wait timeout for %s", email)
		case <-time.After(poll):
		}
	}
}

func verifyOTP(ctx context.Context, client *http.Client, baseURL, email, code string) (string, string, error) {
	payload := verifyOTPBody{Email: email, Code: code}
	var resp verifyOTPResp
	if err := doJSONRequest(ctx, client, http.MethodPost, baseURL+"/auth/verify-otp", payload, &resp, nil); err != nil {
		return "", "", err
	}
	if strings.TrimSpace(resp.AccessToken) == "" || strings.TrimSpace(resp.RefreshToken) == "" {
		return "", "", fmt.Errorf("missing tokens from verify-otp")
	}
	return resp.AccessToken, resp.RefreshToken, nil
}

func refreshAccessToken(ctx context.Context, client *http.Client, baseURL, refreshToken string) (string, error) {
	payload := refreshBody{RefreshToken: refreshToken}
	var resp refreshResp
	if err := doJSONRequest(ctx, client, http.MethodPost, baseURL+"/auth/refresh", payload, &resp, nil); err != nil {
		return "", err
	}
	if strings.TrimSpace(resp.AccessToken) == "" {
		return "", fmt.Errorf("missing access token from refresh")
	}
	return resp.AccessToken, nil
}

func sendSubmission(ctx context.Context, client *http.Client, cfg config, job submissionJob, code string, stats *stats) {
	atomic.AddInt64(&stats.attempts, 1)
	start := time.Now()
	payload := submissionBody{
		ContestID: job.problem.contestID,
		Index:     job.problem.index,
		Lang:      cfg.lang,
		Code:      code,
	}

	status, err := submitWithToken(ctx, client, cfg.apiBase, job.user, payload)
	if status == http.StatusUnauthorized && cfg.keepRefreshing {
		atomic.AddInt64(&stats.unauthorized, 1)
		if refreshed := tryRefreshToken(ctx, client, cfg.apiBase, job.user, stats); refreshed {
			status, err = submitWithToken(ctx, client, cfg.apiBase, job.user, payload)
		}
		if err != nil || status >= 400 {
			atomic.AddInt64(&stats.failures, 1)
		} else {
			atomic.AddInt64(&stats.successes, 1)
		}
	} else if err != nil || status >= 400 {
		atomic.AddInt64(&stats.failures, 1)
	} else {
		atomic.AddInt64(&stats.successes, 1)
	}

	atomic.AddInt64(&stats.latencyNanos, time.Since(start).Nanoseconds())
}

func submitWithToken(ctx context.Context, client *http.Client, baseURL string, u *user, payload submissionBody) (int, error) {
	token := u.getAccessToken()
	headers := map[string]string{
		"Authorization": "Bearer " + token,
	}
	return doJSONRequestWithStatus(ctx, client, http.MethodPost, baseURL+"/submissions", payload, nil, headers)
}

func tryRefreshToken(ctx context.Context, client *http.Client, baseURL string, u *user, stats *stats) bool {
	u.mu.Lock()
	refreshToken := u.refreshToken
	u.mu.Unlock()
	if refreshToken == "" {
		return false
	}
	access, err := refreshAccessToken(ctx, client, baseURL, refreshToken)
	if err != nil {
		return false
	}
	u.mu.Lock()
	u.accessToken = access
	u.mu.Unlock()
	atomic.AddInt64(&stats.refreshes, 1)
	return true
}

func (u *user) getAccessToken() string {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.accessToken
}

func dispatchSubmissions(ctx context.Context, jobs chan<- submissionJob, users []*user, problems []problem, cfg config) {
	interval := cfg.interval
	if interval <= 0 {
		interval = 2 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	carry := 0.0
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			carry += float64(cfg.problemsPerSec) * interval.Seconds()
			count := int(math.Floor(carry))
			if count <= 0 {
				continue
			}
			carry -= float64(count)
			for i := 0; i < count; i++ {
				job := submissionJob{
					problem: problems[rand.Intn(len(problems))],
					user:    users[rand.Intn(len(users))],
				}
				select {
				case <-ctx.Done():
					return
				case jobs <- job:
				}
			}
		}
	}
}

func doJSONRequest(ctx context.Context, client *http.Client, method, url string, payload any, out any, headers map[string]string) error {
	_, err := doJSONRequestWithStatus(ctx, client, method, url, payload, out, headers)
	return err
}

func doJSONRequestWithStatus(ctx context.Context, client *http.Client, method, url string, payload any, out any, headers map[string]string) (int, error) {
	var body io.Reader
	if payload != nil {
		buf, err := json.Marshal(payload)
		if err != nil {
			return 0, err
		}
		body = bytes.NewBuffer(buf)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return 0, err
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		msg, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, fmt.Errorf("http %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	if out != nil {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			return resp.StatusCode, err
		}
	}
	return resp.StatusCode, nil
}

func printStats(ctx context.Context, s *stats, interval time.Duration) {
	if interval <= 0 {
		interval = 10 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			attempts := atomic.LoadInt64(&s.attempts)
			successes := atomic.LoadInt64(&s.successes)
			failures := atomic.LoadInt64(&s.failures)
			unauthorized := atomic.LoadInt64(&s.unauthorized)
			refreshes := atomic.LoadInt64(&s.refreshes)
			avgLatency := averageLatency(s)
			fmt.Printf("stats attempts=%d success=%d fail=%d 401=%d refresh=%d avg_latency=%s\n", attempts, successes, failures, unauthorized, refreshes, avgLatency)
		}
	}
}

func printFinalStats(s *stats) {
	attempts := atomic.LoadInt64(&s.attempts)
	successes := atomic.LoadInt64(&s.successes)
	failures := atomic.LoadInt64(&s.failures)
	unauthorized := atomic.LoadInt64(&s.unauthorized)
	refreshes := atomic.LoadInt64(&s.refreshes)
	avgLatency := averageLatency(s)
	fmt.Printf("final attempts=%d success=%d fail=%d 401=%d refresh=%d avg_latency=%s\n", attempts, successes, failures, unauthorized, refreshes, avgLatency)
}

func averageLatency(s *stats) time.Duration {
	attempts := atomic.LoadInt64(&s.attempts)
	if attempts == 0 {
		return 0
	}
	nanos := atomic.LoadInt64(&s.latencyNanos)
	return time.Duration(nanos / attempts)
}

func defaultCode() string {
	return `package main

import "fmt"

func main() {
	fmt.Println("0")
}
`
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
