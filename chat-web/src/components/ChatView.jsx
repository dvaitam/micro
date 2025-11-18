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

const pluralize = (value, unit) => `${value} ${unit}${value === 1 ? '' : 's'} ago`;

const formatRelativeTime = (input) => {
  if (!input) {
    return '';
  }
  const target = new Date(input).getTime();
  if (Number.isNaN(target)) {
    return '';
  }
  const now = Date.now();
  const diff = Math.max(0, now - target);
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  const week = 7 * day;
  if (diff < minute) {
    return 'Just now';
  }
  if (diff < hour) {
    const minutes = Math.floor(diff / minute);
    return pluralize(minutes, 'minute');
  }
  if (diff < day) {
    const hours = Math.floor(diff / hour);
    return pluralize(hours, 'hour');
  }
  if (diff < week) {
    const days = Math.floor(diff / day);
    return pluralize(days, 'day');
  }
  if (diff < week * 2) {
    return '1 week ago';
  }
  return new Date(target).toLocaleString();
};

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

const sanitizeSDP = (sdp) => {
  if (!sdp || typeof sdp !== 'string') {
    return sdp;
  }
  const lines = sdp.split(/\r?\n/);
  const filtered = lines.filter((line) => {
    const trimmed = line.trim();
    if (!trimmed) {
      return false;
    }
    if (trimmed.startsWith('a=ssrc-group:FID ')) {
      return false;
    }
    return true;
  });
  return `${filtered.join('\r\n')}\r\n`;
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

const deriveRtcBaseURL = (apiBase) => {
  const explicit = import.meta.env.VITE_RTC_BASE_URL;
  if (explicit) {
    return explicit.replace(/\/$/, '');
  }
  try {
    const parsed = new URL(apiBase);
    if (parsed.hostname === 'chat.manchik.co.uk') {
      return 'https://webrtc.manchik.co.uk';
    }
    return `${parsed.protocol}//${parsed.hostname}:8085`;
  } catch (err) {
    console.error('Invalid API base for RTC fallback', err);
    return window.location.origin.replace(/\/$/, '');
  }
};

const defaultCallState = {
  status: 'idle',
  sessionId: '',
  conversationId: '',
  role: '',
  peerEmail: '',
  peerName: '',
  localStream: null,
  remoteStream: null,
  turn: null,
};

const callStatusLabel = (state) => {
  switch (state.status) {
    case 'calling':
      return 'Calling…';
    case 'incoming':
      return 'Incoming video call';
    case 'connecting':
      return 'Connecting…';
    case 'in-call':
      return 'In call';
    case 'ending':
      return 'Ending call…';
    default:
      return '';
  }
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
  const [callState, setCallState] = useState(defaultCallState);

  const placeholderCache = useRef(new Map());
  const userAvatarCache = useRef(new Map());
  const convoAvatarCache = useRef(new Map());
  const loadingUserAvatars = useRef(new Set());
  const loadingConvoAvatars = useRef(new Set());
  const wsRef = useRef(null);
  const pendingAnnouncements = useRef([]);
  const pendingSignals = useRef([]);
  const [, forceAvatarRefresh] = useState(0);
  const selectedConversationRef = useRef('');
  const callStateRef = useRef(defaultCallState);
  const peerConnectionRef = useRef(null);
  const localStreamRef = useRef(null);
  const remoteStreamRef = useRef(null);
  const sessionPollRef = useRef(null);
  const seenCandidatesRef = useRef(new Set());
  const currentSessionRef = useRef('');
  const localVideoRef = useRef(null);
  const remoteVideoRef = useRef(null);

  const normalizedCurrentUser = useMemo(() => normalizeEmail(session?.email || ''), [session?.email]);
  const rtcBaseURL = useMemo(() => deriveRtcBaseURL(apiBase), [apiBase]);

  useEffect(() => {
    selectedConversationRef.current = selectedConversationId;
  }, [selectedConversationId]);

  useEffect(() => {
    callStateRef.current = callState;
  }, [callState]);

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

  const rtcFetch = useCallback(async (path, options = {}) => {
    const url = path.startsWith('http') ? path : `${rtcBaseURL}${path.startsWith('/') ? path : `/${path}`}`;
    const headers = new Headers(options.headers || {});
    if (!headers.has('Content-Type') && options.body && !(options.body instanceof FormData)) {
      headers.set('Content-Type', 'application/json');
    }
    if (accessToken) {
      headers.set('Authorization', `Bearer ${accessToken}`);
    }
    if (session?.email) {
      headers.set('X-RTC-Participant', session.email);
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
    const contentType = response.headers.get('Content-Type') || '';
    if (contentType.includes('application/json')) {
      return response.json();
    }
    return {};
  }, [accessToken, rtcBaseURL, session?.email]);

  const upsertConversation = useCallback((conversation, options = {}) => {
    if (!conversation || !conversation.id) {
      return;
    }
    setConversations((prev) => {
      const map = new Map(prev.map((item) => [item.id, item]));
      const existing = map.get(conversation.id) || {};
      const participants = conversation.participants?.length ? conversation.participants : existing.participants || [];
      let unreadCount = typeof existing.unread_count === 'number' ? existing.unread_count : 0;
      if (typeof options.setUnread === 'number') {
        unreadCount = Math.max(0, options.setUnread);
      } else if (typeof options.incrementUnread === 'number') {
        unreadCount = Math.max(0, unreadCount + options.incrementUnread);
      } else if (typeof conversation.unread_count === 'number') {
        unreadCount = Math.max(0, conversation.unread_count);
      }
      const merged = {
        ...existing,
        ...conversation,
        participants,
        participantSignature: conversation.participant_signature || existing.participantSignature || participantSignature(participants),
        unread_count: unreadCount,
      };
      map.set(merged.id, merged);
      return Array.from(map.values()).sort((a, b) => new Date(b.last_activity_at || 0) - new Date(a.last_activity_at || 0));
    });
  }, [participantSignature]);

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
        upsertConversation({
          id: conversationId,
          last_activity_at: last.sent_at,
          lastMessagePreview: last.text,
          last_message: last.text,
          last_message_at: last.sent_at,
          last_sender: last.sender,
        });
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

  const markConversationRead = useCallback(async (conversationId, { skipRequest = false } = {}) => {
    if (!conversationId) {
      return;
    }
    upsertConversation({ id: conversationId }, { setUnread: 0 });
    if (skipRequest) {
      return;
    }
    try {
      await authorizedFetch(`/api/conversations/${encodeURIComponent(conversationId)}/read`, {
        method: 'POST',
      });
    } catch (err) {
      console.debug('mark conversation read failed', err);
    }
  }, [authorizedFetch, upsertConversation]);

  const selectConversation = useCallback(async (conversationId) => {
    if (!conversationId) {
      return;
    }
    setSelectedConversationId(conversationId);
    const needsFetch = !messagesByConversation[conversationId];
    if (needsFetch) {
      await loadMessages(conversationId);
    }
    await markConversationRead(conversationId, { skipRequest: needsFetch });
  }, [loadMessages, markConversationRead, messagesByConversation]);

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

  const conversationPreview = useCallback((conversation) => {
    if (!conversation) {
      return '';
    }
    const preview = conversation.last_message?.trim()
      || conversation.lastMessagePreview?.trim()
      || conversation.last_message_preview?.trim();
    if (preview) {
      const normalizedSender = normalizeEmail(conversation.last_sender || '');
      if (normalizedSender && normalizedSender === normalizedCurrentUser) {
        return `You: ${preview}`;
      }
      return preview;
    }
    const history = messagesByConversation[conversation.id] || [];
    const last = history[history.length - 1];
    if (last?.text?.trim()) {
      const normalizedSender = normalizeEmail(last.sender || last.from || '');
      const text = last.text.trim();
      if (normalizedSender && normalizedSender === normalizedCurrentUser) {
        return `You: ${text}`;
      }
      return text;
    }
    return 'No messages yet';
  }, [messagesByConversation, normalizedCurrentUser]);

  const conversationLastActivityLabel = useCallback((conversation) => {
    if (!conversation) {
      return '';
    }
    return formatRelativeTime(conversation.last_activity_at) || '';
  }, []);

  const sendRtcSignal = useCallback((conversationId, payload) => {
    if (!conversationId || !payload) {
      return;
    }
    const message = JSON.stringify({
      type: 'rtc_signal',
      conversation_id: conversationId,
      text: JSON.stringify(payload),
    });
    const socket = wsRef.current;
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(message);
    } else {
      pendingSignals.current.push(message);
    }
  }, []);

  const cleanupCall = useCallback(async ({ notify = false, sessionId, conversationId } = {}) => {
    const activeSession = sessionId || callStateRef.current.sessionId;
    const activeConversation = conversationId || callStateRef.current.conversationId;
    if (sessionPollRef.current) {
      clearInterval(sessionPollRef.current);
      sessionPollRef.current = null;
    }
    if (peerConnectionRef.current) {
      try {
        peerConnectionRef.current.onicecandidate = null;
        peerConnectionRef.current.ontrack = null;
        peerConnectionRef.current.onconnectionstatechange = null;
        peerConnectionRef.current.close();
      } catch (err) {
        console.debug('peer close failed', err);
      }
      peerConnectionRef.current = null;
    }
    seenCandidatesRef.current.clear();
    currentSessionRef.current = '';
    if (localStreamRef.current) {
      localStreamRef.current.getTracks().forEach((track) => track.stop());
      localStreamRef.current = null;
    }
    if (remoteStreamRef.current) {
      remoteStreamRef.current.getTracks().forEach((track) => track.stop());
      remoteStreamRef.current = null;
    }
    const resetState = { ...defaultCallState };
    callStateRef.current = resetState;
    setCallState(resetState);
    if (notify && activeConversation && activeSession) {
      sendRtcSignal(activeConversation, {
        kind: 'end',
        session_id: activeSession,
        from: session.email,
      });
    }
    if (activeSession) {
      try {
        await rtcFetch(`/sessions/${encodeURIComponent(activeSession)}`, { method: 'DELETE' });
      } catch (err) {
        console.debug('session cleanup failed', err);
      }
    }
  }, [rtcFetch, sendRtcSignal, session.email]);

  const ensureLocalStream = useCallback(async () => {
    if (localStreamRef.current) {
      return localStreamRef.current;
    }
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
    localStreamRef.current = stream;
    setCallState((prev) => ({ ...prev, localStream: stream }));
    return stream;
  }, []);

  const setupPeerConnection = useCallback((pc) => {
    if (!pc) {
      return;
    }
    pc.onicecandidate = (event) => {
      if (event.candidate && currentSessionRef.current) {
        const candidateText = (event.candidate.candidate || '').trim();
        if (!candidateText) {
          return;
        }
        const payload = {
          candidate: candidateText,
          sdp_mid: event.candidate.sdpMid || '',
          from: session.email,
        };
        if (typeof event.candidate.sdpMLineIndex === 'number') {
          payload.sdp_m_line_index = event.candidate.sdpMLineIndex;
        }
        rtcFetch(`/sessions/${encodeURIComponent(currentSessionRef.current)}/candidates`, {
          method: 'POST',
          body: JSON.stringify(payload),
        }).catch((err) => {
          console.debug('candidate publish failed', err);
        });
      }
    };
    pc.ontrack = (event) => {
      const [stream] = event.streams || [];
      if (stream) {
        remoteStreamRef.current = stream;
        setCallState((prev) => ({ ...prev, remoteStream: stream }));
      }
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'connected') {
        setCallState((prev) => ({ ...prev, status: 'in-call' }));
      } else if (['failed', 'disconnected', 'closed'].includes(pc.connectionState)) {
        cleanupCall({ notify: false });
      }
    };
  }, [cleanupCall, rtcFetch, session.email]);

  const processSessionUpdate = useCallback(async (sessionPayload) => {
    if (!sessionPayload) {
      return;
    }
    const pc = peerConnectionRef.current;
    if (!pc) {
      return;
    }
    if (callStateRef.current.role === 'caller' && sessionPayload.answer && (!pc.currentRemoteDescription || pc.currentRemoteDescription.type !== 'answer')) {
      try {
        await pc.setRemoteDescription({
          type: sessionPayload.answer.type || 'answer',
          sdp: sanitizeSDP(sessionPayload.answer.sdp),
        });
        setCallState((prev) => ({ ...prev, status: 'connecting' }));
      } catch (err) {
        console.error('Failed to set remote answer', err);
      }
    }
    if (sessionPayload.candidates) {
      Object.entries(sessionPayload.candidates).forEach(([email, entries]) => {
        if (normalizeEmail(email) === normalizedCurrentUser) {
          return;
        }
        entries.forEach((candidate) => {
          const fingerprint = `${email}:${candidate.candidate}:${candidate.sdp_mid || ''}:${candidate.sdp_m_line_index ?? ''}`;
          if (seenCandidatesRef.current.has(fingerprint)) {
            return;
          }
          seenCandidatesRef.current.add(fingerprint);
          pc.addIceCandidate({
            candidate: candidate.candidate,
            sdpMid: candidate.sdp_mid || undefined,
            sdpMLineIndex: typeof candidate.sdp_m_line_index === 'number' ? candidate.sdp_m_line_index : undefined,
          }).catch((err) => console.debug('addIceCandidate failed', err));
        });
      });
    }
  }, [normalizedCurrentUser]);

  const beginSessionPolling = useCallback((sessionId) => {
    if (!sessionId) {
      return;
    }
    if (sessionPollRef.current) {
      clearInterval(sessionPollRef.current);
    }
    const poll = async () => {
      try {
        const data = await rtcFetch(`/sessions/${encodeURIComponent(sessionId)}?participant=${encodeURIComponent(session.email)}`);
        if (data?.session) {
          await processSessionUpdate(data.session);
        }
        if (data?.turn && !callStateRef.current.turn) {
          setCallState((prev) => ({ ...prev, turn: data.turn }));
        }
      } catch (err) {
        console.debug('session poll failed', err);
      }
    };
    poll();
    sessionPollRef.current = window.setInterval(poll, 2000);
  }, [processSessionUpdate, rtcFetch, session.email]);

  const startCall = useCallback(async () => {
    if (!selectedConversationId) {
      setSystemNote('Select a conversation to start a call.');
      return;
    }
    if (callStateRef.current.status !== 'idle') {
      setSystemNote('You are already in a call.');
      return;
    }
    try {
      const conversation = conversations.find((conv) => conv.id === selectedConversationId);
      const localStream = await ensureLocalStream();
      const payload = await rtcFetch('/sessions', {
        method: 'POST',
        body: JSON.stringify({
          conversation_id: selectedConversationId,
          initiator: session.email,
        }),
      });
      const rtcSession = payload.session;
      const turn = payload.turn;
      const iceServers = turn?.urls?.length ? [{
        urls: turn.urls,
        username: turn.username,
        credential: turn.credential,
      }] : [{ urls: 'stun:stun.l.google.com:19302' }];
      console.info('[RTC] Using ICE servers', iceServers.map((entry) => entry.urls));
      const peerConnection = new RTCPeerConnection({
        iceServers,
      });
      peerConnectionRef.current = peerConnection;
      currentSessionRef.current = rtcSession.id;
      setupPeerConnection(peerConnection);
      localStream.getTracks().forEach((track) => peerConnection.addTrack(track, localStream));
      const stateUpdate = {
        status: 'calling',
        sessionId: rtcSession.id,
        conversationId: selectedConversationId,
        role: 'caller',
        peerEmail: (conversation?.participants || []).find((p) => normalizeEmail(p) !== normalizedCurrentUser) || '',
        peerName: conversation ? conversationDisplayName(conversation) : 'Participant',
        localStream,
        remoteStream: null,
        turn,
      };
      callStateRef.current = stateUpdate;
      setCallState(stateUpdate);
      const offer = await peerConnection.createOffer({
        offerToReceiveAudio: true,
        offerToReceiveVideo: true,
      });
      await peerConnection.setLocalDescription(offer);
      await rtcFetch(`/sessions/${encodeURIComponent(rtcSession.id)}/offer`, {
        method: 'PUT',
        body: JSON.stringify({
          sdp: offer.sdp,
          type: offer.type,
          from: session.email,
        }),
      });
      sendRtcSignal(selectedConversationId, {
        kind: 'invite',
        session_id: rtcSession.id,
        from: session.email,
        display_name: conversation ? conversationDisplayName(conversation) : session.email,
      });
      beginSessionPolling(rtcSession.id);
    } catch (err) {
      console.error('start call failed', err);
      setSystemNote('Unable to start video call.');
      cleanupCall({ notify: false });
    }
  }, [beginSessionPolling, cleanupCall, conversations, conversationDisplayName, ensureLocalStream, normalizedCurrentUser, rtcFetch, selectedConversationId, sendRtcSignal, session.email]);

  const acceptCall = useCallback(async () => {
    if (callStateRef.current.status !== 'incoming') {
      return;
    }
    try {
      const localStream = await ensureLocalStream();
      const data = await rtcFetch(`/sessions/${encodeURIComponent(callStateRef.current.sessionId)}?participant=${encodeURIComponent(session.email)}`);
      const rtcSession = data.session;
      const turn = data.turn;
      if (!rtcSession?.offer) {
        throw new Error('Missing offer');
      }
      const iceServers = turn?.urls?.length ? [{
        urls: turn.urls,
        username: turn.username,
        credential: turn.credential,
      }] : [{ urls: 'stun:stun.l.google.com:19302' }];
      console.info('[RTC] Using ICE servers', iceServers.map((entry) => entry.urls));
      const peerConnection = new RTCPeerConnection({
        iceServers,
      });
      peerConnectionRef.current = peerConnection;
      currentSessionRef.current = callStateRef.current.sessionId;
      setupPeerConnection(peerConnection);
      localStream.getTracks().forEach((track) => peerConnection.addTrack(track, localStream));
      await peerConnection.setRemoteDescription({
        type: rtcSession.offer.type || 'offer',
        sdp: sanitizeSDP(rtcSession.offer.sdp),
      });
      const answer = await peerConnection.createAnswer();
      await peerConnection.setLocalDescription(answer);
      await rtcFetch(`/sessions/${encodeURIComponent(callStateRef.current.sessionId)}/answer`, {
        method: 'PUT',
        body: JSON.stringify({
          sdp: answer.sdp,
          type: answer.type,
          from: session.email,
        }),
      });
      sendRtcSignal(callStateRef.current.conversationId, {
        kind: 'accept',
        session_id: callStateRef.current.sessionId,
        from: session.email,
      });
      const nextState = {
        ...callStateRef.current,
        status: 'connecting',
        localStream,
        turn,
      };
      callStateRef.current = nextState;
      setCallState(nextState);
      beginSessionPolling(callStateRef.current.sessionId);
    } catch (err) {
      console.error('accept call failed', err);
      setSystemNote('Unable to accept call.');
      sendRtcSignal(callStateRef.current.conversationId, {
        kind: 'decline',
        session_id: callStateRef.current.sessionId,
        from: session.email,
      });
      cleanupCall({ notify: false });
    }
  }, [beginSessionPolling, cleanupCall, ensureLocalStream, rtcFetch, sendRtcSignal, session.email]);

  const rejectCall = useCallback(() => {
    if (callStateRef.current.status !== 'incoming') {
      return;
    }
    sendRtcSignal(callStateRef.current.conversationId, {
      kind: 'decline',
      session_id: callStateRef.current.sessionId,
      from: session.email,
    });
    cleanupCall({ notify: false });
  }, [cleanupCall, sendRtcSignal, session.email]);

  const endCall = useCallback(() => {
    if (callStateRef.current.status === 'idle') {
      return;
    }
    cleanupCall({ notify: true });
  }, [cleanupCall]);

  const handleRtcSignal = useCallback((signal, meta) => {
    if (!signal || !signal.kind || !signal.session_id) {
      return;
    }
    const normalizedFrom = normalizeEmail(signal.from || meta?.from || '');
    const conversationId = signal.conversation_id || meta?.conversation_id;
    if (!conversationId) {
      return;
    }
    if (signal.kind === 'invite') {
      if (callStateRef.current.status !== 'idle') {
        sendRtcSignal(signal.conversation_id, {
          kind: 'busy',
          session_id: signal.session_id,
          from: session.email,
        });
        return;
      }
      const conversation = conversations.find((conv) => conv.id === conversationId);
      const nextState = {
        status: 'incoming',
        sessionId: signal.session_id,
        conversationId,
        role: 'callee',
        peerEmail: normalizedFrom,
        peerName: signal.display_name || (conversation ? conversationDisplayName(conversation) : signal.from || 'Caller'),
        localStream: null,
        remoteStream: null,
        turn: null,
      };
      callStateRef.current = nextState;
      setCallState(nextState);
      if (!selectedConversationRef.current) {
        setSelectedConversationId(conversationId);
      }
      return;
    }

    if (signal.kind === 'accept' && callStateRef.current.role === 'caller' && signal.session_id === callStateRef.current.sessionId) {
      setCallState((prev) => ({ ...prev, status: 'connecting' }));
      return;
    }

    if (signal.kind === 'decline' && signal.session_id === callStateRef.current.sessionId) {
      setSystemNote('Call declined.');
      cleanupCall({ notify: false });
      return;
    }

    if (signal.kind === 'busy' && signal.session_id === callStateRef.current.sessionId) {
      setSystemNote('User is on another call.');
      cleanupCall({ notify: false });
      return;
    }

    if (signal.kind === 'end' && signal.session_id === callStateRef.current.sessionId) {
      cleanupCall({ notify: false });
    }
  }, [cleanupCall, conversationDisplayName, conversations, sendRtcSignal, session.email]);

  const rtcSignalHandlerRef = useRef(() => {});

  useEffect(() => {
    rtcSignalHandlerRef.current = handleRtcSignal;
  }, [handleRtcSignal]);

  useEffect(() => {
    const element = localVideoRef.current;
    if (!element) {
      return;
    }
    element.srcObject = callState.localStream || null;
    if (callState.localStream) {
      element.muted = true;
      element.play().catch(() => {});
    }
  }, [callState.localStream]);

  useEffect(() => {
    const element = remoteVideoRef.current;
    if (!element) {
      return;
    }
    element.srcObject = callState.remoteStream || null;
    if (callState.remoteStream) {
      element.play().catch(() => {});
    }
  }, [callState.remoteStream]);

  useEffect(() => {
    loadConversations();
    loadUsers('');
    return () => {
      if (wsRef.current) {
        wsRef.current.close();
      }
      userAvatarCache.current.forEach((url) => URL.revokeObjectURL(url));
      convoAvatarCache.current.forEach((url) => URL.revokeObjectURL(url));
      cleanupCall({ notify: false });
    };
  }, [cleanupCall, loadConversations, loadUsers]);

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
      while (pendingSignals.current.length > 0) {
        const payload = pendingSignals.current.shift();
        if (payload) {
          ws.send(payload);
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
          const normalizedSender = normalizeEmail(entry.sender || '');
          const isSelf = normalizedSender === normalizedCurrentUser;
          const isActive = selectedConversationRef.current === conversationId;
          const unreadOptions = isSelf || isActive ? { setUnread: 0 } : { incrementUnread: 1 };
          upsertConversation({
            id: conversationId,
            last_activity_at: entry.sent_at,
            lastMessagePreview: entry.text,
            participants: payload.participants || [],
            name: payload.conversation_name,
            last_message: entry.text,
            last_message_at: entry.sent_at,
            last_sender: entry.sender,
          }, unreadOptions);
          if (isActive && !isSelf) {
            markConversationRead(conversationId);
          }
        } else if (payload.type === 'conversation' && payload.conversation) {
          upsertConversation(payload.conversation);
        } else if (payload.type === 'rtc_signal' && payload.text) {
          try {
            const signal = JSON.parse(payload.text);
            if (typeof rtcSignalHandlerRef.current === 'function') {
              rtcSignalHandlerRef.current(signal, payload);
            }
          } catch (err) {
            console.error('invalid rtc signal', err);
          }
        }
      } catch (err) {
        console.error('invalid socket message', err);
      }
    });
    return () => {
      ws.close();
    };
  }, [accessToken, apiBase, appendMessage, markConversationRead, normalizedCurrentUser, upsertConversation]);

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
                <div className="conversation-title-row">
                  <span className="conversation-name">{conversationDisplayName(conversation)}</span>
                  <div className="conversation-meta-group">
                    <span className="conversation-meta">
                      {conversationLastActivityLabel(conversation) || '—'}
                    </span>
                    {conversation.unread_count > 0 && (
                      <span className="unread-badge">
                        {conversation.unread_count > 99 ? '99+' : conversation.unread_count}
                      </span>
                    )}
                  </div>
                </div>
                <span className="conversation-preview">{conversationPreview(conversation)}</span>
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
          <div className="chat-actions">
            <button
              type="button"
              onClick={startCall}
              disabled={!selectedConversationId || callState.status !== 'idle'}
            >
              Start Video Call
            </button>
            {callState.status !== 'idle' && (
              <button
                type="button"
                className="danger"
                onClick={endCall}
              >
                Hang Up
              </button>
            )}
          </div>
        </header>
        {callState.status !== 'idle' && (
          <div className="call-panel">
            <div className="call-status-row">
              <div>
                <p className="call-status-label">{callStatusLabel(callState)}</p>
                <p className="call-peer-name">{callState.peerName || callState.peerEmail || 'Participant'}</p>
              </div>
            </div>
            <div className="video-stage">
              <video ref={remoteVideoRef} className={`video-feed remote ${callState.remoteStream ? 'active' : ''}`} playsInline autoPlay />
              <video ref={localVideoRef} className={`video-feed local ${callState.localStream ? 'active' : ''}`} playsInline autoPlay muted />
            </div>
            <div className="call-buttons">
              {callState.status === 'incoming' ? (
                <>
                  <button type="button" onClick={acceptCall}>Accept</button>
                  <button type="button" className="danger" onClick={rejectCall}>Decline</button>
                </>
              ) : (
                <button type="button" className="danger" onClick={endCall}>Hang Up</button>
              )}
            </div>
          </div>
        )}
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
