package main

import (
	"strconv"
	"strings"
	"sync"

	"github.com/gotd/td/tg"
)

type peerBook struct {
	mu    sync.Mutex
	peers map[int64]tg.InputPeerClass
	chats map[int64]chatJSON
	names map[int64]string
}

func newPeerBook() *peerBook {
	return &peerBook{
		peers: map[int64]tg.InputPeerClass{},
		chats: map[int64]chatJSON{},
		names: map[int64]string{},
	}
}

func (b *peerBook) absorb(users []tg.UserClass, chats []tg.ChatClass) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, raw := range users {
		user, ok := raw.(*tg.User)
		if !ok {
			continue
		}
		name := strings.TrimSpace(user.FirstName + " " + user.LastName)
		b.names[user.ID] = name
		access, _ := user.GetAccessHash()
		b.peers[user.ID] = &tg.InputPeerUser{UserID: user.ID, AccessHash: access}
		b.chats[user.ID] = chatJSON{
			ID:       strconv.FormatInt(user.ID, 10),
			Title:    name,
			Type:     "private",
			Username: user.Username,
		}
	}
	for _, raw := range chats {
		switch chat := raw.(type) {
		case *tg.Chat:
			b.peers[chat.ID] = &tg.InputPeerChat{ChatID: chat.ID}
			b.chats[chat.ID] = chatJSON{ID: strconv.FormatInt(chat.ID, 10), Title: chat.Title, Type: "group"}
		case *tg.Channel:
			access, _ := chat.GetAccessHash()
			b.peers[chat.ID] = &tg.InputPeerChannel{ChannelID: chat.ID, AccessHash: access}
			kind := "channel"
			if chat.Megagroup {
				kind = "group"
			}
			b.chats[chat.ID] = chatJSON{
				ID:       strconv.FormatInt(chat.ID, 10),
				Title:    chat.Title,
				Type:     kind,
				Username: chat.Username,
			}
		}
	}
}

func (b *peerBook) peer(id int64) (tg.InputPeerClass, chatJSON, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	peer, ok := b.peers[id]
	if !ok {
		return nil, chatJSON{}, false
	}
	return peer, b.chats[id], true
}

func (b *peerBook) chatFor(peer tg.PeerClass) chatJSON {
	switch item := peer.(type) {
	case *tg.PeerUser:
		_, chat, ok := b.peer(item.UserID)
		if ok {
			return chat
		}
	case *tg.PeerChat:
		_, chat, ok := b.peer(item.ChatID)
		if ok {
			return chat
		}
	case *tg.PeerChannel:
		_, chat, ok := b.peer(item.ChannelID)
		if ok {
			return chat
		}
	}
	return chatJSON{}
}

func (b *peerBook) chatID(peer tg.PeerClass) string {
	return b.chatFor(peer).ID
}

func (b *peerBook) sender(msg *tg.Message) (string, string) {
	if msg.FromID == nil {
		id := b.chatID(msg.PeerID)
		return id, b.chatFor(msg.PeerID).Title
	}
	switch from := msg.FromID.(type) {
	case *tg.PeerUser:
		_, chat, ok := b.peer(from.UserID)
		if ok {
			return chat.ID, chat.Title
		}
		return strconv.FormatInt(from.UserID, 10), ""
	case *tg.PeerChannel:
		_, chat, ok := b.peer(from.ChannelID)
		if ok {
			return chat.ID, chat.Title
		}
		return strconv.FormatInt(from.ChannelID, 10), ""
	default:
		return "", ""
	}
}
