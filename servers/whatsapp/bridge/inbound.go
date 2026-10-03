package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	waHistorySync "go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/types"
)

// inboundMessage is the bridge → Rails notification. Rails decides whether to
// call the operator webhook. Message text is not written to the bridge log.
type inboundMessage struct {
	MessageID       string        `json:"message_id"`
	Timestamp       string        `json:"timestamp"`
	ChatJID         string        `json:"chat_jid"`
	ChatName        string        `json:"chat_name,omitempty"`
	IsGroup         bool          `json:"is_group"`
	SenderJID       string        `json:"sender_jid,omitempty"`
	SenderPhone     string        `json:"sender_phone,omitempty"`
	SenderName      string        `json:"sender_name,omitempty"`
	IsFromMe        bool          `json:"is_from_me"`
	SkipWebhook     bool          `json:"skip_webhook,omitempty"`
	Type            string        `json:"type"`
	Text            string        `json:"text,omitempty"`
	QuotedMessageID string        `json:"quoted_message_id,omitempty"`
	MentionsOwner   bool          `json:"mentions_owner"`
	Media           *inboundMedia `json:"media,omitempty"`
}

type inboundMedia struct {
	Mimetype string `json:"mimetype,omitempty"`
	Filename string `json:"filename,omitempty"`
}

type inboundSource struct {
	ID          string
	Timestamp   time.Time
	ChatJID     string
	ChatName    string
	SenderJID   string
	SenderPhone string
	SenderName  string
	IsFromMe    bool
	IsGroup     bool
	Message     *waE2E.Message
	OwnUsers    []string
}

// historySyncShouldNotify is true only for catch-up blobs after the first
// connection has already stored the initial history. INITIAL_BOOTSTRAP, FULL,
// and the non-message sync types are never forwarded.
func historySyncShouldNotify(syncType waHistorySync.HistorySync_HistorySyncType, ready bool) bool {
	return ready && syncType == waHistorySync.HistorySync_RECENT
}

func historyReadyPath(storeDir string) string {
	return filepath.Join(storeDir, "inbound_history_ready")
}

func historyReadyFileExists(storeDir string) bool {
	_, err := os.Stat(historyReadyPath(storeDir))
	return err == nil
}

func writeHistoryReadyFile(storeDir string) {
	_ = os.WriteFile(historyReadyPath(storeDir), []byte("1\n"), 0o600)
}

func buildInbound(src inboundSource) *inboundMessage {
	msg := unwrapE2E(src.Message)
	if msg == nil || src.ID == "" {
		return nil
	}
	if skippedMessage(msg) {
		return nil
	}

	kind, text, media := classifyContent(msg)
	if kind == "" {
		return nil
	}

	quoted, mentioned, _ := contextFields(msg)
	mentions := mentionsOwner(mentioned, src.OwnUsers)

	payload := &inboundMessage{
		MessageID:       src.ID,
		Timestamp:       src.Timestamp.UTC().Format(time.RFC3339),
		ChatJID:         src.ChatJID,
		ChatName:        src.ChatName,
		IsGroup:         src.IsGroup,
		SenderJID:       src.SenderJID,
		SenderPhone:     digits(src.SenderPhone),
		SenderName:      src.SenderName,
		IsFromMe:        src.IsFromMe,
		Type:            kind,
		Text:            text,
		QuotedMessageID: quoted,
		MentionsOwner:   mentions,
		Media:           media,
	}
	return payload
}

func skippedMessage(msg *waE2E.Message) bool {
	switch {
	case msg.GetReactionMessage() != nil,
		msg.GetEncReactionMessage() != nil,
		msg.GetProtocolMessage() != nil,
		msg.GetSenderKeyDistributionMessage() != nil,
		msg.GetFastRatchetKeySenderKeyDistributionMessage() != nil,
		msg.GetPollUpdateMessage() != nil,
		msg.GetKeepInChatMessage() != nil,
		msg.GetPinInChatMessage() != nil,
		msg.GetPlaceholderMessage() != nil:
		return true
	default:
		return false
	}
}

func classifyContent(msg *waE2E.Message) (string, string, *inboundMedia) {
	if text := msg.GetConversation(); text != "" {
		return "text", text, nil
	}
	if extended := msg.GetExtendedTextMessage(); extended != nil {
		return "text", extended.GetText(), nil
	}
	if img := msg.GetImageMessage(); img != nil {
		return "image", img.GetCaption(), &inboundMedia{Mimetype: img.GetMimetype(), Filename: "image.jpg"}
	}
	if vid := msg.GetVideoMessage(); vid != nil {
		return "video", vid.GetCaption(), &inboundMedia{Mimetype: vid.GetMimetype(), Filename: "video.mp4"}
	}
	if audio := msg.GetAudioMessage(); audio != nil {
		return "audio", "", &inboundMedia{Mimetype: firstNonEmpty(audio.GetMimetype(), "audio/ogg"), Filename: "audio.ogg"}
	}
	if doc := msg.GetDocumentMessage(); doc != nil {
		name := doc.GetFileName()
		if name == "" {
			name = "document"
		}
		return "document", doc.GetCaption(), &inboundMedia{Mimetype: doc.GetMimetype(), Filename: name}
	}
	if sticker := msg.GetStickerMessage(); sticker != nil {
		return "sticker", "", &inboundMedia{Mimetype: firstNonEmpty(sticker.GetMimetype(), "image/webp"), Filename: "sticker.webp"}
	}
	if loc := msg.GetLocationMessage(); loc != nil {
		text := loc.GetName()
		if text == "" {
			text = loc.GetAddress()
		}
		return "location", text, nil
	}
	if contact := msg.GetContactMessage(); contact != nil {
		return "contact", contact.GetDisplayName(), nil
	}
	if poll := msg.GetPollCreationMessage(); poll != nil {
		return "poll", poll.GetName(), nil
	}
	if poll := msg.GetPollCreationMessageV2(); poll != nil {
		return "poll", poll.GetName(), nil
	}
	if poll := msg.GetPollCreationMessageV3(); poll != nil {
		return "poll", poll.GetName(), nil
	}
	return "", "", nil
}

func contextFields(msg *waE2E.Message) (quoted string, mentioned []string, participant string) {
	info := contextInfo(msg)
	if info == nil {
		return "", nil, ""
	}
	return info.GetStanzaID(), info.GetMentionedJID(), info.GetParticipant()
}

func contextInfo(msg *waE2E.Message) *waE2E.ContextInfo {
	switch {
	case msg.GetExtendedTextMessage() != nil:
		return msg.GetExtendedTextMessage().GetContextInfo()
	case msg.GetImageMessage() != nil:
		return msg.GetImageMessage().GetContextInfo()
	case msg.GetVideoMessage() != nil:
		return msg.GetVideoMessage().GetContextInfo()
	case msg.GetAudioMessage() != nil:
		return msg.GetAudioMessage().GetContextInfo()
	case msg.GetDocumentMessage() != nil:
		return msg.GetDocumentMessage().GetContextInfo()
	case msg.GetStickerMessage() != nil:
		return msg.GetStickerMessage().GetContextInfo()
	case msg.GetLocationMessage() != nil:
		return msg.GetLocationMessage().GetContextInfo()
	case msg.GetContactMessage() != nil:
		return msg.GetContactMessage().GetContextInfo()
	default:
		return nil
	}
}

func mentionsOwner(mentioned []string, own []string) bool {
	for _, jid := range mentioned {
		if jidMatchesOwn(jid, own) {
			return true
		}
	}
	return false
}

func jidMatchesOwn(raw string, own []string) bool {
	user := jidUser(raw)
	if user == "" {
		return false
	}
	for _, candidate := range own {
		if candidate != "" && (candidate == user || candidate == raw) {
			return true
		}
	}
	return false
}

func jidUser(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if i := strings.Index(raw, "@"); i >= 0 {
		raw = raw[:i]
	}
	if i := strings.Index(raw, ":"); i >= 0 {
		raw = raw[:i]
	}
	return raw
}

func unwrapE2E(msg *waE2E.Message) *waE2E.Message {
	if msg == nil {
		return nil
	}
	wrappers := []*waE2E.Message{
		msg.GetEphemeralMessage().GetMessage(),
		msg.GetViewOnceMessage().GetMessage(),
		msg.GetViewOnceMessageV2().GetMessage(),
		msg.GetViewOnceMessageV2Extension().GetMessage(),
		msg.GetDocumentWithCaptionMessage().GetMessage(),
		msg.GetEditedMessage().GetMessage(),
		msg.GetDeviceSentMessage().GetMessage(),
		msg.GetLottieStickerMessage().GetMessage(),
	}
	for _, inner := range wrappers {
		if inner != nil {
			return unwrapE2E(inner)
		}
	}
	return msg
}

func phoneFromInfo(info types.MessageInfo) string {
	if info.SenderAlt.Server == types.DefaultUserServer && info.SenderAlt.User != "" {
		return info.SenderAlt.User
	}
	if info.Chat.Server == types.DefaultUserServer && !info.IsGroup && info.Chat.User != "" {
		return info.Chat.User
	}
	if info.Sender.Server == types.DefaultUserServer && info.Sender.User != "" {
		return info.Sender.User
	}
	return jidUser(info.Sender.User)
}

func digits(value string) string {
	return strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, value)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func groupJID(jid string) bool {
	return strings.HasSuffix(jid, "@"+types.GroupServer)
}

type inboundNotifier struct {
	url    string
	token  string
	client *http.Client
}

func newInboundNotifier(url, token string) *inboundNotifier {
	url = strings.TrimSpace(url)
	if url == "" {
		return nil
	}
	return &inboundNotifier{
		url:   url,
		token: token,
		client: &http.Client{
			Timeout: 5 * time.Second,
		},
	}
}

func (n *inboundNotifier) Notify(payload inboundMessage) {
	if n == nil || n.url == "" || payload.MessageID == "" {
		return
	}
	go n.postWithRetry(payload)
}

func (n *inboundNotifier) postWithRetry(payload inboundMessage) {
	var last error
	for attempt := 1; attempt <= 3; attempt++ {
		err := n.postOnce(payload)
		if err == nil {
			return
		}
		last = err
		if attempt < 3 {
			time.Sleep(time.Duration(attempt) * time.Second)
		}
	}
	log.Printf("inbound notify failed message_id=%s: %v", payload.MessageID, last)
}

func (n *inboundNotifier) postOnce(payload inboundMessage) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost, n.url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Bridge-Token", n.token)
	resp, err := n.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 500 {
		return &inboundStatusError{code: resp.StatusCode}
	}
	if resp.StatusCode >= 400 {
		log.Printf("inbound notify rejected message_id=%s status=%d", payload.MessageID, resp.StatusCode)
		return nil
	}
	return nil
}

type inboundStatusError struct {
	code int
}

func (e *inboundStatusError) Error() string {
	return "inbound status " + strconv.Itoa(e.code)
}
