package main

import (
	"context"
	"testing"

	"github.com/gotd/td/tg"
)

func TestChatIDCandidates(t *testing.T) {
	cases := []struct {
		in   string
		want []int64
	}{
		{in: "2525981439", want: []int64{2525981439}},
		{in: "-2525981439", want: []int64{2525981439}},
		{in: "-1002525981439", want: []int64{2525981439, 1002525981439}},
		{in: "+2525981439", want: []int64{2525981439}},
		{in: "@foo"},
		{in: "abc"},
	}
	for _, tc := range cases {
		got := chatIDCandidates(tc.in)
		if len(got) != len(tc.want) {
			t.Fatalf("chatIDCandidates(%q) = %v, want %v", tc.in, got, tc.want)
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Fatalf("chatIDCandidates(%q) = %v, want %v", tc.in, got, tc.want)
			}
		}
	}
}

func TestResolveUsesCachedPeersWithoutAPI(t *testing.T) {
	bridge := &app{book: newPeerBook()}
	bridge.book.absorb(nil, []tg.ChatClass{
		&tg.Channel{ID: 2525981439, Megagroup: true, Title: "pirloverflow"},
		&tg.Chat{ID: 1543634239, Title: "Polenta & Friends"},
	})

	for _, id := range []string{"2525981439", "-2525981439", "-1002525981439", "+2525981439"} {
		_, chat, err := bridge.resolve(context.Background(), nil, id, false)
		if err != nil {
			t.Fatalf("resolve %q: %v", id, err)
		}
		if chat.ID != "2525981439" || chat.Type != "group" {
			t.Fatalf("resolve %q = %+v", id, chat)
		}
	}

	_, chat, err := bridge.resolve(context.Background(), nil, "-1543634239", false)
	if err != nil {
		t.Fatal(err)
	}
	if chat.ID != "1543634239" || chat.Title != "Polenta & Friends" {
		t.Fatalf("group resolve = %+v", chat)
	}

	_, _, err = bridge.resolve(context.Background(), nil, "1000000001", false)
	if err == nil || err.Error() != "chat not found (usa l'id restituito da telegram_list_chats)" {
		t.Fatalf("unknown id error = %v", err)
	}
}

func TestChatsFromKeepsLastMessagePerPeer(t *testing.T) {
	bridge := &app{book: newPeerBook()}
	box := &tg.MessagesDialogs{
		Dialogs: []tg.DialogClass{
			&tg.Dialog{Peer: &tg.PeerChannel{ChannelID: 2525981439}, TopMessage: 7},
			&tg.Dialog{Peer: &tg.PeerChat{ChatID: 1543634239}, TopMessage: 7},
		},
		Messages: []tg.MessageClass{
			&tg.Message{ID: 7, PeerID: &tg.PeerChannel{ChannelID: 2525981439}, Message: "channel text", Date: 1_700_000_000},
			&tg.MessageService{ID: 7, PeerID: &tg.PeerChat{ChatID: 1543634239}, Date: 1_700_000_001, Action: &tg.MessageActionPinMessage{}},
		},
		Chats: []tg.ChatClass{
			&tg.Channel{ID: 2525981439, Megagroup: true, Title: "pirloverflow"},
			&tg.Chat{ID: 1543634239, Title: "Polenta & Friends"},
		},
	}

	chats := bridge.chatsFrom(box)
	if len(chats) != 2 {
		t.Fatalf("chats = %d", len(chats))
	}
	byID := map[string]chatJSON{}
	for _, chat := range chats {
		byID[chat.ID] = chat
	}
	channel := byID["2525981439"]
	if channel.LastMessage == nil || channel.LastMessage.Text != "channel text" {
		t.Fatalf("channel last = %+v", channel.LastMessage)
	}
	group := byID["1543634239"]
	if group.LastMessage == nil || group.LastMessage.Text != "[service: PinMessage]" {
		t.Fatalf("group last = %+v", group.LastMessage)
	}
}
