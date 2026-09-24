// Gateway under test, Go version: terminate the client's TLS, open a second
// TLS session upstream, splice both ways. SNI parsing and the PostgreSQL
// SSLRequest preamble are omitted deliberately: they cost the same in both
// implementations and are not what distinguishes them.
package main

import (
	"crypto/tls"
	"io"
	"log"
	"net"
	"os"
)

func main() {
	listen, upstream := os.Args[1], os.Args[2]
	// "plain" measures the cost of the design option where the gateway
	// terminates only the client's TLS and the hop to the ember is
	// encrypted below PostgreSQL.
	plaintextUpstream := len(os.Args) > 3 && os.Args[3] == "plain"
	cert, err := tls.LoadX509KeyPair("cert.pem", "key.pem")
	if err != nil {
		log.Fatal(err)
	}
	ln, err := tls.Listen("tcp", listen, &tls.Config{Certificates: []tls.Certificate{cert}})
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("go gateway on %s -> %s", listen, upstream)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go handle(c, upstream, plaintextUpstream)
	}
}

func handle(client net.Conn, upstream string, plaintextUpstream bool) {
	defer client.Close()
	var server net.Conn
	var err error
	if plaintextUpstream {
		server, err = net.Dial("tcp", upstream)
	} else {
		server, err = tls.Dial("tcp", upstream, &tls.Config{InsecureSkipVerify: true})
	}
	if err != nil {
		return
	}
	defer server.Close()
	done := make(chan struct{}, 2)
	go func() { io.Copy(server, client); done <- struct{}{} }()
	go func() { io.Copy(client, server); done <- struct{}{} }()
	<-done
}
