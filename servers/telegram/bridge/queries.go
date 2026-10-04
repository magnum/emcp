package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gotd/td/tg"
)

type chatJSON struct {
	ID          string       `json:"id"`
	Title       string       `json:"title"`
	Type        string       `json:"type"`
	Username    string       `json:"username,omitempty"`
	UnreadCount int          `json:"unread_count"`
	Muted       bool         `json:"muted"`
	LastMessage *messageJSON `json:"last_message,omitempty"`
}

type messageJSON struct {
	MessageID     string `json:"message_id"`
	ChatID        string `json:"chat_id"`
	ChatTitle     string `json:"chat_title,omitempty"`
	ChatType      string `json:"chat_type,omitempty"`
	SenderID      string `json:"sender_id,omitempty"`
	SenderName    string `json:"sender_name,omitempty"`
	Text          string `json:"text"`
	Timestamp     string `json:"timestamp"`
	FromMe        bool   `json:"is_from_me"`
	MentionsOwner bool   `json:"mentions_owner"`
	Muted         bool   `json:"muted,omitempty"`
	SkipWebhook   bool   `json:"skip_webhook,omitempty"`
}

func (a *app) listChats(w http.ResponseWriter, r *http.Request) {
	api, ok := a.requireAPI(w)
	if !ok {
		return
	}
	chats, err := a.loadChats(r.Context(), api)
	if err != nil {
		writeError(w, err)
		return
	}
	query := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("query")))
	kind := strings.TrimSpace(r.URL.Query().Get("type"))
	filtered := make([]chatJSON, 0, len(chats))
	for _, chat := range chats {
		if kind != "" && chat.Type != kind {
			continue
		}
		if query != "" && !strings.Contains(strings.ToLower(chat.Title), query) && !strings.Contains(strings.ToLower(chat.Username), query) {
			continue
		}
		filtered = append(filtered, chat)
	}
	sortChats(filtered, r.URL.Query().Get("sort_by"))
	limit := clamp(atoi(r.URL.Query().Get("limit"), 20), 1, 100)
	page := clamp(atoi(r.URL.Query().Get("page"), 0), 0, 10000)
	start := page * limit
	if start > len(filtered) {
		start = len(filtered)
	}
	end := start + limit
	if end > len(filtered) {
		end = len(filtered)
	}
	writeJSON(w, http.StatusOK, map[string]any{"chats": filtered[start:end]})
}

func (a *app) getChat(w http.ResponseWriter, r *http.Request) {
	api, ok := a.requireAPI(w)
	if !ok {
		return
	}
	chats, err := a.loadChats(r.Context(), api)
	if err != nil {
		writeError(w, err)
		return
	}
	id := strings.TrimSpace(r.URL.Query().Get("chat_id"))
	for _, chat := range chats {
		if chat.ID == id {
			writeJSON(w, http.StatusOK, map[string]any{"chat": chat})
			return
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]any{"error": "chat not found"})
}

func (a *app) listUnread(w http.ResponseWriter, r *http.Request) {
	api, ok := a.requireAPI(w)
	if !ok {
		return
	}
	chats, err := a.loadChats(r.Context(), api)
	if err != nil {
		writeError(w, err)
		return
	}
	unread := make([]chatJSON, 0)
	for _, chat := range chats {
		if chat.UnreadCount > 0 {
			unread = append(unread, chat)
		}
	}
	limit := clamp(atoi(r.URL.Query().Get("limit"), 20), 1, 100)
	if len(unread) > limit {
		unread = unread[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{"chats": unread})
}

func (a *app) searchContacts(w http.ResponseWriter, r *http.Request) {
	api, ok := a.requireAPI(w)
	if !ok {
		return
	}
	query := strings.TrimSpace(r.URL.Query().Get("query"))
	var found tg.ContactsFound
	err := a.call(r.Context(), func() error {
		res, err := api.ContactsSearch(r.Context(), &tg.ContactsSearchRequest{Q: query, Limit: 20})
		if err != nil {
			return err
		}
		found = *res
		return nil
	})
	if err != nil {
		writeError(w, err)
		return
	}
	a.book.absorb(found.Users, found.Chats)
	contacts := make([]map[string]any, 0)
	for _, user := range found.Users {
		account, ok := user.(*tg.User)
		if !ok || account.Self || account.Deleted {
			continue
		}
		contacts = append(contacts, map[string]any{
			"id":       fmtID(account.ID),
			"name":     strings.TrimSpace(account.FirstName + " " + account.LastName),
			"username": account.Username,
			"phone":    account.Phone,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"contacts": contacts})
}

func (a *app) listMessages(w http.ResponseWriter, r *http.Request) {
	api, ok := a.requireAPI(w)
	if !ok {
		return
	}
	peer, chat, err := a.resolve(r.Context(), api, r.URL.Query().Get("chat_id"))
	if err != nil {
		writeError(w, err)
		return
	}
	limit := clamp(atoi(r.URL.Query().Get("limit"), 20), 1, 100)
	page := clamp(atoi(r.URL.Query().Get("page"), 0), 0, 10000)
	query := r.URL.Query().Get("query")
	var box tg.MessagesMessagesClass
	err = a.call(r.Context(), func() error {
		var err error
		if query != "" {
			box, err = api.MessagesSearch(r.Context(), &tg.MessagesSearchRequest{
				Peer:      peer,
				Q:         query,
				Filter:    &tg.InputMessagesFilterEmpty{},
				Limit:     limit,
				AddOffset: page * limit,
			})
			return err
		}
		box, err = api.MessagesGetHistory(r.Context(), &tg.MessagesGetHistoryRequest{
			Peer:     peer,
			Limit:    limit,
			OffsetID: 0,
			AddOffset: page * limit,
		})
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}
	messages, users, chats := splitMessages(box)
	a.book.absorb(users, chats)
	out := a.decorate(messages, chat, r.URL.Query().Get("sender"), r.URL.Query().Get("after"), r.URL.Query().Get("before"))
	writeJSON(w, http.StatusOK, map[string]any{"messages": out})
}

func (a *app) messageContext(w http.ResponseWriter, r *http.Request) {
	api, ok := a.requireAPI(w)
	if !ok {
		return
	}
	peer, chat, err := a.resolve(r.Context(), api, r.URL.Query().Get("chat_id"))
	if err != nil {
		writeError(w, err)
		return
	}
	messageID := atoi(r.URL.Query().Get("message_id"), 0)
	before := clamp(atoi(r.URL.Query().Get("before"), 5), 0, 50)
	after := clamp(atoi(r.URL.Query().Get("after"), 5), 0, 50)
	var box tg.MessagesMessagesClass
	err = a.call(r.Context(), func() error {
		var err error
		box, err = api.MessagesGetHistory(r.Context(), &tg.MessagesGetHistoryRequest{
			Peer:      peer,
			OffsetID:  messageID + 1,
			AddOffset: -after,
			Limit:     before + after + 1,
		})
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}
	messages, users, chats := splitMessages(box)
	a.book.absorb(users, chats)
	out := a.decorate(messages, chat, "", "", "")
	writeJSON(w, http.StatusOK, map[string]any{"messages": out, "message_id": strconv.Itoa(messageID)})
}

func (a *app) lastInteraction(w http.ResponseWriter, r *http.Request) {
	api, ok := a.requireAPI(w)
	if !ok {
		return
	}
	peerID := r.URL.Query().Get("peer_id")
	peer, chat, err := a.resolve(r.Context(), api, peerID)
	if err != nil {
		writeError(w, err)
		return
	}
	var box tg.MessagesMessagesClass
	err = a.call(r.Context(), func() error {
		var err error
		box, err = api.MessagesGetHistory(r.Context(), &tg.MessagesGetHistoryRequest{Peer: peer, Limit: 1})
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}
	messages, users, chats := splitMessages(box)
	a.book.absorb(users, chats)
	out := a.decorate(messages, chat, "", "", "")
	body := map[string]any{"peer_id": peerID, "chat": chat}
	if len(out) > 0 {
		body["message"] = out[0]
	}
	writeJSON(w, http.StatusOK, body)
}

func (a *app) sendMessage(w http.ResponseWriter, r *http.Request) {
	api, ok := a.requireAPI(w)
	if !ok {
		return
	}
	var body struct {
		Recipient string `json:"recipient"`
		Message   string `json:"message"`
		ReplyTo   string `json:"reply_to_message_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON"})
		return
	}
	if strings.TrimSpace(body.Message) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "message is required"})
		return
	}
	peer, chat, err := a.resolve(r.Context(), api, body.Recipient)
	if err != nil {
		writeError(w, err)
		return
	}
	random, err := randomID()
	if err != nil {
		writeError(w, err)
		return
	}
	req := &tg.MessagesSendMessageRequest{
		Peer:     peer,
		Message:  body.Message,
		RandomID: random,
	}
	if reply := atoi(body.ReplyTo, 0); reply > 0 {
		req.ReplyTo = &tg.InputReplyToMessage{ReplyToMsgID: reply}
	}
	var sent tg.UpdatesClass
	err = a.call(r.Context(), func() error {
		var err error
		sent, err = api.MessagesSendMessage(r.Context(), req)
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}
	messageID := ""
	switch box := sent.(type) {
	case *tg.Updates:
		for _, update := range box.Updates {
			if msg, ok := messageFromUpdate(update); ok {
				messageID = strconv.Itoa(msg.ID)
			}
		}
	case *tg.UpdateShortSentMessage:
		messageID = strconv.Itoa(box.ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"message_id": messageID,
		"chat_id":    chat.ID,
		"timestamp":  time.Now().UTC().Format(time.RFC3339),
	})
}

func (a *app) loadChats(ctx context.Context, api *tg.Client) ([]chatJSON, error) {
	var dialogs tg.MessagesDialogsClass
	err := a.call(ctx, func() error {
		var err error
		dialogs, err = api.MessagesGetDialogs(ctx, &tg.MessagesGetDialogsRequest{
			OffsetPeer: &tg.InputPeerEmpty{},
			Limit:      100,
		})
		return err
	})
	if err != nil {
		return nil, err
	}
	return a.chatsFrom(dialogs), nil
}

func (a *app) chatsFrom(box tg.MessagesDialogsClass) []chatJSON {
	dialogs, messages, users, chats := splitDialogs(box)
	a.book.absorb(users, chats)
	byID := map[int]messageJSON{}
	for _, raw := range messages {
		msg, ok := raw.(*tg.Message)
		if !ok {
			continue
		}
		byID[msg.ID] = a.messageJSON(msg, chatJSON{})
	}
	out := make([]chatJSON, 0, len(dialogs))
	for _, raw := range dialogs {
		dialog, ok := raw.(*tg.Dialog)
		if !ok {
			continue
		}
		chat := a.book.chatFor(dialog.Peer)
		if chat.ID == "" {
			continue
		}
		chat.UnreadCount = dialog.UnreadCount
		chat.Muted = muted(dialog.NotifySettings)
		if last, ok := byID[dialog.TopMessage]; ok {
			last.ChatID = chat.ID
			last.ChatTitle = chat.Title
			last.ChatType = chat.Type
			last.Muted = chat.Muted
			chat.LastMessage = &last
		}
		out = append(out, chat)
	}
	return out
}

func (a *app) resolve(ctx context.Context, api *tg.Client, recipient string) (tg.InputPeerClass, chatJSON, error) {
	value := strings.TrimSpace(recipient)
	if value == "" {
		return nil, chatJSON{}, errString("recipient is required")
	}
	if id, err := strconv.ParseInt(strings.TrimPrefix(value, "+"), 10, 64); err == nil && !strings.HasPrefix(value, "@") && !looksLikePhone(value) {
		if peer, chat, ok := a.book.peer(id); ok {
			return peer, chat, nil
		}
		if _, err := a.loadChats(ctx, api); err != nil {
			return nil, chatJSON{}, err
		}
		if peer, chat, ok := a.book.peer(id); ok {
			return peer, chat, nil
		}
		return nil, chatJSON{}, errString("chat not found")
	}
	if looksLikePhone(value) {
		return a.importPhone(ctx, api, digits(value))
	}
	return a.resolveUsername(ctx, api, strings.TrimPrefix(value, "@"))
}

func looksLikePhone(value string) bool {
	trimmed := strings.TrimPrefix(strings.TrimSpace(value), "+")
	if len(trimmed) < 8 {
		return false
	}
	for _, r := range trimmed {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func (a *app) resolveUsername(ctx context.Context, api *tg.Client, username string) (tg.InputPeerClass, chatJSON, error) {
	var resolved *tg.ContactsResolvedPeer
	err := a.call(ctx, func() error {
		var err error
		resolved, err = api.ContactsResolveUsername(ctx, &tg.ContactsResolveUsernameRequest{Username: username})
		return err
	})
	if err != nil {
		return nil, chatJSON{}, err
	}
	a.book.absorb(resolved.Users, resolved.Chats)
	switch peer := resolved.Peer.(type) {
	case *tg.PeerUser:
		found, chat, ok := a.book.peer(peer.UserID)
		if !ok {
			return nil, chatJSON{}, errString("user not found")
		}
		return found, chat, nil
	case *tg.PeerChannel:
		found, chat, ok := a.book.peer(peer.ChannelID)
		if !ok {
			return nil, chatJSON{}, errString("channel not found")
		}
		return found, chat, nil
	case *tg.PeerChat:
		found, chat, ok := a.book.peer(peer.ChatID)
		if !ok {
			return nil, chatJSON{}, errString("chat not found")
		}
		return found, chat, nil
	default:
		return nil, chatJSON{}, errString("username did not resolve")
	}
}

func (a *app) importPhone(ctx context.Context, api *tg.Client, phone string) (tg.InputPeerClass, chatJSON, error) {
	var imported *tg.ContactsImportedContacts
	err := a.call(ctx, func() error {
		var err error
		imported, err = api.ContactsImportContacts(ctx, []tg.InputPhoneContact{{
			ClientID:  1,
			Phone:     phone,
			FirstName: phone,
		}})
		return err
	})
	if err != nil {
		return nil, chatJSON{}, err
	}
	a.book.absorb(imported.Users, nil)
	if len(imported.Users) == 0 {
		return nil, chatJSON{}, errString("phone is not on Telegram")
	}
	user, ok := imported.Users[0].(*tg.User)
	if !ok {
		return nil, chatJSON{}, errString("phone is not on Telegram")
	}
	peer, chat, ok := a.book.peer(user.ID)
	if !ok {
		return nil, chatJSON{}, errString("phone is not on Telegram")
	}
	return peer, chat, nil
}

func (a *app) decorate(messages []tg.MessageClass, chat chatJSON, sender, after, before string) []messageJSON {
	out := make([]messageJSON, 0, len(messages))
	for _, raw := range messages {
		msg, ok := raw.(*tg.Message)
		if !ok {
			continue
		}
		item := a.messageJSON(msg, chat)
		if sender != "" && item.SenderID != sender && !strings.EqualFold(item.SenderName, sender) {
			continue
		}
		if after != "" && item.Timestamp != "" && item.Timestamp < after {
			continue
		}
		if before != "" && item.Timestamp != "" && item.Timestamp > before {
			continue
		}
		out = append(out, item)
	}
	return out
}

func (a *app) messageJSON(msg *tg.Message, chat chatJSON) messageJSON {
	a.mu.Lock()
	selfID := a.selfID
	username := a.username
	a.mu.Unlock()
	senderID, senderName := a.book.sender(msg)
	fromMe := senderID == fmtID(selfID) && selfID != 0
	item := messageJSON{
		MessageID:     strconv.Itoa(msg.ID),
		ChatID:        chat.ID,
		ChatTitle:     chat.Title,
		ChatType:      chat.Type,
		SenderID:      senderID,
		SenderName:    senderName,
		Text:          msg.Message,
		Timestamp:     rfc3339(msg.Date),
		FromMe:        fromMe,
		MentionsOwner: mentions(selfID, username, msg),
		Muted:         chat.Muted,
		SkipWebhook:   fromMe,
	}
	if item.ChatID == "" {
		item.ChatID = a.book.chatID(msg.PeerID)
	}
	return item
}

func (a *app) onUpdate(_ context.Context, updates tg.UpdatesClass) error {
	switch box := updates.(type) {
	case *tg.Updates:
		a.book.absorb(box.Users, box.Chats)
		for _, update := range box.Updates {
			a.forward(update)
		}
	case *tg.UpdatesCombined:
		a.book.absorb(box.Users, box.Chats)
		for _, update := range box.Updates {
			a.forward(update)
		}
	case *tg.UpdateShort:
		a.forward(box.Update)
	}
	return nil
}

func (a *app) forward(update tg.UpdateClass) {
	msg, ok := messageFromUpdate(update)
	if !ok || msg.Out {
		return
	}
	payload := a.messageJSON(msg, chatJSON{})
	if payload.FromMe || payload.SkipWebhook || a.inboundURL == "" {
		return
	}
	body, err := jsonMarshal(payload)
	if err != nil {
		return
	}
	req, err := http.NewRequest(http.MethodPost, a.inboundURL, strings.NewReader(string(body)))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Bridge-Token", a.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	_ = resp.Body.Close()
}

func messageFromUpdate(update tg.UpdateClass) (*tg.Message, bool) {
	switch item := update.(type) {
	case *tg.UpdateNewMessage:
		msg, ok := item.Message.(*tg.Message)
		return msg, ok
	case *tg.UpdateNewChannelMessage:
		msg, ok := item.Message.(*tg.Message)
		return msg, ok
	default:
		return nil, false
	}
}

func mentions(selfID int64, username string, msg *tg.Message) bool {
	if msg.Mentioned {
		return true
	}
	for _, entity := range msg.Entities {
		switch item := entity.(type) {
		case *tg.MessageEntityMentionName:
			if item.UserID == selfID {
				return true
			}
		case *tg.MessageEntityMention:
			if username != "" && strings.Contains(strings.ToLower(msg.Message), "@"+strings.ToLower(username)) {
				return true
			}
		}
	}
	return false
}

func muted(settings tg.PeerNotifySettings) bool {
	until, ok := settings.GetMuteUntil()
	return ok && int64(until) > time.Now().Unix()
}

func splitDialogs(box tg.MessagesDialogsClass) ([]tg.DialogClass, []tg.MessageClass, []tg.UserClass, []tg.ChatClass) {
	switch item := box.(type) {
	case *tg.MessagesDialogs:
		return item.Dialogs, item.Messages, item.Users, item.Chats
	case *tg.MessagesDialogsSlice:
		return item.Dialogs, item.Messages, item.Users, item.Chats
	default:
		return nil, nil, nil, nil
	}
}

func splitMessages(box tg.MessagesMessagesClass) ([]tg.MessageClass, []tg.UserClass, []tg.ChatClass) {
	switch item := box.(type) {
	case *tg.MessagesMessages:
		return item.Messages, item.Users, item.Chats
	case *tg.MessagesMessagesSlice:
		return item.Messages, item.Users, item.Chats
	case *tg.MessagesChannelMessages:
		return item.Messages, item.Users, item.Chats
	default:
		return nil, nil, nil
	}
}

func sortChats(chats []chatJSON, sortBy string) {
	if sortBy == "name" {
		for i := 1; i < len(chats); i++ {
			item := chats[i]
			j := i
			for j > 0 && strings.ToLower(chats[j-1].Title) > strings.ToLower(item.Title) {
				chats[j] = chats[j-1]
				j--
			}
			chats[j] = item
		}
		return
	}
	for i := 1; i < len(chats); i++ {
		item := chats[i]
		j := i
		for j > 0 && chatStamp(chats[j-1]) < chatStamp(item) {
			chats[j] = chats[j-1]
			j--
		}
		chats[j] = item
	}
}

func chatStamp(chat chatJSON) string {
	if chat.LastMessage == nil {
		return ""
	}
	return chat.LastMessage.Timestamp
}

func clamp(value, min, max int) int {
	if value < min {
		return min
	}
	if value > max {
		return max
	}
	return value
}

type stringError string

func (e stringError) Error() string { return string(e) }

func errString(message string) error { return stringError(message) }

func jsonMarshal(value any) ([]byte, error) { return json.Marshal(value) }
