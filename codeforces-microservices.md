## Codeforces microservices

This stack adds a small set of services that work only off the database rows for problem statements, reference solutions, and verifiers.

- `codeforces-api` (Go, port `8082` by default): REST for listing problems and creating submissions, WebSocket fan-out for status updates, and Kafka producer/consumer wiring. It stores submissions immediately and returns right away on POST. Status changes flow through Kafka and are pushed to browsers over WebSockets.
- `codeforces-worker` (Go): Kafka consumer for the submission topic. It flips submissions to `processing`, simulates a verifier run (placeholder), and publishes status updates to Kafka.
- `codeforces-web` (Next.js): Front-end that reads problems from the API, posts submissions, and streams status updates over WebSockets.

### Topics and schema
- Kafka submission topic: `cf.submissions` (override with `KAFKA_SUBMISSION_TOPIC`).
- Kafka status topic: `cf.submission_status` (override with `KAFKA_STATUS_TOPIC`).
- The API ensures the `submissions` table exists and adds `status`, `verdict`, and `updated_at` columns if they are missing.

### Running locally
1. Start Kafka + Postgres (matches the existing DB used by `sync_problems.go`).
2. API:
   ```bash
   cd /home/ubuntu/micro/codeforces-api
   DB_DSN="postgres://postgres:password@localhost:5432/codeforces?sslmode=disable" \
   KAFKA_BROKERS="localhost:9092" \
   go run .
   ```
3. Worker:
   ```bash
   cd /home/ubuntu/micro/codeforces-worker
   DB_DSN="postgres://postgres:password@localhost:5432/codeforces?sslmode=disable" \
   KAFKA_BROKERS="localhost:9092" \
   go run .
   ```
4. Web:
   ```bash
   cd /home/ubuntu/micro/codeforces-web
   npm install
   NEXT_PUBLIC_API_URL="http://localhost:8082" \
   NEXT_PUBLIC_WS_URL="ws://localhost:8082/ws" \
   npm run dev
   ```

### Notes
- The worker currently stubs verifier execution; wire in your actual compile/run logic inside `handleSubmission`.
- The WebSocket endpoint is `/ws?submissionId=<id>`; the front-end subscribes per submission.
- All services default to `localhost` Kafka and Postgres if the env vars are not set.
