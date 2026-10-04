package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/auth"
	"github.com/gotd/td/tg"
	"github.com/gotd/td/tgerr"
)

type app struct {
	apiID      int
	apiHash    string
	phone      string
	token      string
	inboundURL string
	store      *encryptedStorage

	mu       sync.Mutex
	client   *telegram.Client
	api      *tg.Client
	selfID   int64
	username string
	name     string
	step     string
	errText  string
	ready    bool
	book     *peerBook

	codeCh chan string
	passCh chan string
}

func main() {
	application, err := newApp()
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	listen := getenv("TELEGRAM_LISTEN", "127.0.0.1:0")
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("TELEGRAM_URL_FILE"), []byte("http://"+listener.Addr().String()), 0o644); err != nil {
		log.Fatal(err)
	}

	server := &http.Server{Handler: application.routes()}
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("http: %v", err)
		}
	}()

	go func() {
		if err := application.run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("telegram: %v", err)
			application.fail(err)
		}
	}()

	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdown)
}

func newApp() (*app, error) {
	apiID, err := strconv.Atoi(strings.TrimSpace(os.Getenv("TELEGRAM_API_ID")))
	if err != nil || apiID == 0 {
		return nil, errors.New("TELEGRAM_API_ID is required")
	}
	apiHash := strings.TrimSpace(os.Getenv("TELEGRAM_API_HASH"))
	if apiHash == "" {
		return nil, errors.New("TELEGRAM_API_HASH is required")
	}
	key, err := decodeKey(os.Getenv("TELEGRAM_SESSION_KEY"))
	if err != nil {
		return nil, err
	}
	dir := os.Getenv("TELEGRAM_STORE_DIR")
	if dir == "" {
		return nil, errors.New("TELEGRAM_STORE_DIR is required")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &app{
		apiID:      apiID,
		apiHash:    apiHash,
		phone:      digits(os.Getenv("TELEGRAM_PHONE")),
		token:      os.Getenv("TELEGRAM_BRIDGE_TOKEN"),
		inboundURL: os.Getenv("TELEGRAM_INBOUND_URL"),
		store:      &encryptedStorage{path: dir + "/session.bin", key: key},
		step:       "connecting",
		book:       newPeerBook(),
		codeCh:     make(chan string, 1),
		passCh:     make(chan string, 1),
	}, nil
}

func (a *app) run(ctx context.Context) error {
	client := telegram.NewClient(a.apiID, a.apiHash, telegram.Options{
		SessionStorage: a.store,
		UpdateHandler:  telegram.UpdateHandlerFunc(a.onUpdate),
	})
	return client.Run(ctx, func(ctx context.Context) error {
		a.mu.Lock()
		a.client = client
		a.api = client.API()
		a.mu.Unlock()

		flow := auth.NewFlow(a, auth.SendCodeOptions{})
		if err := client.Auth().IfNecessary(ctx, flow); err != nil {
			a.fail(err)
			<-ctx.Done()
			return ctx.Err()
		}
		status, err := client.Auth().Status(ctx)
		if err != nil {
			a.fail(err)
			<-ctx.Done()
			return ctx.Err()
		}
		a.markReady(status.User)
		<-ctx.Done()
		return ctx.Err()
	})
}

func (a *app) Phone(context.Context) (string, error) {
	if a.phone == "" {
		return "", errors.New("TELEGRAM_PHONE is required")
	}
	return a.phone, nil
}

func (a *app) Password(context.Context) (string, error) {
	a.setStep("password")
	select {
	case password := <-a.passCh:
		return password, nil
	case <-time.After(10 * time.Minute):
		return "", errors.New("timed out waiting for the cloud password")
	}
}

func (a *app) AcceptTermsOfService(context.Context, tg.HelpTermsOfService) error {
	return &auth.SignUpRequired{TermsOfService: tg.HelpTermsOfService{}}
}

func (a *app) SignUp(context.Context) (auth.UserInfo, error) {
	return auth.UserInfo{}, errors.New("this phone is not registered on Telegram")
}

func (a *app) Code(context.Context, *tg.AuthSentCode) (string, error) {
	a.setStep("code")
	select {
	case code := <-a.codeCh:
		return digits(code), nil
	case <-time.After(10 * time.Minute):
		return "", errors.New("timed out waiting for the login code")
	}
}

func (a *app) setStep(step string) {
	a.mu.Lock()
	a.step = step
	a.errText = ""
	a.mu.Unlock()
}

func (a *app) fail(err error) {
	a.mu.Lock()
	a.step = "error"
	a.ready = false
	a.errText = err.Error()
	a.mu.Unlock()
}

func (a *app) markReady(user *tg.User) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.ready = true
	a.step = "ready"
	a.errText = ""
	if user == nil {
		return
	}
	a.selfID = user.ID
	a.username = user.Username
	a.name = strings.TrimSpace(user.FirstName + " " + user.LastName)
	if user.Phone != "" {
		a.phone = user.Phone
	}
}

func (a *app) snapshot() map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	body := map[string]any{
		"connected": a.api != nil,
		"logged_in": a.ready,
		"auth_step": a.step,
		"user_id":   "",
		"username":  a.username,
		"name":      a.name,
		"phone":     a.phone,
		"error":     a.errText,
	}
	if a.selfID != 0 {
		body["user_id"] = strconv.FormatInt(a.selfID, 10)
	}
	return body
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})
	mux.HandleFunc("GET /api/status", a.authed(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, a.snapshot())
	}))
	mux.HandleFunc("POST /api/auth/code", a.authed(a.submitCode))
	mux.HandleFunc("POST /api/auth/password", a.authed(a.submitPassword))
	mux.HandleFunc("POST /api/logout", a.authed(a.logout))
	mux.HandleFunc("GET /api/contacts", a.authed(a.searchContacts))
	mux.HandleFunc("GET /api/chats", a.authed(a.listChats))
	mux.HandleFunc("GET /api/chat", a.authed(a.getChat))
	mux.HandleFunc("GET /api/messages", a.authed(a.listMessages))
	mux.HandleFunc("GET /api/message_context", a.authed(a.messageContext))
	mux.HandleFunc("GET /api/last_interaction", a.authed(a.lastInteraction))
	mux.HandleFunc("GET /api/unread", a.authed(a.listUnread))
	mux.HandleFunc("POST /api/send", a.authed(a.sendMessage))
	return mux
}

func (a *app) authed(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if subtleString(r.Header.Get("X-Bridge-Token"), a.token) == false {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "invalid bridge token"})
			return
		}
		next(w, r)
	}
}

func (a *app) submitCode(w http.ResponseWriter, r *http.Request) {
	code := strings.TrimSpace(r.URL.Query().Get("code"))
	if code == "" {
		var body struct {
			Code string `json:"code"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		code = strings.TrimSpace(body.Code)
	}
	if code == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "code is required"})
		return
	}
	select {
	case a.codeCh <- code:
		writeJSON(w, http.StatusOK, a.snapshot())
	default:
		writeJSON(w, http.StatusConflict, map[string]any{"error": "not waiting for a login code"})
	}
}

func (a *app) submitPassword(w http.ResponseWriter, r *http.Request) {
	password := r.URL.Query().Get("password")
	if password == "" {
		var body struct {
			Password string `json:"password"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		password = body.Password
	}
	if password == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "password is required"})
		return
	}
	select {
	case a.passCh <- password:
		writeJSON(w, http.StatusOK, a.snapshot())
	default:
		writeJSON(w, http.StatusConflict, map[string]any{"error": "not waiting for a cloud password"})
	}
}

func (a *app) logout(w http.ResponseWriter, r *http.Request) {
	api := a.tg()
	if api != nil {
		_, _ = api.AuthLogOut(r.Context())
	}
	_ = os.Remove(a.store.path)
	a.mu.Lock()
	a.ready = false
	a.step = "connecting"
	a.selfID = 0
	a.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *app) tg() *tg.Client {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.api
}

func (a *app) requireAPI(w http.ResponseWriter) (*tg.Client, bool) {
	api := a.tg()
	a.mu.Lock()
	ready := a.ready
	a.mu.Unlock()
	if api == nil || !ready {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "Telegram is not linked yet"})
		return nil, false
	}
	return api, true
}

func (a *app) call(ctx context.Context, fn func() error) error {
	var last error
	for attempt := 0; attempt < 4; attempt++ {
		err := fn()
		if err == nil {
			return nil
		}
		wait, ok := tgerr.AsFloodWait(err)
		if !ok {
			return err
		}
		last = err
		if attempt == 3 || wait > 30*time.Second {
			return &floodError{wait: wait, cause: err}
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	return last
}

type floodError struct {
	wait  time.Duration
	cause error
}

func (e *floodError) Error() string { return e.cause.Error() }

func writeError(w http.ResponseWriter, err error) {
	var flood *floodError
	if errors.As(err, &flood) {
		writeJSON(w, http.StatusTooManyRequests, map[string]any{
			"error":              flood.Error(),
			"flood_wait_seconds": int(flood.wait.Seconds()),
		})
		return
	}
	if d, ok := tgerr.AsFloodWait(err); ok {
		writeJSON(w, http.StatusTooManyRequests, map[string]any{
			"error":              err.Error(),
			"flood_wait_seconds": int(d.Seconds()),
		})
		return
	}
	writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func subtleString(left, right string) bool {
	if len(left) != len(right) || left == "" {
		return false
	}
	var diff byte
	for i := range left {
		diff |= left[i] ^ right[i]
	}
	return diff == 0
}

func getenv(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func digits(value string) string {
	var b strings.Builder
	for _, r := range value {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func randomID() (int64, error) {
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return 0, err
	}
	return int64(binary.BigEndian.Uint64(buf[:]) & 0x7fffffffffffffff), nil
}

func rfc3339(unix int) string {
	if unix <= 0 {
		return ""
	}
	return time.Unix(int64(unix), 0).UTC().Format(time.RFC3339)
}

func atoi(value string, fallback int) int {
	n, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return fallback
	}
	return n
}

func fmtID(id int64) string { return fmt.Sprintf("%d", id) }
