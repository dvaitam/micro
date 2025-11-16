## OTP Login + Chat Microservices

This stack now provides OTP-based authentication and a WebSocket chat service on top of the existing Kafka-driven email worker.

### Prerequisites
- MySQL running on the host with database `micro_auth` created and reachable from Docker (DSN defaults to `root:password@tcp(host.docker.internal:3306)/micro_auth?parseTime=true`).
- Kafka cluster reachable at `192.168.68.103:9092`.
- Mailgun credentials that can send email from the configured domain.

### Services
- `registration-api` (port `8082` → container `8080`): serves OTP request/verify forms, manages sessions in MySQL, and renders the chat UI.
- `email-worker`: consumes `new-registration` topic from Kafka, generates 6-digit OTPs, stores them in MySQL for 3 minutes, and emails the code via Mailgun.
- `chat-service` (port `8083`): validates session tokens, upgrades clients to WebSockets, tracks online users, and fans out chat messages via Redis pub/sub.
- `redis`: message broker for the chat service (port `6379` exposed for local inspection if needed).

### Running the stack
1. Ensure the MySQL database exists and credentials match the DSN in `docker-compose.yml`.
2. Start the services:
   ```bash
   docker-compose up --build
   ```
3. Visit `http://localhost:8082/` to request an OTP. After verifying the code (valid for 3 minutes), you will be redirected to `/chat` with a session cookie.
4. Open the chat UI in multiple browsers using different accounts to see presence updates and exchange messages in real time.

### Notes
- Container images compile with Go 1.24; local `go build` may require Go ≥1.21 because dependencies rely on `errors.Join`.
- If you need to adjust DSNs or ports, update `docker-compose.yml` and rebuild.
- Redis pub/sub is only used for live traffic; message persistence or history is out of scope.
