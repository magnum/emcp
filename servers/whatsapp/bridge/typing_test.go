package main

import (
	"sync"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types"
)

func TestTypingKeeperRefreshesUntilTheReplyWindowEnds(t *testing.T) {
	var mu sync.Mutex
	var states []types.ChatPresence
	keeper := newTypingKeeper(func(_ types.JID, state types.ChatPresence) error {
		mu.Lock()
		states = append(states, state)
		mu.Unlock()
		return nil
	}, 20*time.Millisecond, 55*time.Millisecond)

	jid := types.JID{User: "393331111111", Server: types.DefaultUserServer}
	if err := keeper.Start(jid); err != nil {
		t.Fatal(err)
	}
	time.Sleep(90 * time.Millisecond)

	mu.Lock()
	defer mu.Unlock()
	if len(states) < 3 || states[0] != types.ChatPresenceComposing {
		t.Fatalf("states: %v", states)
	}
	if states[len(states)-1] != types.ChatPresencePaused {
		t.Fatalf("expected paused, got %v", states)
	}
}

func TestTypingKeeperStopForSendDoesNotPause(t *testing.T) {
	var mu sync.Mutex
	var states []types.ChatPresence
	keeper := newTypingKeeper(func(_ types.JID, state types.ChatPresence) error {
		mu.Lock()
		states = append(states, state)
		mu.Unlock()
		return nil
	}, 200*time.Millisecond, time.Second)

	jid := types.JID{User: "393331111111", Server: types.DefaultUserServer}
	if err := keeper.Start(jid); err != nil {
		t.Fatal(err)
	}
	if !keeper.Stop(jid, false) {
		t.Fatal("expected an active typing loop")
	}
	time.Sleep(40 * time.Millisecond)

	mu.Lock()
	defer mu.Unlock()
	for _, state := range states {
		if state == types.ChatPresencePaused {
			t.Fatalf("send should replace typing, got %v", states)
		}
	}
	if len(states) != 1 || states[0] != types.ChatPresenceComposing {
		t.Fatalf("states: %v", states)
	}
}
