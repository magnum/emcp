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

	_ "github.com/mattn/go-sqlite3"
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
	mu           sync.RWMutex
	storeDir     string
	container    *sqlstore.Container
	client       *whatsmeow.Client
	messages     *MessageStore
	logger       waLog.Logger
	notifier     *inboundNotifier
	historyReady bool
	qr           string
	qrPNG        string
	pairing      bool
	lastError    string
}

func NewSession(storeDir string, messages *MessageStore, notifier *inboundNotifier) (*Session, error) {
	if err := os.MkdirAll(storeDir, 0o700); err != nil {
		return nil, err
	}

	logger := waLog.Stdout("WhatsApp", "INFO", true)
	ctx := context.Background()
	refreshWAVersion(ctx, logger)
	container, err := sqlstore.New(ctx, "sqlite3", sessionDBDSN(storeDir), waLog.Stdout("Database", "INFO", true))
	if err != nil {
		return nil, fmt.Errorf("open whatsapp session store: %w", err)
	}

	session := &Session{
		storeDir:     storeDir,
		container:    container,
		messages:     messages,
		logger:       logger,
		notifier:     notifier,
		historyReady: historyReadyFileExists(storeDir),
	}
	if err := session.start(ctx); err != nil {
		return nil, err
	}
	return session, nil
}

func (s *Session) start(ctx context.Context) error {
	device, err := s.firstDevice(ctx)
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

func (s *Session) firstDevice(ctx context.Context) (*store.Device, error) {
	device, err := s.container.GetFirstDevice(ctx)
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
	s.setPairing("", true, "")
	s.setError("")

	// Receive QR events before Connect(). whatsmeow drops codes when the
	// channel buffer is full and nobody is listening yet.
	go func() {
		for evt := range qrChan {
			switch evt.Event {
			case "code":
				s.applyPairingCode(evt.Code)
			case "success":
				s.setPairing("", false, "")
			case "timeout":
				s.setPairing("", true, "")
				s.setError("QR code expired — click Start pairing again")
			case "error":
				message := "WhatsApp pairing error"
				if evt.Error != nil {
					message = evt.Error.Error()
				}
				s.failPairing(message)
			case "err-client-outdated":
				s.failPairing("WhatsApp rejected this companion as outdated. Redeploy EmCP so the bridge can use a current WhatsApp Web version.")
			default:
				if strings.HasPrefix(evt.Event, "err-") {
					s.failPairing("WhatsApp pairing failed (" + evt.Event + ")")
					break
				}
				s.logger.Infof("QR channel event: %s", evt.Event)
			}
		}
	}()

	if err := client.Connect(); err != nil {
		return fmt.Errorf("connect to WhatsApp: %w", err)
	}
	return nil
}

func (s *Session) applyPairingCode(code string) {
	if strings.TrimSpace(code) == "" {
		return
	}
	encoded, pngErr := encodeQRPNG(code)
	if pngErr != nil {
		s.logger.Warnf("QR PNG encode failed: %v", pngErr)
		s.setError("Could not render QR image: " + pngErr.Error())
		s.setPairing(code, true, "")
		return
	}
	s.setPairing(code, true, encoded)
	s.setError("")
}

func encodeQRPNG(code string) (string, error) {
	qr, err := qrcode.New(code, qrcode.Low)
	if err != nil {
		return "", err
	}
	png, err := qr.PNG(384)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(png), nil
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
			_ = client.Logout(context.Background())
		}
		client.Disconnect()
	}

	_ = os.Remove(filepath.Join(s.storeDir, "whatsapp.db"))
	_ = os.Remove(filepath.Join(s.storeDir, "whatsapp.db-wal"))
	_ = os.Remove(filepath.Join(s.storeDir, "whatsapp.db-shm"))

	ctx := context.Background()
	container, err := sqlstore.New(ctx, "sqlite3", sessionDBDSN(s.storeDir), waLog.Stdout("Database", "INFO", true))
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
	case *events.QR:
		if len(v.Codes) > 0 {
			s.applyPairingCode(v.Codes[0])
		}
	case *events.Connected:
		s.noteConnected()
		s.setError("")
		// Websocket connect happens during QR pairing too. Only clear the QR
		// after the device is actually linked.
		s.mu.RLock()
		linked := s.client != nil && s.client.Store != nil && s.client.Store.ID != nil
		s.mu.RUnlock()
		if linked {
			s.setPairing("", false, "")
		}
	case *events.OfflineSyncCompleted:
		// The ready file lets the next connection forward RECENT catch-up.
		// This connection keeps the flag it had when it connected, so the
		// initial history blob is stored without calling Rails.
		writeHistoryReadyFile(s.storeDir)
	case *events.LoggedOut:
		s.setError("WhatsApp logged this device out — click Start pairing for a new QR code")
		s.setPairing("", true, "")
	}
}

func (s *Session) noteConnected() {
	s.mu.Lock()
	s.historyReady = historyReadyFileExists(s.storeDir)
	s.mu.Unlock()
}

func (s *Session) catchUpReady() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.historyReady
}

func (s *Session) ownUsers() []string {
	s.mu.RLock()
	client := s.client
	s.mu.RUnlock()
	if client == nil || client.Store == nil {
		return nil
	}
	var users []string
	if client.Store.ID != nil && client.Store.ID.User != "" {
		users = append(users, client.Store.ID.User)
	}
	if client.Store.LID.User != "" {
		users = append(users, client.Store.LID.User)
	}
	return users
}

func (s *Session) storeIncoming(msg *events.Message) {
	if msg == nil || msg.Message == nil {
		return
	}
	chatJID := msg.Info.Chat.String()
	name := s.chatName(msg.Info.Chat, chatJID, msg.Info.Sender.User)
	_ = s.messages.StoreChat(chatJID, name, msg.Info.Timestamp)
	payload := buildInbound(inboundSource{
		ID:          msg.Info.ID,
		Timestamp:   msg.Info.Timestamp,
		ChatJID:     chatJID,
		ChatName:    name,
		SenderJID:   msg.Info.Sender.String(),
		SenderPhone: phoneFromInfo(msg.Info),
		SenderName:  msg.Info.PushName,
		IsFromMe:    msg.Info.IsFromMe,
		IsGroup:     msg.Info.IsGroup,
		Message:     msg.Message,
		OwnUsers:    s.ownUsers(),
	})
	s.persistAndMaybeNotify(payload, msg.Info.Sender.User, msg.Info.Timestamp, true)
}

func (s *Session) storeHistory(sync *events.HistorySync) {
	if sync == nil || sync.Data == nil {
		return
	}
	notify := historySyncShouldNotify(sync.Data.GetSyncType(), s.catchUpReady())
	own := s.ownUsers()
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
			sender := info.GetParticipant()
			if sender == "" {
				sender = info.GetRemoteJID()
			}
			payload := buildInbound(inboundSource{
				ID:          info.GetID(),
				Timestamp:   ts,
				ChatJID:     chatJID,
				ChatName:    name,
				SenderJID:   sender,
				SenderPhone: jidUser(sender),
				SenderName:  webMsg.GetPushName(),
				IsFromMe:    info.GetFromMe(),
				IsGroup:     groupJID(chatJID),
				Message:     webMsg.GetMessage(),
				OwnUsers:    own,
			})
			s.persistAndMaybeNotify(payload, sender, ts, notify)
		}
		if latest.IsZero() {
			latest = time.Now()
		}
		_ = s.messages.StoreChat(chatJID, name, latest)
	}
}

func (s *Session) persistAndMaybeNotify(payload *inboundMessage, sender string, ts time.Time, notify bool) {
	if payload == nil {
		return
	}
	mediaType := ""
	filename := ""
	if payload.Media != nil {
		mediaType = payload.Type
		filename = payload.Media.Filename
	}
	inserted, err := s.messages.StoreMessage(payload.MessageID, payload.ChatJID, sender, payload.Text, ts, payload.IsFromMe, mediaType, filename)
	if err != nil {
		s.logger.Warnf("store message: %v", err)
		return
	}
	if notify && inserted && s.notifier != nil {
		s.notifier.Notify(*payload)
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
		info, err := client.GetGroupInfo(context.Background(), jid)
		if err == nil && info.Name != "" {
			return info.Name
		}
		return "Group " + jid.User
	}

	contact, err := client.Store.Contacts.GetContact(context.Background(), jid)
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
}

func (s *Session) setError(message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastError = message
}

func (s *Session) failPairing(message string) {
	s.setPairing("", false, "")
	s.setError(message)
}

func sessionDBDSN(storeDir string) string {
	return "file:" + filepath.Join(storeDir, "whatsapp.db") + "?_foreign_keys=on&_busy_timeout=5000"
}

func refreshWAVersion(ctx context.Context, logger waLog.Logger) {
	latest, err := whatsmeow.GetLatestVersion(ctx, nil)
	if err != nil {
		logger.Warnf("could not fetch current WhatsApp Web version: %v (using %s)", err, store.GetWAVersion())
		return
	}
	store.SetWAVersion(*latest)
	logger.Infof("using WhatsApp Web version %s", latest.String())
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
