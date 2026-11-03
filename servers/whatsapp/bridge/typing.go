package main

import (
	"context"
	"sync"
	"time"

	"go.mau.fi/whatsmeow/types"
)

const (
	typingRefresh = 8 * time.Second
	typingFor     = 2 * time.Minute
)

// typingKeeper repeats the standard WhatsApp "composing" chatstate until the
// reply is sent or the wait expires. Clients hide the indicator after about
// ten seconds, so it is refreshed until then.
type typingKeeper struct {
	send     func(types.JID, types.ChatPresence) error
	refresh  time.Duration
	deadline time.Duration

	mu     sync.Mutex
	next   int
	active map[string]*typingSlot
}

type typingSlot struct {
	cancel context.CancelFunc
	gen    int
}

func newTypingKeeper(send func(types.JID, types.ChatPresence) error, refresh, deadline time.Duration) *typingKeeper {
	if refresh <= 0 {
		refresh = typingRefresh
	}
	if deadline <= 0 {
		deadline = typingFor
	}
	return &typingKeeper{
		send:     send,
		refresh:  refresh,
		deadline: deadline,
		active:   map[string]*typingSlot{},
	}
}

func (k *typingKeeper) Start(jid types.JID) error {
	if err := k.send(jid, types.ChatPresenceComposing); err != nil {
		return err
	}

	k.mu.Lock()
	key := jid.String()
	if slot, ok := k.active[key]; ok {
		slot.cancel()
	}
	gen := k.next
	k.next++
	ctx, cancel := context.WithCancel(context.Background())
	k.active[key] = &typingSlot{cancel: cancel, gen: gen}
	k.mu.Unlock()

	go k.keep(ctx, jid, gen)
	return nil
}

// Stop ends the indicator for this chat. paused sends the standard "paused"
// chatstate; a send leaves it false so the outgoing message replaces typing.
// It reports whether a typing loop was still running.
func (k *typingKeeper) Stop(jid types.JID, paused bool) bool {
	stopped := k.take(jid, -1)
	if paused && stopped {
		_ = k.send(jid, types.ChatPresencePaused)
	}
	return stopped
}

func (k *typingKeeper) StopAll() {
	k.mu.Lock()
	defer k.mu.Unlock()
	for key, slot := range k.active {
		slot.cancel()
		delete(k.active, key)
	}
}

func (k *typingKeeper) keep(ctx context.Context, jid types.JID, gen int) {
	ticker := time.NewTicker(k.refresh)
	defer ticker.Stop()
	timer := time.NewTimer(k.deadline)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			if k.take(jid, gen) {
				_ = k.send(jid, types.ChatPresencePaused)
			}
			return
		case <-ticker.C:
			if !k.current(jid, gen) {
				return
			}
			_ = k.send(jid, types.ChatPresenceComposing)
		}
	}
}

func (k *typingKeeper) current(jid types.JID, gen int) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	slot, ok := k.active[jid.String()]
	return ok && slot.gen == gen
}

// take removes the loop. gen < 0 matches whichever loop is current.
func (k *typingKeeper) take(jid types.JID, gen int) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	key := jid.String()
	slot, ok := k.active[key]
	if !ok || (gen >= 0 && slot.gen != gen) {
		return false
	}
	slot.cancel()
	delete(k.active, key)
	return true
}
