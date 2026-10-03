package main

import (
	"testing"
	"time"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	waHistorySync "go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

func TestHistorySyncShouldNotifyOnlyRecentCatchUp(t *testing.T) {
	silent := []waHistorySync.HistorySync_HistorySyncType{
		waHistorySync.HistorySync_INITIAL_BOOTSTRAP,
		waHistorySync.HistorySync_INITIAL_STATUS_V3,
		waHistorySync.HistorySync_FULL,
		waHistorySync.HistorySync_PUSH_NAME,
		waHistorySync.HistorySync_NON_BLOCKING_DATA,
		waHistorySync.HistorySync_ON_DEMAND,
	}
	for _, syncType := range silent {
		if historySyncShouldNotify(syncType, true) {
			t.Fatalf("sync type %s must not notify", syncType)
		}
	}
	if historySyncShouldNotify(waHistorySync.HistorySync_RECENT, false) {
		t.Fatal("RECENT before the initial history is finished must not notify")
	}
	if !historySyncShouldNotify(waHistorySync.HistorySync_RECENT, true) {
		t.Fatal("RECENT after the initial history must notify")
	}
}

func TestClassifyCoversLiveMessageKinds(t *testing.T) {
	own := []string{"393330000000"}
	when := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)

	direct := buildInbound(inboundSource{
		ID: "direct-1", Timestamp: when, ChatJID: "393331111111@s.whatsapp.net",
		SenderJID: "393331111111@s.whatsapp.net", SenderPhone: "393331111111",
		IsGroup: false, Message: &waE2E.Message{Conversation: proto.String("ciao")}, OwnUsers: own,
	})
	if direct == nil || direct.Type != "text" || direct.MentionsOwner || direct.Text != "ciao" {
		t.Fatalf("direct text without an @mention: %#v", direct)
	}

	group := buildInbound(inboundSource{
		ID: "group-1", Timestamp: when, ChatJID: "120363@g.us", IsGroup: true,
		SenderPhone: "393331111111",
		Message:     &waE2E.Message{Conversation: proto.String("ciao")}, OwnUsers: own,
	})
	if group == nil || group.MentionsOwner {
		t.Fatalf("plain group message must not count as a mention: %#v", group)
	}

	mention := buildInbound(inboundSource{
		ID: "group-2", Timestamp: when, ChatJID: "120363@g.us", IsGroup: true,
		SenderPhone: "393331111111",
		Message: &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: proto.String("@Antonio Molinari hey"),
			ContextInfo: &waE2E.ContextInfo{
				MentionedJID: []string{"393330000000@s.whatsapp.net"},
			},
		}},
		OwnUsers: own,
	})
	if mention == nil || !mention.MentionsOwner {
		t.Fatalf("group @mention of the phone jid: %#v", mention)
	}

	lidMention := buildInbound(inboundSource{
		ID: "group-3", Timestamp: when, ChatJID: "120363@g.us", IsGroup: true,
		Message: &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: proto.String("@Antonio Molinari"),
			ContextInfo: &waE2E.ContextInfo{
				MentionedJID: []string{"111222333@lid"},
			},
		}},
		OwnUsers: []string{"393330000000", "111222333"},
	})
	if lidMention == nil || !lidMention.MentionsOwner {
		t.Fatalf("group @mention of the lid: %#v", lidMention)
	}

	quoteOnly := buildInbound(inboundSource{
		ID: "group-4", Timestamp: when, ChatJID: "120363@g.us", IsGroup: true,
		Message: &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: proto.String("reply"),
			ContextInfo: &waE2E.ContextInfo{
				StanzaID:    proto.String("quoted-9"),
				Participant: proto.String("393330000000@s.whatsapp.net"),
			},
		}},
		OwnUsers: own,
	})
	if quoteOnly == nil || quoteOnly.MentionsOwner || quoteOnly.QuotedMessageID != "quoted-9" {
		t.Fatalf("a reply without an @mention is not a mention: %#v", quoteOnly)
	}

	image := buildInbound(inboundSource{
		ID: "media-1", Timestamp: when, ChatJID: "393331111111@s.whatsapp.net",
		Message: &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
			Caption: proto.String("look"), Mimetype: proto.String("image/jpeg"),
		}},
	})
	if image == nil || image.Type != "image" || image.Text != "look" || image.Media == nil || image.Media.Mimetype != "image/jpeg" {
		t.Fatalf("image: %#v", image)
	}

	audio := buildInbound(inboundSource{
		ID: "media-2", Timestamp: when,
		Message: &waE2E.Message{AudioMessage: &waE2E.AudioMessage{Mimetype: proto.String("audio/ogg")}},
	})
	if audio == nil || audio.Type != "audio" || audio.Media == nil || audio.Media.Filename != "audio.ogg" {
		t.Fatalf("audio: %#v", audio)
	}

	ephemeral := buildInbound(inboundSource{
		ID: "eph-1", Timestamp: when,
		Message: &waE2E.Message{EphemeralMessage: &waE2E.FutureProofMessage{
			Message: &waE2E.Message{Conversation: proto.String("vanishes")},
		}},
	})
	if ephemeral == nil || ephemeral.Text != "vanishes" || ephemeral.Type != "text" {
		t.Fatalf("ephemeral: %#v", ephemeral)
	}

	fromMe := buildInbound(inboundSource{
		ID: "me-1", Timestamp: when, IsFromMe: true,
		Message: &waE2E.Message{Conversation: proto.String("embot")},
	})
	if fromMe == nil || !fromMe.IsFromMe {
		t.Fatalf("from me must still be forwarded for the Rails word exception: %#v", fromMe)
	}

	if buildInbound(inboundSource{
		ID: "react-1", Message: &waE2E.Message{ReactionMessage: &waE2E.ReactionMessage{Text: proto.String("👍")}},
	}) != nil {
		t.Fatal("reactions are excluded on purpose")
	}
	if buildInbound(inboundSource{
		ID: "proto-1", Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{}},
	}) != nil {
		t.Fatal("protocol messages are excluded on purpose")
	}
}

func TestNonMessageEventsAreNotInbound(t *testing.T) {
	if inboundEventKind(&events.Receipt{}) != "" {
		t.Fatal("read receipts are not messages")
	}
	if inboundEventKind(&events.UndecryptableMessage{}) != "" {
		t.Fatal("undecryptable messages wait for a later Message retry")
	}
	if inboundEventKind(&events.ChatPresence{}) != "" {
		t.Fatal("typing notifications are not messages")
	}
	if inboundEventKind(&events.Message{}) != "live" {
		t.Fatal("live messages must be forwarded")
	}
	if inboundEventKind(&events.HistorySync{}) != "history" {
		t.Fatal("history sync is the catch-up path")
	}
}

func TestPhoneFromInfoPrefersPhoneOverLID(t *testing.T) {
	info := types.MessageInfo{
		MessageSource: types.MessageSource{
			Chat:      types.JID{User: "120363", Server: types.GroupServer},
			Sender:    types.JID{User: "999lid", Server: types.HiddenUserServer},
			SenderAlt: types.JID{User: "393331111111", Server: types.DefaultUserServer},
			IsGroup:   true,
		},
	}
	if phoneFromInfo(info) != "393331111111" {
		t.Fatalf("phone: %s", phoneFromInfo(info))
	}
}

func inboundEventKind(evt any) string {
	switch evt.(type) {
	case *events.Message:
		return "live"
	case *events.HistorySync:
		return "history"
	default:
		return ""
	}
}
