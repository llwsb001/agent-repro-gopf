package main

import (
	"flag"
	"fmt"
	"net/http"
	"strings"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:18080", "listen address")
	flag.Parse()
	body := strings.Repeat("x", 396)
	big := strings.Repeat("y", 1<<20)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte(body))
	})
	http.HandleFunc("/big", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(big))
	})
	fmt.Println("backend on", *addr)
	http.ListenAndServe(*addr, nil)
}
