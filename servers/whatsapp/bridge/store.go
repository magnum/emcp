package main

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Message struct {
	ID        string    `json:"id"`
	Time      time.Time `json:"timestamp"`
	Sender    string    `json:"sender"`
	Content   string    `json:"content"`
	IsFromMe  bool      `json:"is_from_me"`
	ChatJID   string    `json:"chat_jid"`
	ChatName  string    `json:"chat_name,omitempty"`
	MediaType string    `json:"media_type,omitempty"`
	Filename  string    `json:"filename,omitempty"`
}

type Chat struct {
	JID             string     `json:"jid"`
	Name            string     `json:"name,omitempty"`
	LastMessageTime *time.Time `json:"last_message_time,omitempty"`
	LastMessage     string     `json:"last_message,omitempty"`
	LastSender      string     `json:"last_sender,omitempty"`
	LastIsFromMe    *bool      `json:"last_is_from_me,omitempty"`
	IsGroup         bool       `json:"is_group"`
}

type Contact struct {
	PhoneNumber string `json:"phone_number"`
	Name        string `json:"name,omitempty"`
	JID         string `json:"jid"`
}

type MessageStore struct {
	db *sql.DB
}

func NewMessageStore(dir string) (*MessageStore, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create store directory: %w", err)
	}

	db, err := sql.Open("sqlite3", filepath.Join(dir, "messages.db")+"?_foreign_keys=on&_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("open messages database: %w", err)
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS chats (
			jid TEXT PRIMARY KEY,
			name TEXT,
			last_message_time TEXT
		);
		CREATE TABLE IF NOT EXISTS messages (
			id TEXT,
			chat_jid TEXT,
			sender TEXT,
			content TEXT,
			timestamp TEXT,
			is_from_me INTEGER,
			media_type TEXT,
			filename TEXT,
			PRIMARY KEY (id, chat_jid)
		);
		CREATE INDEX IF NOT EXISTS messages_chat_time ON messages (chat_jid, timestamp);
	`)
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("create tables: %w", err)
	}

	return &MessageStore{db: db}, nil
}

func (store *MessageStore) Close() error {
	if store == nil || store.db == nil {
		return nil
	}
	return store.db.Close()
}

func (store *MessageStore) StoreChat(jid, name string, lastMessageTime time.Time) error {
	_, err := store.db.Exec(
		`INSERT INTO chats (jid, name, last_message_time) VALUES (?, ?, ?)
		 ON CONFLICT(jid) DO UPDATE SET
			name = CASE WHEN excluded.name != '' THEN excluded.name ELSE chats.name END,
			last_message_time = CASE
				WHEN excluded.last_message_time > chats.last_message_time OR chats.last_message_time IS NULL
				THEN excluded.last_message_time
				ELSE chats.last_message_time
			END`,
		jid, name, lastMessageTime.UTC().Format(time.RFC3339),
	)
	return err
}

func (store *MessageStore) StoreMessage(id, chatJID, sender, content string, timestamp time.Time, isFromMe bool, mediaType, filename string) error {
	if content == "" && mediaType == "" {
		return nil
	}

	_, err := store.db.Exec(
		`INSERT OR REPLACE INTO messages
			(id, chat_jid, sender, content, timestamp, is_from_me, media_type, filename)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		id, chatJID, sender, content, timestamp.UTC().Format(time.RFC3339), boolToInt(isFromMe), mediaType, filename,
	)
	return err
}

func (store *MessageStore) ChatName(jid string) string {
	var name string
	err := store.db.QueryRow("SELECT name FROM chats WHERE jid = ?", jid).Scan(&name)
	if err != nil {
		return ""
	}
	return name
}

type messageQuery struct {
	After   *time.Time
	Before  *time.Time
	Sender  string
	ChatJID string
	Query   string
	Limit   int
	Offset  int
}

func (store *MessageStore) ListMessages(q messageQuery) ([]Message, error) {
	if q.Limit <= 0 {
		q.Limit = 20
	}
	if q.Limit > 100 {
		q.Limit = 100
	}

	parts := []string{
		`SELECT messages.id, messages.timestamp, messages.sender, messages.content, messages.is_from_me,
			messages.chat_jid, COALESCE(chats.name, ''), messages.media_type, COALESCE(messages.filename, '')
		 FROM messages
		 JOIN chats ON messages.chat_jid = chats.jid`,
	}
	where := []string{}
	args := []any{}

	if q.After != nil {
		where = append(where, "messages.timestamp > ?")
		args = append(args, q.After.UTC().Format(time.RFC3339))
	}
	if q.Before != nil {
		where = append(where, "messages.timestamp < ?")
		args = append(args, q.Before.UTC().Format(time.RFC3339))
	}
	if q.Sender != "" {
		where = append(where, "messages.sender = ?")
		args = append(args, q.Sender)
	}
	if q.ChatJID != "" {
		where = append(where, "messages.chat_jid = ?")
		args = append(args, q.ChatJID)
	}
	if q.Query != "" {
		where = append(where, "LOWER(messages.content) LIKE LOWER(?)")
		args = append(args, "%"+q.Query+"%")
	}
	if len(where) > 0 {
		parts = append(parts, "WHERE "+strings.Join(where, " AND "))
	}
	parts = append(parts, "ORDER BY messages.timestamp DESC LIMIT ? OFFSET ?")
	args = append(args, q.Limit, q.Offset)

	rows, err := store.db.Query(strings.Join(parts, " "), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []Message
	for rows.Next() {
		msg, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		messages = append(messages, msg)
	}
	if messages == nil {
		messages = []Message{}
	}
	return messages, rows.Err()
}

func (store *MessageStore) MessageContext(id string, before, after int) (map[string]any, error) {
	if before < 0 {
		before = 0
	}
	if after < 0 {
		after = 0
	}
	if before > 50 {
		before = 50
	}
	if after > 50 {
		after = 50
	}

	row := store.db.QueryRow(
		`SELECT messages.id, messages.timestamp, messages.sender, messages.content, messages.is_from_me,
			messages.chat_jid, COALESCE(chats.name, ''), messages.media_type, COALESCE(messages.filename, '')
		 FROM messages
		 JOIN chats ON messages.chat_jid = chats.jid
		 WHERE messages.id = ?
		 LIMIT 1`,
		id,
	)
	target, err := scanMessage(row)
	if err != nil {
		return nil, err
	}

	beforeMsgs, err := store.messagesAround(target.ChatJID, target.Time, before, true)
	if err != nil {
		return nil, err
	}
	afterMsgs, err := store.messagesAround(target.ChatJID, target.Time, after, false)
	if err != nil {
		return nil, err
	}

	return map[string]any{
		"message": target,
		"before":  beforeMsgs,
		"after":   afterMsgs,
	}, nil
}

func (store *MessageStore) messagesAround(chatJID string, ts time.Time, limit int, older bool) ([]Message, error) {
	if limit == 0 {
		return []Message{}, nil
	}

	cmp := ">"
	order := "ASC"
	if older {
		cmp = "<"
		order = "DESC"
	}

	rows, err := store.db.Query(
		`SELECT messages.id, messages.timestamp, messages.sender, messages.content, messages.is_from_me,
			messages.chat_jid, COALESCE(chats.name, ''), messages.media_type, COALESCE(messages.filename, '')
		 FROM messages
		 JOIN chats ON messages.chat_jid = chats.jid
		 WHERE messages.chat_jid = ? AND messages.timestamp `+cmp+` ?
		 ORDER BY messages.timestamp `+order+`
		 LIMIT ?`,
		chatJID, ts.UTC().Format(time.RFC3339), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []Message
	for rows.Next() {
		msg, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		messages = append(messages, msg)
	}
	if older {
		for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
			messages[i], messages[j] = messages[j], messages[i]
		}
	}
	if messages == nil {
		messages = []Message{}
	}
	return messages, rows.Err()
}

func (store *MessageStore) ListChats(query string, limit, offset int, sortBy string) ([]Chat, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	order := "chats.last_message_time DESC"
	if sortBy == "name" {
		order = "chats.name COLLATE NOCASE ASC"
	}

	sqlText := `
		SELECT chats.jid, COALESCE(chats.name, ''), chats.last_message_time,
			COALESCE(messages.content, ''), COALESCE(messages.sender, ''), messages.is_from_me
		FROM chats
		LEFT JOIN messages ON chats.jid = messages.chat_jid AND chats.last_message_time = messages.timestamp
	`
	args := []any{}
	if query != "" {
		sqlText += " WHERE (LOWER(chats.name) LIKE LOWER(?) OR chats.jid LIKE ?)"
		pattern := "%" + query + "%"
		args = append(args, pattern, pattern)
	}
	sqlText += " ORDER BY " + order + " LIMIT ? OFFSET ?"
	args = append(args, limit, offset)

	rows, err := store.db.Query(sqlText, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	chats := []Chat{}
	for rows.Next() {
		chat, err := scanChat(rows)
		if err != nil {
			return nil, err
		}
		chats = append(chats, chat)
	}
	return chats, rows.Err()
}

func (store *MessageStore) GetChat(jid string) (*Chat, error) {
	row := store.db.QueryRow(
		`SELECT chats.jid, COALESCE(chats.name, ''), chats.last_message_time,
			COALESCE(messages.content, ''), COALESCE(messages.sender, ''), messages.is_from_me
		 FROM chats
		 LEFT JOIN messages ON chats.jid = messages.chat_jid AND chats.last_message_time = messages.timestamp
		 WHERE chats.jid = ?`,
		jid,
	)
	chat, err := scanChat(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &chat, nil
}

func (store *MessageStore) DirectChat(phone string) (*Chat, error) {
	row := store.db.QueryRow(
		`SELECT chats.jid, COALESCE(chats.name, ''), chats.last_message_time,
			COALESCE(messages.content, ''), COALESCE(messages.sender, ''), messages.is_from_me
		 FROM chats
		 LEFT JOIN messages ON chats.jid = messages.chat_jid AND chats.last_message_time = messages.timestamp
		 WHERE chats.jid LIKE ? AND chats.jid NOT LIKE '%@g.us'
		 LIMIT 1`,
		"%"+phone+"%",
	)
	chat, err := scanChat(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &chat, nil
}

func (store *MessageStore) ContactChats(jid string, limit, offset int) ([]Chat, error) {
	if limit <= 0 {
		limit = 20
	}
	rows, err := store.db.Query(
		`SELECT DISTINCT chats.jid, COALESCE(chats.name, ''), chats.last_message_time,
			COALESCE(last.content, ''), COALESCE(last.sender, ''), last.is_from_me
		 FROM chats
		 JOIN messages ON chats.jid = messages.chat_jid
		 LEFT JOIN messages last ON chats.jid = last.chat_jid AND chats.last_message_time = last.timestamp
		 WHERE messages.sender = ? OR chats.jid = ?
		 ORDER BY chats.last_message_time DESC
		 LIMIT ? OFFSET ?`,
		jid, jid, limit, offset,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	chats := []Chat{}
	for rows.Next() {
		chat, err := scanChat(rows)
		if err != nil {
			return nil, err
		}
		chats = append(chats, chat)
	}
	return chats, rows.Err()
}

func (store *MessageStore) LastInteraction(jid string) (*Message, error) {
	row := store.db.QueryRow(
		`SELECT messages.id, messages.timestamp, messages.sender, messages.content, messages.is_from_me,
			messages.chat_jid, COALESCE(chats.name, ''), messages.media_type, COALESCE(messages.filename, '')
		 FROM messages
		 JOIN chats ON messages.chat_jid = chats.jid
		 WHERE messages.sender = ? OR chats.jid = ?
		 ORDER BY messages.timestamp DESC
		 LIMIT 1`,
		jid, jid,
	)
	msg, err := scanMessage(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &msg, nil
}

func (store *MessageStore) SearchContacts(query string) ([]Contact, error) {
	pattern := "%" + query + "%"
	rows, err := store.db.Query(
		`SELECT DISTINCT jid, COALESCE(name, '')
		 FROM chats
		 WHERE (LOWER(name) LIKE LOWER(?) OR LOWER(jid) LIKE LOWER(?))
			AND jid NOT LIKE '%@g.us'
		 ORDER BY name, jid
		 LIMIT 50`,
		pattern, pattern,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	contacts := []Contact{}
	for rows.Next() {
		var jid, name string
		if err := rows.Scan(&jid, &name); err != nil {
			return nil, err
		}
		phone := jid
		if at := strings.Index(jid, "@"); at >= 0 {
			phone = jid[:at]
		}
		contacts = append(contacts, Contact{PhoneNumber: phone, Name: name, JID: jid})
	}
	return contacts, rows.Err()
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanMessage(row rowScanner) (Message, error) {
	var (
		msg       Message
		timestamp string
		fromMe    int
		mediaType sql.NullString
	)
	err := row.Scan(&msg.ID, &timestamp, &msg.Sender, &msg.Content, &fromMe, &msg.ChatJID, &msg.ChatName, &mediaType, &msg.Filename)
	if err != nil {
		return Message{}, err
	}
	msg.Time, _ = time.Parse(time.RFC3339, timestamp)
	msg.IsFromMe = fromMe == 1
	if mediaType.Valid {
		msg.MediaType = mediaType.String
	}
	return msg, nil
}

func scanChat(row rowScanner) (Chat, error) {
	var jid, name, lastTime, lastMessage, lastSender string
	var lastFromMe sql.NullInt64
	if err := row.Scan(&jid, &name, &lastTime, &lastMessage, &lastSender, &lastFromMe); err != nil {
		return Chat{}, err
	}
	return buildChat(jid, name, lastTime, lastMessage, lastSender, lastFromMe), nil
}

func buildChat(jid, name, lastTime, lastMessage, lastSender string, lastFromMe sql.NullInt64) Chat {
	chat := Chat{
		JID:         jid,
		Name:        name,
		LastMessage: lastMessage,
		LastSender:  lastSender,
		IsGroup:     strings.HasSuffix(jid, "@g.us"),
	}
	if lastTime != "" {
		if ts, err := time.Parse(time.RFC3339, lastTime); err == nil {
			chat.LastMessageTime = &ts
		}
	}
	if lastFromMe.Valid {
		value := lastFromMe.Int64 == 1
		chat.LastIsFromMe = &value
	}
	return chat
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
