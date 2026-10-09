// Stateful HTTP fixture for measuring the runtime, without a model dependency.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "80"
	}
	if os.Getenv("PROBE_ROLE") == "echo" {
		log.Fatal(http.ListenAndServe(":"+port, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "echo-from-general") })))
	}
	if _, err := os.Stat("/deleted-in-layer"); !os.IsNotExist(err) {
		log.Fatal("OCI whiteout was not applied")
	}
	if err := os.MkdirAll("/home/probe", 0755); err != nil {
		log.Fatal(err)
	}
	if os.Getenv("OWNERSHIP_PROBE") == "true" {
		if err := os.MkdirAll("/home/probe/foreign", 0755); err != nil {
			log.Fatal(err)
		}
		if err := os.WriteFile("/home/probe/foreign/file", []byte("uid-1000"), 0644); err != nil {
			log.Fatal(err)
		}
		for _, p := range []string{"/home/probe/foreign/file", "/home/probe/foreign"} {
			if err := os.Chown(p, 1000, 1000); err != nil {
				log.Fatal(err)
			}
		}
	}
	var mu sync.Mutex
	var memory int
	http.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "ready") })
	http.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		b, err := os.ReadFile("/proc/self/status")
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		fields := map[string]string{}
		for _, line := range strings.Split(string(b), "\n") {
			if k, v, ok := strings.Cut(line, ":"); ok && (strings.HasPrefix(k, "Cap") || k == "Uid" || k == "Gid" || k == "NoNewPrivs") {
				fields[k] = strings.TrimSpace(v)
			}
		}
		json.NewEncoder(w).Encode(fields)
	})
	http.HandleFunc("/ownership", func(w http.ResponseWriter, r *http.Request) {
		info, err := os.Stat("/home/probe/foreign/file")
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		stat := info.Sys().(*syscall.Stat_t)
		data, err := os.ReadFile("/home/probe/foreign/file")
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"uid": stat.Uid, "gid": stat.Gid, "mode": fmt.Sprintf("%04o", info.Mode().Perm()), "content": string(data)})
	})
	http.HandleFunc("/egress", func(w http.ResponseWriter, r *http.Request) {
		c := &http.Client{Timeout: 10 * time.Second}
		resp, err := c.Get(os.Getenv("EGRESS_URL"))
		if err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, io.LimitReader(resp.Body, 4096))
	})
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		b, err := os.ReadFile("/home/probe/count")
		if err != nil && !os.IsNotExist(err) {
			http.Error(w, err.Error(), 500)
			return
		}
		file, _ := strconv.Atoi(string(b))
		file++
		memory++
		if err := os.WriteFile("/home/probe/count", []byte(strconv.Itoa(file)), 0644); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		json.NewEncoder(w).Encode(map[string]int{"memory": memory, "file": file})
	})
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
