package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/skip2/go-qrcode"
	"go.mau.fi/whatsmeow"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

type SessionStatus struct {
	Connected   bool   `json:"connected"`
	LoggedIn    bool   `json:"logged_in"`
	Pairing     bool   `json:"pairing"`
	JID         string `json:"jid,omitempty"`
	PushName    string `json:"push_name,omitempty"`
	QR          string `json:"qr,omitempty"`
	QRPngBase64 string `json:"qr_png_base64,omitempty"`
	Error       string `json:"error,omitempty"`
}

type Session struct {
	mu        sync.RWMutex
	storeDir  string
	container *sqlstore.Container
	client    *whatsmeow.Client
	messages  *MessageStore
	logger    waLog.Logger
	qr        string
	qrPNG     string
	pairing   bool
	lastError string
}

func NewSession(storeDir string, messages *MessageStore) (*Session, error) {
	if err := os.MkdirAll(storeDir, 0o700); err != nil {
		return nil, err
	}

	logger := waLog.Stdout("WhatsApp", "INFO", true)
	ctx := context.Background()
	container, err := sqlstore.New("sqlite", filepath.Join(storeDir, "whatsapp.db")+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)", waLog.Stdout("Database", "INFO", true))
	if err != nil {
		return nil, fmt.Errorf("open whatsapp session store: %w", err)
	}

	session := &Session{
		storeDir:  storeDir,
		container: container,
		messages:  messages,
		logger:    logger,
	}
	if err := session.start(ctx); err != nil {
		return nil, err
	}
	return session, nil
}

func (s *Session) start(ctx context.Context) error {
	device, err := s.firstDevice()
	if err != nil {
		return err
	}

	client := whatsmeow.NewClient(device, s.logger)
	if client == nil {
		return fmt.Errorf("failed to create WhatsApp client")
	}
	client.AddEventHandler(s.handleEvent)

	s.mu.Lock()
	s.client = client
	s.mu.Unlock()

	if client.Store.ID == nil {
		return s.startPairing(ctx, client)
	}

	s.setPairing("", false, "")
	if err := client.Connect(); err != nil {
		s.setError(err.Error())
		return fmt.Errorf("connect to WhatsApp: %w", err)
	}
	return nil
}

func (s *Session) firstDevice() (*store.Device, error) {
	device, err := s.container.GetFirstDevice()
	if err == nil && device != nil {
		return device, nil
	}
	return s.container.NewDevice(), nil
}

func (s *Session) startPairing(ctx context.Context, client *whatsmeow.Client) error {
	qrChan, err := client.GetQRChannel(ctx)
	if err != nil {
		return fmt.Errorf("get QR channel: %w", err)
	}
	if err := client.Connect(); err != nil {
		return fmt.Errorf("connect to WhatsApp: %w", err)
	}

	s.setPairing("", true, "")
	go func() {
		for evt := range qrChan {
			switch evt.Event {
			case "code":
				png, pngErr := qrcode.Encode(evt.Code, qrcode.Medium, 256)
				encoded := ""
				if pngErr == nil {
					encoded = base64.StdEncoding.EncodeToString(png)
				}
				s.setPairing(evt.Code, true, encoded)
			case "success":
				s.setPairing("", false, "")
			case "timeout":
				s.setError("QR code expired — reconnect from the auth page to get a new code")
			}
		}
	}()
	return nil
}

func (s *Session) Status() SessionStatus {
	s.mu.RLock()
	defer s.mu.RUnlock()

	status := SessionStatus{
		Pairing:     s.pairing,
		QR:          s.qr,
		QRPngBase64: s.qrPNG,
		Error:       s.lastError,
	}
	if s.client != nil {
		status.Connected = s.client.IsConnected()
		if s.client.Store != nil && s.client.Store.ID != nil {
			status.LoggedIn = true
			status.JID = s.client.Store.ID.String()
			status.PushName = s.client.Store.PushName
		}
	}
	return status
}

func (s *Session) Send(recipient, message string) error {
	s.mu.RLock()
	client := s.client
	s.mu.RUnlock()
	if client == nil || !client.IsConnected() {
		return fmt.Errorf("not connected to WhatsApp")
	}
	if strings.TrimSpace(recipient) == "" {
		return fmt.Errorf("recipient is required")
	}
	if strings.TrimSpace(message) == "" {
		return fmt.Errorf("message is required")
	}

	jid, err := parseRecipient(recipient)
	if err != nil {
		return err
	}
	_, err = client.SendMessage(context.Background(), jid, &waE2E.Message{
		Conversation: proto.String(message),
	})
	return err
}

func (s *Session) Logout() error {
	s.mu.Lock()
	client := s.client
	s.client = nil
	s.pairing = false
	s.qr = ""
	s.qrPNG = ""
	s.lastError = ""
	s.mu.Unlock()

	if client != nil {
		if client.IsLoggedIn() {
			_ = client.Logout()
		}
		client.Disconnect()
	}

	_ = os.Remove(filepath.Join(s.storeDir, "whatsapp.db"))
	_ = os.Remove(filepath.Join(s.storeDir, "whatsapp.db-wal"))
	_ = os.Remove(filepath.Join(s.storeDir, "whatsapp.db-shm"))

	ctx := context.Background()
	container, err := sqlstore.New("sqlite", filepath.Join(s.storeDir, "whatsapp.db")+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)", waLog.Stdout("Database", "INFO", true))
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.container = container
	s.mu.Unlock()
	return s.start(ctx)
}

func (s *Session) Close() {
	s.mu.Lock()
	client := s.client
	s.client = nil
	s.mu.Unlock()
	if client != nil {
		client.Disconnect()
	}
}

func (s *Session) handleEvent(evt any) {
	switch v := evt.(type) {
	case *events.Message:
		s.storeIncoming(v)
	case *events.HistorySync:
		s.storeHistory(v)
	case *events.Connected:
		s.setError("")
		s.setPairing("", false, "")
	case *events.LoggedOut:
		s.setError("WhatsApp logged this device out — scan a new QR code")
		s.setPairing("", true, "")
	}
}

func (s *Session) storeIncoming(msg *events.Message) {
	if msg == nil || msg.Message == nil {
		return
	}
	chatJID := msg.Info.Chat.String()
	name := s.chatName(msg.Info.Chat, chatJID, msg.Info.Sender.User)
	_ = s.messages.StoreChat(chatJID, name, msg.Info.Timestamp)
	content := extractText(msg.Message)
	mediaType, filename := extractMediaMeta(msg.Message)
	if err := s.messages.StoreMessage(msg.Info.ID, chatJID, msg.Info.Sender.User, content, msg.Info.Timestamp, msg.Info.IsFromMe, mediaType, filename); err != nil {
		s.logger.Warnf("store message: %v", err)
	}
}

func (s *Session) storeHistory(sync *events.HistorySync) {
	if sync == nil || sync.Data == nil {
		return
	}
	for _, conversation := range sync.Data.GetConversations() {
		chatJID := conversation.GetID()
		if chatJID == "" {
			continue
		}
		jid, err := types.ParseJID(chatJID)
		if err != nil {
			continue
		}
		name := conversation.GetName()
		if name == "" {
			name = conversation.GetDisplayName()
		}
		if name == "" {
			name = s.chatName(jid, chatJID, "")
		}

		messages := conversation.GetMessages()
		if len(messages) == 0 {
			_ = s.messages.StoreChat(chatJID, name, time.Now())
			continue
		}

		var latest time.Time
		for _, wrapped := range messages {
			webMsg := wrapped.GetMessage()
			if webMsg == nil {
				continue
			}
			ts := time.Unix(int64(webMsg.GetMessageTimestamp()), 0)
			if ts.After(latest) {
				latest = ts
			}
			info := webMsg.GetKey()
			if info == nil {
				continue
			}
			content := extractText(webMsg.GetMessage())
			mediaType, filename := extractMediaMeta(webMsg.GetMessage())
			sender := info.GetParticipant()
			if sender == "" {
				sender = info.GetRemoteJID()
			}
			_ = s.messages.StoreMessage(info.GetID(), chatJID, sender, content, ts, info.GetFromMe(), mediaType, filename)
		}
		if latest.IsZero() {
			latest = time.Now()
		}
		_ = s.messages.StoreChat(chatJID, name, latest)
	}
}

func (s *Session) chatName(jid types.JID, chatJID, sender string) string {
	if existing := s.messages.ChatName(chatJID); existing != "" {
		return existing
	}

	s.mu.RLock()
	client := s.client
	s.mu.RUnlock()
	if client == nil {
		if sender != "" {
			return sender
		}
		return jid.User
	}

	if jid.Server == types.GroupServer {
		info, err := client.GetGroupInfo(jid)
		if err == nil && info.Name != "" {
			return info.Name
		}
		return "Group " + jid.User
	}

	contact, err := client.Store.Contacts.GetContact(jid)
	if err == nil && contact.FullName != "" {
		return contact.FullName
	}
	if sender != "" {
		return sender
	}
	return jid.User
}

func (s *Session) setPairing(code string, pairing bool, png string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.qr = code
	s.pairing = pairing
	if png != "" || !pairing {
		s.qrPNG = png
	}
	if pairing {
		s.lastError = ""
	}
}

func (s *Session) setError(message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastError = message
}

func parseRecipient(recipient string) (types.JID, error) {
	if strings.Contains(recipient, "@") {
		return types.ParseJID(recipient)
	}
	cleaned := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, recipient)
	if cleaned == "" {
		return types.JID{}, fmt.Errorf("invalid recipient")
	}
	return types.JID{User: cleaned, Server: types.DefaultUserServer}, nil
}

func extractText(msg *waE2E.Message) string {
	if msg == nil {
		return ""
	}
	if text := msg.GetConversation(); text != "" {
		return text
	}
	if extended := msg.GetExtendedTextMessage(); extended != nil {
		return extended.GetText()
	}
	if img := msg.GetImageMessage(); img != nil {
		return img.GetCaption()
	}
	if vid := msg.GetVideoMessage(); vid != nil {
		return vid.GetCaption()
	}
	if doc := msg.GetDocumentMessage(); doc != nil {
		return doc.GetCaption()
	}
	return ""
}

func extractMediaMeta(msg *waE2E.Message) (string, string) {
	if msg == nil {
		return "", ""
	}
	switch {
	case msg.GetImageMessage() != nil:
		return "image", "image.jpg"
	case msg.GetVideoMessage() != nil:
		return "video", "video.mp4"
	case msg.GetAudioMessage() != nil:
		return "audio", "audio.ogg"
	case msg.GetDocumentMessage() != nil:
		name := msg.GetDocumentMessage().GetFileName()
		if name == "" {
			name = "document"
		}
		return "document", name
	default:
		return "", ""
	}
}
