import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

const normalizeEmail = (value) => (value || '').trim().toLowerCase();

const dedupeAndSort = (list) => {
  const normalized = Array.from(new Set((list || []).map((entry) => normalizeEmail(entry)).filter(Boolean)));
  normalized.sort();
  return normalized;
};

const participantSignature = (list) => dedupeAndSort(list).join('|');

const initialsFromText = (text) => {
  if (!text) {
    return '?';
  }
  const clean = text.trim();
  if (!clean) {
    return '?';
  }
  const parts = clean.split(/\s+/).filter(Boolean);
  const first = parts[0]?.[0] || '?';
  const second = parts[1]?.[0] || parts[0]?.[1] || '';
  return `${first}${second}`.toUpperCase();
};

const encodeSvg = (svg) => window.btoa(unescape(encodeURIComponent(svg)));

const buildPlaceholder = (text, variant, cache) => {
  const initials = initialsFromText(text || 'Chat');
  const key = `${variant}:${initials}`;
  if (cache.current.has(key)) {
    return cache.current.get(key);
  }
  const background = variant === 'group' ? '#e4ecff' : '#fde2e4';
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96"><rect width="96" height="96" rx="48" fill="${background}"/><text x="50%" y="57%" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Arial" font-size="34" fill="#0f172a">${initials}</text></svg>`;
  const dataURL = `data:image/svg+xml;base64,${encodeSvg(svg)}`;
  cache.current.set(key, dataURL);
  return dataURL;
};

const deriveWsURL = (apiBase, token) => {
  const explicitURL = import.meta.env.VITE_WS_URL;
  if (explicitURL) {
    const joiner = explicitURL.includes('?') ? '&' : '?';
    return `${explicitURL}${joiner}token=${encodeURIComponent(token)}`;
  }
  const wsHost = import.meta.env.VITE_WS_HOST;
  if (wsHost) {
    const normalized = wsHost.replace(/^https?:\/\//, '').replace(/^wss?:\/\//, '');
    const proto = wsHost.startsWith('wss:') || apiBase.startsWith('https') ? 'wss' : 'ws';
    return `${proto}://${normalized}${normalized.includes('?') ? '&' : '?'}token=${encodeURIComponent(token)}`;
  }
  const base = new URL(apiBase);
  const secure = base.protocol === 'https:';
  let host = `${base.hostname}:8083`;
  if (base.hostname === 'chat.manchik.co.uk') {
    host = 'ws.manchik.co.uk';
  }
  return `${secure ? 'wss' : 'ws'}://${host}/ws?token=${encodeURIComponent(token)}`;
};

function ChatView({ apiBase, accessToken, session, onLogout }) {
  const [conversations, setConversations] = useState([]);
  const [messagesByConversation, setMessagesByConversation] = useState({});
  const [users, setUsers] = useState([]);
  const [userSearch, setUserSearch] = useState('');
  const [selectedUserEmails, setSelectedUserEmails] = useState([]);
  const [groupName, setGroupName] = useState('');
  const [groupPhotoFile, setGroupPhotoFile] = useState(null);
  const [selectedConversationId, setSelectedConversationId] = useState('');
  const [connectionStatus, setConnectionStatus] = useState('Connecting…');
  const [messageDraft, setMessageDraft] = useState('');
  const [systemNote, setSystemNote] = useState('');

  const placeholderCache = useRef(new Map());
  const userAvatarCache = useRef(new Map());
  const convoAvatarCache = useRef(new Map());
  const loadingUserAvatars = useRef(new Set());
  const loadingConvoAvatars = useRef(new Set());
  const wsRef = useRef(null);
  const pendingAnnouncements = useRef([]);
  const [, forceAvatarRefresh] = useState(0);
  const selectedConversationRef = useRef('');

  const normalizedCurrentUser = useMemo(() => normalizeEmail(session?.email || ''), [session?.email]);

  useEffect(() => {
    selectedConversationRef.current = selectedConversationId;
  }, [selectedConversationId]);

  const authorizedFetch = useCallback(async (path, options = {}) => {
    const url = path.startsWith('http') ? path : `${apiBase}${path.startsWith('/') ? path : `/${path}`}`;
    const headers = new Headers(options.headers || {});
    if (accessToken) {
      headers.set('Authorization', `Bearer ${accessToken}`);
    }
    const isFormData = options.body instanceof FormData;
    if (!isFormData && options.body && !headers.has('Content-Type')) {
      headers.set('Content-Type', 'application/json');
    }
    const response = await fetch(url, {
      credentials: 'include',
      ...options,
      headers,
    });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(text || response.statusText);
    }
    return response;
  }, [apiBase, accessToken]);

  const fetchJSON = useCallback(async (path, options = {}) => {
    const response = await authorizedFetch(path, options);
    const contentType = response.headers.get('Content-Type') || '';
    if (contentType.includes('application/json')) {
      return response.json();
    }
    return {};
  }, [authorizedFetch]);

  const upsertConversation = useCallback((conversation) => {
    setConversations((prev) => {
      const map = new Map(prev.map((item) => [item.id, item]));
      const existing = map.get(conversation.id) || {};
      const participants = conversation.participants?.length ? conversation.participants : existing.participants || [];
      const merged = {
        ...existing,
        ...conversation,
        participants,
        participantSignature: conversation.participant_signature || existing.participantSignature || participantSignature(participants),
      };
      map.set(merged.id, merged);
      return Array.from(map.values()).sort((a, b) => new Date(b.last_activity_at || 0) - new Date(a.last_activity_at || 0));
    });
  }, []);

  const appendMessage = useCallback((conversationId, message) => {
    setMessagesByConversation((prev) => ({
      ...prev,
      [conversationId]: [...(prev[conversationId] || []), message],
    }));
  }, []);

  const loadMessages = useCallback(async (conversationId) => {
    if (!conversationId) {
      return;
    }
    try {
      const data = await fetchJSON(`/api/conversations/${encodeURIComponent(conversationId)}/messages?limit=200`);
      const list = Array.isArray(data.messages) ? data.messages : [];
      setMessagesByConversation((prev) => ({
        ...prev,
        [conversationId]: list,
      }));
      if (list.length > 0) {
        const last = list[list.length - 1];
        upsertConversation({ id: conversationId, last_activity_at: last.sent_at, lastMessagePreview: last.text });
      }
    } catch (err) {
      console.error('load messages failed', err);
      setSystemNote('Unable to load messages for this chat.');
    }
  }, [fetchJSON, upsertConversation]);

  const loadConversations = useCallback(async () => {
    try {
      const data = await fetchJSON('/api/conversations');
      const list = Array.isArray(data.conversations) ? data.conversations : [];
      setConversations(list.map((conv) => ({
        ...conv,
        participantSignature: participantSignature(conv.participants || []),
      })).sort((a, b) => new Date(b.last_activity_at || 0) - new Date(a.last_activity_at || 0)));
      if (list.length > 0 && !selectedConversationRef.current) {
        const firstId = list[0].id;
        setSelectedConversationId(firstId);
        await loadMessages(firstId);
      }
    } catch (err) {
      console.error('load conversations failed', err);
      setSystemNote('Unable to load conversations.');
    }
  }, [fetchJSON, loadMessages]);

  const loadUsers = useCallback(async (query = '') => {
    try {
      const url = query.trim() ? `/api/users/all?q=${encodeURIComponent(query.trim())}` : '/api/users/all';
      const data = await fetchJSON(url);
      const list = Array.isArray(data.users) ? data.users : [];
      setUsers(list);
    } catch (err) {
      console.error('load users failed', err);
      setUsers([]);
    }
  }, [fetchJSON]);

  const selectConversation = useCallback(async (conversationId) => {
    if (!conversationId) {
      return;
    }
    setSelectedConversationId(conversationId);
    if (!messagesByConversation[conversationId]) {
      await loadMessages(conversationId);
    }
  }, [loadMessages, messagesByConversation]);

  const announceConversation = useCallback((conversationId) => {
    if (!conversationId) {
      return;
    }
    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({ type: 'conversation', conversation_id: conversationId }));
    } else {
      pendingAnnouncements.current.push(conversationId);
    }
  }, []);

  const createChat = useCallback(async () => {
    const participants = selectedUserEmails.filter(Boolean);
    if (participants.length === 0) {
      setSystemNote('Select at least one user to start a chat.');
      return;
    }
    try {
      const payload = {
        name: groupName.trim(),
        participants,
      };
      const data = await fetchJSON('/api/conversations', {
        method: 'POST',
        body: JSON.stringify(payload),
      });
      const conversation = data.conversation || data;
      upsertConversation(conversation);
      setMessagesByConversation((prev) => ({
        ...prev,
        [conversation.id]: prev[conversation.id] || [],
      }));
      setSelectedUserEmails([]);
      setGroupName('');
      if (groupPhotoFile) {
        await authorizedFetch(`/api/conversations/${encodeURIComponent(conversation.id)}/photo`, {
          method: 'POST',
          headers: { 'Content-Type': groupPhotoFile.type || 'image/jpeg' },
          body: groupPhotoFile,
        });
        setGroupPhotoFile(null);
      convoAvatarCache.current.delete(conversation.id);
      }
      await selectConversation(conversation.id);
      announceConversation(conversation.id);
    } catch (err) {
      console.error('create chat failed', err);
      setSystemNote('Unable to create chat.');
    }
  }, [announceConversation, authorizedFetch, fetchJSON, groupName, groupPhotoFile, selectedUserEmails, selectConversation, upsertConversation]);

  const sendMessage = useCallback(async () => {
    const text = messageDraft.trim();
    if (!text || !selectedConversationId) {
      return;
    }
    try {
      const payload = { text };
      await fetchJSON(`/api/conversations/${encodeURIComponent(selectedConversationId)}/messages`, {
        method: 'POST',
        body: JSON.stringify(payload),
      });
      setMessageDraft('');
      await loadMessages(selectedConversationId);
    } catch (err) {
      console.error('send message failed', err);
      setSystemNote('Unable to send message.');
    }
  }, [fetchJSON, loadMessages, messageDraft, selectedConversationId]);

  const loadUserAvatar = useCallback(async (email) => {
    const normalized = normalizeEmail(email);
    if (!normalized || userAvatarCache.current.has(normalized) || loadingUserAvatars.current.has(normalized)) {
      return;
    }
    loadingUserAvatars.current.add(normalized);
    try {
      const response = await authorizedFetch(`/api/users/photo?email=${encodeURIComponent(email)}`);
      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      userAvatarCache.current.set(normalized, url);
      forceAvatarRefresh((value) => value + 1);
    } catch (err) {
      console.debug('user avatar missing', err);
    } finally {
      loadingUserAvatars.current.delete(normalized);
    }
  }, [authorizedFetch]);

  const loadConversationAvatar = useCallback(async (conversationId) => {
    if (!conversationId || convoAvatarCache.current.has(conversationId) || loadingConvoAvatars.current.has(conversationId)) {
      return;
    }
    loadingConvoAvatars.current.add(conversationId);
    try {
      const response = await authorizedFetch(`/api/conversations/${encodeURIComponent(conversationId)}/photo`);
      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      convoAvatarCache.current.set(conversationId, url);
      forceAvatarRefresh((value) => value + 1);
    } catch (err) {
      console.debug('conversation avatar missing', err);
    } finally {
      loadingConvoAvatars.current.delete(conversationId);
    }
  }, [authorizedFetch]);

  const conversationDisplayName = useCallback((conversation) => {
    if (!conversation) {
      return 'Conversation';
    }
    if (conversation.name?.trim()) {
      return conversation.name.trim();
    }
    const participants = conversation.participants || [];
    if (participants.length === 0) {
      return 'Conversation';
    }
    const others = participants.filter((p) => normalizeEmail(p) !== normalizedCurrentUser);
    if (others.length === 0) {
      return participants.join(', ');
    }
    if (others.length === 1) {
      return others[0];
    }
    if (others.length === 2 && !conversation.is_group) {
      return others.join(', ');
    }
    return 'Group chat';
  }, [normalizedCurrentUser]);

  const primaryEmail = useCallback((conversation) => {
    if (!conversation) {
      return '';
    }
    const participants = conversation.participants || [];
    if (participants.length === 1) {
      return participants[0];
    }
    if (conversation.is_group || participants.length > 2) {
      return '';
    }
    return participants.find((p) => normalizeEmail(p) !== normalizedCurrentUser) || participants[0];
  }, [normalizedCurrentUser]);

  const avatarSourceForConversation = useCallback((conversation) => {
    if (!conversation) {
      return buildPlaceholder('Chat', 'group', placeholderCache);
    }
    if (conversation.is_group || (conversation.participants || []).length > 2) {
      if (convoAvatarCache.current.has(conversation.id)) {
        return convoAvatarCache.current.get(conversation.id);
      }
      loadConversationAvatar(conversation.id);
      return buildPlaceholder(conversationDisplayName(conversation), 'group', placeholderCache);
    }
    const email = primaryEmail(conversation);
    if (!email) {
      return buildPlaceholder('Chat', 'user', placeholderCache);
    }
    const normalized = normalizeEmail(email);
    if (userAvatarCache.current.has(normalized)) {
      return userAvatarCache.current.get(normalized);
    }
    loadUserAvatar(email);
    return buildPlaceholder(conversationDisplayName(conversation), 'user', placeholderCache);
  }, [conversationDisplayName, loadConversationAvatar, loadUserAvatar, primaryEmail]);

  const avatarSourceForUser = useCallback((user) => {
    const displayName = user.name?.trim() || user.email;
    const normalized = normalizeEmail(user.email);
    if (userAvatarCache.current.has(normalized)) {
      return userAvatarCache.current.get(normalized);
    }
    if (user.has_avatar) {
      loadUserAvatar(user.email);
    }
    return buildPlaceholder(displayName, 'user', placeholderCache);
  }, [loadUserAvatar]);

  useEffect(() => {
    loadConversations();
    loadUsers('');
    return () => {
      if (wsRef.current) {
        wsRef.current.close();
      }
      userAvatarCache.current.forEach((url) => URL.revokeObjectURL(url));
      convoAvatarCache.current.forEach((url) => URL.revokeObjectURL(url));
    };
  }, [loadConversations, loadUsers]);

  useEffect(() => {
    if (!userSearch.trim()) {
      return;
    }
    const handle = setTimeout(() => {
      loadUsers(userSearch);
    }, 300);
    return () => clearTimeout(handle);
  }, [loadUsers, userSearch]);

  useEffect(() => {
    if (!accessToken) {
      return;
    }
    const wsURL = deriveWsURL(apiBase, accessToken);
    const ws = new WebSocket(wsURL);
    wsRef.current = ws;
    ws.addEventListener('open', () => {
      setConnectionStatus('Connected');
      while (pendingAnnouncements.current.length > 0) {
        const id = pendingAnnouncements.current.shift();
        if (id) {
          ws.send(JSON.stringify({ type: 'conversation', conversation_id: id }));
        }
      }
    });
    ws.addEventListener('close', () => {
      setConnectionStatus('Disconnected');
    });
    ws.addEventListener('message', (event) => {
      try {
        const payload = JSON.parse(event.data);
        if (payload.type === 'message' && payload.conversation_id) {
          const conversationId = payload.conversation_id;
          const entry = {
            sender: payload.from || payload.sender || 'system',
            text: payload.text || '',
            sent_at: payload.sent_at || new Date().toISOString(),
          };
          appendMessage(conversationId, entry);
          upsertConversation({
            id: conversationId,
            last_activity_at: entry.sent_at,
            lastMessagePreview: entry.text,
            participants: payload.participants || [],
            name: payload.conversation_name,
          });
        } else if (payload.type === 'conversation' && payload.conversation) {
          upsertConversation(payload.conversation);
        }
      } catch (err) {
        console.error('invalid socket message', err);
      }
    });
    return () => {
      ws.close();
    };
  }, [accessToken, apiBase, appendMessage, upsertConversation]);

  const conversationMessages = messagesByConversation[selectedConversationId] || [];
  const selectedConversation = conversations.find((conv) => conv.id === selectedConversationId);

  return (
    <div className="chat-layout">
      <aside className="sidebar">
        <div className="sidebar-header">
          <div>
            <p className="sidebar-title">Chats</p>
            <p className="sidebar-subtitle">{session.email}</p>
          </div>
          <button className="ghost" onClick={onLogout}>Sign out</button>
        </div>
        <div className="connection-state">{connectionStatus}</div>
        <div className="conversation-list">
          {conversations.length === 0 && <p className="empty-state">No chats yet.</p>}
          {conversations.map((conversation) => (
            <button
              key={conversation.id}
              className={`conversation-item ${conversation.id === selectedConversationId ? 'active' : ''}`}
              onClick={() => selectConversation(conversation.id)}
            >
              <img
                src={avatarSourceForConversation(conversation)}
                alt="avatar"
                className="conversation-avatar"
              />
              <div className="conversation-text">
                <span className="conversation-name">{conversationDisplayName(conversation)}</span>
                <span className="conversation-meta">{new Date(conversation.last_activity_at || 0).toLocaleString()}</span>
              </div>
            </button>
          ))}
        </div>
        <div className="start-chat-panel">
          <h3>Start Chat</h3>
          <input
            type="text"
            placeholder="Search users…"
            value={userSearch}
            onChange={(event) => setUserSearch(event.target.value)}
          />
          <div className="user-list">
            {users.map((user) => {
              const selected = selectedUserEmails.includes(user.email);
              const isCurrent = normalizeEmail(user.email) === normalizedCurrentUser;
              return (
                <label key={user.email} className={`user-item ${isCurrent ? 'me' : ''}`}>
                  {!isCurrent && (
                    <input
                      type="checkbox"
                      checked={selected}
                      onChange={(event) => {
                        setSelectedUserEmails((prev) => {
                          if (event.target.checked) {
                            return [...prev, user.email];
                          }
                          return prev.filter((email) => email !== user.email);
                        });
                      }}
                    />
                  )}
                  <img src={avatarSourceForUser(user)} alt="avatar" className="user-avatar" />
                  <span>{isCurrent ? `${user.name || user.email} (you)` : (user.name || user.email)}</span>
                </label>
              );
            })}
          </div>
          <input
            type="text"
            placeholder="Group name (optional)"
            value={groupName}
            onChange={(event) => setGroupName(event.target.value)}
          />
          <input
            type="file"
            accept="image/*"
            onChange={(event) => setGroupPhotoFile(event.target.files?.[0] || null)}
          />
          <button onClick={createChat}>Create Chat</button>
        </div>
      </aside>
      <section className="chat-section">
        <header className="chat-header">
          <div>
            <h2>{selectedConversation ? conversationDisplayName(selectedConversation) : 'Select a chat to begin'}</h2>
            <p className="chat-subtitle">Messages appear here</p>
          </div>
        </header>
        <div className="message-history">
          {conversationMessages.length === 0 && (
            <div className="message-row system">
              <div className="message-bubble">No messages yet. Say hello!</div>
            </div>
          )}
          {conversationMessages.map((message) => {
            const normalizedSender = normalizeEmail(message.sender || message.from);
            const isSystem = !message.sender && !message.from;
            const outgoing = !isSystem && normalizedSender === normalizedCurrentUser;
            const position = isSystem ? 'system' : (outgoing ? 'outgoing' : 'incoming');
            return (
              <div className={`message-row ${position}`} key={`${message.id || message.sent_at}-${message.sender}-${message.text}`}>
                <div className="message-bubble">
                  <div>{message.text}</div>
                  {!isSystem && (
                    <div className="message-meta">{new Date(message.sent_at || 0).toLocaleString()}</div>
                  )}
                </div>
              </div>
            );
          })}
        </div>
        <form
          className="message-composer"
          onSubmit={(event) => {
            event.preventDefault();
            sendMessage();
          }}
        >
          <input
            type="text"
            placeholder="Type a message"
            value={messageDraft}
            onChange={(event) => setMessageDraft(event.target.value)}
            disabled={!selectedConversationId}
          />
          <button type="submit" disabled={!selectedConversationId || !messageDraft.trim()}>Send</button>
        </form>
        {systemNote && <div className="system-note">{systemNote}</div>}
      </section>
    </div>
  );
}

export default ChatView;
