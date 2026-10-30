package main

import (
	"context"
	"github.com/redis/go-redis/v9"
	"log"
	"luma/backend/internal/auth"
	"luma/backend/internal/config"
	"luma/backend/internal/conversation"
	"luma/backend/internal/database"
	"luma/backend/internal/device"
	"luma/backend/internal/file"
	"luma/backend/internal/friend"
	"luma/backend/internal/message"
	"luma/backend/internal/middleware"
	"luma/backend/internal/presence"
	"luma/backend/internal/sync"
	"luma/backend/internal/user"
	"luma/backend/internal/useridindex"
	ws "luma/backend/internal/websocket"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	migrateOnly := len(os.Args) == 2 && os.Args[1] == "migrate"
	if len(os.Args) != 1 && !migrateOnly {
		log.Fatal("usage: luma [migrate]")
	}
	cfg, e := config.Load()
	if e != nil {
		log.Fatal(e)
	}
	userIDIndexKey, e := useridindex.ParseKey(cfg.UserIDHMACSecret)
	if e != nil {
		log.Fatal(e)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	db, e := database.Open(ctx, cfg.DatabaseURL)
	if e != nil {
		// Driver errors may echo connection strings. Never place credentials in logs.
		log.Fatal("database unavailable; check DATABASE_URL and PostgreSQL")
	}
	defer db.Close()
	if migrateOnly || cfg.AutoMigrate {
		if e = database.Migrate(ctx, db, cfg.MigrationsDir); e != nil {
			log.Fatal("database migration failed; inspect schema and migration files")
		}
		e = userIDIndexKey.Backfill(ctx, db)
	} else {
		if e = database.VerifySchema(ctx, db, cfg.MigrationsDir); e != nil {
			log.Fatal("database schema incompatible; run the matching migration job before API startup")
		}
		if e = database.VerifyRuntimeRole(ctx, db); e != nil {
			log.Fatal("unsafe API database role; use the reviewed runtime grants")
		}
		e = userIDIndexKey.Verify(ctx, db)
	}
	if e != nil {
		log.Fatal("UserID HMAC index unavailable; check secret continuity and database migration")
	}
	if migrateOnly {
		log.Print("database migration and UserID index verification completed")
		return
	}
	opt, e := redis.ParseURL(cfg.RedisURL)
	if e != nil {
		log.Fatal("invalid REDIS_URL")
	}
	cache := redis.NewClient(opt)
	defer cache.Close()
	if e = cache.Ping(ctx).Err(); e != nil {
		log.Fatal("redis unavailable")
	}
	files, e := file.New(cfg, db)
	if e != nil {
		log.Fatal(e)
	}
	if e = files.Reconcile(ctx); e != nil {
		log.Print("file reconciliation failed")
	}
	go func() {
		ticker := time.NewTicker(10 * time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if err := files.Reconcile(ctx); err != nil {
					log.Print("file reconciliation failed")
				}
			}
		}
	}()
	authSvc := auth.Service{DB: db, Cache: cache, UserIDIndexKey: userIDIndexKey}
	userSvc := user.Service{DB: db, UserIDIndexKey: userIDIndexKey}
	deviceSvc := device.Service{DB: db}
	friendSvc := friend.Service{DB: db, UserIDIndexKey: userIDIndexKey}
	convSvc := conversation.Service{DB: db}
	syncSvc := sync.Service{DB: db}
	hub := ws.New(db, cache)
	deviceSvc.Notify = hub
	messageSvc := message.Service{DB: db, Notify: hub}
	presenceSvc := presence.Service{DB: db, Redis: cache, Notify: hub}
	mux := http.NewServeMux()
	public := func(pattern string, h http.HandlerFunc, max int) {
		mux.Handle(pattern, middleware.Limit(cache, pattern, max, time.Minute, cfg.TrustedProxyIP, h))
	}
	private := func(pattern string, h http.HandlerFunc, max int) {
		mux.Handle(pattern, authSvc.Require(middleware.Limit(cache, pattern, max, time.Minute, cfg.TrustedProxyIP, h)))
	}
	public("POST /v1/auth/register/challenge", authSvc.Challenge, 10)
	public("POST /v1/auth/register", authSvc.Register, 5)
	public("POST /v1/auth/challenge", authSvc.Challenge, 20)
	public("POST /v1/auth/token", authSvc.Token, 20)
	public("POST /v1/auth/refresh", authSvc.Refresh, 30)
	private("POST /v1/auth/revoke", authSvc.Revoke, 30)
	private("GET /v1/users/me", userSvc.Me, 120)
	private("PATCH /v1/users/me", userSvc.Me, 30)
	private("GET /v1/users/search", userSvc.Search, 15)
	private("GET /v1/devices", deviceSvc.List, 60)
	private("POST /v1/devices/authorize/challenge", deviceSvc.AuthorizeChallenge, 10)
	private("POST /v1/devices/authorize", deviceSvc.Authorize, 10)
	private("DELETE /v1/devices/{id}", deviceSvc.Revoke, 10)
	private("PUT /v1/devices/{id}/v4-prekeys", deviceSvc.PutV4Prekeys, 10)
	private("GET /v1/devices/{id}/v4-prekeys/status", deviceSvc.V4PrekeyStatus, 30)
	private("GET /v1/users/{id}/v4-prekey-bundle", deviceSvc.V4Bundle, 30)
	private("POST /v1/friend/request", friendSvc.Request, 10)
	private("GET /v1/friends", friendSvc.List, 60)
	private("GET /v1/friend/requests", friendSvc.Requests, 60)
	private("POST /v1/friend/accept", friendSvc.Decide, 30)
	private("POST /v1/friend/reject", friendSvc.Decide, 30)
	private("DELETE /v1/friend/{id}", friendSvc.Remove, 30)
	private("POST /v1/friend/block", friendSvc.Block, 30)
	private("POST /v1/conversations", convSvc.Create, 30)
	private("GET /v1/conversations", convSvc.List, 60)
	private("POST /v1/messages", messageSvc.Send, 60)
	private("POST /v1/messages/delivered", messageSvc.Delivered, 60)
	private("POST /v1/messages/v4/events", messageSvc.V4Event, 60)
	private("POST /v1/sessions/controls", messageSvc.SessionControl, 120)
	private("GET /v1/sync/events", syncSvc.Events, 120)
	private("POST /v1/sync/ack", syncSvc.Ack, 120)
	private("POST /v1/files/upload/init", files.Init, 30)
	private("POST /v1/files/upload/complete", files.Complete, 30)
	private("PUT /v1/files/{id}/upload", files.Upload, 30)
	private("GET /v1/files/{id}/content", files.Content, 60)
	private("GET /v1/files/{id}/download", files.Download, 60)
	private("DELETE /v1/files/{id}", files.Delete, 30)
	private("PUT /v1/presence/heartbeat", presenceSvc.Heartbeat, 120)
	private("GET /v1/presence/{userID}", presenceSvc.Get, 60)
	private("GET /v1/ws", hub.Serve, 30)
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		middleware.JSON(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /ready", func(w http.ResponseWriter, r *http.Request) {
		checkCtx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if db.Ping(checkCtx) != nil || cache.Ping(checkCtx).Err() != nil || files.CheckStorage(checkCtx) != nil {
			middleware.JSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"})
			return
		}
		middleware.JSON(w, 200, map[string]string{"status": "ok"})
	})
	server := &http.Server{Addr: cfg.Addr, Handler: middleware.RequestID(mux), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	go func() {
		if cfg.TLSCert != "" {
			e = server.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey)
		} else {
			e = server.ListenAndServe()
		}
		if e != nil && e != http.ErrServerClosed {
			log.Printf("server stopped: %v", e)
			stop()
		}
	}()
	log.Printf("Luma backend listening on %s", cfg.Addr)
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdown)
}
