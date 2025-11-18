## OTP Login + Chat Microservices

This stack now provides OTP-based authentication and a WebSocket chat service on top of the existing Kafka-driven email worker.

### Prerequisites
- Docker and Docker Compose installed locally.
- Mailgun credentials that can send email from the configured domain.

### Services
- `registration-api` (port `8082` → container `8080`): serves OTP request/verify forms, manages sessions in MySQL, and renders the chat UI.
- `email-worker`: consumes `new-registration` topic from Kafka, generates 6-digit OTPs, stores them in MySQL for 3 minutes, and emails the code via Mailgun.
- `chat-service` (port `8083`): validates session tokens, upgrades clients to WebSockets, tracks online users, and fans out chat messages via Redis pub/sub.
- `rtc-service` (port `8085`): lightweight WebRTC signaling + TURN credential service that issues call sessions, stores offers/answers/ICE candidates in-memory, and hands out short-lived TURN credentials for browsers/iOS clients.
- `turn-server` (ports `3478` + UDP relay range `49160-49200`): coturn configured for long-term credentials using a shared secret so media can flow when peers are behind restrictive NATs.
- `redis`: message broker for the chat service (port `6379` exposed for local inspection if needed).
- `mysql`: stores auth/session data for the API, worker, and chat service (`3306` exposed for convenience).
- `cassandra`: stores chat history for `message-service`.
- `kafka` + `zookeeper`: run the `new-registration` topic used by the `email-worker`; `kafka:9092` is wired into the services by default.

### Running the stack
1. (Optional) Adjust DSNs, ports, or Mailgun settings in `docker-compose.yml`.
2. Start the services:
   ```bash
   docker-compose up --build
   ```
3. Visit `http://localhost:8082/` to request an OTP. After verifying the code (valid for 3 minutes), you will be redirected to `/chat` with a session cookie.
4. Open the chat UI in multiple browsers using different accounts to see presence updates and exchange messages in real time.

### WebRTC signaling + TURN
`rtc-service` exposes a simple HTTP API:

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/sessions` | `POST` | Create a call session. Body requires `initiator` and optional `conversation_id`. Response includes the session payload plus an initial set of TURN credentials for the initiator. |
| `/sessions/{id}` | `GET` | Fetch the latest offer, answer, and ICE candidates. Add `?participant=email@example.com` to also mint TURN credentials for that participant. |
| `/sessions/{id}` | `DELETE` | Tear down an active call session immediately. |
| `/sessions/{id}/offer` | `PUT` | Store/replace the SDP offer (body: `{ \"from\": \"...\", \"sdp\": \"...\" }`). |
| `/sessions/{id}/answer` | `PUT` | Store/replace the SDP answer. |
| `/sessions/{id}/candidates` | `POST` | Append a single ICE candidate for the caller identified by `from`. |

Sessions expire after 15 minutes of inactivity by default (`SESSION_TTL_SECONDS`). Every mutation (offer/answer/candidate) keeps the session alive, so mobile/web clients can simply poll `/sessions/{id}` while negotiating.

Set these environment variables (either exported before `docker compose up` or placed in an `.env` file):

- `TURN_SHARED_SECRET`: required. Used both by `turn-server` (coturn) and `rtc-service` to mint long-term TURN credentials. Defaults to `devsecret` for local play but **must** be overridden in any shared environment.
- `TURN_SERVER_URLS`: optional CSV override for the ICE server list exposed to clients (defaults to `turn:localhost:3478?...` so browsers can reach the bundled coturn instance published on the host).
- `TURN_CREDENTIAL_TTL`: life span of TURN usernames/passwords in seconds (default 600).
- `SESSION_TTL_SECONDS`: inactivity timeout for signaling sessions (default 900).
- `CORS_ALLOWED_ORIGINS`: CSV of browser origins that may call the signaling REST API. When unset it allows `http://localhost:5173` and `http://127.0.0.1:5173`; in production wire this to the same list as `CHAT_WEB_ORIGIN` via `.env` (see docker-compose).
- `CHAT_RTC_BASE_URL`: optional build arg/env var that `chat-web` reads to reach the signaling API (defaults to `https://webrtc.manchik.co.uk`).

The public TLS endpoints terminate on the host nginx instance:
- `https://webrtc.manchik.co.uk` → proxies to `rtc-service` (REST signaling + TURN credential minting).
- `https://turn.manchik.co.uk` → shares the same API surface for credential hydration while the actual TURN media relaying stays on `turn.manchik.co.uk:3478` (UDP/TCP). Configure clients with `turn:turn.manchik.co.uk:3478?transport=udp` and `turn:turn.manchik.co.uk:3478?transport=tcp` (or the TLS port if you front it with 443).

`chat-web` now exposes “Start video call” controls per conversation. When you start a call it creates an RTC session via `https://webrtc.manchik.co.uk`, signals the invite over the existing WebSocket channel, and automatically rings other participants. Accept/decline/end actions are also relayed over WebSockets while SDP/ICE payloads are persisted in `rtc-service` so both web and iOS clients can join.

### Notes
- Container images compile with Go 1.24; local `go build` may require Go ≥1.21 because dependencies rely on `errors.Join`.
- If you need to adjust DSNs or ports, update `docker-compose.yml` and rebuild.
- Redis pub/sub is only used for live traffic; message persistence or history is out of scope.
- For TURN in production you’ll typically point `TURN_SERVER_URLS` at a public IP/DNS that routes to a hardened coturn instance and open the UDP relay range in your firewall—the built-in `localhost` defaults only work for local development on the same machine that runs Docker.
