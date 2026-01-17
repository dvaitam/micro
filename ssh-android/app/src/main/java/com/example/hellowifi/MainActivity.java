package com.example.hellowifi;

import android.content.SharedPreferences;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.MotionEvent;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;
import android.util.Log;

import androidx.appcompat.app.AppCompatActivity;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.IOException;
import java.util.Locale;

import okhttp3.Call;
import okhttp3.Callback;
import okhttp3.HttpUrl;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;

public class MainActivity extends AppCompatActivity {
    private static final MediaType JSON = MediaType.parse("application/json; charset=utf-8");
    private static final String DEFAULT_AUTH_BASE_URL = "https://ssh.manchik.co.uk";
    private static final String DEFAULT_SSH_BASE_URL = "https://ssh.manchik.co.uk";
    private static final String TAG = "HelloWifi";

    private OkHttpClient client;
    private Gson gson;
    private SharedPreferences prefs;

    private EditText authBaseUrlInput;
    private EditText sshBaseUrlInput;
    private EditText emailInput;
    private EditText otpInput;
    private TextView statusText;
    private LinearLayout connectionsContainer;
    private TextView selectedConnectionText;
    private LinearLayout loginSection;

    private EditText newName;
    private EditText newHost;
    private EditText newPort;
    private EditText newUsername;
    private EditText newPassword;
    private EditText newPrivateKey;
    private EditText newPassphrase;

    private EditText commandInput;
    private EditText keepaliveInput;
    private TextView commandOutput;
    private Button runCommandButton;
    private ProgressBar runProgress;
    private LinearLayout liveContainer;
    private FrameLayout trackpadArea;
    private TextView trackpadStatus;

    private String accessToken = "";
    private String sessionToken = "";
    private String email = "";
    private int selectedConnectionId = -1;

    private WebSocket liveWs;
    private WebSocket controlWs;
    private int controlWsConnId = -1;
    private long lastTrackpadSend = 0L;
    private float lastX = 0f;
    private float lastY = 0f;
    private boolean trackpadActive = false;
    private boolean runInProgress = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        client = new OkHttpClient();
        gson = new Gson();
        prefs = getSharedPreferences("ssh_web_prefs", MODE_PRIVATE);

        bindViews();
        loadPrefs();
        wireActions();
        updateLoginUi();

        if (!TextUtils.isEmpty(sessionToken)) {
            refreshSession();
        }
    }

    private void bindViews() {
        loginSection = findViewById(R.id.loginSection);
        authBaseUrlInput = findViewById(R.id.authBaseUrl);
        sshBaseUrlInput = findViewById(R.id.sshBaseUrl);
        emailInput = findViewById(R.id.email);
        otpInput = findViewById(R.id.otp);
        statusText = findViewById(R.id.status);
        connectionsContainer = findViewById(R.id.connectionsContainer);
        selectedConnectionText = findViewById(R.id.selectedConnection);

        newName = findViewById(R.id.newName);
        newHost = findViewById(R.id.newHost);
        newPort = findViewById(R.id.newPort);
        newUsername = findViewById(R.id.newUsername);
        newPassword = findViewById(R.id.newPassword);
        newPrivateKey = findViewById(R.id.newPrivateKey);
        newPassphrase = findViewById(R.id.newPassphrase);

        commandInput = findViewById(R.id.command);
        keepaliveInput = findViewById(R.id.keepalive);
        commandOutput = findViewById(R.id.commandOutput);
        runCommandButton = findViewById(R.id.runCommand);
        runProgress = findViewById(R.id.runProgress);

        liveContainer = findViewById(R.id.liveContainer);
        trackpadArea = findViewById(R.id.trackpadArea);
        trackpadStatus = findViewById(R.id.trackpadStatus);
    }

    private void wireActions() {
        Button saveBaseUrl = findViewById(R.id.saveBaseUrl);
        saveBaseUrl.setOnClickListener(v -> saveBaseUrls());

        Button requestOtp = findViewById(R.id.requestOtp);
        requestOtp.setOnClickListener(v -> requestOtp());

        Button verifyOtp = findViewById(R.id.verifyOtp);
        verifyOtp.setOnClickListener(v -> verifyOtp());

        Button refreshConnections = findViewById(R.id.refreshConnections);
        refreshConnections.setOnClickListener(v -> loadConnections());

        Button createConn = findViewById(R.id.createConnection);
        createConn.setOnClickListener(v -> createConnection());

        runCommandButton.setOnClickListener(v -> {
            Log.i(TAG, "Run clicked");
            runCommandStream();
        });

        Button refreshLive = findViewById(R.id.refreshLive);
        refreshLive.setOnClickListener(v -> loadLive());

        Button clickOnce = findViewById(R.id.clickOnce);
        clickOnce.setOnClickListener(v -> sendClick(1));

        Button clickDouble = findViewById(R.id.clickDouble);
        clickDouble.setOnClickListener(v -> sendClick(2));

        trackpadArea.setOnTouchListener((v, event) -> handleTrackpadTouch(event));
    }

    private void loadPrefs() {
        String authBase = prefs.getString("auth_base_url", "");
        String sshBase = prefs.getString("ssh_base_url", "");
        sessionToken = prefs.getString("session_token", "");
        email = prefs.getString("email", "");

        if (TextUtils.isEmpty(authBase)) {
            authBase = DEFAULT_AUTH_BASE_URL;
        }
        if (TextUtils.isEmpty(sshBase)) {
            sshBase = DEFAULT_SSH_BASE_URL;
        }
        prefs.edit()
            .putString("auth_base_url", authBase)
            .putString("ssh_base_url", sshBase)
            .apply();

        authBaseUrlInput.setText(authBase);
        sshBaseUrlInput.setText(sshBase);
        emailInput.setText(email);
    }

    private void saveBaseUrls() {
        String authBase = getAuthBaseUrl();
        String sshBase = getSshBaseUrl();
        prefs.edit()
            .putString("auth_base_url", authBase)
            .putString("ssh_base_url", sshBase)
            .apply();
        setStatus("Saved base URLs");
    }

    private String getAuthBaseUrl() {
        String input = authBaseUrlInput.getText().toString().trim();
        String normalized = normalizeBaseUrl(input);
        if (!TextUtils.isEmpty(normalized)) return normalized;
        String fromPrefs = normalizeBaseUrl(prefs.getString("auth_base_url", ""));
        if (!TextUtils.isEmpty(fromPrefs)) return fromPrefs;
        return DEFAULT_AUTH_BASE_URL;
    }

    private String getSshBaseUrl() {
        String input = sshBaseUrlInput.getText().toString().trim();
        String normalized = normalizeBaseUrl(input);
        if (!TextUtils.isEmpty(normalized)) return normalized;
        String fromPrefs = normalizeBaseUrl(prefs.getString("ssh_base_url", ""));
        if (!TextUtils.isEmpty(fromPrefs)) return fromPrefs;
        return getAuthBaseUrl();
    }

    private void requestOtp() {
        String base = getAuthBaseUrl();
        String emailValue = emailInput.getText().toString().trim();
        if (TextUtils.isEmpty(base) || TextUtils.isEmpty(emailValue)) {
            setStatus("Enter base URL and email");
            return;
        }
        JsonObject payload = new JsonObject();
        payload.addProperty("email", emailValue);
        RequestBody body = RequestBody.create(payload.toString(), JSON);
        HttpUrl url = buildUrl(base, "/api/request-otp");
        if (url == null) return;
        Request request = new Request.Builder()
            .url(url)
            .post(body)
            .build();
        client.newCall(request).enqueue(new SimpleCallback("OTP requested"));
    }

    private void verifyOtp() {
        String base = getAuthBaseUrl();
        String emailValue = emailInput.getText().toString().trim();
        String otpValue = otpInput.getText().toString().trim();
        if (TextUtils.isEmpty(base) || TextUtils.isEmpty(emailValue) || TextUtils.isEmpty(otpValue)) {
            setStatus("Enter base URL, email, and OTP");
            return;
        }
        JsonObject payload = new JsonObject();
        payload.addProperty("email", emailValue);
        payload.addProperty("otp", otpValue);
        RequestBody body = RequestBody.create(payload.toString(), JSON);
        HttpUrl url = buildUrl(base, "/api/verify-otp");
        if (url == null) return;
        Request request = new Request.Builder()
            .url(url)
            .post(body)
            .build();
        client.newCall(request).enqueue(new Callback() {
            @Override
            public void onFailure(Call call, IOException e) {
                setStatus("Verify failed: " + e.getMessage());
            }

            @Override
            public void onResponse(Call call, Response response) throws IOException {
                String text = response.body() != null ? response.body().string() : "";
                if (!response.isSuccessful()) {
                    setStatus("Verify failed: " + text);
                    return;
                }
                JsonObject obj = parseJsonObject(text);
                if (obj == null) {
                    setStatus("Verify failed: invalid response");
                    return;
                }
                accessToken = getString(obj, "access_token");
                sessionToken = getString(obj, "session_token");
                email = getString(obj, "email");
                prefs.edit()
                    .putString("session_token", sessionToken)
                    .putString("email", email)
                    .apply();
                runOnUiThread(() -> emailInput.setText(email));
                setStatus("Logged in");
                updateLoginUi();
                loadConnections();
                connectLiveWs();
            }
        });
    }

    private void refreshSession() {
        String base = getAuthBaseUrl();
        if (TextUtils.isEmpty(base) || TextUtils.isEmpty(sessionToken)) {
            return;
        }
        HttpUrl url = buildUrl(base, "/api/session");
        if (url == null) return;
        Request request = new Request.Builder()
            .url(url)
            .header("Authorization", "Bearer " + sessionToken)
            .get()
            .build();
        client.newCall(request).enqueue(new Callback() {
            @Override
            public void onFailure(Call call, IOException e) {
                setStatus("Session refresh failed: " + e.getMessage());
            }

            @Override
            public void onResponse(Call call, Response response) throws IOException {
                String text = response.body() != null ? response.body().string() : "";
                if (!response.isSuccessful()) {
                    setStatus("Session refresh failed");
                    return;
                }
                JsonObject obj = parseJsonObject(text);
                if (obj == null) {
                    setStatus("Session refresh failed: invalid response");
                    return;
                }
                accessToken = getString(obj, "access_token");
                email = getString(obj, "email");
                prefs.edit().putString("email", email).apply();
                runOnUiThread(() -> emailInput.setText(email));
                updateLoginUi();
                connectLiveWs();
                loadConnections();
            }
        });
    }

    private void loadConnections() {
        String base = getSshBaseUrl();
        if (!ensureAuthReady(base)) return;

        HttpUrl url = buildUrl(base, "/api/ssh/connections");
        if (url == null) return;
        Request request = new Request.Builder()
            .url(url)
            .header("Authorization", "Bearer " + accessToken)
            .get()
            .build();
        client.newCall(request).enqueue(new Callback() {
            @Override
            public void onFailure(Call call, IOException e) {
                setStatus("Load failed: " + e.getMessage());
            }

            @Override
            public void onResponse(Call call, Response response) throws IOException {
                String text = response.body() != null ? response.body().string() : "";
                if (!response.isSuccessful()) {
                    setStatus("Load failed: " + text);
                    return;
                }
                JsonObject obj = parseJsonObject(text);
                if (obj == null || !obj.has("connections")) {
                    setStatus("Load failed: invalid response");
                    return;
                }
                JsonArray arr = obj.getAsJsonArray("connections");
                runOnUiThread(() -> renderConnections(arr));
            }
        });
    }

    private void renderConnections(JsonArray arr) {
        connectionsContainer.removeAllViews();
        for (JsonElement el : arr) {
            JsonObject conn = el.getAsJsonObject();
            int id = conn.get("id").getAsInt();
            String name = getString(conn, "name");
            String host = getString(conn, "host");
            String username = getString(conn, "username");
            int port = conn.has("port") ? conn.get("port").getAsInt() : 22;
            Button btn = new Button(this);
            String label = String.format(Locale.US, "#%d %s %s@%s:%d", id, name, username, host, port);
            btn.setText(label);
            btn.setOnClickListener(v -> {
                selectedConnectionId = id;
                selectedConnectionText.setText("Selected: " + id);
                setStatus("Selected connection " + id);
                ensureControlWs(id);
            });
            connectionsContainer.addView(btn);
        }
    }

    private void createConnection() {
        String base = getSshBaseUrl();
        if (!ensureAuthReady(base)) return;

        JsonObject payload = new JsonObject();
        payload.addProperty("name", newName.getText().toString().trim());
        payload.addProperty("host", newHost.getText().toString().trim());
        payload.addProperty("port", parseIntOrDefault(newPort.getText().toString().trim(), 22));
        payload.addProperty("username", newUsername.getText().toString().trim());
        payload.addProperty("password", newPassword.getText().toString());
        payload.addProperty("private_key", newPrivateKey.getText().toString());
        payload.addProperty("passphrase", newPassphrase.getText().toString());

        RequestBody body = RequestBody.create(payload.toString(), JSON);
        HttpUrl url = buildUrl(base, "/api/ssh/connections");
        if (url == null) return;
        Request request = new Request.Builder()
            .url(url)
            .header("Authorization", "Bearer " + accessToken)
            .post(body)
            .build();

        client.newCall(request).enqueue(new Callback() {
            @Override
            public void onFailure(Call call, IOException e) {
                setStatus("Create failed: " + e.getMessage());
            }

            @Override
            public void onResponse(Call call, Response response) throws IOException {
                String text = response.body() != null ? response.body().string() : "";
                if (!response.isSuccessful()) {
                    setStatus("Create failed: " + text);
                    return;
                }
                runOnUiThread(() -> {
                    newName.setText("");
                    newHost.setText("");
                    newPort.setText("");
                    newUsername.setText("");
                    newPassword.setText("");
                    newPrivateKey.setText("");
                    newPassphrase.setText("");
                });
                setStatus("Connection created");
                loadConnections();
            }
        });
    }

    private void runCommandStream() {
        String base = getSshBaseUrl();
        if (!ensureAuthReady(base)) return;
        if (selectedConnectionId <= 0) {
            setStatus("Select a connection first");
            return;
        }

        String cmd = commandInput.getText().toString().trim();
        if (TextUtils.isEmpty(cmd)) {
            setStatus("Enter a command");
            return;
        }
        int keepalive = parseIntOrDefault(keepaliveInput.getText().toString().trim(), 300);

        if (runInProgress) return;
        setRunInProgress(true);
        setStatus("Starting command...");
        HttpUrl httpUrl = buildUrl(base, "/api/ssh/stream");
        if (httpUrl == null) {
            setRunInProgress(false);
            return;
        }
        HttpUrl httpWithQuery = httpUrl
            .newBuilder()
            .addQueryParameter("id", String.valueOf(selectedConnectionId))
            .addQueryParameter("cmd", cmd)
            .addQueryParameter("keepalive_seconds", String.valueOf(keepalive))
            .addQueryParameter("access_token", accessToken)
            .build();
        String wsUrl = toWebSocketUrl(httpWithQuery.toString());

        Request request = new Request.Builder().url(wsUrl).build();
        commandOutput.setText("");
        client.newWebSocket(request, new WebSocketListener() {
            @Override
            public void onOpen(WebSocket webSocket, Response response) {
                Log.d(TAG, "Command WS open");
                setStatus("Command running...");
            }

            @Override
            public void onMessage(WebSocket webSocket, String text) {
                if ("__CMD_DONE__".equals(text)) {
                    Log.d(TAG, "Command done");
                    webSocket.close(1000, "done");
                    setRunInProgress(false);
                    return;
                }
                runOnUiThread(() -> commandOutput.append(text));
            }

            @Override
            public void onFailure(WebSocket webSocket, Throwable t, Response response) {
                Log.e(TAG, "Command WS failure", t);
                setStatus("Stream error: " + t.getMessage());
                setRunInProgress(false);
            }

            @Override
            public void onClosed(WebSocket webSocket, int code, String reason) {
                Log.d(TAG, "Command WS closed: " + reason);
                setRunInProgress(false);
            }
        });
    }

    private void loadLive() {
        String base = getSshBaseUrl();
        if (!ensureAuthReady(base)) return;
        HttpUrl url = buildUrl(base, "/api/ssh/live");
        if (url == null) return;
        Request request = new Request.Builder()
            .url(url)
            .header("Authorization", "Bearer " + accessToken)
            .get()
            .build();

        client.newCall(request).enqueue(new Callback() {
            @Override
            public void onFailure(Call call, IOException e) {
                setStatus("Live load failed: " + e.getMessage());
            }

            @Override
            public void onResponse(Call call, Response response) throws IOException {
                String text = response.body() != null ? response.body().string() : "";
                if (!response.isSuccessful()) {
                    setStatus("Live load failed: " + text);
                    return;
                }
                JsonObject obj = parseJsonObject(text);
                if (obj == null || !obj.has("live")) {
                    setStatus("Live load failed: invalid response");
                    return;
                }
                JsonArray arr = obj.getAsJsonArray("live");
                runOnUiThread(() -> renderLive(arr));
            }
        });
    }

    private void renderLive(JsonArray arr) {
        liveContainer.removeAllViews();
        for (JsonElement el : arr) {
            JsonObject live = el.getAsJsonObject();
            int id = live.get("id").getAsInt();
            String expiresAt = getString(live, "expires_at");
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            TextView label = new TextView(this);
            label.setText("#" + id + " expires " + expiresAt);
            Button disconnect = new Button(this);
            disconnect.setText("Disconnect");
            disconnect.setOnClickListener(v -> disconnectLive(id));
            row.addView(label);
            row.addView(disconnect);
            liveContainer.addView(row);
        }
    }

    private void disconnectLive(int id) {
        String base = getSshBaseUrl();
        if (!ensureAuthReady(base)) return;
        HttpUrl url = buildUrl(base, "/api/ssh/live/" + id);
        if (url == null) return;
        Request request = new Request.Builder()
            .url(url)
            .header("Authorization", "Bearer " + accessToken)
            .delete()
            .build();
        client.newCall(request).enqueue(new SimpleCallback("Disconnected " + id));
    }

    private void connectLiveWs() {
        String base = getSshBaseUrl();
        if (!ensureAuthReady(base)) return;
        if (liveWs != null) {
            liveWs.close(1000, "reconnect");
            liveWs = null;
        }
        HttpUrl httpUrl = buildUrl(base, "/api/ssh/live/ws");
        if (httpUrl == null) return;
        HttpUrl httpWithQuery = httpUrl
            .newBuilder()
            .addQueryParameter("access_token", accessToken)
            .build();
        String wsUrl = toWebSocketUrl(httpWithQuery.toString());
        Request request = new Request.Builder().url(wsUrl).build();
        liveWs = client.newWebSocket(request, new WebSocketListener() {
            @Override
            public void onMessage(WebSocket webSocket, String text) {
                JsonObject obj = parseJsonObject(text);
                if (obj == null || !obj.has("live")) return;
                JsonArray arr = obj.getAsJsonArray("live");
                runOnUiThread(() -> renderLive(arr));
            }

            @Override
            public void onFailure(WebSocket webSocket, Throwable t, Response response) {
                setStatus("Live WS error: " + t.getMessage());
            }
        });
    }

    private void ensureControlWs(int connId) {
        String base = getSshBaseUrl();
        if (!ensureAuthReady(base)) return;
        if (controlWs != null && controlWsConnId == connId) {
            return;
        }
        if (controlWs != null) {
            controlWs.close(1000, "switch");
            controlWs = null;
        }
        int keepalive = parseIntOrDefault(keepaliveInput.getText().toString().trim(), 300);
        HttpUrl httpUrl = buildUrl(base, "/api/ssh/control/ws");
        if (httpUrl == null) return;
        HttpUrl httpWithQuery = httpUrl
            .newBuilder()
            .addQueryParameter("id", String.valueOf(connId))
            .addQueryParameter("keepalive_seconds", String.valueOf(keepalive))
            .addQueryParameter("access_token", accessToken)
            .build();
        String wsUrl = toWebSocketUrl(httpWithQuery.toString());
        Request request = new Request.Builder().url(wsUrl).build();
        controlWsConnId = connId;
        controlWs = client.newWebSocket(request, new WebSocketListener() {
            @Override
            public void onOpen(WebSocket webSocket, Response response) {
                setTrackpadStatus("Control connected");
            }

            @Override
            public void onFailure(WebSocket webSocket, Throwable t, Response response) {
                setTrackpadStatus("Control error: " + t.getMessage());
            }

            @Override
            public void onClosed(WebSocket webSocket, int code, String reason) {
                setTrackpadStatus("Control closed");
            }
        });
    }

    private boolean handleTrackpadTouch(MotionEvent event) {
        switch (event.getAction()) {
            case MotionEvent.ACTION_DOWN:
                trackpadActive = true;
                lastX = event.getX();
                lastY = event.getY();
                lastTrackpadSend = 0L;
                return true;
            case MotionEvent.ACTION_MOVE:
                if (!trackpadActive) return true;
                float dx = (event.getX() - lastX) * 10f;
                float dy = (event.getY() - lastY) * 10f;
                lastX = event.getX();
                lastY = event.getY();
                if (Math.abs(dx) < 1f && Math.abs(dy) < 1f) return true;
                long now = System.currentTimeMillis();
                if (now - lastTrackpadSend < 80) return true;
                lastTrackpadSend = now;
                sendTrackpadMove((int) dx, (int) dy);
                return true;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                trackpadActive = false;
                return true;
            default:
                return false;
        }
    }

    private void sendTrackpadMove(int dx, int dy) {
        if (selectedConnectionId <= 0) {
            setStatus("Select a connection before using trackpad");
            return;
        }
        ensureControlWs(selectedConnectionId);
        if (controlWs == null) {
            setTrackpadStatus("Control not ready");
            return;
        }
        JsonObject payload = new JsonObject();
        payload.addProperty("type", "move");
        payload.addProperty("dx", dx);
        payload.addProperty("dy", dy);
        controlWs.send(payload.toString());
        setTrackpadStatus("Move sent (" + dx + ", " + dy + ")");
    }

    private void sendClick(int button) {
        if (selectedConnectionId <= 0) {
            setStatus("Select a connection before clicking");
            return;
        }
        ensureControlWs(selectedConnectionId);
        if (controlWs == null) {
            setTrackpadStatus("Control not ready");
            return;
        }
        JsonObject payload = new JsonObject();
        payload.addProperty("type", "click");
        payload.addProperty("button", button);
        controlWs.send(payload.toString());
        setTrackpadStatus("Click " + button + " sent");
    }

    private boolean ensureAuthReady(String base) {
        if (TextUtils.isEmpty(base)) {
            setStatus("Enter base URLs first");
            return false;
        }
        if (TextUtils.isEmpty(accessToken)) {
            setStatus("Login required");
            return false;
        }
        return true;
    }

    private HttpUrl buildUrl(String base, String path) {
        HttpUrl baseUrl = HttpUrl.parse(trimTrailingSlash(base));
        if (baseUrl == null) {
            setStatus("Invalid base URL: " + base);
            return null;
        }
        return baseUrl.newBuilder().addPathSegments(path.replaceFirst("^/", "")).build();
    }

    private String toWebSocketUrl(String httpUrl) {
        if (httpUrl.startsWith("https://")) {
            return httpUrl.replaceFirst("https://", "wss://");
        }
        if (httpUrl.startsWith("http://")) {
            return httpUrl.replaceFirst("http://", "ws://");
        }
        return httpUrl;
    }

    private String trimTrailingSlash(String base) {
        if (base.endsWith("/")) return base.substring(0, base.length() - 1);
        return base;
    }

    private String normalizeBaseUrl(String raw) {
        if (TextUtils.isEmpty(raw)) return "";
        String trimmed = raw.trim();
        if (!trimmed.startsWith("http://") && !trimmed.startsWith("https://")) {
            trimmed = "https://" + trimmed;
        }
        HttpUrl parsed = HttpUrl.parse(trimmed);
        if (parsed == null) return "";
        HttpUrl normalized = parsed.newBuilder().encodedPath("/").build();
        String out = normalized.toString();
        return trimTrailingSlash(out);
    }

    private int parseIntOrDefault(String value, int fallback) {
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private JsonObject parseJsonObject(String text) {
        try {
            return JsonParser.parseString(text).getAsJsonObject();
        } catch (Exception e) {
            return null;
        }
    }

    private String getString(JsonObject obj, String key) {
        if (obj == null || !obj.has(key) || obj.get(key).isJsonNull()) return "";
        return obj.get(key).getAsString();
    }

    private void setStatus(String msg) {
        runOnUiThread(() -> statusText.setText(msg));
        Log.i(TAG, msg);
    }

    private void setTrackpadStatus(String msg) {
        runOnUiThread(() -> trackpadStatus.setText(msg));
    }

    private void updateLoginUi() {
        boolean loggedIn = !TextUtils.isEmpty(accessToken);
        runOnUiThread(() -> loginSection.setVisibility(loggedIn ? View.GONE : View.VISIBLE));
    }

    private void setRunInProgress(boolean inProgress) {
        runInProgress = inProgress;
        runOnUiThread(() -> {
            runCommandButton.setEnabled(!inProgress);
            runProgress.setVisibility(inProgress ? View.VISIBLE : View.GONE);
            runCommandButton.setText(inProgress ? "Running..." : "Run");
        });
    }

    private void showToast(String msg) {
        runOnUiThread(() -> Toast.makeText(this, msg, Toast.LENGTH_SHORT).show());
    }

    private class SimpleCallback implements Callback {
        private final String okMessage;

        SimpleCallback(String okMessage) {
            this.okMessage = okMessage;
        }

        @Override
        public void onFailure(Call call, IOException e) {
            setStatus("Request failed: " + e.getMessage());
        }

        @Override
        public void onResponse(Call call, Response response) throws IOException {
            String text = response.body() != null ? response.body().string() : "";
            if (response.isSuccessful()) {
                setStatus(okMessage);
            } else {
                setStatus("Request failed: " + text);
            }
        }
    }

    @Override
    protected void onDestroy() {
        if (liveWs != null) liveWs.close(1000, "bye");
        if (controlWs != null) controlWs.close(1000, "bye");
        super.onDestroy();
    }
}
