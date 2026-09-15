// WhatsApp Web companion HTTP bridge for EmCP.
// Based on https://github.com/lharries/whatsapp-mcp (MIT) and whatsmeow.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func main() {
	storeDir := envOr("WHATSAPP_STORE_DIR", "store")
	listen := envOr("WHATSAPP_LISTEN", "127.0.0.1:8080")
	urlFile := os.Getenv("WHATSAPP_URL_FILE")
	token := os.Getenv("WHATSAPP_BRIDGE_TOKEN")

	messages, err := NewMessageStore(storeDir)
	if err != nil {
		log.Fatalf("message store: %v", err)
	}
	defer messages.Close()

	session, err := NewSession(storeDir, messages)
	if err != nil {
		log.Fatalf("whatsapp session: %v", err)
	}
	defer session.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})
	mux.Handle("/api/status", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		status := session.Status()
		writeJSON(w, http.StatusOK, status)
	})))
	mux.Handle("/api/logout", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if err := session.Logout(); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"success": false, "message": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": "logged out"})
	})))
	mux.Handle("/api/send", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Recipient string `json:"recipient"`
			Message   string `json:"message"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		if err := session.Send(req.Recipient, req.Message); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"success": false, "message": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": "Message sent to " + req.Recipient})
	})))
	mux.Handle("/api/chats", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		limit, offset := pageParams(r, 20)
		chats, err := messages.ListChats(r.URL.Query().Get("query"), limit, offset, r.URL.Query().Get("sort_by"))
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, chats)
	})))
	mux.Handle("/api/chat", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jid := r.URL.Query().Get("jid")
		if jid == "" {
			http.Error(w, "jid is required", http.StatusBadRequest)
			return
		}
		chat, err := messages.GetChat(jid)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		if chat == nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"error": "chat not found"})
			return
		}
		writeJSON(w, http.StatusOK, chat)
	})))
	mux.Handle("/api/direct_chat", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		phone := r.URL.Query().Get("phone")
		if phone == "" {
			http.Error(w, "phone is required", http.StatusBadRequest)
			return
		}
		chat, err := messages.DirectChat(phone)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		if chat == nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"error": "chat not found"})
			return
		}
		writeJSON(w, http.StatusOK, chat)
	})))
	mux.Handle("/api/contact_chats", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jid := r.URL.Query().Get("jid")
		if jid == "" {
			http.Error(w, "jid is required", http.StatusBadRequest)
			return
		}
		limit, offset := pageParams(r, 20)
		chats, err := messages.ContactChats(jid, limit, offset)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, chats)
	})))
	mux.Handle("/api/contacts", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query().Get("query")
		if query == "" {
			http.Error(w, "query is required", http.StatusBadRequest)
			return
		}
		contacts, err := messages.SearchContacts(query)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, contacts)
	})))
	mux.Handle("/api/messages", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		limit, offset := pageParams(r, 20)
		q := messageQuery{Limit: limit, Offset: offset, Sender: r.URL.Query().Get("sender"), ChatJID: r.URL.Query().Get("chat_jid"), Query: r.URL.Query().Get("query")}
		if value := r.URL.Query().Get("after"); value != "" {
			ts, err := time.Parse(time.RFC3339, value)
			if err != nil {
				http.Error(w, "after must be RFC3339", http.StatusBadRequest)
				return
			}
			q.After = &ts
		}
		if value := r.URL.Query().Get("before"); value != "" {
			ts, err := time.Parse(time.RFC3339, value)
			if err != nil {
				http.Error(w, "before must be RFC3339", http.StatusBadRequest)
				return
			}
			q.Before = &ts
		}
		msgs, err := messages.ListMessages(q)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, msgs)
	})))
	mux.Handle("/api/message_context", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("message_id")
		if id == "" {
			http.Error(w, "message_id is required", http.StatusBadRequest)
			return
		}
		before, _ := strconv.Atoi(r.URL.Query().Get("before"))
		after, _ := strconv.Atoi(r.URL.Query().Get("after"))
		if before == 0 {
			before = 5
		}
		if after == 0 {
			after = 5
		}
		payload, err := messages.MessageContext(id, before, after)
		if err != nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, payload)
	})))
	mux.Handle("/api/last_interaction", requireToken(token, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jid := r.URL.Query().Get("jid")
		if jid == "" {
			http.Error(w, "jid is required", http.StatusBadRequest)
			return
		}
		msg, err := messages.LastInteraction(jid)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		if msg == nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"error": "no messages"})
			return
		}
		writeJSON(w, http.StatusOK, msg)
	})))

	listener, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("listen %s: %v", listen, err)
	}
	actual := "http://" + listener.Addr().String()
	if urlFile != "" {
		if err := os.WriteFile(urlFile, []byte(actual+"\n"), 0o600); err != nil {
			log.Fatalf("write url file: %v", err)
		}
	}
	log.Printf("WhatsApp bridge listening on %s (store %s)", actual, storeDir)

	server := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
			log.Fatalf("http server: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	_ = server.Close()
}

func requireToken(token string, next http.Handler) http.Handler {
	if token == "" {
		return next
	}
	expected := []byte(token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("X-Bridge-Token"))
		if len(got) == 0 {
			header := r.Header.Get("Authorization")
			if len(header) > 7 && header[:7] == "Bearer " {
				got = []byte(header[7:])
			}
		}
		if len(got) != len(expected) || subtle.ConstantTimeCompare(got, expected) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func pageParams(r *http.Request, defaultLimit int) (int, int) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	if limit <= 0 {
		limit = defaultLimit
	}
	if page < 0 {
		page = 0
	}
	return limit, page * limit
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
