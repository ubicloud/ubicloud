// Stands in for an ember's PostgreSQL: a TLS server that answers each request
// with a response of the requested size. Written in Go so it is never the
// bottleneck in a gateway comparison.
package main

import (
	"crypto/tls"
	"encoding/binary"
	"io"
	"log"
	"net"
	"os"
)

func main() {
	addr := os.Args[1]
	// "plain" stands in for an ember whose PostgreSQL has ssl off, with the
	// hop encrypted below PostgreSQL instead.
	plaintext := len(os.Args) > 2 && os.Args[2] == "plain"
	var ln net.Listener
	var err error
	if plaintext {
		ln, err = net.Listen("tcp", addr)
	} else {
		var cert tls.Certificate
		cert, err = tls.LoadX509KeyPair("cert.pem", "key.pem")
		if err != nil {
			log.Fatal(err)
		}
		ln, err = tls.Listen("tcp", addr, &tls.Config{Certificates: []tls.Certificate{cert}})
	}
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("upstream on %s", addr)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go serve(c)
	}
}

// Protocol: client writes a 4-byte big-endian response size, we write that
// many bytes back.
func serve(c net.Conn) {
	defer c.Close()
	buf := make([]byte, 65536)
	var hdr [4]byte
	for {
		if _, err := io.ReadFull(c, hdr[:]); err != nil {
			return
		}
		n := int(binary.BigEndian.Uint32(hdr[:]))
		for n > 0 {
			chunk := len(buf)
			if n < chunk {
				chunk = n
			}
			if _, err := c.Write(buf[:chunk]); err != nil {
				return
			}
			n -= chunk
		}
	}
}
